import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/heavy_budget.dart';
import '../../tool/test_flow/heavy_lease.dart';

// Real OS file locks in a private state directory; memory is injected so the
// machine's live load cannot make these flaky.
void main() {
  late Directory tmp;
  const MemorySnapshot roomy = MemorySnapshot(
    totalPhysMb: 64 * 1024,
    availPhysMb: 40000,
    availCommitMb: 60000,
  );

  setUp(() => tmp = Directory.systemTemp.createTempSync('heavy_lease_test'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A lock still closing on Windows; the OS temp cleaner gets it.
    }
  });

  Map<String, String> env(int slots) => <String, String>{
        'FUSHI_HEAVY_DIR': '${tmp.path}/state',
        'FUSHI_HEAVY_SLOTS': '$slots',
      };

  Future<HeavyLease> take(
    int slots, {
    HeavyKind kind = HeavyKind.analyze,
    String? worktree,
    MemorySnapshot memory = roomy,
    Duration waitMax = const Duration(seconds: 1),
  }) =>
      acquireHeavyLease(
        need: heavyNeedFor(kind),
        label: 'lease-${kind.name}',
        worktreeRoot: worktree,
        waitMax: waitMax,
        environment: env(slots),
        readMemory: () => memory,
        poll: const Duration(milliseconds: 50),
        log: (_) {},
      );

  test(
    'a full machine refuses (never "runs anyway") and names the holder',
    () async {
      final HeavyLease a = await take(1);
      expect(a.slot, 0);
      await expectLater(
        take(1),
        throwsA(
          isA<HeavyLeaseTimeout>().having(
            (HeavyLeaseTimeout e) => e.message,
            'message',
            allOf(contains('all 1 slots busy'), contains('lease-analyze')),
          ),
        ),
      );
      a.release();
      final HeavyLease b = await take(1);
      expect(b.slot, 0);
      b.release();
    },
  );

  test(
    'distinct slots up to the count; holders are visible to others',
    () async {
      final HeavyLease a = await take(2);
      final HeavyLease b = await take(2);
      expect(<int?>{a.slot, b.slot}, <int>{0, 1});
      final List<HeavyHolder> holders = readHeavyHolders(
        Directory('${tmp.path}/state'),
        2,
      );
      expect(holders.map((HeavyHolder h) => h.pid).toSet(), <int>{pid});
      a.release();
      b.release();
      expect(readHeavyHolders(Directory('${tmp.path}/state'), 2), isEmpty);
    },
  );

  test(
    'waits on memory even with a slot free, and admits once it frees',
    () async {
      const MemorySnapshot tight = MemorySnapshot(
        totalPhysMb: 64 * 1024,
        availPhysMb: 5000,
        availCommitMb: 60000,
      );
      await expectLater(
        take(4, memory: tight),
        throwsA(
          isA<HeavyLeaseTimeout>().having(
            (HeavyLeaseTimeout e) => e.message,
            'message',
            contains('available RAM'),
          ),
        ),
      );
      int reads = 0;
      final HeavyLease admitted = await acquireHeavyLease(
        need: heavyNeedFor(HeavyKind.analyze),
        label: 'late',
        waitMax: const Duration(seconds: 5),
        environment: env(4),
        readMemory: () => ++reads < 3 ? tight : roomy,
        poll: const Duration(milliseconds: 50),
        log: (_) {},
      );
      expect(admitted.slot, isNotNull);
      expect(reads, greaterThanOrEqualTo(3));
      admitted.release();
    },
  );

  test('just-admitted runs reserve their need for the next waiter', () async {
    // Room for one 3 GB run on top of the 4 GB reserve, not for two.
    const MemorySnapshot one = MemorySnapshot(
      totalPhysMb: 64 * 1024,
      availPhysMb: 8000,
      availCommitMb: 60000,
    );
    final HeavyLease a = await take(4, memory: one);
    await expectLater(take(4, memory: one), throwsA(isA<HeavyLeaseTimeout>()));
    a.release();
  });

  test(
    'build/-writers of one worktree run one at a time; analyze does not',
    () async {
      final String wt = '${tmp.path}/wt';
      final HeavyLease t = await take(4, kind: HeavyKind.test, worktree: wt);
      await expectLater(
        take(4, kind: HeavyKind.build, worktree: wt),
        throwsA(
          isA<HeavyLeaseTimeout>().having(
            (HeavyLeaseTimeout e) => e.message,
            'message',
            contains('worktree still busy'),
          ),
        ),
      );
      final HeavyLease a = await take(4, kind: HeavyKind.analyze, worktree: wt);
      expect(a.slot, isNotNull);
      a.release();
      // Another checkout is not blocked.
      final HeavyLease other = await take(
        4,
        kind: HeavyKind.test,
        worktree: '${tmp.path}/wt2',
      );
      other.release();
      t.release();
      final HeavyLease again = await take(
        4,
        kind: HeavyKind.test,
        worktree: wt,
      );
      again.release();
    },
  );

  test('children inherit the lease; nested tools take none', () async {
    final HeavyLease a = await take(1);
    expect(a.childEnvironment[kHeavyLeaseEnv], '$pid');
    final HeavyLease nested = await acquireHeavyLease(
      need: heavyNeedFor(HeavyKind.test),
      label: 'nested',
      worktreeRoot: '${tmp.path}/wt',
      environment: <String, String>{...env(1), ...a.childEnvironment},
      readMemory: () => roomy,
      log: (_) {},
    );
    expect(nested.slot, isNull);
    expect(nested.skipReason, contains('$pid'));
    expect(nested.childEnvironment, isEmpty);
    nested.release();
    a.release();
  });

  // pre_push_check --no-lease (2026-10-02): a caller that schedules runs
  // itself drops the memory ceiling, never the priority or the kill-on-exit
  // that stops a leftover flutter_tester holding sqlite3.dll.
  test('the job keeps priority and kill-on-close without a memory ceiling', () {
    const int priorityClass = 0x20; // JOB_OBJECT_LIMIT_PRIORITY_CLASS
    const int jobMemory = 0x200; // JOB_OBJECT_LIMIT_JOB_MEMORY
    const int killOnClose = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    expect(heavyJobLimitFlags(memoryCap: true),
        priorityClass | jobMemory | killOnClose);
    expect(heavyJobLimitFlags(memoryCap: false), priorityClass | killOnClose);
  });
}
