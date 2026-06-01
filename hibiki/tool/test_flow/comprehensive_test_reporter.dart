import 'dart:convert';
import 'dart:io';

import 'comprehensive_test_matrix.dart';

enum ScenarioStatus {
  pending,
  blocked,
  passed,
  failed,
}

class ScenarioReport {
  const ScenarioReport({
    required this.platform,
    required this.scenario,
    required this.status,
    required this.commands,
    required this.assertions,
    required this.evidence,
    this.blockedReason = '',
    this.exitCode,
    this.durationMs,
  });

  final TestPlatformId platform;
  final ScenarioId scenario;
  final ScenarioStatus status;
  final List<String> commands;
  final List<String> assertions;
  final List<String> evidence;
  final String blockedReason;
  final int? exitCode;
  final int? durationMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'platform': platform.name,
        'scenario': scenario.name,
        'status': status.name,
        'commands': commands,
        'assertions': assertions,
        'evidence': evidence,
        'blockedReason': blockedReason,
        'exitCode': exitCode,
        'durationMs': durationMs,
      };
}

class ComprehensiveReport {
  const ComprehensiveReport({required this.entries});

  final List<ScenarioReport> entries;

  bool get hasFailures => entries.any((ScenarioReport entry) {
        return entry.status == ScenarioStatus.failed;
      });

  Map<String, Object> toJson() => <String, Object>{
        'entries':
            entries.map((ScenarioReport entry) => entry.toJson()).toList(),
      };
}

ComprehensiveReport buildDryRunReport({
  required List<PlatformPlan> matrix,
  required Set<TestPlatformId> selectedPlatforms,
  required Set<ScenarioId> selectedScenarios,
  required TestPlatformId hostPlatform,
}) {
  final List<ScenarioReport> entries = <ScenarioReport>[];
  for (final PlatformPlan plan in matrix) {
    if (!selectedPlatforms.contains(plan.platform)) continue;
    final bool hostMissing = plan.platform != hostPlatform &&
        plan.platform == TestPlatformId.macos &&
        plan.blockedWhenHostMissing;
    for (final TestScenario scenario in plan.scenarios) {
      if (!selectedScenarios.contains(scenario.id)) continue;
      entries.add(ScenarioReport(
        platform: plan.platform,
        scenario: scenario.id,
        status: hostMissing ? ScenarioStatus.blocked : ScenarioStatus.pending,
        commands: scenario.commands,
        assertions: scenario.assertions,
        evidence: scenario.evidence,
        blockedReason: hostMissing ? plan.hostMissingMessage : '',
      ));
    }
  }
  return ComprehensiveReport(entries: entries);
}

void writeComprehensiveReport(ComprehensiveReport report, String outputDir) {
  final Directory dir = Directory(outputDir);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  File('${dir.path}/report.json').writeAsStringSync(
    jsonEncode(report.toJson()),
    flush: true,
  );
  File('${dir.path}/report.md').writeAsStringSync(
    _renderMarkdown(report),
    flush: true,
  );
}

String _renderMarkdown(ComprehensiveReport report) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('# Hibiki Comprehensive Test Report')
    ..writeln();
  for (final ScenarioReport entry in report.entries) {
    buffer
      ..writeln('## ${_platformLabel(entry.platform)} / ${entry.scenario.name}')
      ..writeln()
      ..writeln('- status: ${entry.status.name}');
    if (entry.blockedReason.isNotEmpty) {
      buffer.writeln('- blockedReason: ${entry.blockedReason}');
    }
    if (entry.exitCode != null) {
      buffer.writeln('- exitCode: ${entry.exitCode}');
    }
    if (entry.durationMs != null) {
      buffer.writeln('- durationMs: ${entry.durationMs}');
    }
    buffer
      ..writeln('- commands: ${entry.commands.join(' | ')}')
      ..writeln('- assertions: ${entry.assertions.join(' | ')}')
      ..writeln('- evidence: ${entry.evidence.join(' | ')}')
      ..writeln();
  }
  return buffer.toString();
}

String _platformLabel(TestPlatformId platform) => switch (platform) {
      TestPlatformId.android => 'Android',
      TestPlatformId.windows => 'Windows',
      TestPlatformId.macos => 'macOS',
    };
