import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'test_flow/flutter_test_failure_filter.dart';

Future<void> main(List<String> args) async {
  final _FlutterTestFailureOptions options =
      _FlutterTestFailureOptions.parse(args);
  final Directory outputDir = Directory(options.outputDir)
    ..createSync(recursive: true);
  final File jsonLog = File('${outputDir.path}/flutter_test.jsonl');
  final File stderrLog = File('${outputDir.path}/flutter_test_stderr.log');

  final List<String> flutterArgs = <String>[
    'test',
    '--reporter',
    'json',
    ...options.flutterTestArgs,
  ];
  final Process process = await Process.start(
    _resolveFlutterExecutable(),
    flutterArgs,
    runInShell: Platform.isWindows,
  );

  final IOSink logSink = jsonLog.openWrite();
  final IOSink stderrSink = stderrLog.openWrite();
  final List<String> jsonLines = <String>[];
  final Completer<void> stdoutDone = Completer<void>();
  final Completer<void> stderrDone = Completer<void>();
  const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);

  process.stdout.transform(decoder).transform(const LineSplitter()).listen(
      (String line) {
    jsonLines.add(line);
    logSink.writeln(line);
    if (options.verboseOutput) {
      stdout.writeln(line);
    }
  }, onDone: stdoutDone.complete, onError: stdoutDone.completeError);

  // Always mirror the child's stderr. Native-assets / compile failures report
  // exclusively there, and swallowing it is what makes a dead run look silent
  // and therefore green.
  process.stderr.transform(decoder).listen((String chunk) {
    stderrSink.write(chunk);
    stderr.write(chunk);
  }, onDone: stderrDone.complete, onError: stderrDone.completeError);

  final int exitCode = await process.exitCode;
  await Future.wait(<Future<void>>[stdoutDone.future, stderrDone.future]);
  await logSink.close();
  await stderrSink.close();

  final FlutterTestRunSummary summary = parseFlutterTestJsonEvents(jsonLines);
  final String? verdictFailure = resolveFlutterTestVerdictFailure(
    flutterExitCode: exitCode,
    summary: summary,
    minimumTests: options.minimumTests,
  );

  if (verdictFailure != null) {
    stderr.writeln(renderFlutterTestFailureSummary(
      summary,
      logPath: jsonLog.path,
      stderrLogPath: stderrLog.path,
      minimumTests: options.minimumTests,
    ));
    await stderr.flush();
    stdout.writeln('$kFlutterTestVerdictPrefix FAILED - $verdictFailure '
        '(tests completed: ${summary.testsCompleted}, '
        'flutter exit code: $exitCode)');
    await stdout.flush();
    exit(exitCode != 0 ? exitCode : 1);
  }

  stdout
    ..writeln('Full JSON log: ${jsonLog.path}')
    ..writeln(
        '$kFlutterTestVerdictPrefix PASSED - ${summary.testsCompleted} tests ran, '
        'all tests passed');
  await stdout.flush();
}

class _FlutterTestFailureOptions {
  const _FlutterTestFailureOptions({
    required this.outputDir,
    required this.verboseOutput,
    required this.minimumTests,
    required this.flutterTestArgs,
  });

  final String outputDir;
  final bool verboseOutput;
  final int minimumTests;
  final List<String> flutterTestArgs;

  static _FlutterTestFailureOptions parse(List<String> args) {
    String outputDir = '../.codex-test/flutter-test';
    bool verboseOutput = false;
    int minimumTests = 1;
    final List<String> flutterTestArgs = <String>[];

    for (final String arg in args) {
      if (arg.startsWith('--output-dir=')) {
        outputDir = arg.substring('--output-dir='.length);
      } else if (arg.startsWith('--min-tests=')) {
        final String raw = arg.substring('--min-tests='.length);
        final int? parsed = int.tryParse(raw);
        if (parsed == null || parsed < 0) {
          stderr.writeln('Invalid --min-tests value: $raw');
          exit(64);
        }
        minimumTests = parsed;
      } else if (arg == '--verbose-output') {
        verboseOutput = true;
      } else {
        flutterTestArgs.add(arg);
      }
    }

    return _FlutterTestFailureOptions(
      outputDir: outputDir,
      verboseOutput: verboseOutput,
      minimumTests: minimumTests,
      flutterTestArgs: flutterTestArgs,
    );
  }
}

String _resolveFlutterExecutable() {
  if (!Platform.isWindows) return 'flutter';
  const String flutter =
      r'D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat';
  if (File(flutter).existsSync()) return flutter;
  return 'flutter';
}
