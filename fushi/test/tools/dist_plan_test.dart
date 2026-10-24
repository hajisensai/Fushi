// Contract of the dist_test batch planner: every suite runs exactly once per
// required placement, platform gates and capability tags pin suites, and only
// safe paths go on the wire. See docs/specs/2026-10-24-distributed-unit-tests.md §3.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/dist_plan.dart';

/// The sample sources are assembled from pieces so that this file's own text
/// carries no platform gate or tag the scanner (or
/// test/build/golden_tests_location_guard_test.dart) would act on.
const String _platform = 'Platform.';
const String _testOn =
    '@Test'
    'On';
const String _tags =
    '@Ta'
    'gs';
const String _tagsArg =
    'ta'
    'gs:';
const String _goldenTag =
    'gold'
    'en';
const String _chrome =
    'chr'
    'ome';
const String _realdata =
    'real'
    'data';
const String _ffmpeg =
    'ff'
    'mpeg';

void main() {
  group('scanSuiteRequirement', () {
    test('no gate: anywhere', () {
      final SuiteRequirement r = scanSuiteRequirement('void main() {}');
      expect(r.platforms, isEmpty);
      expect(r.capabilities, isEmpty);
    });

    test('platform checks pin to those platforms', () {
      expect(
        scanSuiteRequirement('if (${_platform}isWindows) {}').platforms,
        <DistPlatform>{DistPlatform.windows},
      );
      expect(
        scanSuiteRequirement(
          'skip: !${_platform}isMacOS; x = ${_platform}isWindows;',
        ).platforms,
        <DistPlatform>{DistPlatform.windows, DistPlatform.macos},
      );
      expect(scanSuiteRequirement('${_platform}isLinux').platforms, isEmpty);
    });

    test('test-on selectors', () {
      expect(
        scanSuiteRequirement("$_testOn('windows')").platforms,
        <DistPlatform>{DistPlatform.windows},
      );
      expect(
        scanSuiteRequirement("$_testOn('!windows')").platforms,
        <DistPlatform>{DistPlatform.macos},
      );
      expect(
        scanSuiteRequirement("$_testOn('mac-os')").platforms,
        <DistPlatform>{DistPlatform.macos},
      );
      expect(scanSuiteRequirement("$_testOn('vm')").platforms, isEmpty);
    });

    test('capability tags, file-level and per test, multi-line', () {
      expect(
        scanSuiteRequirement(
          "$_tags(<String>[\n  '$_chrome',\n  '$_realdata',\n])",
        ).capabilities,
        <String>{_chrome, _realdata},
      );
      expect(
        scanSuiteRequirement(
          "test('x', () {}, $_tagsArg <String>['$_goldenTag']);",
        ).capabilities,
        <String>{_goldenTag},
      );
      expect(
        scanSuiteRequirement(
          "test('x', () {}, $_tagsArg '$_ffmpeg');",
        ).capabilities,
        <String>{_ffmpeg},
      );
      expect(
        scanSuiteRequirement("$_tags(<String>['other'])").capabilities,
        isEmpty,
      );
    });

    test('this file itself is not pinned anywhere', () {
      final SuiteRequirement self = scanSuiteRequirement(
        File('test/tools/dist_plan_test.dart').readAsStringSync(),
      );
      expect(self.platforms, isEmpty);
      expect(self.capabilities, isEmpty);
    });
  });

  group('dist_affinity.json', () {
    test('every pin names an existing suite, platforms and a reason', () {
      final Map<String, Set<DistPlatform>> pins = readDistAffinity(
        File(kDistAffinityPath).readAsStringSync(),
      );
      expect(pins, isNotEmpty);
      for (final MapEntry<String, Set<DistPlatform>> e in pins.entries) {
        expect(File(e.key).existsSync(), isTrue, reason: 'stale pin ${e.key}');
        expect(isSafeDistTestPath(e.key), isTrue, reason: e.key);
      }
    });

    test('a pin replaces the scanned platforms and keeps the tags', () {
      const SuiteRequirement scanned = SuiteRequirement(
        platforms: <DistPlatform>{DistPlatform.macos},
        capabilities: <String>{_chrome},
      );
      final SuiteRequirement pinned = applyDistPin(scanned, <DistPlatform>{
        DistPlatform.windows,
      });
      expect(pinned.platforms, <DistPlatform>{DistPlatform.windows});
      expect(pinned.capabilities, <String>{_chrome});
      expect(applyDistPin(scanned, null), same(scanned));
    });

    test('pins without a reason or with an unknown platform are rejected', () {
      for (final String bad in <String>[
        '{"pins": {"test/a_test.dart": {"platforms": ["windows"]}}}',
        '{"pins": {"test/a_test.dart": {"platforms": [], "reason": "x"}}}',
        '{"pins": {"test/a_test.dart": {"platforms": ["linux"], "reason": "x"}}}',
      ]) {
        expect(
          () => readDistAffinity(bad),
          throwsA(isA<FormatException>()),
          reason: bad,
        );
      }
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
      // 80 % of the work in ~1000 ms batches, the lightest 20 % in ~250 ms
      // batches that sort to the end of the queue.
      final List<int> loads = batches
          .map((DistBatch b) => b.estimatedMs)
          .toList();
      expect(loads, orderedEquals(List<int>.of(loads)..sort((a, b) => b - a)));
      expect(loads.first, lessThanOrEqualTo(1000 + 101));
      expect(loads.last, lessThanOrEqualTo(250 + 101));
      final int tailMs = batches
          .where((DistBatch b) => b.estimatedMs <= 250 + 101)
          .fold<int>(0, (int s, DistBatch b) => s + b.estimatedMs);
      expect(tailMs, inInclusiveRange(total * 0.15, total * 0.3));
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
            capabilities: <String>{_chrome},
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
      expect(holding(win).single.capabilities, <String>{_chrome});
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
