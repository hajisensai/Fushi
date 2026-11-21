import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'test_flow/dist_breaker.dart';
import 'test_flow/dist_console.dart';
import 'test_flow/dist_coverage.dart';
import 'test_flow/dist_plan.dart';
import 'test_flow/dist_results.dart';
import 'test_flow/dist_snapshot.dart';
import 'test_flow/dist_stop.dart';
import 'test_flow/dist_workers.dart';
import 'test_flow/flutter_test_failure_filter.dart';
import 'test_flow/heavy_lease.dart' show heavyStateDir;
import 'test_flow/heavy_offload_rival.dart'
    show DistOffloadTally, HeavyOffloadClaim;
import 'test_flow/suite_timings.dart';

/// Runs the unit tests spread over several machines.
///
///   cd fushi
///   dart tool/dist_test.dart                     # all of test/
///   dart tool/dist_test.dart test/reader         # a subtree / files
///   dart tool/dist_test.dart --workers=self-mac  # a subset of workers
///   dart tool/dist_test.dart --status            # who is reachable
///   dart tool/dist_test.dart --dry-run           # show what would run where
///   dart tool/dist_test.dart --itest             # the desktop integration
///                                                # tests of dist_itests.json
///   dart tool/dist_test.dart --analyze [paths]   # flutter analyze on another
///                                                # machine
///   dart tool/dist_test.dart --offload [paths]   # the other machines, and
///                                                # this one as their peer
///                                                # while a heavy slot here
///                                                # is free (--no-local: not)
///   dart tool/dist_test.dart --package=packages/fushi_engine [paths]
///                                                # a workspace package's tests
///                                                # (pure Dart ones: dart test)
///   dart tool/dist_test.dart --coverage [--coverage-out=lcov.info]
///                                                # lcov merged from every batch
///   dart tool/dist_test.dart --build -- flutter build apk --release
///   dart tool/dist_test.dart --build -- gradlew :app:assembleRelease
///                                                # compile check on another
///                                                # machine; only its log and
///                                                # exit code come back
///
/// tool/heavy.dart runs `--offload` / `--analyze` / `--build` by itself for
/// the `flutter test` / `dart test` / `flutter analyze` / compile checks it
/// would otherwise run here (test_flow/heavy_offload.dart); exit code
/// [kDistOffloadDeclined] then means no other machine took any of it.
/// With `--offload-claim=<file>` (heavy.dart, test_flow/heavy_offload_rival.dart)
/// a worker that locked its remote checkout first creates that file
/// exclusively and backs out when heavy.dart admitted the run here first;
/// a run that only found busy / paused / unreachable machines then exits
/// [kDistOffloadBusy] instead, so heavy.dart asks again while it queues.
///
/// Any other `--flag` is passed to every `flutter test` (e.g.
/// `--exclude-tags golden`). Workers: tool/dist_test/workers.local.json.
/// Design: docs/specs/2026-10-24-distributed-unit-tests.md.
///
/// Last stdout line: `DIST TEST VERDICT: PASSED|FAILED - ...`; exit code 0
/// only when green.
///
/// Off this machine (`--offload` / `--analyze` / `--build`, tool/heavy.dart)
/// a run that cannot get going here (bad or missing worker config, no
/// snapshot, an internal error) is no verdict on the code: it exits
/// [kDistOffloadDeclined] with the reason, and heavy.dart runs the command
/// here. Ctrl-C and `--max-minutes=N` stop the workers' remote runs and
/// release their checkouts before exiting (130 / 124).
Future<void> main(List<String> args) async {
  final _Options options = _Options.parse(args);
  _stop.watch(
    deadline: options.maxMinutes > 0
        ? Duration(minutes: options.maxMinutes)
        : null,
  );
  try {
    await _main(options);
  } on Object catch (e, s) {
    if (!options.offMachine) rethrow;
    stderr.writeln('dist_test: internal error: $e\n$s');
    await _stop.stop(
      kDistOffloadDeclined,
      'DIST OFFLOAD: declined after an internal error of dist_test; '
      'stopping the workers',
    );
  }
  await _stop.dispose();
}

/// The claim and the decline code of an off-machine run (`--offload-claim`).
DistOffloadTally _tally = DistOffloadTally(null);

/// The one stopper of this run: Ctrl-C, the deadline and internal errors all
/// end the run through it (test_flow/dist_stop.dart).
final DistStopper _stop = DistStopper();

/// Refuses a run that cannot start: off this machine heavy.dart then runs the
/// command here ([kDistOffloadDeclined]); otherwise a usage error.
Never _refuse(_Options options, String why) {
  stderr.writeln(why);
  if (options.offMachine) {
    stdout.writeln('DIST OFFLOAD: declined: ${why.split('\n').first}');
    exit(kDistOffloadDeclined);
  }
  exit(64);
}

Future<void> _main(_Options options) async {
  if (options.itest && options.flutterArgs.isNotEmpty) {
    _refuse(
      options,
      '--itest takes no flutter test options '
      '(${options.flutterArgs.join(' ')}): each file is one app launch',
    );
  }
  if (<bool>[
        options.itest,
        options.analyze,
        options.build != null,
      ].where((bool b) => b).length >
      1) {
    _refuse(options, '--itest, --analyze and --build each run on their own');
  }
  if (options.buildCommand != null && options.build == null) {
    _refuse(
      options,
      '--build takes `-- flutter build <apk|appbundle|windows|macos> '
      '[--debug|--profile|--release] [--split-per-abi] '
      '[--target-platform=android-...]` or `-- gradlew '
      '<:app:assemble*|:app:bundle*>` (macos --debug only), not: '
      '${options.buildCommand!.join(' ')}',
    );
  }
  if (!isDistPackageDir(options.package) ||
      (options.package != kDistAppPackage &&
          (options.itest || options.analyze || options.build != null))) {
    _refuse(
      options,
      '--package takes packages/<name> and goes with test runs only: '
      '${options.package}',
    );
  }
  if (options.analyze) {
    final List<String> bad = <String>[
      for (final String a in options.flutterArgs)
        if (!kDistAnalyzeOptions.contains(a)) a,
      for (final String p in options.paths)
        if (!isSafeDistAnalyzePath(p)) p,
    ];
    if (bad.isNotEmpty) {
      _refuse(
        options,
        '--analyze takes ${kDistAnalyzeOptions.join(' / ')} and paths under '
        'lib/ test/ tool/ integration_test/ test_driver/ bin/ only: '
        '${bad.join(', ')}',
      );
    }
  }
  if (!hasSharedConsole()) {
    _refuse(
      options,
      'dist_test: this process has no console, so every flutter / git / ssh '
      'it starts would open a window of its own and take the focus. Run it '
      'from a terminal or an agent shell.',
    );
  }
  if (!File('pubspec.yaml').existsSync() || !Directory('test').existsSync()) {
    _refuse(options, 'run from fushi/ (the Flutter app directory)');
  }
  final String repoRoot = Directory.current.parent.absolute.path.replaceAll(
    r'\',
    '/',
  );
  // The package whose test/ this run covers; suite paths stay relative to it.
  final String packageDir = '$repoRoot/${options.package}';
  if (!Directory('$packageDir/test').existsSync()) {
    _refuse(options, '${options.package} has no test/ directory');
  }
  final String runner = distTestRunnerOf(
    File('$packageDir/pubspec.yaml').readAsStringSync(),
  );
  if (options.coverage && (options.itest || runner == 'dart')) {
    _refuse(
      options,
      '--coverage goes with flutter test runs only (not --itest, not a pure '
      'Dart package)',
    );
  }

  final File configFile = File(options.configPath);
  if (!configFile.existsSync()) {
    _refuse(
      options,
      'no worker config at ${options.configPath}; copy '
      'tool/dist_test/workers.example.json there and edit it',
    );
  }
  List<DistWorkerConfig> configs;
  try {
    configs = readDistWorkers(configFile.readAsStringSync());
  } on DistConfigError catch (e) {
    _refuse(options, '${options.configPath}: $e');
  } on FormatException catch (e) {
    _refuse(options, '${options.configPath}: not JSON: ${e.message}');
  }
  if (options.workers != null) {
    final Set<String> unknown = options.workers!.difference(
      configs.map((DistWorkerConfig c) => c.name).toSet(),
    );
    if (unknown.isNotEmpty) {
      _refuse(options, 'unknown worker(s): ${unknown.join(', ')}');
    }
    configs = <DistWorkerConfig>[
      for (final DistWorkerConfig c in configs)
        if (options.workers!.contains(c.name)) c,
    ];
  }
  // Off this machine: the other machines are the workers, and for tests this
  // one joins them as a peer ([fallback] below; never for analyze or a
  // build: heavy.dart then runs it here itself).
  final DistJob? job = options.analyze
      ? const DistJob.analyze()
      : (options.build == null ? null : DistJob.build(options.build!));
  final bool offMachine = options.offload || job != null;
  final List<DistWorker> workers = <DistWorker>[
    for (final DistWorkerConfig c in configs)
      if ((!offMachine || c.kind != DistWorkerKind.local) &&
          (options.build?.runsOn(c.platform) ?? true))
        ...createDistWorkers(c, repoRoot: repoRoot),
  ];
  // This machine's worker in an offloaded test run: driven alongside the
  // others from the start (it queues for a heavy slot here like any heavy
  // run, and leaves that queue once the others did it all or none of them
  // is left to share with), then once more for whatever is still left.
  final List<DistWorker> fallback = <DistWorker>[
    if (options.offload && job == null && !options.noLocal)
      for (final DistWorkerConfig c in configs)
        if (c.kind == DistWorkerKind.local)
          ...createDistWorkers(c, repoRoot: repoRoot),
  ];
  _stop.register(<DistWorker>[...workers, ...fallback]);
  final String? claimPath = options.offloadClaim;
  if (offMachine && claimPath != null) {
    _tally = DistOffloadTally(HeavyOffloadClaim(claimPath));
    for (final DistWorker w in workers) {
      w.onLocked = _tally.locked;
    }
  }
  if (workers.isEmpty) {
    if (offMachine) {
      stdout.writeln('DIST OFFLOAD: no other machine is configured');
      exit(kDistOffloadDeclined);
    }
    _refuse(options, 'no workers selected');
  }

  if (options.status) {
    await Future.wait(<Future<void>>[
      for (final DistWorker w in workers)
        w.status().then((String s) {
          final DistBreakerEntry? held = _breaker.held(w.breakerKey);
          stdout.writeln(
            '${w.name}: $s'
            '${held == null ? '' : ' [left out of offloaded runs until ${_clock(held.until)}: ${held.why}]'}',
          );
        }),
    ]);
    return;
  }

  // A machine that just had no connection or no disk is not asked by the
  // runs heavy.dart hands over (dist_breaker.dart); a run started by hand
  // asks every machine it was given.
  if (offMachine) {
    final Set<String> said = <String>{};
    workers.removeWhere((DistWorker w) {
      final DistBreakerEntry? held = _breaker.held(w.breakerKey);
      if (held != null && said.add(w.breakerKey)) {
        stdout.writeln(
          '[${w.breakerKey}] not asked until ${_clock(held.until)}: '
          '${held.why} on its last ${held.fails} ask(s)',
        );
      }
      return held != null;
    });
    if (workers.isEmpty) {
      // For now only: the caller queues here and asks again.
      stdout.writeln(
        'DIST OFFLOAD: every other machine is left out for now '
        '(unreachable / short of disk)',
      );
      exit(_tally.declineCode);
    }
  }
  // Test runs wait in a worker's own queue for its checkout
  // (worker_slot.sh) as long as --busy-retries lets them wait at all. An
  // analyze / compile check goes through the machines one after another:
  // waiting on the first while the second is free would be backwards.
  if (job == null && options.busyRetries > 0) {
    for (final DistWorker w in workers) {
      w.queueWaitSeconds = kDistQueueWaitSeconds;
    }
  }

  if (job != null) {
    final DistSnapshot snapshot = await _snapshot(repoRoot, options);
    final String runId = _runId();
    _stop.runId = runId;
    final Directory out = Directory(
      options.outputDir ?? '../.codex-test/dist/$runId',
    )..createSync(recursive: true);
    exit(
      await _jobOffMachine(
        job,
        workers,
        snapshot: snapshot,
        runId: runId,
        out: out,
        paths: options.paths,
        options: options.flutterArgs,
        busyRetries: options.busyRetries,
      ),
    );
  }

  // ---- plan ----
  final Map<String, int> weights;
  final List<DistUnit> units;
  if (options.itest) {
    final Map<String, Set<DistPlatform>> manifest = _selectItests(
      options.paths,
    );
    weights = <String, int>{
      for (final String p in manifest.keys) p: kDistItestWeightMs,
    };
    units = distItestUnits(manifest);
  } else {
    final Map<String, int> bytes = _discoverSuites(packageDir, options.paths);
    if (bytes.isEmpty) {
      _refuse(options, 'no *_test.dart under ${options.paths.join(', ')}');
    }
    final List<String> unsafe = <String>[
      for (final String p in bytes.keys)
        if (!isSafeDistTestPath(p)) p,
    ];
    if (unsafe.isNotEmpty) {
      _refuse(
        options,
        'test paths outside [A-Za-z0-9_./-] cannot be shipped: '
        '${unsafe.join(', ')}',
      );
    }
    // Measured timings and manual pins exist for the app's suites only; a
    // package's weights come from file sizes.
    final bool app = options.package == kDistAppPackage;
    weights = suiteShardWeights(
      bytes,
      app ? readSuiteTimings(File(kSuiteTimingsPath)) : <String, int>{},
    );
    final Map<String, Set<DistPlatform>> pins = app
        ? readDistAffinity(File(kDistAffinityPath).readAsStringSync())
        : <String, Set<DistPlatform>>{};
    final Map<String, SuiteRequirement> requirements =
        <String, SuiteRequirement>{
          for (final String p in bytes.keys)
            p: applyDistPin(
              scanSuiteRequirement(File('$packageDir/$p').readAsStringSync()),
              pins[p],
            ),
        };
    units = distUnits(weights: weights, requirements: requirements);
  }
  final List<DistUnit> unplaceable = <DistUnit>[
    for (final DistUnit u in units)
      if (!<DistWorker>[
        ...workers,
        ...fallback,
      ].any((DistWorker w) => w.eligible(u)))
        u,
  ];
  if (options.offload &&
      !units.any(
        (DistUnit u) => workers.any((DistWorker w) => w.eligible(u)),
      )) {
    stdout.writeln(
      'DIST OFFLOAD: no other machine may run these suites '
      '(platform / capability pins)',
    );
    exit(kDistOffloadDeclined);
  }
  final DistSuiteQueue queue = DistSuiteQueue(
    units.where((DistUnit u) => !unplaceable.contains(u)),
  );
  _printPlan(units, unplaceable);
  if (options.dryRun) return;

  // ---- snapshot ----
  final DistSnapshot snapshot = await _snapshot(repoRoot, options);

  final String runId = _runId();
  _stop.runId = runId;
  final Directory out = Directory(
    options.outputDir ?? '../.codex-test/dist/$runId',
  )..createSync(recursive: true);
  stdout.writeln('logs: ${out.absolute.path}');

  // ---- run ----
  final Stopwatch wall = Stopwatch()..start();
  final List<DistWorker> everyWorker = <DistWorker>[...workers, ...fallback];
  final _Scheduler scheduler = _Scheduler(
    queue: queue,
    workers: everyWorker,
    package: options.package,
    flutterArgs: options.flutterArgs,
    out: out,
    runId: runId,
    snapshot: snapshot,
    busyRetries: options.busyRetries,
    concurrency: options.concurrency,
  );
  // A coverage batch takes a worker's whole share at once
  // (distChunkBudgetMs): this machine, admitted in a second while the others
  // still push, would take the entire queue and run it alone at
  // --concurrency=1. Coverage keeps it for the leftovers.
  final bool coverage = options.flutterArgs.contains('--coverage');
  scheduler.localIsPeer = !coverage;
  await Future.wait(<Future<void>>[
    for (final DistWorker w in coverage ? workers : everyWorker)
      scheduler.drive(w),
  ]);
  scheduler.localIsPeer = false;
  if (options.offload && scheduler.results.isEmpty) {
    // Nothing ran anywhere else (unreachable, busy, paused): the caller runs
    // the whole command here, in its own form.
    await Future.wait(<Future<void>>[
      for (final DistWorker w in everyWorker) w.finish(runId),
    ]);
    stdout.writeln('DIST OFFLOAD: no other machine took any suite');
    exit(_tally.declineCode);
  }
  // Left over for this machine: suites no other machine ran while it was not
  // driven yet (coverage) or had let go. Never one it was dropped from for
  // failing -- that failure would only repeat.
  final List<DistWorker> idleHere = <DistWorker>[
    for (final DistWorker w in fallback)
      if (!scheduler.isUsable(w) && !scheduler.wasDropped(w)) w,
  ];
  if (queue.remaining.isNotEmpty && idleHere.isNotEmpty) {
    stdout.writeln(
      '${queue.remaining.length} suite(s) left that no other machine ran: '
      'running them here',
    );
    await Future.wait(<Future<void>>[
      for (final DistWorker w in idleHere) scheduler.drive(w),
    ]);
  }
  // Every red suite once more on another machine, for the report only.
  await scheduler.rerunFailures();
  await Future.wait(<Future<void>>[
    for (final DistWorker w in everyWorker) w.finish(runId),
  ]);
  wall.stop();

  final DistRunVerdict verdict = DistRunVerdict(
    results: scheduler.results,
    filtered: distTestFilterActive(options.flutterArgs),
    // Every placement planned, not what the queue still holds: the verdict
    // checks each one against the batches that came back.
    requested: <String>[for (final DistUnit u in units) u.path],
  );
  _writeTimings(out, scheduler.results, weights.keys.toSet());
  if (options.coverage) {
    _writeCoverage(
      scheduler.coverage,
      package: options.package,
      to: File(options.coverageOut ?? '$packageDir/coverage/lcov.info'),
    );
  }
  final String summary =
      renderDistSummary(
        verdict: verdict,
        estimatedMsByBatch: scheduler.weightByBatch,
        wall: wall.elapsed,
        snapshot: snapshot.commit,
      ) +
      renderDistFollowUp(
        reruns: scheduler.reruns,
        notRerun: scheduler.notRerun,
        skips: <DistPlatformSkip>[
          for (final DistBatchResult r in scheduler.results)
            ...platformSkipsOf(r),
        ],
      );
  File('${out.path}/summary.md').writeAsStringSync(summary);
  stdout.writeln(summary);
  for (final DistBatchResult r in verdict.failedBatches) {
    if (r.infraError != null) continue;
    stderr.writeln(
      renderFlutterTestFailureSummary(
        r.summary,
        logPath: '${out.path}/batch-${r.batchId}.${r.worker}.jsonl',
        stderrLogPath: '${out.path}/batch-${r.batchId}.${r.worker}.stderr.log',
      ),
    );
  }
  final String? failure = verdict.failure;
  stdout.writeln(
    failure == null
        ? 'DIST TEST VERDICT: PASSED - ${verdict.suitesRan} of '
              '${verdict.requested.length} suites, '
              '${verdict.testsCompleted} tests ran on '
              '${scheduler.results.map((DistBatchResult r) => r.worker).toSet().length} '
              'worker(s) in ${wall.elapsed.inSeconds}s'
        : 'DIST TEST VERDICT: FAILED - $failure '
              '(tests completed: ${verdict.testsCompleted})',
  );
  await stdout.flush();
  exit(failure == null ? 0 : 1);
}

/// Pull-based and adaptive: every worker prepares, then repeatedly cuts its
/// next batch off the shared queue, sized from its own measured speed
/// ([distChunkBudgetMs]), until nothing it can run is left and nothing in
/// flight could come back.
class _Scheduler {
  _Scheduler({
    required this.queue,
    required List<DistWorker> workers,
    required this.package,
    required this.flutterArgs,
    required this.out,
    required this.runId,
    required this.snapshot,
    this.busyRetries = kBusyRetries,
    this.concurrency,
  }) : _speeds = <DistWorker, DistSpeed>{
         for (final DistWorker w in workers) w: DistSpeed(),
       };

  final DistSuiteQueue queue;

  /// Whose suites these are ([kDistAppPackage] or `packages/<name>`).
  final String package;
  final List<String> flutterArgs;

  /// The caller's cap on test processes per batch (`--concurrency=N`).
  final int? concurrency;

  /// lcov of every batch that ran to the end (`--coverage`), unchecked.
  final List<String> coverage = <String>[];

  bool get _coverage => flutterArgs.contains('--coverage');

  /// Tests are selected by name / tag (dist_results.dart).
  bool get _filtered => distTestFilterActive(flutterArgs);

  /// Three times what [worker]'s own speed predicts, plus slack, plus the
  /// fixed coverage cost of every test process the batch runs as there.
  Duration _batchTimeout(DistWorker worker, DistBatch batch, DistSpeed speed) =>
      Duration(milliseconds: (batch.weightMs * speed.factor * 3).round()) +
      const Duration(minutes: 10) +
      (_coverage
          ? kDistCoverageProcessCost * worker.processCount(batch)
          : Duration.zero);
  final Directory out;
  final String runId;
  final DistSnapshot snapshot;

  /// Busy answers in a row before a worker is dropped ([kBusyRetries]).
  final int busyRetries;
  final List<DistBatchResult> results = <DistBatchResult>[];
  final Map<int, int> weightByBatch = <int, int>{};

  /// Classification re-runs of red suites ([rerunFailures]).
  final List<DistRerun> reruns = <DistRerun>[];
  final List<DistNotRerun> notRerun = <DistNotRerun>[];

  final Map<DistWorker, DistSpeed> _speeds;

  /// Workers that are ready and not dropped: the ones sharing the queue.
  final Set<DistWorker> _live = <DistWorker>{};

  /// Workers that prepared and were never dropped: still usable after the
  /// queue ran dry (for [rerunFailures]).
  final List<DistWorker> _usable = <DistWorker>[];

  /// [worker] prepared and was never dropped ([_usable]).
  bool isUsable(DistWorker worker) => _usable.contains(worker);

  /// Workers dropped for a failed prepare or in the middle of the run (not
  /// the ones let go because nothing was left for them).
  final Set<DistWorker> _dropped = <DistWorker>{};

  /// [worker] was dropped ([_dropped]).
  bool wasDropped(DistWorker worker) => _dropped.contains(worker);

  /// Workers whose prepare is under way.
  final Set<DistWorker> _preparing = <DistWorker>{};

  /// Set by main() while this machine's worker is driven alongside the
  /// others: it then shares their queue. While it still waits for a heavy
  /// slot here and nothing has run anywhere yet, it is only wanted as long
  /// as another machine is preparing or working too: with all of them gone
  /// (busy, unreachable, failed) it leaves the heavy queue and the run
  /// declines, so that heavy.dart -- which queues here and keeps asking the
  /// other machines meanwhile -- takes over. Once something ran it keeps its
  /// place in the queue (the run will not decline any more).
  bool localIsPeer = false;

  static bool _isLocal(DistWorker w) => w.config.kind == DistWorkerKind.local;

  /// Another machine's worker is preparing or working.
  bool get _othersAtIt =>
      _preparing.any((DistWorker w) => !_isLocal(w)) ||
      _live.any((DistWorker w) => !_isLocal(w));

  /// [worker], not yet prepared, is still worth waiting for: something it
  /// may run is left (or a batch in flight could requeue some), and for
  /// this machine's peer worker another machine is still at it.
  bool _wantedWhilePreparing(DistWorker worker) => distWantedWhilePreparing(
    claimLost: _tally.lost,
    batchesInFlight: _inFlight > 0,
    workLeftForIt: queue.remaining.any(worker.eligible),
    localPeer: localIsPeer && _isLocal(worker),
    othersAtIt: _othersAtIt,
    anyResults: results.isNotEmpty,
  );

  /// The units of every batch that ran to the end, by batch id.
  final Map<int, List<DistUnit>> _unitsByBatch = <int, List<DistUnit>>{};

  /// A worker that is busy (owner's memory limit) is asked again after this
  /// long, at most [kBusyRetries] times in a row.
  static const Duration kBusyWait = kDistBusyAskAgain;
  static const int kBusyRetries = 20;

  int _inFlight = 0;
  Completer<void> _changed = Completer<void>();

  void _notify() {
    final Completer<void> done = _changed;
    _changed = Completer<void>();
    done.complete();
  }

  double get _liveSpeedSum => _live.fold<double>(
    0,
    (double s, DistWorker w) => s + 1 / _speeds[w]!.factor,
  );

  Future<void> drive(DistWorker worker) async {
    _preparing.add(worker);
    // Appended: this machine's worker may be driven twice in a run (main()).
    final IOSink prepLog = File(
      '${out.path}/prepare.${worker.name}.log',
    ).openWrite(mode: FileMode.append);
    final Stopwatch prep = Stopwatch()..start();
    try {
      stdout.writeln('[${worker.name}] preparing');
      final bool ready;
      try {
        ready = await _prepareAskingAgain(worker, prepLog);
        // Live before it stops counting as preparing: a peer waiting for a
        // slot here must never see this machine as neither.
        if (ready) _live.add(worker);
      } finally {
        _preparing.remove(worker);
        _notify();
      }
      if (!ready) {
        // The others ran everything this worker could have (a slow first
        // prepare must not hold up a run that is otherwise done) -- or, for
        // this machine's peer still waiting for a slot, no other machine is
        // left to share with ([localIsPeer]).
        final bool alone =
            localIsPeer &&
            _isLocal(worker) &&
            !_othersAtIt &&
            results.isEmpty &&
            queue.remaining.any(worker.eligible);
        stdout.writeln(
          alone
              ? '[${worker.name}] leaves the heavy queue here after '
                    '${prep.elapsed.inSeconds}s: no other machine is at it'
              : '[${worker.name}] not needed: nothing left for it after '
                    '${prep.elapsed.inSeconds}s of preparing',
        );
        await worker.abandon();
        await prepLog.close();
        await worker.finish(runId);
        _notify();
        return;
      }
      stdout.writeln('[${worker.name}] ready after ${prep.elapsed.inSeconds}s');
      _breakerLearns(worker);
    } on Object catch (e) {
      _live.remove(worker);
      _dropped.add(worker);
      // No connection is "for now" like busy: nothing of the run got there.
      if (e is! DistWorkerBusy && e is! DistWorkerUnreachable) {
        _tally.failed(worker);
      }
      _breakerLearns(worker, e);
      stdout.writeln(
        '[${worker.name}] DROPPED: prepare failed: $e '
        '(see prepare.${worker.name}.log)',
      );
      await prepLog.close();
      await worker.finish(runId);
      _notify();
      return;
    }
    await prepLog.close();
    final DistSpeed speed = _speeds[worker]!;

    int infraStreak = 0;
    int busyStreak = 0;
    bool dropped = false;
    while (true) {
      await _stop.holdIfStopping();
      if (worker.resting) {
        // Gave its checkout to a waiting run after the last batch: back in
        // that worker's queue, but only while something is left for it.
        if (!queue.remaining.any(worker.eligible)) {
          if (_inFlight == 0) break;
          await _changed.future;
          continue;
        }
        try {
          if (!await _resume(worker)) continue;
        } on Object catch (e) {
          stdout.writeln(
            '[${worker.name}] DROPPED: did not get its checkout back: $e',
          );
          dropped = true;
          break;
        }
      }
      final DistBatch? batch = queue.take(
        eligible: worker.eligible,
        budgetMs: distChunkBudgetMs(
          remainingEligibleMs: queue.remainingMs(worker.eligible),
          speed: speed,
          liveSpeedSum: _liveSpeedSum,
          coverage: _coverage,
        ),
      );
      if (batch == null) {
        if (_inFlight == 0) break;
        await _changed.future;
        continue;
      }
      _inFlight++;
      weightByBatch[batch.id] = batch.weightMs;
      final String base = '${out.path}/batch-${batch.id}.${worker.name}';
      final IOSink errLog = File('$base.stderr.log').openWrite();
      final Stopwatch sw = Stopwatch()..start();
      DistBatchRun run;
      try {
        run = await worker.run(
          batch,
          package: package,
          flutterArgs: flutterArgs,
          stderrLog: errLog,
          timeout: _batchTimeout(worker, batch, speed),
          concurrencyCap: concurrency,
        );
      } on Object catch (e) {
        run = DistBatchRun(
          exitCode: -1,
          lines: const <String>[],
          infraError: 'could not start: $e',
        );
      }
      sw.stop();
      await errLog.close();
      _inFlight--;
      final String? busy = run.busy;
      if (busy != null) {
        // Turned down before anything ran (worker_shim.sh): the batch goes
        // back whole, and it is neither a failure nor an infrastructure one.
        queue.giveBack(batch);
        weightByBatch.remove(batch.id);
        _notify();
        if (run.paused || ++busyStreak > busyRetries) {
          stdout.writeln('[${worker.name}] DROPPED: $busy');
          dropped = true;
          break;
        }
        stdout.writeln(
          '[${worker.name}] $busy; asking again in ${kBusyWait.inSeconds}s',
        );
        await Future<void>.delayed(kBusyWait);
        continue;
      }
      busyStreak = 0;
      File(
        '$base.jsonl',
      ).writeAsStringSync(run.lines.isEmpty ? '' : '${run.lines.join('\n')}\n');

      if (run.infraError != null && queue.retryAfterInfra(batch)) {
        // Back into the queue for whichever worker asks next. Test failures
        // are never retried (that would hide flaky reds); this is only for
        // runs that did not get a fair chance.
        weightByBatch.remove(batch.id);
        stdout.writeln(
          '[${worker.name}] batch ${batch.id} requeued: '
          '${run.infraError}',
        );
        infraStreak++;
        _notify();
        if (infraStreak >= 2) {
          _tally.failed(worker);
          stdout.writeln(
            '[${worker.name}] DROPPED after two infrastructure '
            'failures in a row',
          );
          dropped = true;
          break;
        }
        continue;
      }
      // A second infrastructure failure of suites that already had their
      // retry is recorded red and blamed on them (a test that hangs every
      // time), not on this worker: it does not count towards dropping it.
      if (run.infraError == null) {
        infraStreak = 0;
        speed.record(wallMs: sw.elapsedMilliseconds, weightMs: batch.weightMs);
      }
      final DistBatchResult result = DistBatchResult(
        batchId: batch.id,
        worker: worker.name,
        files: batch.files,
        exitCode: run.exitCode,
        lines: run.lines,
        elapsed: sw.elapsed,
        infraError: run.infraError,
        filtered: _filtered,
      );
      results.add(result);
      coverage.addAll(run.coverage);
      _unitsByBatch[batch.id] = batch.units;
      final String? failure = result.failure;
      stdout.writeln(
        '[${worker.name}] batch ${batch.id} (${batch.files.length} suites: '
        '${batch.label}): ${result.summary.testsCompleted} tests, '
        '${failure == null ? 'ok' : 'FAILED'} in ${sw.elapsed.inSeconds}s; '
        'speed ${speed.factor.toStringAsFixed(2)} wall/weight, '
        '${queue.remaining.length} suites left',
      );
      _notify();
      // Between two batches the checkout goes to a run that waits for it
      // (worker_slot.sh `yield`); this run queues behind it for its next one.
      await worker.rest(runId);
      if (worker.resting) {
        stdout.writeln(
          '[${worker.name}] gave its checkout to a waiting run; queueing '
          'there again for the next batch',
        );
      }
      if (infraStreak >= 2) {
        stdout.writeln(
          '[${worker.name}] DROPPED after two infrastructure '
          'failures in a row',
        );
        dropped = true;
        break;
      }
    }
    _live.remove(worker);
    if (dropped) {
      _dropped.add(worker);
      await worker.finish(runId);
    } else {
      // Kept prepared (checkout lock / heavy lease) for [rerunFailures];
      // main() finishes every worker afterwards.
      _usable.add(worker);
    }
    _notify();
  }

  /// [_prepareWhileNeeded], asking a worker that turned the run down before
  /// taking anything ([DistWorkerBusy]: its checkout locked by another run,
  /// paused) again [kBusyWait] after that ask began ([distBusyPause]: the
  /// time it waited in the worker's queue counts), at most [busyRetries]
  /// times in a row -- the same patience as for a batch it turns down. False when the others
  /// meanwhile ran everything it could have.
  Future<bool> _prepareAskingAgain(DistWorker worker, IOSink log) async =>
      await distRetryWhileBusy<bool>(
        () async {
          await _stop.holdIfStopping();
          return _prepareWhileNeeded(worker, log);
        },
        retries: busyRetries,
        stillWanted: () => _wantedWhilePreparing(worker),
        // Each answer, not only the last of them: "in use" is the machine
        // answering, short of disk is known at the first one.
        answered: (DistWorkerBusy e) => _breakerLearns(worker, e),
        said: (String l) => stdout.writeln('[${worker.name}] $l'),
      ) ??
      false;

  /// [worker] back on its checkout after [DistWorker.rest]; false when
  /// nothing was left for it by the time its turn came.
  Future<bool> _resume(DistWorker worker) async {
    final IOSink log = File(
      '${out.path}/prepare.${worker.name}.log',
    ).openWrite(mode: FileMode.append);
    final Stopwatch sw = Stopwatch()..start();
    try {
      final bool back = await worker.resume(
        log,
        stillWanted: () => queue.remaining.any(worker.eligible),
      );
      if (back) {
        stdout.writeln(
          '[${worker.name}] has its checkout again after '
          '${sw.elapsed.inSeconds}s',
        );
      }
      return back;
    } finally {
      await log.close();
    }
  }

  /// Prepares [worker]; false as soon as nothing it may run is left in the
  /// queue and no batch is in flight (whose infrastructure failure could
  /// requeue some), i.e. the other workers have done its share. Prepare
  /// errors propagate.
  Future<bool> _prepareWhileNeeded(DistWorker worker, IOSink log) async {
    bool done = false;
    Object? error;
    StackTrace? trace;
    unawaited(
      worker
          .prepare(snapshot, runId, log)
          .then(
            (_) {
              done = true;
              _notify();
            },
            onError: (Object e, StackTrace s) {
              error = e;
              trace = s;
              _notify();
            },
          ),
    );
    // The caller's machine may admit the run while this worker still waits
    // in its queue (--offload-claim): looked at every two seconds, so the
    // place there is given up at once instead of after the wait.
    final Timer? poll = _tally.claim == null
        ? null
        : Timer.periodic(const Duration(seconds: 2), (_) => _notify());
    try {
      while (true) {
        if (error != null) Error.throwWithStackTrace(error!, trace!);
        if (done) return true;
        if (!_wantedWhilePreparing(worker)) return false;
        await _changed.future;
      }
    } finally {
      poll?.cancel();
    }
  }

  /// Re-runs every red suite once, alone, on a worker of another machine
  /// that may run it (§4 of the spec): red there too is a real red, green
  /// there leaves a machine-local suspect. For the report only; the verdict
  /// comes from the first run. Each worker runs its re-runs one at a time.
  Future<void> rerunFailures() async {
    final List<({DistUnit unit, String redOn, String redMachine})> red =
        <({DistUnit unit, String redOn, String redMachine})>[];
    final Map<String, String> machineOf = <String, String>{
      for (final DistWorker w in _speeds.keys) w.name: w.machine,
    };
    for (final DistBatchResult r in results) {
      final List<DistUnit> units = _unitsByBatch[r.batchId] ?? <DistUnit>[];
      for (final String path in failedSuitesOf(r)) {
        for (final DistUnit u in units) {
          if (u.path == path) {
            red.add((
              unit: u,
              redOn: r.worker,
              redMachine: machineOf[r.worker]!,
            ));
          }
        }
      }
    }
    if (red.isEmpty) return;
    if (red.length > kDistMaxReruns) {
      for (final ({DistUnit unit, String redOn, String redMachine}) r in red) {
        notRerun.add((
          path: r.unit.path,
          redOn: r.redOn,
          why: '${red.length} red suites (re-runs only up to $kDistMaxReruns)',
        ));
      }
      return;
    }
    // Faster machines first.
    final List<DistWorker> order = List<DistWorker>.of(_usable)
      ..sort(
        (DistWorker a, DistWorker b) =>
            _speeds[a]!.factor.compareTo(_speeds[b]!.factor),
      );
    final Map<DistWorker, List<({DistUnit unit, String redOn})>> plan =
        <DistWorker, List<({DistUnit unit, String redOn})>>{};
    for (final ({DistUnit unit, String redOn, String redMachine}) r in red) {
      final DistWorker? target = pickRerunTarget<DistWorker>(
        r.unit,
        redMachine: r.redMachine,
        order: order,
        machineOf: (DistWorker w) => w.machine,
        eligible: (DistWorker w, DistUnit u) => w.eligible(u),
      );
      if (target == null) {
        notRerun.add((
          path: r.unit.path,
          redOn: r.redOn,
          why: 'no other machine may run it',
        ));
        continue;
      }
      plan.putIfAbsent(target, () => <({DistUnit unit, String redOn})>[]).add((
        unit: r.unit,
        redOn: r.redOn,
      ));
    }
    stdout.writeln(
      're-running ${red.length - notRerun.length} red suite(s) on another '
      'machine for classification',
    );
    int nextId = 1000000;
    await Future.wait(<Future<void>>[
      for (final MapEntry<DistWorker, List<({DistUnit unit, String redOn})>> e
          in plan.entries)
        () async {
          for (final ({DistUnit unit, String redOn}) r in e.value) {
            await _stop.holdIfStopping();
            final DistBatch batch = DistBatch(
              id: nextId++,
              units: <DistUnit>[r.unit],
            );
            final String base = '${out.path}/rerun-${batch.id}.${e.key.name}';
            final IOSink errLog = File('$base.stderr.log').openWrite();
            final Stopwatch sw = Stopwatch()..start();
            DistBatchRun run;
            try {
              if (e.key.resting && !await _resume(e.key)) {
                throw DistWorkerError('did not get its checkout back');
              }
              run = await e.key.run(
                batch,
                package: package,
                flutterArgs: flutterArgs,
                stderrLog: errLog,
                timeout: _batchTimeout(e.key, batch, _speeds[e.key]!),
                concurrencyCap: concurrency,
              );
            } on Object catch (err) {
              run = DistBatchRun(
                exitCode: -1,
                lines: const <String>[],
                infraError: 'could not start: $err',
              );
            }
            sw.stop();
            await errLog.close();
            File('$base.jsonl').writeAsStringSync(
              run.lines.isEmpty ? '' : '${run.lines.join('\n')}\n',
            );
            final DistRerunOutcome outcome = classifyRerun(
              DistBatchResult(
                batchId: batch.id,
                worker: e.key.name,
                files: batch.files,
                exitCode: run.exitCode,
                lines: run.lines,
                elapsed: sw.elapsed,
                infraError: run.infraError ?? run.busy,
                filtered: _filtered,
              ),
            );
            reruns.add(
              DistRerun(
                path: r.unit.path,
                redOn: r.redOn,
                rerunOn: e.key.name,
                outcome: outcome,
              ),
            );
            stdout.writeln(
              '[${e.key.name}] re-run of ${r.unit.path} (red on ${r.redOn}): '
              '${outcome.name}',
            );
          }
        }(),
    ]);
  }
}

/// The run's snapshot commit (HEAD + working tree, secrets held at HEAD).
Future<DistSnapshot> _snapshot(String repoRoot, _Options options) async {
  final Directory scratch = Directory.systemTemp.createTempSync('dist_test_');
  final DistSnapshot snapshot;
  try {
    snapshot = await createDistSnapshot(gitIn(repoRoot), scratchDir: scratch);
  } on DistSnapshotError catch (e) {
    // No commit to ship says nothing about the code: off this machine
    // heavy.dart runs the command here instead.
    if (options.offMachine) {
      scratch.deleteSync(recursive: true);
      _refuse(options, 'no snapshot of the working tree: ${e.message}');
    }
    stderr.writeln(e.message);
    stdout.writeln('DIST TEST VERDICT: FAILED - no snapshot');
    exit(1);
  } finally {
    scratch.deleteSync(recursive: true);
  }
  stdout.writeln(
    'snapshot ${snapshot.commit.substring(0, 12)}'
    '${snapshot.isHead ? ' (= HEAD)' : ' (HEAD + working tree)'}; '
    'held at HEAD: ${snapshot.protectedPaths.join(', ')}',
  );
  return snapshot;
}

/// Machines left out for a while after an answer that has nothing to do
/// with the run (test_flow/dist_breaker.dart); shared by every checkout here.
final DistBreaker _breaker = DistBreaker(
  File('${heavyStateDir().path}/$kDistBreakerFile'),
);

/// Tells the breaker how a prepare on [worker] ended ([error] null: it went
/// through); what that means is decided there ([DistBreaker.learn]). Says
/// once per machine and run that it is left out.
void _breakerLearns(DistWorker worker, [Object? error]) {
  final DistBreakerEntry? held = _breaker.learn(worker.breakerKey, error);
  if (held == null || !_saidHeld.add(worker.breakerKey)) return;
  stdout.writeln(
    '[${worker.breakerKey}] ${held.why}: offloaded runs leave it out until '
    '${_clock(held.until)}',
  );
}

final Set<String> _saidHeld = <String>{};

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// [job] (`flutter analyze` of [paths] with [options], or a compile check) on
/// the first of [workers] (config order) that prepares and takes it; its
/// output goes to stdout and its exit code is returned.
/// [kDistOffloadDeclined] when none did. When some only turned it down for
/// now (busy, paused, unreachable), every worker is asked again after
/// [_Scheduler.kBusyWait], at most [busyRetries] more rounds -- the same
/// patience `--busy-retries` gives the test path.
Future<int> _jobOffMachine(
  DistJob job,
  List<DistWorker> workers, {
  required DistSnapshot snapshot,
  required String runId,
  required Directory out,
  required List<String> paths,
  required List<String> options,
  required int busyRetries,
}) async {
  for (int round = 0; ; round++) {
    final ({int? code, bool busy}) r = await _jobRound(
      job,
      workers,
      snapshot: snapshot,
      runId: runId,
      out: out,
      paths: paths,
      options: options,
    );
    if (r.code != null) return r.code!;
    if (!distJobAskAgain(
      busy: r.busy,
      round: round,
      retries: busyRetries,
      lost: _tally.lost,
    )) {
      break;
    }
    stdout.writeln(
      'every machine turned the ${job.build == null ? 'analyze' : 'build'} '
      'down for now; asking again in ${_Scheduler.kBusyWait.inSeconds}s '
      '(${round + 1}/$busyRetries)',
    );
    await Future<void>.delayed(_Scheduler.kBusyWait);
    await _stop.holdIfStopping();
  }
  stdout.writeln(
    'DIST OFFLOAD: no other machine took the '
    '${job.build == null ? 'analyze' : 'build'}',
  );
  return _tally.declineCode;
}

/// One pass of [_jobOffMachine] over [workers]: the exit code of the first
/// that ran the job, else null and whether any turned it down only for now.
Future<({int? code, bool busy})> _jobRound(
  DistJob job,
  List<DistWorker> workers, {
  required DistSnapshot snapshot,
  required String runId,
  required Directory out,
  required List<String> paths,
  required List<String> options,
}) async {
  final DistBuild? build = job.build;
  final String tag = build == null ? 'analyze' : 'build';
  bool busy = false;
  for (final DistWorker w in workers) {
    await _stop.holdIfStopping();
    final String? blocker = await w.jobBlocker(job);
    if (blocker != null) {
      if (distJobBlockerIsTransient(blocker)) {
        busy = true;
      } else {
        _tally.cannotTake();
      }
      stdout.writeln('[${w.name}] skipped: $blocker');
      continue;
    }
    final IOSink prepLog = File(
      '${out.path}/prepare.${w.name}.log',
    ).openWrite();
    final Stopwatch prep = Stopwatch()..start();
    try {
      stdout.writeln('[${w.name}] preparing');
      await w.prepare(snapshot, runId, prepLog);
      stdout.writeln('[${w.name}] ready after ${prep.elapsed.inSeconds}s');
      _breakerLearns(w);
    } on Object catch (e) {
      if (e is DistWorkerBusy || e is DistWorkerUnreachable) {
        busy = true;
      } else {
        _tally.failed(w);
      }
      _breakerLearns(w, e);
      stdout.writeln('[${w.name}] skipped: prepare failed: $e');
      await prepLog.close();
      await w.finish(runId);
      continue;
    }
    await prepLog.close();
    final IOSink errLog = File(
      '${out.path}/$tag.${w.name}.stderr.log',
    ).openWrite();
    final Stopwatch sw = Stopwatch()..start();
    DistBatchRun run;
    try {
      stdout.writeln('[${w.name}] ${job.label}');
      run = build == null
          ? await w.analyze(
              paths,
              options: options,
              stderrLog: errLog,
              timeout: kDistAnalyzeTimeout,
            )
          : await w.build(build, stderrLog: errLog, timeout: kDistBuildTimeout);
    } on Object catch (e) {
      run = DistBatchRun(
        exitCode: -1,
        lines: const <String>[],
        infraError: 'could not start: $e',
      );
    }
    await errLog.close();
    await _stop.holdIfStopping();
    await w.finish(runId);
    final String? skipped = run.busy ?? run.infraError;
    if (run.busy != null) {
      busy = true;
    } else if (run.infraError != null) {
      _tally.failed(w);
    }
    if (skipped != null) {
      stdout.writeln('[${w.name}] skipped: $skipped');
      continue;
    }
    File(
      '${out.path}/$tag.${w.name}.log',
    ).writeAsStringSync(run.lines.isEmpty ? '' : '${run.lines.join('\n')}\n');
    stdout
      ..writeAll(run.lines, '\n')
      ..writeln()
      ..writeln(
        'DIST ${tag.toUpperCase()}: ${build?.label ?? ''}'
        '${build == null ? '' : ' '}ran on ${w.name} in '
        '${sw.elapsed.inSeconds}s -> exit ${run.exitCode}',
      );
    await stdout.flush();
    return (code: run.exitCode, busy: false);
  }
  return (code: null, busy: busy);
}

/// Merges the batches' lcov into [to] (only `lib/` records of [package] are
/// taken from the workers' data).
void _writeCoverage(
  List<String> lcov, {
  required String package,
  required File to,
}) {
  final DistCoverage merged = <String, Map<int, int>>{};
  int dropped = 0;
  for (final String text in lcov) {
    dropped += mergeLcov(merged, text, package: package);
  }
  to.parent.createSync(recursive: true);
  to.writeAsStringSync(renderLcov(merged));
  stdout.writeln(
    'DIST COVERAGE: ${to.absolute.path} (${merged.length} files from '
    '${lcov.length} test processes'
    '${dropped == 0 ? '' : '; $dropped records outside $package/lib dropped'})',
  );
}

class _Options {
  _Options({
    required this.paths,
    required this.flutterArgs,
    required this.configPath,
    required this.workers,
    required this.outputDir,
    required this.status,
    required this.dryRun,
    required this.itest,
    required this.analyze,
    required this.offload,
    required this.noLocal,
    required this.busyRetries,
    required this.offloadClaim,
    required this.package,
    required this.coverageOut,
    required this.buildCommand,
    required this.maxMinutes,
    required this.concurrency,
  });

  /// `--max-minutes=N`: the whole run stops after N minutes (124), remote
  /// runs killed and checkouts released; 0 = no limit.
  final int maxMinutes;

  /// `--concurrency=N`: at most N test processes per batch on any worker
  /// (the caller's explicit `flutter test -j N`); null = each worker's own.
  final int? concurrency;

  /// Off this machine: tool/heavy.dart runs the command here itself when
  /// this run declines ([kDistOffloadDeclined]).
  bool get offMachine => offload || analyze || buildCommand != null;

  final List<String> paths;
  final List<String> flutterArgs;
  final String configPath;
  final Set<String>? workers;
  final String? outputDir;
  final bool status;
  final bool dryRun;

  /// Integration tests (tool/test_flow/dist_itests.json) instead of test/.
  final bool itest;

  /// `flutter analyze` of [paths] (none: the whole app) on the first other
  /// machine that takes it, instead of tests.
  final bool analyze;

  /// tool/heavy.dart handing work off this machine: the other machines, and
  /// this one as their peer while it gets a heavy slot here
  /// ([_Scheduler.localIsPeer]); [kDistOffloadDeclined] / busy when nothing
  /// ran anywhere.
  final bool offload;

  /// [kDistNoLocalFlag]: no local worker at all. heavy.dart passes it to the
  /// attempts it makes while the run already queues here: its own queue is
  /// this machine's bid, a local worker would only queue a second time.
  final bool noLocal;

  /// How often in a row a busy worker is asked again before it is dropped.
  final int busyRetries;

  /// `--offload-claim=<file>`: heavy.dart's claim file for this attempt
  /// (test_flow/heavy_offload_rival.dart); null otherwise.
  final String? offloadClaim;

  /// Whose test/ this run covers: [kDistAppPackage] or `packages/<name>`.
  final String package;

  /// `--coverage` (passed on to every `flutter test`): the merged lcov goes
  /// to [coverageOut], by default the package's coverage/lcov.info.
  bool get coverage => flutterArgs.contains('--coverage');
  final String? coverageOut;

  /// `--build -- <command>`: the command as given (null without `--build`).
  final List<String>? buildCommand;

  /// [buildCommand] as a compile check, or null when it is none.
  DistBuild? get build =>
      buildCommand == null ? null : distBuildOf(buildCommand!);

  static _Options parse(List<String> args) {
    final List<String> paths = <String>[];
    final List<String> flutterArgs = <String>[];
    String configPath = 'tool/dist_test/workers.local.json';
    Set<String>? workers;
    String? outputDir;
    bool status = false;
    bool dryRun = false;
    bool itest = false;
    bool analyze = false;
    bool offload = false;
    bool noLocal = false;
    int busyRetries = _Scheduler.kBusyRetries;
    String? offloadClaim;
    String package = kDistAppPackage;
    String? coverageOut;
    bool build = false;
    List<String>? buildCommand;
    int maxMinutes = 0;
    int? concurrency;
    for (int i = 0; i < args.length; i++) {
      final String arg = args[i];
      if (arg == '--' && build) {
        buildCommand = args.sublist(i + 1);
        break;
      }
      if (arg == '--build') {
        build = true;
        buildCommand = const <String>[];
      } else if (arg == '--coverage') {
        flutterArgs.add(arg);
      } else if (arg.startsWith('--coverage-out=')) {
        coverageOut = arg.substring('--coverage-out='.length);
      } else if (arg.startsWith('--package=')) {
        package = arg.substring('--package='.length).replaceAll(r'\', '/');
      } else if (arg == '--status') {
        status = true;
      } else if (arg == '--dry-run') {
        dryRun = true;
      } else if (arg == '--itest') {
        itest = true;
      } else if (arg == '--analyze') {
        analyze = true;
      } else if (arg == '--offload') {
        offload = true;
      } else if (arg == kDistNoLocalFlag) {
        noLocal = true;
      } else if (arg.startsWith('--busy-retries=')) {
        busyRetries =
            int.tryParse(arg.substring('--busy-retries='.length)) ??
            busyRetries;
      } else if (arg.startsWith('--offload-claim=')) {
        offloadClaim = arg.substring('--offload-claim='.length);
      } else if (arg.startsWith('--max-minutes=')) {
        maxMinutes = int.tryParse(arg.substring('--max-minutes='.length)) ?? 0;
      } else if (arg.startsWith('--concurrency=')) {
        final int? n = int.tryParse(arg.substring('--concurrency='.length));
        concurrency = n != null && n >= 1 ? n : null;
      } else if (arg.startsWith('--config=')) {
        configPath = arg.substring('--config='.length);
      } else if (arg.startsWith('--workers=')) {
        workers = arg.substring('--workers='.length).split(',').toSet();
      } else if (arg.startsWith('--output-dir=')) {
        outputDir = arg.substring('--output-dir='.length);
      } else if (arg.startsWith('--')) {
        flutterArgs.add(arg);
        // `--exclude-tags golden` style: take the value along.
        if (!arg.contains('=') &&
            !kDistAnalyzeOptions.contains(arg) &&
            i + 1 < args.length &&
            !args[i + 1].startsWith('-') &&
            !args[i + 1].startsWith('test') &&
            !args[i + 1].startsWith('integration_test')) {
          flutterArgs.add(args[++i]);
        }
      } else {
        paths.add(arg.replaceAll(r'\', '/'));
      }
    }
    return _Options(
      paths: paths.isEmpty && !itest && !analyze && !build
          ? <String>['test']
          : paths,
      flutterArgs: flutterArgs,
      configPath: configPath,
      workers: workers,
      outputDir: outputDir,
      status: status,
      dryRun: dryRun,
      itest: itest,
      analyze: analyze,
      offload: offload,
      noLocal: noLocal,
      busyRetries: busyRetries,
      offloadClaim: offloadClaim,
      package: package,
      coverageOut: coverageOut,
      buildCommand: buildCommand,
      maxMinutes: maxMinutes,
      concurrency: concurrency,
    );
  }
}

/// The manifest's integration tests, all of them or the [paths] given (each
/// must be listed: the manifest says on which platforms it runs).
Map<String, Set<DistPlatform>> _selectItests(List<String> paths) {
  final Map<String, Set<DistPlatform>> manifest;
  try {
    manifest = readDistItests(File(kDistItestManifestPath).readAsStringSync());
  } on FormatException catch (e) {
    stderr.writeln('$kDistItestManifestPath: ${e.message}');
    exit(64);
  }
  if (paths.isEmpty) return manifest;
  final List<String> unlisted = <String>[
    for (final String p in paths)
      if (!manifest.containsKey(p)) p,
  ];
  if (unlisted.isNotEmpty) {
    stderr.writeln(
      'not in $kDistItestManifestPath (add it there with its platforms): '
      '${unlisted.join(', ')}',
    );
    exit(64);
  }
  return <String, Set<DistPlatform>>{
    for (final String p in paths) p: manifest[p]!,
  };
}

/// `*_test.dart` under [paths] (files or directories inside `test/` of the
/// package at [base]) → bytes, keyed by their path relative to [base].
Map<String, int> _discoverSuites(String base, List<String> paths) {
  final Map<String, int> bytes = <String, int>{};
  for (final String raw in paths) {
    final String path = raw.endsWith('/')
        ? raw.substring(0, raw.length - 1)
        : raw;
    if (path != 'test' && !path.startsWith('test/')) {
      stderr.writeln('only paths under test/ can be distributed: $raw');
      exit(64);
    }
    final File file = File('$base/$path');
    if (file.existsSync()) {
      bytes[path] = file.lengthSync();
      continue;
    }
    final Directory dir = Directory('$base/$path');
    if (!dir.existsSync()) {
      stderr.writeln('no such test path: $raw');
      exit(64);
    }
    final int strip = dir.path.length - path.length;
    for (final FileSystemEntity e in dir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (e is File && e.path.endsWith('_test.dart')) {
        bytes[e.path.substring(strip).replaceAll(r'\', '/')] = e.lengthSync();
      }
    }
  }
  return bytes;
}

void _printPlan(List<DistUnit> units, List<DistUnit> unplaceable) {
  final Map<String, (int, int)> byLabel = <String, (int, int)>{};
  for (final DistUnit u in units) {
    final (int, int) prev = byLabel[u.label] ?? (0, 0);
    byLabel[u.label] = (prev.$1 + 1, prev.$2 + u.weightMs);
  }
  final int totalMs = units.fold<int>(0, (int s, DistUnit u) => s + u.weightMs);
  stdout.writeln(
    '${units.length} suite placements, ~${(totalMs / 60000).toStringAsFixed(1)} '
    'model minutes; batches are cut on the fly from each worker\'s speed:',
  );
  for (final String label in byLabel.keys.toList()..sort()) {
    final (int, int) v = byLabel[label]!;
    stdout.writeln(
      '  $label: ${v.$1} suites, ~${(v.$2 / 60000).toStringAsFixed(1)} min',
    );
  }
  if (unplaceable.isNotEmpty) {
    stdout.writeln(
      '  NO ELIGIBLE WORKER: ${unplaceable.length} suites (will count as '
      'not run)',
    );
  }
}

void _writeTimings(
  Directory out,
  List<DistBatchResult> results,
  Set<String> known,
) {
  final Map<String, Map<String, int>> byWorker = <String, Map<String, int>>{};
  for (final DistBatchResult r in results) {
    final Map<String, int> durations = suiteDurationsFromEvents(
      r.lines.where((String l) => l.startsWith('{')).map(_decodeEvent).nonNulls,
      known,
    );
    byWorker.putIfAbsent(r.worker, () => <String, int>{}).addAll(<String, int>{
      for (final MapEntry<String, int> e in durations.entries)
        e.key: roundSuiteTiming(e.value),
    });
  }
  for (final MapEntry<String, Map<String, int>> e in byWorker.entries) {
    writeSuiteTimings(File('${out.path}/timings.${e.key}.json'), e.value);
  }
}

Map<String, Object?>? _decodeEvent(String line) {
  try {
    final Object? v = jsonDecode(line);
    return v is Map<String, Object?> ? v : null;
  } on FormatException {
    return null;
  }
}

String _runId() {
  final DateTime n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  // The random tail keeps two coordinators started in the same second apart
  // (the run id names the remote lock owner and the snapshot ref).
  final String tail = Random()
      .nextInt(0x10000)
      .toRadixString(16)
      .padLeft(4, '0');
  return '${n.year}${two(n.month)}${two(n.day)}-'
      '${two(n.hour)}${two(n.minute)}${two(n.second)}-$tail';
}
