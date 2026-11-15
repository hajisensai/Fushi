// Contract (2026-11-10): an offloadable heavy run that cannot start here at
// once keeps asking the other machines while it queues; a slot here or a
// worker there, whichever comes first, takes it, and the other side never
// runs it. Before, a run that fell back here never asked again: with the Mac
// free again, 15-21 runs still waited here for memory.
//
// Real OS file locks and claim files in a private directory; the dist_test
// attempts are fakes whose "remote" side is the same DistOffloadTally
// dist_test uses.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/dist_plan.dart';
import '../../tool/test_flow/heavy_budget.dart';
import '../../tool/test_flow/heavy_lease.dart';
import '../../tool/test_flow/heavy_offload.dart';
import '../../tool/test_flow/heavy_offload_rival.dart';

/// One dist_test attempt: [remote] is its side of the claim.
class _Attempt implements HeavyOffloadAttempt {
  _Attempt(HeavyOffloadClaim claim)
    : remote = DistOffloadTally(HeavyOffloadClaim(claim.path));

  final DistOffloadTally remote;
  final Completer<int> done = Completer<int>();

  @override
  Future<int> get exitCode => done.future;
}

class _FakeRival implements HeavyLeaseRival {
  _FakeRival({this.claims = true});

  @override
  bool get tookIt => false;
  final bool claims;
  int claimCalls = 0;

  @override
  bool claimHere() {
    claimCalls++;
    return claims;
  }
}

void main() {
  late Directory tmp;
  const MemorySnapshot roomy = MemorySnapshot(
    totalPhysMb: 64 * 1024,
    availPhysMb: 40000,
    availCommitMb: 60000,
  );

  setUp(() => tmp = Directory.systemTemp.createTempSync('heavy_rival_test'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A lock still closing on Windows; the OS temp cleaner gets it.
    }
  });

  Directory state() => Directory('${tmp.path}/state');
  Directory claims() => Directory('${tmp.path}/claims');

  Future<HeavyLease> take({
    HeavyLeaseRival? rival,
    Duration? waitMax = const Duration(seconds: 5),
  }) async {
    final HeavyLease lease = await acquireHeavyLease(
      need: heavyNeedFor(HeavyKind.test),
      label: 'lease-test',
      waitMax: waitMax,
      rival: rival,
      environment: <String, String>{
        'FUSHI_HEAVY_DIR': state().path,
        'FUSHI_HEAVY_SLOTS': '1',
      },
      readMemory: () => roomy,
      poll: const Duration(milliseconds: 20),
      log: (_) {},
    );
    addTearDown(lease.release);
    return lease;
  }

  HeavyOffloadRival rivalWith(List<_Attempt> attempts) => HeavyOffloadRival(
    claims: claims(),
    every: const Duration(milliseconds: 20),
    ask: (HeavyOffloadClaim c) {
      final _Attempt a = _Attempt(c);
      attempts.add(a);
      return a;
    },
  )..start();

  Future<void> until(bool Function() done) async {
    final Stopwatch sw = Stopwatch()..start();
    while (!done()) {
      if (sw.elapsed > const Duration(seconds: 10)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('queued here, taken there: it leaves the queue and is followed '
      'there', () async {
    final HeavyLease holder = await take();
    final List<_Attempt> attempts = <_Attempt>[];
    final HeavyOffloadRival rival = rivalWith(attempts);
    final Future<HeavyLease> waiting = take(rival: rival, waitMax: null);
    await until(() => readHeavyQueue(state()).length == 1);
    await until(() => attempts.isNotEmpty);
    // A worker there locked its checkout: dist_test takes the claim.
    expect(attempts.first.remote.locked('mac'), isTrue);
    await expectLater(waiting, throwsA(isA<HeavyLeaseWithdrawn>()));
    expect(readHeavyQueue(state()), isEmpty, reason: 'ticket left behind');
    expect(rival.taken, same(attempts.first));
    attempts.first.done.complete(0);
    expect(
      heavyOffloadNext(await rival.taken!.exitCode, HeavyOffloadKind.test),
      HeavyOffloadNext.done,
    );
    await rival.close();
    expect(attempts, hasLength(1), reason: 'nothing asked after it was taken');
    holder.release();
  });

  test('queued here, admitted here first: the attempt out backs out at its '
      'lock and none follows', () async {
    final HeavyLease holder = await take();
    final List<_Attempt> attempts = <_Attempt>[];
    final HeavyOffloadRival rival = rivalWith(attempts);
    final Future<HeavyLease> waiting = take(rival: rival, waitMax: null);
    await until(() => attempts.isNotEmpty);
    holder.release();
    final HeavyLease lease = await waiting;
    expect(lease.slot, 0);
    // The attempt reaches its worker's lock only now: it lost.
    final _Attempt late = attempts.last;
    expect(late.remote.locked('mac'), isFalse);
    expect(late.remote.lost, isTrue);
    late.done.complete(late.remote.declineCode);
    final int asked = attempts.length;
    await rival.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(attempts, hasLength(asked), reason: 'asked again after admission');
    lease.release();
  });

  test('the other side claimed in the instant before admission: the free '
      'slot is let go again', () async {
    final _FakeRival lost = _FakeRival(claims: false);
    await expectLater(take(rival: lost), throwsA(isA<HeavyLeaseWithdrawn>()));
    expect(lost.claimCalls, 1);
    expect(readHeavyQueue(state()), isEmpty);
    // The slot was not kept.
    final HeavyLease next = await take(waitMax: Duration.zero);
    expect(next.slot, 0);
    next.release();
  });

  test('a free slot here is taken at once, rival or not', () async {
    final _FakeRival rival = _FakeRival();
    final HeavyLease lease = await take(rival: rival);
    expect(lease.waited, lessThan(const Duration(seconds: 1)));
    expect(rival.claimCalls, 1);
    lease.release();
  });

  test('other machines always busy: asked again and again, nothing taken, '
      'no claim files left', () async {
    final List<_Attempt> attempts = <_Attempt>[];
    final HeavyOffloadRival rival = HeavyOffloadRival(
      claims: claims(),
      every: const Duration(milliseconds: 10),
      ask: (HeavyOffloadClaim c) {
        final _Attempt a = _Attempt(c);
        attempts.add(a);
        // Every worker locked by another run: nothing claimed.
        a.done.complete(a.remote.declineCode);
        return a;
      },
    )..start();
    await until(() => attempts.length >= 4);
    expect(attempts.map((_Attempt a) => a.remote.declineCode).toSet(), <int>{
      kDistOffloadBusy,
    });
    expect(rival.tookIt, isFalse);
    await rival.close();
    expect(claims().listSync(), isEmpty);
  });

  test('a failure there after taking it, or a declined config: run here, '
      'stop asking', () async {
    // Prepare failed after the lock (a compile error there): the existing
    // rule, run it here.
    final DistOffloadTally prepareRed = DistOffloadTally(
      HeavyOffloadClaim('${tmp.path}/a.claim'),
    );
    expect(prepareRed.locked('mac'), isTrue);
    prepareRed.failed('mac');
    expect(prepareRed.declineCode, kDistOffloadDeclined);
    expect(
      heavyOffloadNext(prepareRed.declineCode, HeavyOffloadKind.test),
      HeavyOffloadNext.runHere,
    );
    // Busy at the run (low memory there) after the lock is still busy.
    final DistOffloadTally runBusy = DistOffloadTally(
      HeavyOffloadClaim('${tmp.path}/b.claim'),
    );
    expect(runBusy.locked('mac'), isTrue);
    expect(runBusy.declineCode, kDistOffloadBusy);
    // Failing before the lock (unreachable) is "busy for now".
    final DistOffloadTally unreachable = DistOffloadTally(
      HeavyOffloadClaim('${tmp.path}/c.claim'),
    )..failed('mac');
    expect(unreachable.declineCode, kDistOffloadBusy);
    // No toolchain there is for good.
    final DistOffloadTally noToolchain = DistOffloadTally(
      HeavyOffloadClaim('${tmp.path}/d.claim'),
    )..cannotTake();
    expect(noToolchain.declineCode, kDistOffloadDeclined);
    // Without --offload-claim every decline is 75, as before.
    expect(DistOffloadTally(null).declineCode, kDistOffloadDeclined);

    // Red tests there are the verdict; a red compile check is built here.
    expect(heavyOffloadNext(1, HeavyOffloadKind.test), HeavyOffloadNext.done);
    expect(
      heavyOffloadNext(1, HeavyOffloadKind.analyze),
      HeavyOffloadNext.done,
    );
    expect(
      heavyOffloadNext(1, HeavyOffloadKind.build),
      HeavyOffloadNext.runHere,
    );
    for (final int code in <int>[124, 130]) {
      expect(
        heavyOffloadNext(code, HeavyOffloadKind.build),
        HeavyOffloadNext.done,
      );
    }

    // The rival stops asking after a decline for good.
    final List<_Attempt> attempts = <_Attempt>[];
    final List<String> said = <String>[];
    final HeavyOffloadRival rival = HeavyOffloadRival(
      claims: claims(),
      every: const Duration(milliseconds: 10),
      log: said.add,
      ask: (HeavyOffloadClaim c) {
        final _Attempt a = _Attempt(c);
        attempts.add(a);
        a.done.complete(kDistOffloadDeclined);
        return a;
      },
    )..start();
    await until(() => attempts.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(attempts, hasLength(1));
    expect(said.single, contains('declined for good'));
    await rival.close();
  });

  test('one claim, two sides: only the first to take it has it', () {
    final String path = '${tmp.path}/x.claim';
    final HeavyOffloadClaim here = HeavyOffloadClaim(path);
    final HeavyOffloadClaim there = HeavyOffloadClaim(path);
    expect(here.takenByOther, isFalse);
    expect(there.take(), isTrue);
    expect(there.take(), isTrue, reason: 'idempotent for its owner');
    expect(here.take(), isFalse);
    expect(here.takenByOther, isTrue);
    expect(there.takenByOther, isFalse);
  });
}
