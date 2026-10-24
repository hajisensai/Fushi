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
      // Empty is the goal: a host-dependent red gets its root fix instead.
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

  group('DistSuiteQueue', () {
    final Map<String, int> weights = <String, int>{
      for (int i = 0; i < 200; i++)
        'test/f${i.toString().padLeft(3, '0')}_test.dart': (i * 37) % 101 + 1,
    };
    bool any(DistUnit u) => u.eligibleFor(DistPlatform.macos, <String>{});

    test('draining it hands out every placement exactly once', () {
      final DistSuiteQueue queue = DistSuiteQueue(
        distUnits(
          weights: weights,
          requirements: const <String, SuiteRequirement>{},
        ),
      );
      final List<String> taken = <String>[];
      final Set<int> ids = <int>{};
      for (
        DistBatch? b = queue.take(eligible: any, budgetMs: 9000);
        b != null;
        b = queue.take(eligible: any, budgetMs: 9000)
      ) {
        expect(ids.add(b.id), isTrue);
        expect(b.weightMs, lessThanOrEqualTo(9000));
        taken.addAll(b.files);
      }
      expect(taken.toSet(), weights.keys.toSet());
      expect(taken.length, weights.length);
      expect(queue.isEmpty, isTrue);
    });

    test('a batch is at least one suite and fills up to the budget', () {
      final DistSuiteQueue queue = DistSuiteQueue(
        distUnits(
          weights: weights,
          requirements: const <String, SuiteRequirement>{},
        ),
      );
      final DistBatch tiny = queue.take(eligible: any, budgetMs: 1)!;
      expect(tiny.units, hasLength(1));
      // Heaviest first: the first suite out is the heaviest one.
      expect(
        tiny.units.single.weightMs,
        weights.values.reduce((int a, int b) => a > b ? a : b) +
            kDistSuiteOverheadMs,
      );
      final DistBatch big = queue.take(eligible: any, budgetMs: 20000)!;
      expect(big.weightMs, inInclusiveRange(20000 - 1600, 20000));
    });

    test('a suite pinned to two platforms is two units; pinned go first', () {
      const String both = 'test/f000_test.dart';
      const String win = 'test/f001_test.dart';
      final List<DistUnit> units = distUnits(
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
      );
      expect(
        units
            .where((DistUnit u) => u.path == both)
            .map((DistUnit u) => u.platform),
        unorderedEquals(<DistPlatform>[
          DistPlatform.windows,
          DistPlatform.macos,
        ]),
      );
      final DistSuiteQueue queue = DistSuiteQueue(units);
      final DistBatch mac = queue.take(eligible: any, budgetMs: 1)!;
      expect(mac.files, <String>[both], reason: 'pinned before free suites');
      expect(mac.units.single.platform, DistPlatform.macos);
      // The Windows-only chrome suite never goes to a Mac without chrome.
      for (
        DistBatch? b = queue.take(eligible: any, budgetMs: 100000);
        b != null;
        b = queue.take(eligible: any, budgetMs: 100000)
      ) {
        expect(b.files, isNot(contains(win)));
      }
      expect(
        queue.remaining.map((DistUnit u) => u.path),
        unorderedEquals(<String>[both, win]),
      );
    });

    test('giveBack returns the suites for anyone, heaviest first again', () {
      final DistSuiteQueue queue = DistSuiteQueue(
        distUnits(
          weights: weights,
          requirements: const <String, SuiteRequirement>{},
        ),
      );
      final DistBatch first = queue.take(eligible: any, budgetMs: 5000)!;
      queue.giveBack(first);
      expect(queue.remaining, hasLength(weights.length));
      final DistBatch again = queue.take(eligible: any, budgetMs: 5000)!;
      expect(again.files, first.files);
      expect(again.id, isNot(first.id));
    });
  });

  group('distChunkBudgetMs', () {
    DistSpeed measured(double factor) =>
        DistSpeed()..record(wallMs: (1000 * factor).round(), weightMs: 1000);

    test('speed follows recent batches (moving average, not a mean)', () {
      final DistSpeed speed = DistSpeed()
        ..record(wallMs: 260, weightMs: 1000)
        ..record(wallMs: 670, weightMs: 1000);
      expect(
        speed.factor,
        closeTo(kDistSpeedAlpha * 0.67 + (1 - kDistSpeedAlpha) * 0.26, 1e-9),
      );
      // A cumulative mean would sit at 0.465 here.
      expect(speed.factor, greaterThan(0.5));
    });

    test('an unmeasured worker takes a probe batch of about a minute', () {
      expect(
        distChunkBudgetMs(
          remainingEligibleMs: 100000000,
          speed: DistSpeed(),
          liveSpeedSum: 1,
        ),
        60000,
      );
    });

    test('a faster worker gets a proportionally bigger share', () {
      final DistSpeed fast = measured(0.5);
      final DistSpeed slow = measured(2.0);
      const double sum = 1 / 0.5 + 1 / 2.0;
      const int remaining = 600000;
      final int f = distChunkBudgetMs(
        remainingEligibleMs: remaining,
        speed: fast,
        liveSpeedSum: sum,
      );
      final int s = distChunkBudgetMs(
        remainingEligibleMs: remaining,
        speed: slow,
        liveSpeedSum: sum,
      );
      expect(f, (remaining * (2 / sum) / 2).round());
      expect(s, (remaining * (0.5 / sum) / 2).round());
      expect(f / s, closeTo(4, 1e-9));
    });

    test(
      'a batch lasts between 20 s and 4 min of that worker\'s wall time',
      () {
        final DistSpeed speed = measured(2.0);
        expect(
          distChunkBudgetMs(
            remainingEligibleMs: 1000000000,
            speed: speed,
            liveSpeedSum: 0.5,
          ),
          (240000 / 2.0).round(),
        );
        expect(
          distChunkBudgetMs(
            remainingEligibleMs: 10,
            speed: speed,
            liveSpeedSum: 0.5,
          ),
          (20000 / 2.0).round(),
        );
      },
    );
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
