import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'test_flow/dist_console.dart';
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
///
/// Any other `--flag` is passed to every `flutter test` (e.g.
/// `--exclude-tags golden`). Workers: tool/dist_test/workers.local.json.
/// Design: docs/specs/2026-10-24-distributed-unit-tests.md.
///
/// Last stdout line: `DIST TEST VERDICT: PASSED|FAILED - ...`; exit code 0
/// only when green.
Future<void> main(List<String> args) async {
  final _Options options = _Options.parse(args);
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
  final List<DistWorker> workers = <DistWorker>[
    for (final DistWorkerConfig c in configs)
      ...createDistWorkers(c, repoRoot: repoRoot),
  ];
  if (workers.isEmpty) {
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

  // ---- plan ----
  final Map<String, int> bytes = _discoverSuites(options.paths);
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
  final Map<String, int> weights = suiteShardWeights(
    bytes,
    readSuiteTimings(File(kSuiteTimingsPath)),
  );
  final Map<String, Set<DistPlatform>> pins = readDistAffinity(
    File(kDistAffinityPath).readAsStringSync(),
  );
  final Map<String, SuiteRequirement> requirements = <String, SuiteRequirement>{
    for (final String p in bytes.keys)
      p: applyDistPin(
        scanSuiteRequirement(File(p).readAsStringSync()),
        pins[p],
      ),
  };
  final List<DistUnit> units = distUnits(
    weights: weights,
    requirements: requirements,
  );
  final List<DistUnit> unplaceable = <DistUnit>[
    for (final DistUnit u in units)
      if (!workers.any((DistWorker w) => w.eligible(u))) u,
  ];
  final DistSuiteQueue queue = DistSuiteQueue(
    units.where((DistUnit u) => !unplaceable.contains(u)),
  );
  _printPlan(units, unplaceable);
  if (options.dryRun) return;

  // ---- snapshot ----
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

  final String runId = _runId();
  final Directory out = Directory(
    options.outputDir ?? '../.codex-test/dist/$runId',
  )..createSync(recursive: true);
  stdout.writeln('logs: ${out.absolute.path}');

  // ---- run ----
  final Stopwatch wall = Stopwatch()..start();
  final _Scheduler scheduler = _Scheduler(
    queue: queue,
    workers: workers,
    flutterArgs: options.flutterArgs,
    out: out,
    runId: runId,
    snapshot: snapshot,
  );
  final StreamSubscription<ProcessSignal> sigint = ProcessSignal.sigint
      .watch()
      .listen((_) async {
        stderr.writeln('\ninterrupted: stopping the workers');
        await Future.wait(<Future<void>>[
          for (final DistWorker w in workers) w.cancel(),
        ]);
        await Future.wait(<Future<void>>[
          for (final DistWorker w in workers) w.finish(runId),
        ]);
        exit(130);
      });
  await Future.wait(<Future<void>>[
    for (final DistWorker w in workers) scheduler.drive(w),
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
  final String summary = renderDistSummary(
    verdict: verdict,
    estimatedMsByBatch: scheduler.weightByBatch,
    wall: wall.elapsed,
    snapshot: snapshot.commit,
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
    required this.flutterArgs,
    required this.out,
    required this.runId,
    required this.snapshot,
  }) : _speeds = <DistWorker, DistSpeed>{
         for (final DistWorker w in workers) w: DistSpeed(),
       };

  final DistSuiteQueue queue;
  final List<String> flutterArgs;
  final Directory out;
  final String runId;
  final DistSnapshot snapshot;
  final List<DistBatchResult> results = <DistBatchResult>[];
  final Map<int, int> weightByBatch = <int, int>{};

  final Map<DistWorker, DistSpeed> _speeds;

  /// Workers that are ready and not dropped: the ones sharing the queue.
  final Set<DistWorker> _live = <DistWorker>{};

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
      await worker.prepare(snapshot, runId, prepLog);
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
      File(
        '$base.jsonl',
      ).writeAsStringSync(run.lines.isEmpty ? '' : '${run.lines.join('\n')}\n');
      _inFlight--;

      if (run.infraError != null && batch.attempts == 0) {
        // Back into the queue for whichever worker asks next. Test failures
        // are never retried (that would hide flaky reds); this is only for
        // runs that did not get a fair chance.
        queue.giveBack(batch);
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
          break;
        }
        continue;
      }
      if (run.infraError == null) {
        infraStreak = 0;
        speed.record(wallMs: sw.elapsedMilliseconds, weightMs: batch.weightMs);
      } else {
        infraStreak++;
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
        break;
      }
    }
    _live.remove(worker);
    await worker.finish(runId);
    _notify();
  }
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
  });

  final List<String> paths;
  final List<String> flutterArgs;
  final String configPath;
  final Set<String>? workers;
  final String? outputDir;
  final bool status;
  final bool dryRun;

  static _Options parse(List<String> args) {
    final List<String> paths = <String>[];
    final List<String> flutterArgs = <String>[];
    String configPath = 'tool/dist_test/workers.local.json';
    Set<String>? workers;
    String? outputDir;
    bool status = false;
    bool dryRun = false;
    for (int i = 0; i < args.length; i++) {
      final String arg = args[i];
      if (arg == '--status') {
        status = true;
      } else if (arg == '--dry-run') {
        dryRun = true;
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
            i + 1 < args.length &&
            !args[i + 1].startsWith('-') &&
            !args[i + 1].startsWith('test')) {
          flutterArgs.add(args[++i]);
        }
      } else {
        paths.add(arg.replaceAll(r'\', '/'));
      }
    }
    return _Options(
      paths: paths.isEmpty ? <String>['test'] : paths,
      flutterArgs: flutterArgs,
      configPath: configPath,
      workers: workers,
      outputDir: outputDir,
      status: status,
      dryRun: dryRun,
    );
  }
}

/// `*_test.dart` under [paths] (files or directories inside `test/`) → bytes.
Map<String, int> _discoverSuites(List<String> paths) {
  final Map<String, int> bytes = <String, int>{};
  for (final String raw in paths) {
    final String path = raw.endsWith('/')
        ? raw.substring(0, raw.length - 1)
        : raw;
    if (!path.startsWith('test')) {
      stderr.writeln('only paths under test/ can be distributed: $raw');
      exit(64);
    }
    if (File(path).existsSync()) {
      bytes[path] = File(path).lengthSync();
      continue;
    }
    if (!Directory(path).existsSync()) {
      stderr.writeln('no such test path: $raw');
      exit(64);
    }
    for (final FileSystemEntity e in Directory(
      path,
    ).listSync(recursive: true, followLinks: false)) {
      if (e is File && e.path.endsWith('_test.dart')) {
        bytes[e.path.replaceAll(r'\', '/')] = e.lengthSync();
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
