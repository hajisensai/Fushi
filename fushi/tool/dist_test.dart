import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'test_flow/dist_console.dart';
import 'test_flow/dist_coverage.dart';
import 'test_flow/dist_plan.dart';
import 'test_flow/dist_results.dart';
import 'test_flow/dist_snapshot.dart';
import 'test_flow/dist_workers.dart';
import 'test_flow/flutter_test_failure_filter.dart';
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
///   dart tool/dist_test.dart --offload [paths]   # other machines first; this
///                                                # one only for the leftovers
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
///
/// Any other `--flag` is passed to every `flutter test` (e.g.
/// `--exclude-tags golden`). Workers: tool/dist_test/workers.local.json.
/// Design: docs/specs/2026-10-24-distributed-unit-tests.md.
///
/// Last stdout line: `DIST TEST VERDICT: PASSED|FAILED - ...`; exit code 0
/// only when green.
Future<void> main(List<String> args) async {
  final _Options options = _Options.parse(args);
  if (options.itest && options.flutterArgs.isNotEmpty) {
    stderr.writeln(
      '--itest takes no flutter test options '
      '(${options.flutterArgs.join(' ')}): each file is one app launch',
    );
    exit(64);
  }
  if (<bool>[
        options.itest,
        options.analyze,
        options.build != null,
      ].where((bool b) => b).length >
      1) {
    stderr.writeln('--itest, --analyze and --build each run on their own');
    exit(64);
  }
  if (options.buildCommand != null && options.build == null) {
    stderr.writeln(
      '--build takes `-- flutter build <apk|appbundle|windows|macos> '
      '[--debug|--profile|--release] [--split-per-abi] '
      '[--target-platform=android-...]` or `-- gradlew '
      '<:app:assemble*|:app:bundle*>` (macos --debug only), not: '
      '${options.buildCommand!.join(' ')}',
    );
    exit(64);
  }
  if (!isDistPackageDir(options.package) ||
      (options.package != kDistAppPackage &&
          (options.itest || options.analyze || options.build != null))) {
    stderr.writeln(
      '--package takes packages/<name> and goes with test runs only: '
      '${options.package}',
    );
    exit(64);
  }
  if (options.analyze) {
    final List<String> bad = <String>[
      for (final String a in options.flutterArgs)
        if (!kDistAnalyzeOptions.contains(a)) a,
      for (final String p in options.paths)
        if (!isSafeDistAnalyzePath(p)) p,
    ];
    if (bad.isNotEmpty) {
      stderr.writeln(
        '--analyze takes ${kDistAnalyzeOptions.join(' / ')} and paths under '
        'lib/ test/ tool/ integration_test/ test_driver/ bin/ only: '
        '${bad.join(', ')}',
      );
      exit(64);
    }
  }
  if (!hasSharedConsole()) {
    stderr.writeln(
      'dist_test: this process has no console, so every flutter / git / ssh '
      'it starts would open a window of its own and take the focus. Run it '
      'from a terminal or an agent shell.',
    );
    exit(64);
  }
  if (!File('pubspec.yaml').existsSync() || !Directory('test').existsSync()) {
    stderr.writeln('run from fushi/ (the Flutter app directory)');
    exit(64);
  }
  final String repoRoot = Directory.current.parent.absolute.path.replaceAll(
    r'\',
    '/',
  );
  // The package whose test/ this run covers; suite paths stay relative to it.
  final String packageDir = '$repoRoot/${options.package}';
  if (!Directory('$packageDir/test').existsSync()) {
    stderr.writeln('${options.package} has no test/ directory');
    exit(64);
  }
  final String runner = distTestRunnerOf(
    File('$packageDir/pubspec.yaml').readAsStringSync(),
  );
  if (options.coverage && (options.itest || runner == 'dart')) {
    stderr.writeln(
      '--coverage goes with flutter test runs only (not --itest, not a pure '
      'Dart package)',
    );
    exit(64);
  }

  final File configFile = File(options.configPath);
  if (!configFile.existsSync()) {
    stderr.writeln(
      'no worker config at ${options.configPath}; copy '
      'tool/dist_test/workers.example.json there and edit it',
    );
    exit(64);
  }
  List<DistWorkerConfig> configs;
  try {
    configs = readDistWorkers(configFile.readAsStringSync());
  } on DistConfigError catch (e) {
    stderr.writeln('${options.configPath}: $e');
    exit(64);
  }
  if (options.workers != null) {
    final Set<String> unknown = options.workers!.difference(
      configs.map((DistWorkerConfig c) => c.name).toSet(),
    );
    if (unknown.isNotEmpty) {
      stderr.writeln('unknown worker(s): ${unknown.join(', ')}');
      exit(64);
    }
    configs = <DistWorkerConfig>[
      for (final DistWorkerConfig c in configs)
        if (options.workers!.contains(c.name)) c,
    ];
  }
  // Off this machine: the other machines are the workers; this one only
  // picks up test suites they could not run (never analyze or a build:
  // heavy.dart then runs it here itself).
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
  final List<DistWorker> fallback = <DistWorker>[
    if (options.offload && job == null)
      for (final DistWorkerConfig c in configs)
        if (c.kind == DistWorkerKind.local)
          ...createDistWorkers(c, repoRoot: repoRoot),
  ];
  if (workers.isEmpty) {
    if (offMachine) {
      stdout.writeln('DIST OFFLOAD: no other machine is configured');
      exit(kDistOffloadDeclined);
    }
    stderr.writeln('no workers selected');
    exit(64);
  }

  if (options.status) {
    await Future.wait(<Future<void>>[
      for (final DistWorker w in workers)
        w.status().then((String s) => stdout.writeln('${w.name}: $s')),
    ]);
    return;
  }

  if (job != null) {
    final DistSnapshot snapshot = await _snapshot(repoRoot);
    final String runId = _runId();
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
      stderr.writeln('no *_test.dart under ${options.paths.join(', ')}');
      exit(64);
    }
    final List<String> unsafe = <String>[
      for (final String p in bytes.keys)
        if (!isSafeDistTestPath(p)) p,
    ];
    if (unsafe.isNotEmpty) {
      stderr.writeln(
        'test paths outside [A-Za-z0-9_./-] cannot be shipped: '
        '${unsafe.join(', ')}',
      );
      exit(64);
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
  final DistSnapshot snapshot = await _snapshot(repoRoot);

  final String runId = _runId();
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
  );
  final StreamSubscription<ProcessSignal> sigint = ProcessSignal.sigint
      .watch()
      .listen((_) async {
        stderr.writeln('\ninterrupted: stopping the workers');
        await Future.wait(<Future<void>>[
          for (final DistWorker w in everyWorker) w.cancel(),
        ]);
        await Future.wait(<Future<void>>[
          for (final DistWorker w in everyWorker) w.finish(runId),
        ]);
        exit(130);
      });
  await Future.wait(<Future<void>>[
    for (final DistWorker w in workers) scheduler.drive(w),
  ]);
  if (options.offload && scheduler.results.isEmpty) {
    // Nothing ran anywhere else (unreachable, busy, paused): the caller runs
    // the whole command here, in its own form.
    await Future.wait(<Future<void>>[
      for (final DistWorker w in everyWorker) w.finish(runId),
    ]);
    await sigint.cancel();
    stdout.writeln('DIST OFFLOAD: no other machine took any suite');
    exit(kDistOffloadDeclined);
  }
  if (queue.remaining.isNotEmpty && fallback.isNotEmpty) {
    stdout.writeln(
      '${queue.remaining.length} suite(s) left that no other machine ran: '
      'running them here',
    );
    await Future.wait(<Future<void>>[
      for (final DistWorker w in fallback) scheduler.drive(w),
    ]);
  }
  // Every red suite once more on another machine, for the report only.
  await scheduler.rerunFailures();
  await Future.wait(<Future<void>>[
    for (final DistWorker w in everyWorker) w.finish(runId),
  ]);
  await sigint.cancel();
  wall.stop();

  final DistRunVerdict verdict = DistRunVerdict(
    results: scheduler.results,
    unplaced: <String>[
      for (final DistUnit u in <DistUnit>[...unplaceable, ...queue.remaining])
        '${u.path} (${u.label})',
    ],
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
        ? 'DIST TEST VERDICT: PASSED - ${verdict.testsCompleted} tests ran on '
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
  }) : _speeds = <DistWorker, DistSpeed>{
         for (final DistWorker w in workers) w: DistSpeed(),
       };

  final DistSuiteQueue queue;

  /// Whose suites these are ([kDistAppPackage] or `packages/<name>`).
  final String package;
  final List<String> flutterArgs;

  /// lcov of every batch that ran to the end (`--coverage`), unchecked.
  final List<String> coverage = <String>[];
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

  /// The units of every batch that ran to the end, by batch id.
  final Map<int, List<DistUnit>> _unitsByBatch = <int, List<DistUnit>>{};

  /// A worker that is busy (owner's memory limit) is asked again after this
  /// long, at most [kBusyRetries] times in a row.
  static const Duration kBusyWait = Duration(seconds: 30);
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
    final IOSink prepLog = File(
      '${out.path}/prepare.${worker.name}.log',
    ).openWrite();
    final Stopwatch prep = Stopwatch()..start();
    try {
      stdout.writeln('[${worker.name}] preparing');
      if (!await _prepareWhileNeeded(worker, prepLog)) {
        // The others ran everything this worker could have (a slow first
        // prepare must not hold up a run that is otherwise done).
        stdout.writeln(
          '[${worker.name}] not needed: nothing left for it after '
          '${prep.elapsed.inSeconds}s of preparing',
        );
        await worker.abandon();
        await prepLog.close();
        await worker.finish(runId);
        _notify();
        return;
      }
      stdout.writeln('[${worker.name}] ready after ${prep.elapsed.inSeconds}s');
    } on Object catch (e) {
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
    _live.add(worker);
    final DistSpeed speed = _speeds[worker]!;

    int infraStreak = 0;
    int busyStreak = 0;
    bool dropped = false;
    while (true) {
      final DistBatch? batch = queue.take(
        eligible: worker.eligible,
        budgetMs: distChunkBudgetMs(
          remainingEligibleMs: queue.remainingMs(worker.eligible),
          speed: speed,
          liveSpeedSum: _liveSpeedSum,
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
          // Three times what this machine's own speed predicts, plus slack.
          timeout:
              Duration(
                milliseconds: (batch.weightMs * speed.factor * 3).round(),
              ) +
              const Duration(minutes: 10),
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
      await worker.finish(runId);
    } else {
      // Kept prepared (checkout lock / heavy lease) for [rerunFailures];
      // main() finishes every worker afterwards.
      _usable.add(worker);
    }
    _notify();
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
    while (true) {
      if (error != null) Error.throwWithStackTrace(error!, trace!);
      if (done) return true;
      if (_inFlight == 0 && !queue.remaining.any(worker.eligible)) {
        return false;
      }
      await _changed.future;
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
            final DistBatch batch = DistBatch(
              id: nextId++,
              units: <DistUnit>[r.unit],
            );
            final String base = '${out.path}/rerun-${batch.id}.${e.key.name}';
            final IOSink errLog = File('$base.stderr.log').openWrite();
            final Stopwatch sw = Stopwatch()..start();
            DistBatchRun run;
            try {
              run = await e.key.run(
                batch,
                package: package,
                flutterArgs: flutterArgs,
                stderrLog: errLog,
                timeout:
                    Duration(
                      milliseconds:
                          (batch.weightMs * _speeds[e.key]!.factor * 3).round(),
                    ) +
                    const Duration(minutes: 10),
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
Future<DistSnapshot> _snapshot(String repoRoot) async {
  final Directory scratch = Directory.systemTemp.createTempSync('dist_test_');
  final DistSnapshot snapshot;
  try {
    snapshot = await createDistSnapshot(gitIn(repoRoot), scratchDir: scratch);
  } on DistSnapshotError catch (e) {
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

/// [job] (`flutter analyze` of [paths] with [options], or a compile check) on
/// the first of [workers] (config order) that prepares and takes it; its
/// output goes to stdout and its exit code is returned.
/// [kDistOffloadDeclined] when none did.
Future<int> _jobOffMachine(
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
  for (final DistWorker w in workers) {
    final String? blocker = await w.jobBlocker(job);
    if (blocker != null) {
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
    } on Object catch (e) {
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
    await w.finish(runId);
    final String? skipped = run.busy ?? run.infraError;
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
    return run.exitCode;
  }
  stdout.writeln('DIST OFFLOAD: no other machine took the $tag');
  return kDistOffloadDeclined;
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
    required this.busyRetries,
    required this.package,
    required this.coverageOut,
    required this.buildCommand,
  });

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

  /// tool/heavy.dart handing work off this machine: other machines first,
  /// this one only for what they leave; [kDistOffloadDeclined] when no other
  /// machine took anything.
  final bool offload;

  /// How often in a row a busy worker is asked again before it is dropped.
  final int busyRetries;

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
    int busyRetries = _Scheduler.kBusyRetries;
    String package = kDistAppPackage;
    String? coverageOut;
    bool build = false;
    List<String>? buildCommand;
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
      } else if (arg.startsWith('--busy-retries=')) {
        busyRetries =
            int.tryParse(arg.substring('--busy-retries='.length)) ??
            busyRetries;
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
      busyRetries: busyRetries,
      package: package,
      coverageOut: coverageOut,
      buildCommand: buildCommand,
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
