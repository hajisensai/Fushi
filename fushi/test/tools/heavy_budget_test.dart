import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/heavy_budget.dart';

void main() {
  group('withDefaultTestConcurrency', () {
    test('adds a default to flutter test only', () {
      expect(
        withDefaultTestConcurrency(<String>['flutter', 'test', 'a_test.dart']),
        <String>['flutter', 'test', '--concurrency=4', 'a_test.dart'],
      );
      expect(
        withDefaultTestConcurrency(<String>[
          'D:/sdk/bin/flutter.bat',
          'test',
          'a_test.dart',
          '--no-pub',
        ]),
        <String>[
          'D:/sdk/bin/flutter.bat',
          'test',
          '--concurrency=4',
          'a_test.dart',
          '--no-pub',
        ],
      );
      expect(
        withDefaultTestConcurrency(<String>['fvm', 'flutter', 'test']),
        <String>['fvm', 'flutter', 'test', '--concurrency=4'],
      );
    });

    test('keeps an explicit choice and other commands', () {
      for (final List<String> argv in <List<String>>[
        <String>['flutter', 'test', '--concurrency=1', 'a_test.dart'],
        <String>['flutter', 'test', '--concurrency', '2'],
        <String>['flutter', 'test', '-j', '2'],
        <String>['flutter', 'test', '-j2'],
        <String>['flutter', 'analyze', '--no-pub'],
        <String>['dart', 'test'],
        <String>['gradlew', 'test'],
        <String>[],
      ]) {
        expect(withDefaultTestConcurrency(argv), argv);
      }
    });
  });

  group('classifyHeavyCommand', () {
    HeavyKind kind(List<String> argv) => classifyHeavyCommand(argv).kind;

    test('flutter / dart / fvm subcommands', () {
      expect(
        kind(<String>['flutter', 'test', 'test/a_test.dart']),
        HeavyKind.test,
      );
      expect(
        kind(<String>[r'D:\flutter\bin\flutter.bat', '--no-color', 'test']),
        HeavyKind.test,
      );
      expect(kind(<String>['dart', 'test']), HeavyKind.test);
      expect(
        kind(<String>['flutter', 'analyze', '--no-pub']),
        HeavyKind.analyze,
      );
      expect(kind(<String>['dart.exe', 'analyze']), HeavyKind.analyze);
      expect(kind(<String>['flutter', 'build', 'windows']), HeavyKind.build);
      expect(kind(<String>['fvm', 'flutter', 'test']), HeavyKind.test);
      expect(kind(<String>['flutter', 'pub', 'get']), HeavyKind.other);
    });

    test('gradle / xcodebuild / the Windows itest runner are builds', () {
      expect(
        kind(<String>[r'.\gradlew.bat', ':app:assembleRelease']),
        HeavyKind.build,
      );
      expect(kind(<String>['./gradlew', 'assembleDebug']), HeavyKind.build);
      expect(
        kind(<String>['xcodebuild', '-scheme', 'Runner']),
        HeavyKind.build,
      );
      expect(
        kind(<String>['powershell', '-File', r'tool\run_windows_itest.ps1']),
        HeavyKind.build,
      );
      expect(kind(<String>[]), HeavyKind.other);
    });

    // Wrapped in heavy.dart these tools take no lease of their own and their
    // Job Object nests inside the wrapper's, so the wrapper books and caps
    // for them: exactly their own ceiling, neither the generic 16 GB nor
    // less than pre_push_check --parallel needs.
    test('lease-taking repo tools are booked at their own ceiling', () {
      int cap(List<String> argv) => classifyHeavyCommand(argv).capMb;
      final int test = heavyNeedFor(HeavyKind.test).capMb;
      final int analyze = heavyNeedFor(HeavyKind.analyze).capMb;
      expect(cap(<String>['dart', 'tool/pre_push_check.dart']), test);
      expect(
        cap(<String>['dart', 'run', r'tool\pre_push_check.dart', '--parallel']),
        test + analyze,
      );
      expect(prePushCheckCapMb(parallel: true), test + analyze);
      expect(
        cap(<String>['dart.exe', 'tool/flutter_test_failures.dart', '--x=1']),
        test,
      );
      final HeavyNeed ftf = classifyHeavyCommand(<String>[
        'dart',
        'tool/flutter_test_failures.dart',
      ]);
      expect(ftf.kind, HeavyKind.test);
      expect(ftf.worktreeExclusive, isTrue);
      // Any other dart script / `dart run` of one stays as before.
      expect(kind(<String>['dart', 'tool/i18n_sync.dart']), HeavyKind.other);
      expect(kind(<String>['dart', 'run', 'slang']), HeavyKind.build);
    });

    test('only analyze may share a worktree; every kind has a ceiling', () {
      for (final HeavyKind k in HeavyKind.values) {
        final HeavyNeed n = heavyNeedFor(k);
        expect(n.worktreeExclusive, k != HeavyKind.analyze, reason: '$k');
        expect(n.capMb, greaterThanOrEqualTo(8192), reason: '$k');
      }
    });

    // 2026-10-25: analyze is mostly memory and under one core; holding a
    // regular slot at its full ceiling made tests queue behind it.
    test('only analyze is light and books less than its ceiling', () {
      for (final HeavyKind k in HeavyKind.values) {
        final HeavyNeed n = heavyNeedFor(k);
        expect(n.light, k == HeavyKind.analyze, reason: '$k');
        expect(n.bookedMb, lessThanOrEqualTo(n.capMb), reason: '$k');
        if (k != HeavyKind.analyze) {
          expect(n.bookedMb, n.capMb, reason: '$k');
        }
      }
      final HeavyNeed analyze = heavyNeedFor(HeavyKind.analyze);
      expect(analyze.capMb, 8192);
      expect(analyze.bookedMb, 4608);
      // Still never three test runs at once on a 64 GB machine (2026-10-19);
      // two tests and an analyze fit, as do a test and both light slots.
      final int test = heavyNeedFor(HeavyKind.test).bookedMb;
      final int budget = defaultHeavyBudgetMb(65156);
      expect(3 * test, greaterThan(budget));
      expect(2 * test + analyze.bookedMb, lessThanOrEqualTo(budget));
      expect(
        test + kLightSlotCount * analyze.bookedMb,
        lessThanOrEqualTo(budget),
      );
    });
  });

  test('defaultHeavySlots: one per 20 GB, 1..4', () {
    expect(defaultHeavySlots(8 * 1024), 1);
    expect(defaultHeavySlots(32 * 1024), 1);
    expect(defaultHeavySlots(65156), 3);
    expect(defaultHeavySlots(256 * 1024), 4);
  });

  test('defaultHeavyBudgetMb: half the RAM in whole GB', () {
    expect(defaultHeavyBudgetMb(65156), 32768);
    expect(defaultHeavyBudgetMb(32 * 1024), 16384);
    expect(defaultHeavyBudgetMb(8 * 1024), 4096);
  });

  // 2026-10-19 (owner's call): three 12-16 GB ceilings promised 48 GB on a
  // 64 GB desktop full of agent sessions; the commit limit ran out.
  test('heavyBudgetBlocker books the holders\' ceilings, not free RAM', () {
    final int test = heavyNeedFor(HeavyKind.test).bookedMb;
    final int analyze = heavyNeedFor(HeavyKind.analyze).bookedMb;
    final int build = heavyNeedFor(HeavyKind.build).bookedMb;
    const int budget = 32768;
    // Idle machine: always starts, even past the budget on its own.
    expect(
      heavyBudgetBlocker(needMb: 40000, heldCapsMb: <int>[], budgetMb: budget),
      isNull,
    );
    expect(
      heavyBudgetBlocker(
        needMb: analyze,
        heldCapsMb: <int>[test, test],
        budgetMb: budget,
      ),
      isNull,
    );
    expect(
      heavyBudgetBlocker(
        needMb: test,
        heldCapsMb: <int>[build],
        budgetMb: budget,
      ),
      isNull,
    );
    expect(
      heavyBudgetBlocker(
        needMb: test,
        heldCapsMb: <int>[test, test],
        budgetMb: budget,
      ),
      contains('memory budget: 24576 MB booked + 12288 MB > 32768 MB'),
    );
    expect(
      heavyBudgetBlocker(
        needMb: analyze,
        heldCapsMb: <int>[build, test],
        budgetMb: budget,
      ),
      isNotNull,
    );
  });

  test('a holder without a recorded ceiling books the largest one', () {
    final HeavyHolder? old = HeavyHolder.fromJson(0, <String, Object>{
      'pid': 7,
      'startedAt': 1,
      'label': 'old',
      'cwd': '',
    });
    expect(old?.capMb, isNull);
    expect(old?.bookedMb, kUnknownHolderCapMb);
    for (final HeavyKind k in HeavyKind.values) {
      expect(heavyNeedFor(k).capMb, lessThanOrEqualTo(kUnknownHolderCapMb));
    }
  });

  test('HeavyHolder JSON round-trips and rejects junk', () {
    const HeavyHolder h = HeavyHolder(
      slot: 2,
      pid: 42,
      startedAtMs: 7,
      label: 'flutter test',
      cwd: 'D:/x',
    );
    final HeavyHolder? back = HeavyHolder.fromJson(2, h.toJson());
    expect(back?.pid, 42);
    expect(
      HeavyHolder.fromJson(
        2,
        const HeavyHolder(
          slot: 2,
          pid: 42,
          startedAtMs: 7,
          label: 'flutter test',
          cwd: 'D:/x',
          capMb: 12288,
        ).toJson(),
      )?.bookedMb,
      12288,
    );
    // A holder written by an older checkout still carries needMb; it is read
    // as usual (the field is simply ignored now).
    expect(
      HeavyHolder.fromJson(1, <String, Object>{
        'pid': 7,
        'needMb': 3072,
        'startedAt': 1,
        'label': 'old',
        'cwd': '',
      })?.label,
      'old',
    );
    expect(back?.label, 'flutter test');
    expect(HeavyHolder.fromJson(0, ''), isNull);
    expect(HeavyHolder.fromJson(0, <String, Object>{'pid': 'x'}), isNull);
  });

  test('heavyLeaseSkipReason: CI, manual off, nested under a holder', () {
    expect(heavyLeaseSkipReason(<String, String>{}), isNull);
    expect(heavyLeaseSkipReason(<String, String>{'CI': 'true'}), 'CI');
    expect(
      heavyLeaseSkipReason(<String, String>{'FUSHI_HEAVY': 'OFF'}),
      'FUSHI_HEAVY=off',
    );
    expect(
      heavyLeaseSkipReason(<String, String>{kHeavyLeaseEnv: '123'}),
      contains('123'),
    );
    expect(heavyLeaseSkipReason(<String, String>{kHeavyLeaseEnv: ''}), isNull);
  });

  test('heavyCapHit: at or just under the ceiling', () {
    expect(heavyCapHit(12288, 12288), isTrue);
    expect(heavyCapHit(12250, 12288), isTrue);
    expect(heavyCapHit(9000, 12288), isFalse);
  });
}
