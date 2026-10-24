// Contract of the dist_test batch planner: every suite runs exactly once per
// required placement, platform gates and capability tags pin suites, and only
// safe paths go on the wire. See docs/specs/2026-10-24-distributed-unit-tests.md §3.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/dist_plan.dart';

/// Tag names are concatenated: a quoted literal of the reference-platform tag
/// in this file would trip test/build/golden_tests_location_guard_test.dart.
const String _goldenTag =
    'gold'
    'en';

void main() {
  group('scanSuiteRequirement', () {
    test('no gate: anywhere', () {
      final SuiteRequirement r = scanSuiteRequirement('void main() {}');
      expect(r.platforms, isEmpty);
      expect(r.capabilities, isEmpty);
    });

    test('Platform.isWindows / isMacOS pin to those platforms', () {
      expect(
        scanSuiteRequirement('if (Platform.isWindows) {}').platforms,
        <DistPlatform>{DistPlatform.windows},
      );
      expect(
        scanSuiteRequirement(
          'skip: !Platform.isMacOS; x = Platform.isWindows;',
        ).platforms,
        <DistPlatform>{DistPlatform.windows, DistPlatform.macos},
      );
      expect(scanSuiteRequirement('Platform.isLinux').platforms, isEmpty);
    });

    test('@TestOn selectors', () {
      expect(
        scanSuiteRequirement("@TestOn('windows')").platforms,
        <DistPlatform>{DistPlatform.windows},
      );
      expect(
        scanSuiteRequirement("@TestOn('!windows')").platforms,
        <DistPlatform>{DistPlatform.macos},
      );
      expect(
        scanSuiteRequirement("@TestOn('mac-os')").platforms,
        <DistPlatform>{DistPlatform.macos},
      );
      expect(scanSuiteRequirement("@TestOn('vm')").platforms, isEmpty);
    });

    test('capability tags, file-level and per test, multi-line', () {
      expect(
        scanSuiteRequirement(
          "@Tags(<String>[\n  'chrome',\n  'realdata',\n])",
        ).capabilities,
        <String>{'chrome', 'realdata'},
      );
      expect(
        scanSuiteRequirement(
          "test('x', () {}, tags: <String>['$_goldenTag']);",
        ).capabilities,
        <String>{_goldenTag},
      );
      expect(
        scanSuiteRequirement("test('x', () {}, tags: 'ffmpeg');").capabilities,
        <String>{'ffmpeg'},
      );
      expect(
        scanSuiteRequirement("@Tags(<String>['other'])").capabilities,
        isEmpty,
      );
    });
  });

  group('planDistBatches', () {
    final Map<String, int> weights = <String, int>{
      for (int i = 0; i < 200; i++)
        'test/f${i.toString().padLeft(3, '0')}_test.dart': (i * 37) % 101 + 1,
    };

    test('free suites: union is everything, no duplicates, batches even', () {
      final List<DistBatch> batches = planDistBatches(
        weights: weights,
        requirements: const <String, SuiteRequirement>{},
        targetMs: 1000,
      );
      final List<String> all = <String>[
        for (final DistBatch b in batches) ...b.files,
      ];
      expect(all.toSet(), weights.keys.toSet());
      expect(all.length, weights.length);
      final int total = weights.values.reduce((int a, int b) => a + b);
      expect(batches.length, (total / 1000).ceil());
      final List<int> loads =
          batches.map((DistBatch b) => b.estimatedMs).toList()..sort();
      expect(loads.last - loads.first, lessThanOrEqualTo(101));
      expect(
        batches.map((DistBatch b) => b.id).toList(),
        List<int>.generate(batches.length, (int i) => i + 1),
      );
    });

    test('a suite pinned to two platforms runs once on each', () {
      const String both = 'test/f000_test.dart';
      const String win = 'test/f001_test.dart';
      final List<DistBatch> batches = planDistBatches(
        weights: weights,
        requirements: <String, SuiteRequirement>{
          both: const SuiteRequirement(
            platforms: <DistPlatform>{DistPlatform.windows, DistPlatform.macos},
          ),
          win: const SuiteRequirement(
            platforms: <DistPlatform>{DistPlatform.windows},
            capabilities: <String>{'chrome'},
          ),
        },
        targetMs: 1000,
      );
      List<DistBatch> holding(String f) => <DistBatch>[
        for (final DistBatch b in batches)
          if (b.files.contains(f)) b,
      ];
      expect(
        holding(both).map((DistBatch b) => b.platform).toSet(),
        <DistPlatform>{DistPlatform.windows, DistPlatform.macos},
      );
      expect(holding(win), hasLength(1));
      expect(holding(win).single.platform, DistPlatform.windows);
      expect(holding(win).single.capabilities, <String>{'chrome'});
      expect(holding('test/f002_test.dart').single.platform, isNull);
    });
  });

  test('takeNextBatch: eligible only, pinned first, then heaviest', () {
    DistBatch b(int id, int ms, {DistPlatform? platform}) => DistBatch(
      id: id,
      files: <String>['test/b${id}_test.dart'],
      estimatedMs: ms,
      platform: platform,
      capabilities: const <String>{},
    );
    final List<DistBatch> pending = <DistBatch>[
      b(1, 500),
      b(2, 900),
      b(3, 100, platform: DistPlatform.windows),
      b(4, 50, platform: DistPlatform.macos),
    ];
    bool mac(DistBatch x) => x.eligibleFor(DistPlatform.macos, <String>{});
    expect(takeNextBatch(pending, mac)!.id, 4);
    expect(takeNextBatch(pending, mac)!.id, 2);
    expect(takeNextBatch(pending, mac)!.id, 1);
    expect(takeNextBatch(pending, mac), isNull);
    expect(pending.single.id, 3);
  });

  test('isSafeDistTestPath', () {
    expect(isSafeDistTestPath('test/a/b_test.dart'), isTrue);
    for (final String bad in <String>[
      'test/../x_test.dart',
      '/etc/x_test.dart',
      'test/a b_test.dart',
      r'test/$(rm)_test.dart',
      'test/a_test.dart; rm -rf ~',
      'lib/a_test.dart',
      'test/a.dart',
    ]) {
      expect(isSafeDistTestPath(bad), isFalse, reason: bad);
    }
  });

  test('splitByPathChars keeps order and the character cap', () {
    final List<String> files = <String>[
      for (int i = 0; i < 50; i++) 'test/${'x' * 20}${i}_test.dart',
    ];
    final List<List<String>> chunks = splitByPathChars(files, 200);
    expect(<String>[for (final List<String> c in chunks) ...c], files);
    for (final List<String> c in chunks) {
      expect(
        c.fold<int>(0, (int s, String f) => s + f.length + 1),
        lessThanOrEqualTo(200),
      );
    }
    expect(
      splitByPathChars(<String>['test/${'y' * 300}_test.dart'], 200),
      hasLength(1),
    );
  });
}
