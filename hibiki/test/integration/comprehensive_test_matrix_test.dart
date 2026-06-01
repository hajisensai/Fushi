import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../tool/test_flow/comprehensive_test_executor.dart';
import '../../tool/test_flow/comprehensive_test_matrix.dart';
import '../../tool/test_flow/comprehensive_test_reporter.dart';
import '../../tool/test_flow/test_fixture_generator.dart';

void main() {
  group('comprehensive test matrix', () {
    test('covers android, windows, and macos', () {
      final List<PlatformPlan> matrix = buildComprehensiveMatrix();

      expect(
        matrix.map((PlatformPlan plan) => plan.platform).toSet(),
        <TestPlatformId>{
          TestPlatformId.android,
          TestPlatformId.windows,
          TestPlatformId.macos,
        },
      );
    });

    test('every platform has every required scenario', () {
      final List<PlatformPlan> matrix = buildComprehensiveMatrix();
      const Set<ScenarioId> required = <ScenarioId>{
        ScenarioId.dictionaryImportSearch,
        ScenarioId.fontImportApply,
        ScenarioId.syncSettingsEffect,
        ScenarioId.syncP2pRoundtrip,
        ScenarioId.bookImportOpen,
        ScenarioId.readerPagination,
        ScenarioId.readerPageTurnLookup,
        ScenarioId.settingsControlsEffect,
        ScenarioId.regressionOpenBugs,
      };

      for (final PlatformPlan plan in matrix) {
        expect(
          plan.scenarios.map((TestScenario scenario) => scenario.id).toSet(),
          required,
          reason: '${plan.platform.name} must not drift from the shared matrix',
        );
      }
    });

    test('every scenario declares commands, assertions, and evidence', () {
      final List<PlatformPlan> matrix = buildComprehensiveMatrix();

      for (final PlatformPlan plan in matrix) {
        for (final TestScenario scenario in plan.scenarios) {
          expect(scenario.commands, isNotEmpty,
              reason: '${plan.platform.name}/${scenario.id.name} commands');
          expect(scenario.assertions, isNotEmpty,
              reason: '${plan.platform.name}/${scenario.id.name} assertions');
          expect(scenario.evidence, isNotEmpty,
              reason: '${plan.platform.name}/${scenario.id.name} evidence');
        }
      }
    });

    test('non-macos host blocks macos instead of silently passing it', () {
      final PlatformPlan macos = buildComprehensiveMatrix().singleWhere(
        (PlatformPlan plan) => plan.platform == TestPlatformId.macos,
      );

      if (!Platform.isMacOS) {
        expect(macos.blockedWhenHostMissing, isTrue);
        expect(macos.hostMissingMessage, contains('macOS'));
      }
    });

    test('dry-run report writes json and markdown with blocked macos status',
        () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('hibiki_comprehensive_');
      addTearDown(() {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });

      final ComprehensiveReport report = buildDryRunReport(
        matrix: buildComprehensiveMatrix(),
        selectedPlatforms: const <TestPlatformId>{
          TestPlatformId.android,
          TestPlatformId.windows,
          TestPlatformId.macos,
        },
        selectedScenarios: ScenarioId.values.toSet(),
        hostPlatform: TestPlatformId.windows,
      );

      writeComprehensiveReport(report, dir.path);

      final File json = File('${dir.path}/report.json');
      final File markdown = File('${dir.path}/report.md');
      expect(json.existsSync(), isTrue);
      expect(markdown.existsSync(), isTrue);
      expect(json.readAsStringSync(), contains('"platform":"macos"'));
      expect(json.readAsStringSync(), contains('"status":"blocked"'));
      expect(markdown.readAsStringSync(), contains('macOS'));
      expect(markdown.readAsStringSync(), contains('blocked'));
    });

    test('desktop drive command adds a concrete target device', () {
      final CommandInvocation invocation = buildCommandInvocation(
        'flutter drive --target=integration_test/comprehensive_imports_test.dart',
        platform: TestPlatformId.windows,
      );

      expect(invocation.executable, isNotEmpty);
      expect(
        invocation.args,
        containsAllInOrder(<String>[
          'drive',
          '--target=integration_test/comprehensive_imports_test.dart',
          '--driver=test_driver/integration_test.dart',
          '-d',
          'windows',
        ]),
      );
    });

    test('drive command keeps explicit driver when one is provided', () {
      final CommandInvocation invocation = buildCommandInvocation(
        'flutter drive --driver=test_driver/custom.dart --target=integration_test/comprehensive_imports_test.dart',
        platform: TestPlatformId.windows,
      );

      expect(
        invocation.args.where((String arg) => arg.startsWith('--driver')),
        <String>['--driver=test_driver/custom.dart'],
      );
    });

    test('execution report records pass fail statuses and log evidence',
        () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('hibiki_comprehensive_exec_');
      addTearDown(() {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });

      final ComprehensiveReport report = await buildExecutionReport(
        matrix: buildComprehensiveMatrix(),
        selectedPlatforms: const <TestPlatformId>{TestPlatformId.windows},
        selectedScenarios: const <ScenarioId>{
          ScenarioId.syncP2pRoundtrip,
          ScenarioId.readerPagination,
        },
        hostPlatform: TestPlatformId.windows,
        outputDir: dir.path,
        commandRunner: (CommandRequest request) async {
          final bool shouldPass =
              request.scenario == ScenarioId.syncP2pRoundtrip;
          return CommandResult(
            exitCode: shouldPass ? 0 : 1,
            stdout: 'stdout for ${request.scenario.name}',
            stderr: shouldPass ? '' : 'failure for ${request.scenario.name}',
            duration: const Duration(milliseconds: 7),
          );
        },
      );

      final ScenarioReport passed = report.entries.singleWhere(
        (ScenarioReport entry) => entry.scenario == ScenarioId.syncP2pRoundtrip,
      );
      final ScenarioReport failed = report.entries.singleWhere(
        (ScenarioReport entry) => entry.scenario == ScenarioId.readerPagination,
      );

      expect(passed.status, ScenarioStatus.passed);
      expect(failed.status, ScenarioStatus.failed);
      expect(failed.exitCode, 1);
      expect(
        failed.evidence,
        contains(endsWith('windows_readerPagination_stderr.log')),
      );
      expect(
        File('${dir.path}/windows_readerPagination_stderr.log')
            .readAsStringSync(),
        contains('failure for readerPagination'),
      );
      expect(report.hasFailures, isTrue);
    });

    test('fixture generator writes required comprehensive test files',
        () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('hibiki_comprehensive_fx_');
      addTearDown(() {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });

      final FixtureGenerationResult result =
          await generateComprehensiveFixtures(outputDir: dir.path);

      expect(result.markerEpub.existsSync(), isTrue);
      expect(result.dictionaryZip.existsSync(), isTrue);
      expect(result.fontFile.existsSync(), isTrue);
      expect(result.markerEpub.lengthSync(), greaterThan(1024));
      expect(result.dictionaryZip.readAsBytesSync(), isNotEmpty);
      expect(result.fontFile.lengthSync(), greaterThan(64));
    });
  });
}
