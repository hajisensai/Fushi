// Contract: dist_test's local worker queues for a heavy slot with one
// DistLocalLeaseWait per prepare. A prepare the scheduler abandoned stays
// abandoned even when the worker is prepared again right away for the
// leftovers: revived, the old wait would take the slot and this checkout's
// worktree lock, and the new wait would queue for that lock forever (review
// of the 2026-11-20 change that made the local worker the others' peer).
//
// Covered here: the lease-level contract (two tokens, the abandoned one
// leaves the queue, the next one gets slot and worktree lock). Not covered:
// LocalDistWorker.prepare's own wiring (a fresh token per call, abandon on
// the current one), which needs a pub-got checkout and native_libs.ps1;
// since the peer only withdraws while nothing ran (distWantedWhilePreparing
// anyResults), a re-prepare right after withdrawing is also unreachable.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/dist_workers.dart';
import '../../tool/test_flow/heavy_budget.dart';
import '../../tool/test_flow/heavy_lease.dart';

void main() {
  late Directory tmp;
  const MemorySnapshot roomy = MemorySnapshot(
    totalPhysMb: 64 * 1024,
    availPhysMb: 40000,
    availCommitMb: 60000,
  );

  setUp(() => tmp = Directory.systemTemp.createTempSync('dist_local_wait_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A lock still closing on Windows; the OS temp cleaner gets it.
    }
  });

  /// A test-kind lease (worktree-exclusive, like the local worker's) on a
  /// one-slot machine, for the checkout [worktree].
  Future<HeavyLease> take(String worktree, {HeavyLeaseRival? rival}) =>
      acquireHeavyLease(
        need: heavyNeedFor(HeavyKind.test),
        label: 'dist-local-wait-test',
        worktreeRoot: worktree,
        rival: rival,
        environment: <String, String>{
          'FUSHI_HEAVY_DIR': '${tmp.path}/state',
          'FUSHI_HEAVY_SLOTS': '1',
        },
        readMemory: () => roomy,
        poll: const Duration(milliseconds: 20),
        log: (_) {},
      );

  test('a wait abandoned before a slot frees up leaves the queue; the next '
      'prepare\'s wait gets the slot and the worktree lock', () async {
    // Another heavy run holds the only slot (another checkout).
    final HeavyLease other = await take('${tmp.path}/other');

    final String here = '${tmp.path}/here';
    final DistLocalLeaseWait first = DistLocalLeaseWait();
    final Future<HeavyLease> firstWait = take(here, rival: first);
    // The scheduler lets go of the worker, then prepares it again at once
    // (long before the first wait's next poll).
    first.abandoned = true;
    final DistLocalLeaseWait second = DistLocalLeaseWait();
    final Future<HeavyLease> secondWait = take(here, rival: second);

    expect(first.tookIt, isTrue, reason: 'a new prepare revived the old wait');
    expect(second.tookIt, isFalse);

    await expectLater(firstWait, throwsA(isA<HeavyLeaseWithdrawn>()));
    other.release();
    final HeavyLease mine = await secondWait.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail(
        'the second prepare never got the slot: the abandoned wait holds '
        'the worktree lock',
      ),
    );
    expect(mine.slot, isNotNull);
    mine.release();
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a slot freed at the moment of abandoning is never used', () {
    final DistLocalLeaseWait wait = DistLocalLeaseWait();
    expect(wait.claimHere(), isTrue);
    wait.abandoned = true;
    expect(wait.claimHere(), isFalse);
    expect(wait.tookIt, isTrue);
  });
}
