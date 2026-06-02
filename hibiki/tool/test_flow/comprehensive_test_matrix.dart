enum TestPlatformId {
  android,
  windows,
  macos,
}

enum HostPlatformId {
  linux,
  windows,
  macos,
}

enum OutputExpectationKind {
  contains,
  excludes,
}

enum OutputExpectationStream {
  stdout,
  stderr,
  combined,
}

enum ScenarioId {
  appSmoke,
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
    required this.outputExpectations,
    this.requiredFixtures = const <String>[],
  });

  final ScenarioId id;
  final List<String> commands;
  final List<String> assertions;
  final List<String> evidence;
  final List<OutputExpectation> outputExpectations;
  final List<String> requiredFixtures;
}

class OutputExpectation {
  const OutputExpectation.contains(
    this.text, {
    this.stream = OutputExpectationStream.combined,
  }) : kind = OutputExpectationKind.contains;

  const OutputExpectation.excludes(
    this.text, {
    this.stream = OutputExpectationStream.combined,
  }) : kind = OutputExpectationKind.excludes;

  final OutputExpectationKind kind;
  final OutputExpectationStream stream;
  final String text;
}

class PlatformPlan {
  const PlatformPlan({
    required this.platform,
    required this.scenarios,
    required this.compatibleHosts,
    this.hostMissingMessage = '',
  });

  final TestPlatformId platform;
  final List<TestScenario> scenarios;
  final Set<HostPlatformId> compatibleHosts;
  final String hostMissingMessage;

  bool get blockedWhenHostMissing =>
      compatibleHosts.length != HostPlatformId.values.length;

  bool supportsHost(HostPlatformId hostPlatform) {
    return compatibleHosts.contains(hostPlatform);
  }

  String blockedReasonForHost(HostPlatformId hostPlatform) {
    if (hostMissingMessage.isNotEmpty) return hostMissingMessage;
    return '${platform.label} scenarios require ${platform.label} host automation; '
        '${hostPlatform.label} cannot run this target.';
  }
}

List<PlatformPlan> buildComprehensiveMatrix() {
  return const <PlatformPlan>[
    PlatformPlan(
      platform: TestPlatformId.android,
      compatibleHosts: <HostPlatformId>{
        HostPlatformId.linux,
        HostPlatformId.windows,
        HostPlatformId.macos,
      },
      scenarios: <TestScenario>[
        TestScenarios.appSmoke,
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
      compatibleHosts: <HostPlatformId>{
        HostPlatformId.windows,
      },
      hostMissingMessage:
          'Windows scenarios require running this runner on a Windows host.',
      scenarios: <TestScenario>[
        TestScenarios.appSmoke,
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
      compatibleHosts: <HostPlatformId>{
        HostPlatformId.macos,
      },
      hostMissingMessage:
          'macOS scenarios require running this runner on a macOS host.',
      scenarios: <TestScenario>[
        TestScenarios.appSmoke,
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

extension TestPlatformLabel on TestPlatformId {
  String get label => switch (this) {
        TestPlatformId.android => 'Android',
        TestPlatformId.windows => 'Windows',
        TestPlatformId.macos => 'macOS',
      };
}

extension HostPlatformLabel on HostPlatformId {
  String get label => switch (this) {
        HostPlatformId.linux => 'Linux',
        HostPlatformId.windows => 'Windows',
        HostPlatformId.macos => 'macOS',
      };
}

abstract final class TestScenarios {
  static const List<OutputExpectation> flutterSuccessOutput =
      <OutputExpectation>[
    OutputExpectation.contains('All tests passed'),
    OutputExpectation.excludes('Some tests failed'),
  ];

  static const TestScenario appSmoke = TestScenario(
    id: ScenarioId.appSmoke,
    commands: <String>[
      'flutter drive --target=integration_test/app_smoke_test.dart',
    ],
    assertions: <String>[
      'app renders a Scaffold within 90 seconds',
      'primary navigation can switch away and back',
      'unexpected FlutterError entries are rejected',
    ],
    evidence: <String>[
      'report.json',
      'integration log',
    ],
    outputExpectations: flutterSuccessOutput,
  );

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
    outputExpectations: flutterSuccessOutput,
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
    outputExpectations: flutterSuccessOutput,
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
    outputExpectations: flutterSuccessOutput,
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
    outputExpectations: flutterSuccessOutput,
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
    outputExpectations: flutterSuccessOutput,
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
    outputExpectations: flutterSuccessOutput,
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
    outputExpectations: flutterSuccessOutput,
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
    outputExpectations: flutterSuccessOutput,
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
    outputExpectations: flutterSuccessOutput,
    requiredFixtures: <String>['kagami.epub', 'kagami.m4b', 'kagami.srt'],
  );
}
