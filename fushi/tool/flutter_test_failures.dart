import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'test_flow/flutter_sdk_executables.dart';
import 'test_flow/flutter_test_failure_filter.dart';
import 'test_flow/heavy_budget.dart';
import 'test_flow/heavy_lease.dart';
import 'test_flow/suite_timings.dart';
import 'test_flow/test_file_shards.dart';

Future<void> main(List<String> args) async {
  final _FlutterTestFailureOptions options = _FlutterTestFailureOptions.parse(
    args,
  );
  // The machine-wide heavy-run lease (test_flow/heavy_lease.dart; nothing on
  // CI): a slot, and this worktree's build/ and default
  // output directory to itself -- two runs in one checkout used to fight over
  // sqlite3.dll and flutter_test.jsonl.
  final HeavyNeed need = heavyNeedFor(HeavyKind.test);
  final HeavyJob? job = joinHeavyJob(need.capMb, log: stderr.writeln);
  final HeavyLease lease;
  try {
    lease = await acquireHeavyLease(
      need: need,
      label: 'flutter_test_failures -> ${options.outputDir}',
      worktreeRoot: locateCheckoutRoot(),
      waitMax: options.waitMaxMinutes > 0
          ? Duration(minutes: options.waitMaxMinutes)
          : null,
    );
  } on HeavyLeaseTimeout catch (e) {
    stderr.writeln(e.message);
    stdout.writeln(
      '$kFlutterTestVerdictPrefix FAILED - not admitted: the '
      'machine had no room (tests completed: 0)',
    );
    exit(75);
  }
  final Directory outputDir = Directory(options.outputDir)
    ..createSync(recursive: true);
  final File jsonLog = File('${outputDir.path}/flutter_test.jsonl');
  final File stderrLog = File('${outputDir.path}/flutter_test_stderr.log');

  // A shard can run as several sequential `flutter test` processes
  // (--max-suites-per-run, see splitIntoBatches); every other run is one batch
  // of "no explicit files". Each batch's events are appended to the same log,
  // each starting with the reporter's own `start` event.
  final List<List<String>> batches;
  if (options.fileShard == null) {
    batches = <List<String>>[<String>[]];
  } else {
    final List<String> files = _shardTestFiles(options.fileShard!);
    batches = options.maxSuitesPerRun > 0
        ? splitIntoBatches(files, options.maxSuitesPerRun)
        : <List<String>>[files];
  }

  final IOSink logSink = jsonLog.openWrite();
  final IOSink stderrSink = stderrLog.openWrite();
  final List<FlutterTestRunSummary> summaries = <FlutterTestRunSummary>[];
  int exitCode = 0;
  for (int i = 0; i < batches.length; i++) {
    if (batches.length > 1) {
      stdout.writeln(
        'Batch ${i + 1}/${batches.length}: '
        '${batches[i].length} test files',
      );
    }
    final ({int exitCode, List<String> lines}) run = await _runFlutterTest(
      <String>[
        'test',
        '--reporter',
        'json',
        ...options.flutterTestArgs,
        ...batches[i],
      ],
      logSink: logSink,
      stderrSink: stderrSink,
      verbose: options.verboseOutput,
    );
    summaries.add(parseFlutterTestJsonEvents(run.lines));
    if (exitCode == 0) exitCode = run.exitCode;
  }
  await logSink.close();
  await stderrSink.close();
  lease.release();
  final int? peak = job?.peakMb();
  if (peak != null && heavyCapHit(peak, need.capMb)) {
    stderr.writeln(
      'heavy: MEMORY CAP HIT ($peak MB of ${need.capMb} MB) -- '
      'failures in this run can come from the ceiling, not from the code; '
      'narrow the run or lower --concurrency.',
    );
  }

  final FlutterTestRunSummary summary = FlutterTestRunSummary.merge(summaries);
  final String? verdictFailure = resolveFlutterTestVerdictFailure(
    flutterExitCode: exitCode,
    summary: summary,
    minimumTests: options.minimumTests,
  );

  if (verdictFailure != null) {
    stderr.writeln(
      renderFlutterTestFailureSummary(
        summary,
        logPath: jsonLog.path,
        stderrLogPath: stderrLog.path,
        minimumTests: options.minimumTests,
      ),
    );
    await stderr.flush();
    stdout.writeln(
      '$kFlutterTestVerdictPrefix FAILED - $verdictFailure '
      '(tests completed: ${summary.testsCompleted}, '
      'flutter exit code: $exitCode)',
    );
    await stdout.flush();
    exit(exitCode != 0 ? exitCode : 1);
  }

  stdout
    ..writeln('Full JSON log: ${jsonLog.path}')
    ..writeln(
      '$kFlutterTestVerdictPrefix PASSED - ${summary.testsCompleted} tests ran, '
      'all tests passed',
    );
  await stdout.flush();
}

/// One `flutter test` process: its stdout lines go to [logSink] (and are
/// returned for parsing), its stderr to [stderrSink] and our own stderr.
Future<({int exitCode, List<String> lines})> _runFlutterTest(
  List<String> flutterArgs, {
  required IOSink logSink,
  required IOSink stderrSink,
  required bool verbose,
}) async {
  final Process process = await Process.start(
    FlutterSdkExecutables.current().flutter(),
    flutterArgs,
    runInShell: Platform.isWindows,
  );
  final List<String> jsonLines = <String>[];
  final Completer<void> stdoutDone = Completer<void>();
  final Completer<void> stderrDone = Completer<void>();
  const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);

  process.stdout
      .transform(decoder)
      .transform(const LineSplitter())
      .listen(
        (String line) {
          jsonLines.add(line);
          logSink.writeln(line);
          if (verbose) {
            stdout.writeln(line);
          }
        },
        onDone: stdoutDone.complete,
        onError: stdoutDone.completeError,
      );

  // Always mirror the child's stderr. Native-assets / compile failures report
  // exclusively there, and swallowing it is what makes a dead run look silent
  // and therefore green.
  process.stderr
      .transform(decoder)
      .listen(
        (String chunk) {
          stderrSink.write(chunk);
          stderr.write(chunk);
        },
        onDone: stderrDone.complete,
        onError: stderrDone.completeError,
      );

  final int exitCode = await process.exitCode;
  await Future.wait(<Future<void>>[stdoutDone.future, stderrDone.future]);
  return (exitCode: exitCode, lines: jsonLines);
}

class _FlutterTestFailureOptions {
  const _FlutterTestFailureOptions({
    required this.outputDir,
    required this.verboseOutput,
    required this.minimumTests,
    required this.flutterTestArgs,
    required this.fileShard,
    required this.waitMaxMinutes,
    required this.maxSuitesPerRun,
  });

  final String outputDir;
  final bool verboseOutput;
  final int minimumTests;
  final List<String> flutterTestArgs;
  final TestFileShard? fileShard;

  /// How long to queue for the heavy-run lease before failing; 0 (the
  /// default) waits in the queue until admitted.
  final int waitMaxMinutes;

  /// With `--file-shard`: run the shard as sequential `flutter test` processes
  /// of at most this many suites each (see [splitIntoBatches]); 0 = one run.
  final int maxSuitesPerRun;

  static _FlutterTestFailureOptions parse(List<String> args) {
    String outputDir = '../.codex-test/flutter-test';
    bool verboseOutput = false;
    int minimumTests = 1;
    final List<String> flutterTestArgs = <String>[];
    TestFileShard? fileShard;
    int waitMaxMinutes = 0;
    int maxSuitesPerRun = 0;

    for (final String arg in args) {
      if (arg.startsWith('--wait-max-min=')) {
        final String raw = arg.substring('--wait-max-min='.length);
        final int? parsed = int.tryParse(raw);
        if (parsed == null || parsed < 0) {
          stderr.writeln('Invalid --wait-max-min value: $raw');
          exit(64);
        }
        waitMaxMinutes = parsed;
      } else if (arg.startsWith('--output-dir=')) {
        outputDir = arg.substring('--output-dir='.length);
      } else if (arg.startsWith('--min-tests=')) {
        final String raw = arg.substring('--min-tests='.length);
        final int? parsed = int.tryParse(raw);
        if (parsed == null || parsed < 0) {
          stderr.writeln('Invalid --min-tests value: $raw');
          exit(64);
        }
        minimumTests = parsed;
      } else if (arg.startsWith('--file-shard=')) {
        final String raw = arg.substring('--file-shard='.length);
        fileShard = TestFileShard.tryParse(raw);
        if (fileShard == null) {
          stderr.writeln(
            'Invalid --file-shard value: $raw '
            '(expected <index>/<total>, 0 <= index < total)',
          );
          exit(64);
        }
      } else if (arg.startsWith('--max-suites-per-run=')) {
        final String raw = arg.substring('--max-suites-per-run='.length);
        final int? parsed = int.tryParse(raw);
        if (parsed == null || parsed < 1) {
          stderr.writeln('Invalid --max-suites-per-run value: $raw');
          exit(64);
        }
        maxSuitesPerRun = parsed;
      } else if (arg == '--verbose-output') {
        verboseOutput = true;
      } else {
        flutterTestArgs.add(arg);
      }
    }

    if (maxSuitesPerRun > 0 && fileShard == null) {
      // Batching needs the explicit file list that only --file-shard builds.
      stderr.writeln('--max-suites-per-run needs --file-shard');
      exit(64);
    }

    return _FlutterTestFailureOptions(
      outputDir: outputDir,
      verboseOutput: verboseOutput,
      minimumTests: minimumTests,
      flutterTestArgs: flutterTestArgs,
      fileShard: fileShard,
      waitMaxMinutes: waitMaxMinutes,
      maxSuitesPerRun: maxSuitesPerRun,
    );
  }
}

/// Lists this shard's suites under `test/` (the directory `flutter test` scans
/// by default), passed as explicit paths so the other shards' suites are never
/// compiled here. Do not combine `--file-shard` with explicit test paths.
/// Balanced by the measured suite times in [kSuiteTimingsPath] (see
/// test_flow/suite_timings.dart).
List<String> _shardTestFiles(TestFileShard shard) {
  final Map<String, int> bytes = <String, int>{};
  for (final FileSystemEntity entity in Directory(
    'test',
  ).listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('_test.dart')) continue;
    bytes[entity.path.replaceAll(r'\', '/')] = entity.lengthSync();
  }
  final Map<String, int> timings = readSuiteTimings(File(kSuiteTimingsPath));
  final Map<String, int> weights = suiteShardWeights(bytes, timings);
  final List<String> selected = selectTestFileShard(weights, shard);
  if (selected.isEmpty) {
    // An empty path list would make `flutter test` fall back to the WHOLE
    // test/ directory, silently turning this shard into a full run.
    stderr.writeln(
      'File shard ${shard.index}/${shard.total} is empty '
      '(${weights.length} test files); lower --file-shard total.',
    );
    exit(64);
  }
  final int timed = bytes.keys.where(timings.containsKey).length;
  final int shardMs = selected.fold<int>(
    0,
    (int sum, String path) => sum + weights[path]!,
  );
  stdout.writeln(
    'File shard ${shard.index}/${shard.total}: '
    '${selected.length} of ${weights.length} test files, '
    '~${(shardMs / 60000).toStringAsFixed(1)} suite-minutes '
    '($timed of ${bytes.length} suites have a measured time)',
  );
  return selected;
}
