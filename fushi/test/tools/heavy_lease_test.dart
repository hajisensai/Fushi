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

  Map<String, String> env(int slots) => <String, String>{
        'FUSHI_HEAVY_DIR': '${tmp.path}/state',
        'FUSHI_HEAVY_SLOTS': '$slots',
      };

  Future<HeavyLease> take(
    int slots, {
    HeavyKind kind = HeavyKind.analyze,
    String? worktree,
    MemorySnapshot memory = roomy,
    Duration? waitMax = const Duration(seconds: 1),
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

  // No memory admission (2026-10-03, owner's call): a busy desktop with a
  // free slot must not keep an agent -- and everyone queued behind it --
  // waiting for "available RAM above a reserve".
  test('a free slot is taken at once however little memory is free', () async {
    const MemorySnapshot starved = MemorySnapshot(
      totalPhysMb: 32 * 1024,
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
      <String>['lease-analyze'],
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
