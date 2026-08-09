import 'dart:convert';
import 'dart:io';

import 'comprehensive_test_matrix.dart';
import 'comprehensive_test_reporter.dart';

typedef ComprehensiveCommandRunner = Future<CommandResult> Function(
  CommandRequest request,
);

class CommandInvocation {
  const CommandInvocation({
    required this.executable,
    required this.args,
    required this.displayCommand,
  });

  final String executable;
  final List<String> args;
  final String displayCommand;
}

class CommandRequest {
  const CommandRequest({
    required this.platform,
    required this.scenario,
    required this.command,
    required this.invocation,
    required this.workingDirectory,
    required this.outputDir,
    required this.streamOutput,
  });

  final TestPlatformId platform;
  final ScenarioId scenario;
  final String command;
  final CommandInvocation invocation;
  final String workingDirectory;
  final String outputDir;
  final bool streamOutput;
}

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;

  bool get succeeded => exitCode == 0;
}

CommandInvocation buildCommandInvocation(
  String command, {
  required TestPlatformId platform,
}) {
  final List<String> tokens = _splitCommandLine(command);
  if (tokens.isEmpty) {
    throw const FormatException('Command must not be empty');
  }

  final String executable = _resolveExecutable(tokens.first);
  final List<String> args = <String>[...tokens.skip(1)];
  if (_isFlutterDrive(tokens)) {
    if (!_hasDriverArg(args)) {
      args.add('--driver=test_driver/integration_test.dart');
    }
    if (!_hasDeviceArg(args) && platform != TestPlatformId.android) {
      args.addAll(<String>['-d', _desktopDeviceId(platform)]);
    }
  }

  return CommandInvocation(
    executable: executable,
    args: args,
    displayCommand: <String>[tokens.first, ...args].join(' '),
  );
}

Future<ComprehensiveReport> buildExecutionReport({
  required List<PlatformPlan> matrix,
  required Set<TestPlatformId> selectedPlatforms,
  required Set<ScenarioId> selectedScenarios,
  required HostPlatformId hostPlatform,
  required String outputDir,
  String workingDirectory = '.',
  ComprehensiveCommandRunner commandRunner = runProcessCommand,
  bool streamOutput = false,
}) async {
  final Directory dir = Directory(outputDir)..createSync(recursive: true);
  final List<ScenarioReport> entries = <ScenarioReport>[];

  for (final PlatformPlan plan in matrix) {
    if (!selectedPlatforms.contains(plan.platform)) continue;

    final bool hostMissing = !plan.supportsHost(hostPlatform);

    for (final TestScenario scenario in plan.scenarios) {
      if (!selectedScenarios.contains(scenario.id)) continue;
      if (hostMissing) {
        entries.add(ScenarioReport(
          platform: plan.platform,
          scenario: scenario.id,
          status: ScenarioStatus.blocked,
          commands: scenario.commands,
          assertions: scenario.assertions,
          evidence: scenario.evidence,
          blockedReason: plan.blockedReasonForHost(hostPlatform),
        ));
        continue;
      }

      final List<String> evidence = <String>[...scenario.evidence];
      int exitCode = 0;
      int durationMs = 0;
      String failureReason = '';
      for (int i = 0; i < scenario.commands.length; i++) {
        final String command = scenario.commands[i];
        final CommandInvocation invocation = buildCommandInvocation(
          command,
          platform: plan.platform,
        );
        final CommandResult result = await commandRunner(CommandRequest(
          platform: plan.platform,
          scenario: scenario.id,
          command: command,
          invocation: invocation,
          workingDirectory: workingDirectory,
          outputDir: dir.path,
          streamOutput: streamOutput,
        ));
        durationMs += result.duration.inMilliseconds;

        final String suffix = scenario.commands.length == 1 ? '' : '_$i';
        final File stdoutFile = File(
          '${dir.path}/${plan.platform.name}_${scenario.id.name}${suffix}_stdout.log',
        );
        final File stderrFile = File(
          '${dir.path}/${plan.platform.name}_${scenario.id.name}${suffix}_stderr.log',
        );
        stdoutFile.writeAsStringSync(result.stdout, flush: true);
        stderrFile.writeAsStringSync(result.stderr, flush: true);
        evidence
          ..add(stdoutFile.path)
          ..add(stderrFile.path);

        if (!result.succeeded) {
          exitCode = result.exitCode;
          failureReason = 'Command exited with $exitCode: '
              '${requestDisplay(plan.platform, scenario.id, command)}';
          break;
        }

        final String? outputFailure = validateOutputExpectations(
          result,
          scenario.outputExpectations,
        );
        if (outputFailure != null) {
          exitCode = 1;
          failureReason = outputFailure;
          break;
        }
      }

      entries.add(ScenarioReport(
        platform: plan.platform,
        scenario: scenario.id,
        status: exitCode == 0 ? ScenarioStatus.passed : ScenarioStatus.failed,
        commands: scenario.commands,
        assertions: scenario.assertions,
        evidence: evidence,
        failureReason: failureReason,
        exitCode: exitCode,
        durationMs: durationMs,
      ));
    }
  }

  return ComprehensiveReport(entries: entries);
}

String requestDisplay(
  TestPlatformId platform,
  ScenarioId scenario,
  String command,
) {
  return '${platform.name}/${scenario.name}: $command';
}

String? validateOutputExpectations(
  CommandResult result,
  List<OutputExpectation> expectations,
) {
  for (final OutputExpectation expectation in expectations) {
    final String haystack = _outputForExpectation(result, expectation.stream);
    final bool containsText = haystack.contains(expectation.text);
    switch (expectation.kind) {
      case OutputExpectationKind.contains:
        if (!containsText) {
          return 'Missing required output "${expectation.text}" in '
              '${expectation.stream.name}.';
        }
      case OutputExpectationKind.excludes:
        if (containsText) {
          return 'Forbidden output "${expectation.text}" appeared in '
              '${expectation.stream.name}.';
        }
    }
  }
  return null;
}

String _outputForExpectation(
  CommandResult result,
  OutputExpectationStream stream,
) {
  return switch (stream) {
    OutputExpectationStream.stdout => result.stdout,
    OutputExpectationStream.stderr => result.stderr,
    OutputExpectationStream.combined => '${result.stdout}\n${result.stderr}',
  };
}

Future<CommandResult> runProcessCommand(CommandRequest request) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  // Default to keeping child output in report artifacts. `streamOutput` is a
  // diagnostic escape hatch for jobs where live logs are more useful than a
  // concise failure summary.
  // .codex-test/ — which CI never uploads — so a failing `flutter drive`
  final Process process = await Process.start(
    request.invocation.executable,
    request.invocation.args,
    workingDirectory: request.workingDirectory,
    runInShell: Platform.isWindows,
  );

  final StringBuffer outBuffer = StringBuffer();
  final StringBuffer errBuffer = StringBuffer();
  const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);
  final String tag = '[${request.platform.name}/${request.scenario.name}] ';

  final Future<void> stdoutDone =
      process.stdout.transform(decoder).forEach((String chunk) {
    outBuffer.write(chunk);
    if (request.streamOutput) {
      stdout.write(chunk);
    }
  });
  final Future<void> stderrDone =
      process.stderr.transform(decoder).forEach((String chunk) {
    errBuffer.write(chunk);
    if (request.streamOutput) {
      stderr.write(chunk);
    }
  });

  final int exitCode = await process.exitCode;
  await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
  stopwatch.stop();

  if (exitCode != 0) {
    stderr.writeln('${tag}exited with $exitCode '
        '(${request.invocation.displayCommand})');
  }

  return CommandResult(
    exitCode: exitCode,
    stdout: outBuffer.toString(),
    stderr: errBuffer.toString(),
    duration: stopwatch.elapsed,
  );
}

bool _isFlutterDrive(List<String> tokens) {
  return tokens.length >= 2 &&
      tokens.first == 'flutter' &&
      tokens.elementAt(1) == 'drive';
}

bool _hasDeviceArg(List<String> args) {
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '-d' || args[i] == '--device-id') return true;
    if (args[i].startsWith('-d=')) return true;
    if (args[i].startsWith('--device-id=')) return true;
  }
  return false;
}

bool _hasDriverArg(List<String> args) {
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--driver') return true;
    if (args[i].startsWith('--driver=')) return true;
  }
  return false;
}

String _desktopDeviceId(TestPlatformId platform) => switch (platform) {
      TestPlatformId.windows => 'windows',
      TestPlatformId.macos => 'macos',
      TestPlatformId.android => 'android',
    };

String _resolveExecutable(String executable) {
  if (!Platform.isWindows) return executable;
  if (executable == 'flutter') {
    const String flutter =
        r'D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat';
    if (File(flutter).existsSync()) return flutter;
  }
  if (executable == 'dart') {
    const String dart =
        r'D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat';
    if (File(dart).existsSync()) return dart;
  }
  return executable;
}

List<String> _splitCommandLine(String command) {
  final List<String> tokens = <String>[];
  final StringBuffer current = StringBuffer();
  String? quote;

  for (int i = 0; i < command.length; i++) {
    final String char = command[i];
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        current.write(char);
      }
      continue;
    }

    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }

    if (char.trim().isEmpty) {
      if (current.isNotEmpty) {
        tokens.add(current.toString());
        current.clear();
      }
      continue;
    }

    current.write(char);
  }

  if (quote != null) {
    throw FormatException('Unclosed quote in command: $command');
  }
  if (current.isNotEmpty) {
    tokens.add(current.toString());
  }
  return tokens;
}
