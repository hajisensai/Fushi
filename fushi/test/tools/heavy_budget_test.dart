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

    test('only analyze may share a worktree; every kind has a ceiling', () {
      for (final HeavyKind k in HeavyKind.values) {
        final HeavyNeed n = heavyNeedFor(k);
        expect(n.worktreeExclusive, k != HeavyKind.analyze, reason: '$k');
        expect(n.capMb, greaterThanOrEqualTo(8192), reason: '$k');
      }
    });
  });

  test('defaultHeavySlots: one per 20 GB, 1..4', () {
    expect(defaultHeavySlots(8 * 1024), 1);
    expect(defaultHeavySlots(32 * 1024), 1);
    expect(defaultHeavySlots(65156), 3);
    expect(defaultHeavySlots(256 * 1024), 4);
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
