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

  process.stderr.transform(decoder).listen((String chunk) {
    stderrSink.write(chunk);
    if (options.verboseOutput) {
      stderr.write(chunk);
    }
  }, onDone: stderrDone.complete, onError: stderrDone.completeError);

  final int exitCode = await process.exitCode;
  await Future.wait(<Future<void>>[stdoutDone.future, stderrDone.future]);
  await logSink.close();
  await stderrSink.close();

  final FlutterTestRunSummary summary = parseFlutterTestJsonEvents(jsonLines);
  if (exitCode != 0 || summary.hasFailures) {
    stderr.writeln(renderFlutterTestFailureSummary(
      summary,
      logPath: jsonLog.path,
      stderrLogPath: stderrLog.path,
    ));
  } else {
    stdout.writeln('Flutter tests passed. Full JSON log: ${jsonLog.path}');
  }

  if (exitCode != 0) {
    exit(exitCode);
  }
  if (summary.hasFailures) {
    exit(1);
  }
}

class _FlutterTestFailureOptions {
  const _FlutterTestFailureOptions({
    required this.outputDir,
    required this.verboseOutput,
    required this.flutterTestArgs,
  });

  final String outputDir;
  final bool verboseOutput;
  final List<String> flutterTestArgs;

  static _FlutterTestFailureOptions parse(List<String> args) {
    String outputDir = '../.codex-test/flutter-test';
    bool verboseOutput = false;
    final List<String> flutterTestArgs = <String>[];

    for (final String arg in args) {
      if (arg.startsWith('--output-dir=')) {
        outputDir = arg.substring('--output-dir='.length);
      } else if (arg == '--verbose-output') {
        verboseOutput = true;
      } else {
        flutterTestArgs.add(arg);
      }
    }

    return _FlutterTestFailureOptions(
      outputDir: outputDir,
      verboseOutput: verboseOutput,
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
