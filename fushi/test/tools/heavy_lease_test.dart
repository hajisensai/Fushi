import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/heavy_budget.dart';
import '../../tool/test_flow/heavy_lease.dart';

// Real OS file locks in a private state directory; memory is injected (it
// only sizes the default slot count) so the machine's live load cannot make
// these flaky.
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

  Map<String, String> env(int slots, {int? budgetMb}) => <String, String>{
    'FUSHI_HEAVY_DIR': '${tmp.path}/state',
    'FUSHI_HEAVY_SLOTS': '$slots',
    if (budgetMb != null) 'FUSHI_HEAVY_BUDGET_MB': '$budgetMb',
  };

  Future<HeavyLease> take(
    int slots, {
    // Not analyze: that one is light (own slots, no queue), see below.
    HeavyKind kind = HeavyKind.other,
    String? worktree,
    MemorySnapshot memory = roomy,
    int? budgetMb,
    Duration? waitMax = const Duration(seconds: 1),
  }) async {
    final HeavyLease lease = await acquireHeavyLease(
      need: heavyNeedFor(kind),
      label: 'lease-${kind.name}',
      worktreeRoot: worktree,
      waitMax: waitMax,
      environment: env(slots, budgetMb: budgetMb),
      readMemory: () => memory,
      poll: const Duration(milliseconds: 50),
      log: (_) {},
    );
    // Slots held in this process stay marked in-process until released; a
    // test failing before its own release() must not leak them into the
    // following tests (release() is idempotent).
    addTearDown(lease.release);
    return lease;
  }

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
            allOf(contains('all 1 slots busy'), contains('lease-other')),
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

  // No memory admission (2026-10-03, owner's call): a busy desktop with a
  // free slot must not keep an agent -- and everyone queued behind it --
  // waiting for "available RAM above a reserve".
  test('a free slot is taken at once however little memory is free', () async {
    const MemorySnapshot starved = MemorySnapshot(
      totalPhysMb: 64 * 1024,
      availPhysMb: 600,
      availCommitMb: 300,
    );
    final HeavyLease a = await take(2, kind: HeavyKind.build, memory: starved);
    final HeavyLease b = await take(2, kind: HeavyKind.test, memory: starved);
    expect(<int?>{a.slot, b.slot}, <int>{0, 1});
    expect(a.waited, lessThan(const Duration(seconds: 1)));
    expect(b.waited, lessThan(const Duration(seconds: 1)));
    a.release();
    b.release();
  });

  // 2026-10-19 (owner's call): free slots are not enough, the holders'
  // ceilings plus the next one's must fit half the RAM (64 GB -> 32 GB).
  test(
    'a free slot waits while the ceilings would overbook the budget',
    () async {
      final HeavyLease t1 = await take(4, kind: HeavyKind.test);
      final HeavyLease t2 = await take(4, kind: HeavyKind.test);
      await expectLater(
        take(4, kind: HeavyKind.test),
        throwsA(
          isA<HeavyLeaseTimeout>().having(
            (HeavyLeaseTimeout e) => e.message,
            'message',
            allOf(
              contains('memory budget: 24576 MB booked + 12288 MB > 32768 MB'),
              contains('lease-test'),
            ),
          ),
        ),
      );
      // An analyze still fits next to the two test runs, booked at its
      // measured footprint rather than its 8 GB ceiling.
      final HeavyLease a = await take(4, kind: HeavyKind.analyze);
      expect(
        readHeavyHolders(
          Directory('${tmp.path}/state'),
          4,
        ).map((HeavyHolder h) => h.bookedMb).fold(0, (int s, int m) => s + m),
        24576 + 4608,
      );
      a.release();
      t2.release();
      final HeavyLease t3 = await take(4, kind: HeavyKind.test);
      t3.release();
      t1.release();
    },
  );

  test('a lone run starts even when its ceiling exceeds the budget', () async {
    final HeavyLease b = await take(2, kind: HeavyKind.build, budgetMb: 4096);
    expect(b.slot, 0);
    b.release();
  });

  // A session started with a larger FUSHI_HEAVY_SLOTS holds slots past our
  // count; they are not ours to take, but they book memory all the same.
  test(
    'a slot held past this process\'s slot count still books the budget',
    () async {
      final String? dart = _dartExecutable();
      if (dart == null) {
        markTestSkipped('no dart executable to hold a slot in a child');
        return;
      }
      final Directory state = Directory('${tmp.path}/state')
        ..createSync(recursive: true);
      File('${state.path}/slot-5.json').writeAsStringSync(
        '{"pid":1,"startedAt":1,"label":"wide session","cwd":"","capMb":24576}',
      );
      final File holder = File('${tmp.path}/hold.dart')
        ..writeAsStringSync(_holdLockScript);
      final Process child = await Process.start(dart, <String>[
        holder.path,
        '${state.path}/slot-5.lock',
      ]);
      try {
        await child.stdout
            .transform(const SystemEncoding().decoder)
            .firstWhere((String l) => l.contains('locked'))
            .timeout(const Duration(seconds: 60));
        expect(readHeavyHolders(state, 2).map((HeavyHolder h) => h.slot), <int>[
          5,
        ]);
        await expectLater(
          take(2, kind: HeavyKind.test),
          throwsA(
            isA<HeavyLeaseTimeout>().having(
              (HeavyLeaseTimeout e) => e.message,
              'message',
              allOf(
                contains('24576 MB booked + 12288 MB > 32768 MB'),
                contains('wide session'),
              ),
            ),
          ),
        );
        // An analyze fits next to it, in a light slot.
        final HeavyLease a = await take(2, kind: HeavyKind.analyze);
        expect(a.slot, kLightSlotBase);
        a.release();
      } finally {
        await child.stdin.close();
        await child.exitCode.timeout(const Duration(seconds: 30));
      }
      final HeavyLease t = await take(2, kind: HeavyKind.test);
      expect(t.slot, 0);
      t.release();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

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

  // Queue, never give up (2026-10-03, owner's call): without a wait limit a
  // waiter stays queued however long the machine is busy.
  test('without a wait limit a waiter queues until a slot frees', () async {
    final HeavyLease a = await take(1);
    bool admitted = false;
    final Future<HeavyLease> waiting = take(1, waitMax: null)
      ..then((_) => admitted = true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(admitted, isFalse);
    expect(
      readHeavyQueue(Directory('${tmp.path}/state')).map((q) => q.label),
      <String>['lease-other'],
    );
    a.release();
    final HeavyLease b = await waiting;
    expect(b.slot, 0);
    expect(readHeavyQueue(Directory('${tmp.path}/state')), isEmpty);
    b.release();
  });

  test('a dead waiter\'s ticket is swept, not waited on', () async {
    final Directory queue = Directory('${tmp.path}/state/queue')
      ..createSync(recursive: true);
    File('${queue.path}/00000000000000000001-1-0.ticket').createSync();
    File(
      '${queue.path}/00000000000000000001-1-0.json',
    ).writeAsStringSync('{"pid":1,"label":"dead"}');
    final HeavyLease a = await take(1);
    expect(a.waited, lessThan(const Duration(seconds: 1)));
    expect(queue.listSync(), isEmpty);
    a.release();
  });

  // First come, first served across processes: a free slot goes to the oldest
  // live ticket, not to whoever polls first.
  test(
    'a free slot waits for an earlier live ticket in another process',
    () async {
      final String? dart = _dartExecutable();
      if (dart == null) {
        markTestSkipped('no dart executable to hold a ticket in a child');
        return;
      }
      final Directory queue = Directory('${tmp.path}/state/queue')
        ..createSync(recursive: true);
      const String early = '00000000000000000001-1-0';
      File(
        '${queue.path}/$early.json',
      ).writeAsStringSync('{"pid":1,"label":"earlier run"}');
      final File holder = File('${tmp.path}/hold.dart')
        ..writeAsStringSync(_holdLockScript);
      final Process child = await Process.start(dart, <String>[
        holder.path,
        '${queue.path}/$early.ticket',
      ]);
      try {
        await child.stdout
            .transform(const SystemEncoding().decoder)
            .firstWhere((String l) => l.contains('locked'))
            .timeout(const Duration(seconds: 60));
        await expectLater(
          take(1),
          throwsA(
            isA<HeavyLeaseTimeout>().having(
              (HeavyLeaseTimeout e) => e.message,
              'message',
              allOf(contains('queued behind 1'), contains('earlier run')),
            ),
          ),
        );
      } finally {
        await child.stdin.close();
        await child.exitCode.timeout(const Duration(seconds: 30));
      }
      final HeavyLease a = await take(1);
      expect(a.slot, 0);
      expect(File('${queue.path}/$early.ticket').existsSync(), isFalse);
      a.release();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // 2026-10-25 (owner's feedback: "analyze barely uses CPU but holds task
  // slots and slows the tests down"): analyze takes no regular slot and no
  // queue ticket, only memory budget.
  test('analyze runs while every slot is busy and never queues', () async {
    final HeavyLease t = await take(1, kind: HeavyKind.test);
    bool queued = false;
    final Future<HeavyLease> waiting = take(
      1,
      kind: HeavyKind.test,
      waitMax: null,
    )..then((_) => queued = true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(readHeavyQueue(Directory('${tmp.path}/state')), hasLength(1));
    final HeavyLease a = await take(1, kind: HeavyKind.analyze);
    expect(a.slot, kLightSlotBase);
    expect(a.waited, lessThan(const Duration(seconds: 1)));
    // It took no ticket and left the regular slot for the queued test.
    expect(
      readHeavyQueue(Directory('${tmp.path}/state')).map((q) => q.label),
      <String>['lease-test'],
    );
    expect(queued, isFalse);
    t.release();
    final HeavyLease t2 = await waiting;
    expect(t2.slot, 0);
    a.release();
    t2.release();
  });

  test('light slots are bounded and still book the budget', () async {
    final HeavyLease a1 = await take(1, kind: HeavyKind.analyze);
    final HeavyLease a2 = await take(1, kind: HeavyKind.analyze);
    expect(<int?>{a1.slot, a2.slot}, <int>{kLightSlotBase, kLightSlotBase + 1});
    await expectLater(
      take(1, kind: HeavyKind.analyze),
      throwsA(
        isA<HeavyLeaseTimeout>().having(
          (HeavyLeaseTimeout e) => e.message,
          'message',
          contains('all $kLightSlotCount light slots busy'),
        ),
      ),
    );
    // Two analyzes (9216 MB) + a test (12288 MB) > a 16 GB budget.
    await expectLater(
      take(1, kind: HeavyKind.test, budgetMb: 16384),
      throwsA(
        isA<HeavyLeaseTimeout>().having(
          (HeavyLeaseTimeout e) => e.message,
          'message',
          contains('9216 MB booked + 12288 MB > 16384 MB'),
        ),
      ),
    );
    a2.release();
    a1.release();
  });

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
    expect(
      heavyJobLimitFlags(memoryCap: true),
      priorityClass | jobMemory | killOnClose,
    );
    expect(heavyJobLimitFlags(memoryCap: false), priorityClass | killOnClose);
  });
}

/// The SDK's dart next to the running flutter (FLUTTER_ROOT is set by the
/// flutter tool), or null where it cannot be found.
String? _dartExecutable() {
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) return null;
  final String exe = Platform.isWindows ? 'dart.exe' : 'dart';
  final File f = File('$root/bin/cache/dart-sdk/bin/$exe');
  return f.existsSync() ? f.path : null;
}

/// Holds an exclusive lock on args[0] until its stdin closes.
const String _holdLockScript = '''
import 'dart:io';

void main(List<String> args) {
  final RandomAccessFile f = File(args[0]).openSync(mode: FileMode.append);
  f.lockSync(FileLock.exclusive);
  stdout.writeln('locked');
  stdin.listen((_) {}, onDone: () {
    f.closeSync();
    exit(0);
  });
}
''';
