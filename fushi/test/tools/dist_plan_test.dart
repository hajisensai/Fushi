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

    test('one retry after an infrastructure failure, per suite', () {
      const DistUnit hangs = DistUnit(path: 'test/hang_test.dart', weightMs: 9);
      const DistUnit other = DistUnit(path: 'test/ok_test.dart', weightMs: 5);
      final DistSuiteQueue queue = DistSuiteQueue(<DistUnit>[hangs, other]);
      final DistBatch first = queue.take(eligible: any, budgetMs: 100)!;
      expect(queue.retryAfterInfra(first), isTrue);
      expect(queue.remaining, hasLength(2));
      // Given back and cut up again: the new batch is a different object,
      // the retry was spent all the same.
      final DistBatch second = queue.take(eligible: any, budgetMs: 9)!;
      expect(second.files, <String>['test/hang_test.dart']);
      expect(queue.retryAfterInfra(second), isFalse);
      expect(queue.remaining.map((DistUnit u) => u.path), <String>[
        'test/ok_test.dart',
      ]);
    });

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
    expect(isSafeDistTestPath('integration_test/app_smoke_test.dart'), isTrue);
    for (final String bad in <String>[
      'test/../x_test.dart',
      '/etc/x_test.dart',
      'test/a b_test.dart',
      r'test/$(rm)_test.dart',
      'test/a_test.dart; rm -rf ~',
      'lib/a_test.dart',
      'test/a.dart',
      'integration_test/../lib/x_test.dart',
      'integration_test/helpers/a.dart',
    ]) {
      expect(isSafeDistTestPath(bad), isFalse, reason: bad);
    }
  });

  group('integration tests', () {
    test('every manifest entry is an existing test with its platforms', () {
      final Map<String, Set<DistPlatform>> manifest = readDistItests(
        File(kDistItestManifestPath).readAsStringSync(),
      );
      expect(manifest, isNotEmpty);
      for (final MapEntry<String, Set<DistPlatform>> e in manifest.entries) {
        expect(File(e.key).existsSync(), isTrue, reason: e.key);
        expect(e.value, isNotEmpty, reason: e.key);
      }
    });

    test('manifest entries are checked', () {
      void rejects(String json) => expect(
        () => readDistItests(json),
        throwsFormatException,
        reason: json,
      );
      rejects('{"pins": {}}');
      rejects('{"itests": {"test/a_test.dart": {"platforms": ["macos"]}}}');
      rejects(
        '{"itests": {"integration_test/a_test.dart": {"platforms": []}}}',
      );
      rejects(
        '{"itests": {"integration_test/a_test.dart": {"platforms": ["linux"]}}}',
      );
      rejects('{"itests": {"integration_test/a_test.dart": {}}}');
    });

    test('one unit per platform, all needing the itest capability', () {
      final List<DistUnit> units = distItestUnits(<String, Set<DistPlatform>>{
        'integration_test/a_test.dart': <DistPlatform>{
          DistPlatform.macos,
          DistPlatform.windows,
        },
        'integration_test/b_test.dart': <DistPlatform>{DistPlatform.macos},
      });
      expect(units.map((DistUnit u) => '${u.path}|${u.label}'), <String>[
        'integration_test/a_test.dart|windows+itest',
        'integration_test/a_test.dart|macos+itest',
        'integration_test/b_test.dart|macos+itest',
      ]);
      expect(units.first.weightMs, kDistItestWeightMs);
      expect(
        units.first.eligibleFor(DistPlatform.windows, <String>{}),
        isFalse,
        reason: 'a worker that did not opt in never launches the app',
      );
      expect(
        units.first.eligibleFor(DistPlatform.windows, <String>{
          kDistItestCapability,
        }),
        isTrue,
      );
    });
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

  test('a red suite is re-run on another machine that may run it', () {
    // (name, machine, platform)
    const List<(String, String, DistPlatform)> workers =
        <(String, String, DistPlatform)>[
          ('mac', 'u@mac', DistPlatform.macos),
          ('mac.2', 'u@mac', DistPlatform.macos),
          ('win', 'local', DistPlatform.windows),
          ('friend', 'f@win', DistPlatform.windows),
        ];
    String? pick(DistUnit unit, String redMachine) =>
        pickRerunTarget<(String, String, DistPlatform)>(
          unit,
          redMachine: redMachine,
          order: workers,
          machineOf: ((String, String, DistPlatform) w) => w.$2,
          eligible: ((String, String, DistPlatform) w, DistUnit u) =>
              u.eligibleFor(w.$3, const <String>{}),
        )?.$1;
    const DistUnit any = DistUnit(path: 'test/a_test.dart', weightMs: 1);
    const DistUnit mac = DistUnit(
      path: 'test/m_test.dart',
      weightMs: 1,
      platform: DistPlatform.macos,
    );
    const DistUnit win = DistUnit(
      path: 'test/w_test.dart',
      weightMs: 1,
      platform: DistPlatform.windows,
    );
    expect(pick(any, 'u@mac'), 'win', reason: 'never another slot of it');
    expect(pick(any, 'local'), 'mac');
    expect(pick(win, 'local'), 'friend');
    expect(pick(mac, 'u@mac'), isNull, reason: 'the only Mac');
  });

  group('packages', () {
    test('the app or packages/<name>, nothing else', () {
      expect(isDistPackageDir(kDistAppPackage), isTrue);
      expect(isDistPackageDir('packages/fushi_engine'), isTrue);
      for (final String bad in <String>[
        'packages',
        'packages/../fushi',
        'packages/a/b',
        'packages/Fushi',
        'tools/x',
        '/etc',
      ]) {
        expect(isDistPackageDir(bad), isFalse, reason: bad);
      }
    });

    test('pure Dart packages run under dart test, as on CI', () {
      for (final String dir in <String>[
        'packages/fushi_engine',
        'packages/fushi_server',
        'packages/fushi_compute',
      ]) {
        expect(
          distTestRunnerOf(File('../$dir/pubspec.yaml').readAsStringSync()),
          'dart',
          reason: dir,
        );
      }
      expect(
        distTestRunnerOf(
          File('../packages/fushi_dictionary/pubspec.yaml').readAsStringSync(),
        ),
        'flutter',
      );
      expect(
        distTestRunnerOf(File('pubspec.yaml').readAsStringSync()),
        'flutter',
      );
    });
  });

  group('distBuildOf', () {
    test('flutter build: target first, options normalized, pub dropped', () {
      final DistBuild? apk = distBuildOf(<String>[
        r'D:\sdk\bin\flutter.bat',
        'build',
        'apk',
        '--no-pub',
        '--split-per-abi',
        '--target-platform',
        'android-arm64,android-x64',
        '--debug',
      ]);
      expect(apk?.toolchain, DistToolchain.android);
      expect(apk!.request, <String>[
        'flutter',
        'apk',
        '--debug',
        '--split-per-abi',
        '--target-platform=android-arm64,android-x64',
      ]);
      expect(apk.runsOn(DistPlatform.macos), isTrue);
      final DistBuild? win = distBuildOf(<String>[
        'flutter',
        'build',
        'windows',
      ]);
      expect(win!.request, <String>['flutter', 'windows']);
      expect(win.runsOn(DistPlatform.windows), isTrue);
      expect(win.runsOn(DistPlatform.macos), isFalse);
      expect(
        distBuildOf(<String>[
          'flutter',
          'build',
          'macos',
          '--debug',
        ])!.toolchain,
        DistToolchain.macos,
      );
    });

    test('gradlew tasks', () {
      expect(
        distBuildOf(<String>[
          r'.\gradlew.bat',
          ':app:assembleRelease',
          '-Ptarget-platform=android-arm64',
        ])!.request,
        <String>[
          'gradle',
          ':app:assembleRelease',
          '-Ptarget-platform=android-arm64',
        ],
      );
      expect(distBuildOf(<String>['./gradlew', 'bundleDebug']), isNotNull);
    });

    test('anything carrying values out, needing signing, or unknown stays', () {
      for (final List<String> c in <List<String>>[
        <String>['flutter', 'build', 'ios'],
        <String>['flutter', 'build', 'ipa'],
        <String>['flutter', 'build', 'macos'],
        <String>['flutter', 'build', 'macos', '--release'],
        <String>['flutter', 'build', 'web'],
        <String>['flutter', 'build', 'apk', '--dart-define=SECRET=x'],
        <String>['flutter', 'build', 'apk', '--obfuscate'],
        <String>['flutter', 'build', 'apk', '-t', 'lib/x.dart'],
        <String>['flutter', 'build', 'apk', '--target-platform=ios'],
        <String>['flutter', 'build', 'windows', '--split-per-abi'],
        <String>[
          'flutter',
          'build',
          'windows',
          '--target-platform=android-arm',
        ],
        <String>['flutter', 'build'],
        <String>['flutter', 'run'],
        <String>['gradlew'],
        <String>['gradlew', 'clean'],
        <String>['gradlew', ':app:assembleRelease', '--stacktrace'],
        <String>['gradlew', ':app:assembleRelease', '-Pk=v'],
        <String>['dart', 'build'],
      ]) {
        expect(distBuildOf(c), isNull, reason: c.join(' '));
      }
    });
  });
}
