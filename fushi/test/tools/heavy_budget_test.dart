import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/heavy_budget.dart';

void main() {
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

    test('only analyze may share a worktree; caps sit above needs', () {
      for (final HeavyKind k in HeavyKind.values) {
        final HeavyNeed n = heavyNeedFor(k);
        expect(n.worktreeExclusive, k != HeavyKind.analyze, reason: '$k');
        expect(n.capMb, greaterThan(n.needMb), reason: '$k');
      }
    });
  });

  test('defaultHeavySlots: one per 20 GB, 1..4', () {
    expect(defaultHeavySlots(8 * 1024), 1);
    expect(defaultHeavySlots(32 * 1024), 1);
    expect(defaultHeavySlots(65156), 3);
    expect(defaultHeavySlots(256 * 1024), 4);
  });

  group('heavyAdmissionBlocker', () {
    const int total = 64 * 1024;

    test('admits when RAM and commit both leave the reserves', () {
      expect(
        heavyAdmissionBlocker(
          const MemorySnapshot(
            totalPhysMb: total,
            availPhysMb: 20000,
            availCommitMb: 30000,
          ),
          3072,
        ),
        isNull,
      );
    });

    test('blocks on available RAM below need + reserve', () {
      expect(
        heavyAdmissionBlocker(
          const MemorySnapshot(
            totalPhysMb: total,
            availPhysMb: 7000,
            availCommitMb: 30000,
          ),
          3072,
        ),
        contains('available RAM'),
      );
    });

    test('blocks on commit headroom even with RAM free', () {
      // Commit exhaustion fails every program's allocations, RAM free or not.
      expect(
        heavyAdmissionBlocker(
          const MemorySnapshot(
            totalPhysMb: total,
            availPhysMb: 30000,
            availCommitMb: 10000,
          ),
          3072,
        ),
        contains('commit headroom'),
      );
    });

    test('memory promised to just-started runs counts against the room', () {
      const MemorySnapshot m = MemorySnapshot(
        totalPhysMb: total,
        availPhysMb: 10000,
        availCommitMb: 30000,
      );
      expect(heavyAdmissionBlocker(m, 3072), isNull);
      expect(
        heavyAdmissionBlocker(m, 3072, pendingMb: 3072),
        contains('starting 3072'),
      );
    });

    test('no commit reading (POSIX): RAM alone decides', () {
      expect(
        heavyAdmissionBlocker(
          const MemorySnapshot(totalPhysMb: total, availPhysMb: 20000),
          3072,
        ),
        isNull,
      );
    });

    test('reserves shrink on small machines but never below a floor', () {
      expect(physReserveMb(64 * 1024), 4096);
      expect(physReserveMb(8 * 1024), 1024);
      expect(commitReserveMb(64 * 1024), 8192);
      expect(commitReserveMb(8 * 1024), 2048);
    });
  });

  test('pendingReservationMb counts only holders inside the warm-up', () {
    const int now = 1000000;
    HeavyHolder h(int slot, int ageMs, int need) => HeavyHolder(
          slot: slot,
          pid: 1,
          needMb: need,
          startedAtMs: now - ageMs,
          label: 'x',
          cwd: '',
        );
    expect(
      pendingReservationMb(<HeavyHolder>[
        h(0, 10000, 3072),
        h(1, 89000, 6144),
        h(2, 91000, 9999),
      ], now),
      3072 + 6144,
    );
  });

  test('HeavyHolder JSON round-trips and rejects junk', () {
    const HeavyHolder h = HeavyHolder(
      slot: 2,
      pid: 42,
      needMb: 3072,
      startedAtMs: 7,
      label: 'flutter test',
      cwd: 'D:/x',
    );
    final HeavyHolder? back = HeavyHolder.fromJson(2, h.toJson());
    expect(back?.pid, 42);
    expect(back?.needMb, 3072);
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
