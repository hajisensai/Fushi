import 'dart:io';

import 'test_flow/comprehensive_test_executor.dart';
import 'test_flow/comprehensive_test_matrix.dart';
import 'test_flow/comprehensive_test_reporter.dart';

Future<void> main(List<String> args) async {
  final _RunnerOptions options = _RunnerOptions.parse(args);
  final HostPlatformId host = _hostPlatform();
  final Set<TestPlatformId> platforms = options.platforms;
  final Set<ScenarioId> scenarios = options.scenarios;
  final String outputDir = options.reportDir ??
      '../.codex-test/comprehensive/${DateTime.now().toIso8601String().replaceAll(':', '-')}';

  final ComprehensiveReport report;
  if (options.dryRun) {
    report = buildDryRunReport(
      matrix: buildComprehensiveMatrix(),
      selectedPlatforms: platforms,
      selectedScenarios: scenarios,
      hostPlatform: host,
    );
  } else {
    report = await buildExecutionReport(
      matrix: buildComprehensiveMatrix(),
      selectedPlatforms: platforms,
      selectedScenarios: scenarios,
      hostPlatform: host,
      outputDir: outputDir,
      streamOutput: options.verboseOutput,
    );
  }
  writeComprehensiveReport(report, outputDir);

  stdout.writeln('Comprehensive test report: $outputDir');
  if (report.hasFailures) {
    final String summary = renderComprehensiveFailureSummary(report);
    if (summary.isNotEmpty) {
      stderr.writeln(summary);
    }
    exitCode = 1;
  }
}

HostPlatformId _hostPlatform() {
  if (Platform.isLinux) return HostPlatformId.linux;
  if (Platform.isWindows) return HostPlatformId.windows;
  if (Platform.isMacOS) return HostPlatformId.macos;
  throw UnsupportedError(
    'Unsupported host platform: ${Platform.operatingSystem}',
  );
}

class _RunnerOptions {
  const _RunnerOptions({
    required this.platforms,
    required this.scenarios,
    required this.dryRun,
    required this.reportDir,
    required this.verboseOutput,
  });

  final Set<TestPlatformId> platforms;
  final Set<ScenarioId> scenarios;
  final bool dryRun;
  final String? reportDir;
  final bool verboseOutput;

  static _RunnerOptions parse(List<String> args) {
    Set<TestPlatformId> platforms = TestPlatformId.values.toSet();
    Set<ScenarioId> scenarios = ScenarioId.values.toSet();
    bool dryRun = false;
    String? reportDir;
    bool verboseOutput = false;

    for (final String arg in args) {
      if (arg == '--dry-run') {
        dryRun = true;
      } else if (arg.startsWith('--platform=')) {
        platforms = _parsePlatforms(arg.substring('--platform='.length));
      } else if (arg.startsWith('--only=')) {
        scenarios = _parseScenarios(arg.substring('--only='.length));
      } else if (arg.startsWith('--report-dir=')) {
        reportDir = arg.substring('--report-dir='.length);
      } else if (arg == '--verbose-output') {
        verboseOutput = true;
      } else {
        stderr.writeln('Unknown argument: $arg');
        exit(64);
      }
    }

    return _RunnerOptions(
      platforms: platforms,
      scenarios: scenarios,
      dryRun: dryRun,
      reportDir: reportDir,
      verboseOutput: verboseOutput,
    );
  }

  static Set<TestPlatformId> _parsePlatforms(String raw) {
    if (raw == 'all') return TestPlatformId.values.toSet();
    return raw.split(',').map((String value) {
      return TestPlatformId.values.singleWhere(
        (TestPlatformId platform) => platform.name == value.trim(),
        orElse: () => throw FormatException('Unknown platform: $value'),
      );
    }).toSet();
  }

  static Set<ScenarioId> _parseScenarios(String raw) {
    if (raw == 'all') return ScenarioId.values.toSet();
    return raw.split(',').map((String value) {
      return ScenarioId.values.singleWhere(
        (ScenarioId scenario) => scenario.name == value.trim(),
        orElse: () => throw FormatException('Unknown scenario: $value'),
      );
    }).toSet();
  }
}
