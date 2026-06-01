enum TestPlatformId {
  android,
  windows,
  macos,
}

enum ScenarioId {
  dictionaryImportSearch,
  fontImportApply,
  syncSettingsEffect,
  syncP2pRoundtrip,
  bookImportOpen,
  readerPagination,
  readerPageTurnLookup,
  settingsControlsEffect,
  regressionOpenBugs,
}

class TestScenario {
  const TestScenario({
    required this.id,
    required this.commands,
    required this.assertions,
    required this.evidence,
    this.requiredFixtures = const <String>[],
  });

  final ScenarioId id;
  final List<String> commands;
  final List<String> assertions;
  final List<String> evidence;
  final List<String> requiredFixtures;
}

class PlatformPlan {
  const PlatformPlan({
    required this.platform,
    required this.scenarios,
    this.blockedWhenHostMissing = false,
    this.hostMissingMessage = '',
  });

  final TestPlatformId platform;
  final List<TestScenario> scenarios;
  final bool blockedWhenHostMissing;
  final String hostMissingMessage;
}

List<PlatformPlan> buildComprehensiveMatrix() {
  return const <PlatformPlan>[
    PlatformPlan(
      platform: TestPlatformId.android,
      scenarios: <TestScenario>[
        TestScenarios.dictionaryImportSearch,
        TestScenarios.fontImportApply,
        TestScenarios.syncSettingsEffect,
        TestScenarios.syncP2pRoundtrip,
        TestScenarios.bookImportOpen,
        TestScenarios.readerPagination,
        TestScenarios.readerPageTurnLookup,
        TestScenarios.settingsControlsEffect,
        TestScenarios.regressionOpenBugs,
      ],
    ),
    PlatformPlan(
      platform: TestPlatformId.windows,
      scenarios: <TestScenario>[
        TestScenarios.dictionaryImportSearch,
        TestScenarios.fontImportApply,
        TestScenarios.syncSettingsEffect,
        TestScenarios.syncP2pRoundtrip,
        TestScenarios.bookImportOpen,
        TestScenarios.readerPagination,
        TestScenarios.readerPageTurnLookup,
        TestScenarios.settingsControlsEffect,
        TestScenarios.regressionOpenBugs,
      ],
    ),
    PlatformPlan(
      platform: TestPlatformId.macos,
      blockedWhenHostMissing: true,
      hostMissingMessage:
          'macOS scenarios require running this runner on a macOS host.',
      scenarios: <TestScenario>[
        TestScenarios.dictionaryImportSearch,
        TestScenarios.fontImportApply,
        TestScenarios.syncSettingsEffect,
        TestScenarios.syncP2pRoundtrip,
        TestScenarios.bookImportOpen,
        TestScenarios.readerPagination,
        TestScenarios.readerPageTurnLookup,
        TestScenarios.settingsControlsEffect,
        TestScenarios.regressionOpenBugs,
      ],
    ),
  ];
}

abstract final class TestScenarios {
  static const TestScenario dictionaryImportSearch = TestScenario(
    id: ScenarioId.dictionaryImportSearch,
    commands: <String>[
      'flutter drive --target=integration_test/comprehensive_imports_test.dart',
    ],
    assertions: <String>[
      'dictionary import completes',
      'known lookup term returns dictionary result evidence',
    ],
    evidence: <String>[
      'report.json',
      'integration log',
      'screenshot when supported',
    ],
    requiredFixtures: <String>['test-yomitan.zip'],
  );

  static const TestScenario fontImportApply = TestScenario(
    id: ScenarioId.fontImportApply,
    commands: <String>[
      'flutter drive --target=integration_test/comprehensive_imports_test.dart',
    ],
    assertions: <String>[
      'custom font entry is persisted enabled',
      'reader custom font CSS contains @font-face and expected family',
    ],
    evidence: <String>['report.json', 'integration log'],
    requiredFixtures: <String>['test-font.ttf'],
  );

  static const TestScenario syncSettingsEffect = TestScenario(
    id: ScenarioId.syncSettingsEffect,
    commands: <String>[
      'flutter drive --target=integration_test/comprehensive_settings_test.dart',
    ],
    assertions: <String>[
      'sync backend picker writes through SyncRepository',
      'sync content toggles persist and reload',
    ],
    evidence: <String>['report.json', 'integration log'],
  );

  static const TestScenario syncP2pRoundtrip = TestScenario(
    id: ScenarioId.syncP2pRoundtrip,
    commands: <String>[
      'flutter test test/sync/hibiki_p2p_roundtrip_test.dart',
    ],
    assertions: <String>[
      'local Hibiki sync server stores progress JSON',
      'client backend reads the uploaded progress JSON back',
    ],
    evidence: <String>['report.json', 'server log', 'client log'],
  );

  static const TestScenario bookImportOpen = TestScenario(
    id: ScenarioId.bookImportOpen,
    commands: <String>[
      'flutter drive --target=integration_test/comprehensive_imports_test.dart',
    ],
    assertions: <String>[
      'marker EPUB import creates a shelf entry',
      'Hoshi WebView appears and content-ready marker is visible',
    ],
    evidence: <String>['report.json', 'screenshot when supported'],
    requiredFixtures: <String>['marker.epub'],
  );

  static const TestScenario readerPagination = TestScenario(
    id: ScenarioId.readerPagination,
    commands: <String>[
      'flutter drive --target=integration_test/reader_pagination_test.dart',
    ],
    assertions: <String>[
      'pagination invariants I1-I7 pass',
      'position restoration invariants I9-I10 pass',
    ],
    evidence: <String>['report.json', 'pagination log'],
    requiredFixtures: <String>['marker.epub'],
  );

  static const TestScenario readerPageTurnLookup = TestScenario(
    id: ScenarioId.readerPageTurnLookup,
    commands: <String>[
      'flutter drive --target=integration_test/comprehensive_reader_lookup_test.dart',
    ],
    assertions: <String>[
      'page forward changes visible marker or progress',
      'lookup after page turn returns dictionary result evidence',
    ],
    evidence: <String>[
      'report.json',
      'integration log',
      'screenshot when supported',
    ],
    requiredFixtures: <String>['marker.epub', 'test-yomitan.zip'],
  );

  static const TestScenario settingsControlsEffect = TestScenario(
    id: ScenarioId.settingsControlsEffect,
    commands: <String>[
      'flutter drive --target=integration_test/comprehensive_settings_test.dart',
    ],
    assertions: <String>[
      'Switch controls change, persist, and restore',
      'SegmentedButton controls change, persist or affect rendered state, and restore',
      'Slider and Stepper controls change, persist or affect rendered state, and restore',
      'picker-like rows change persisted values and restore',
    ],
    evidence: <String>['report.json', 'integration log'],
  );

  static const TestScenario regressionOpenBugs = TestScenario(
    id: ScenarioId.regressionOpenBugs,
    commands: <String>[
      'flutter drive --target=integration_test/regression_test.dart',
    ],
    assertions: <String>[
      'each open regression is retested with evidence or marked blocked',
      'layout regressions include bounds evidence',
    ],
    evidence: <String>[
      'report.json',
      '.codex-test screenshot',
      '.codex-test UI hierarchy',
      'logcat or bounds where required',
    ],
    requiredFixtures: <String>['kagami.epub', 'kagami.m4b', 'kagami.srt'],
  );
}
