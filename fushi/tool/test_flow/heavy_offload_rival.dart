// An offloadable heavy run that has to queue here keeps asking the other
// machines while it waits (2026-11-10): whichever comes first takes it -- a
// slot here (test_flow/heavy_lease.dart) or a dist_test worker there -- and
// the other side then never runs it.
//
// The two sides settle it with one claim file per remote attempt: dist_test
// (`--offload-claim=<file>`) creates it exclusively right after a worker
// locked its remote checkout, before anything is pushed; heavy.dart creates
// it exclusively under the admission gate right after it locked a free slot
// here. Whoever creates it first has the run; the loser lets its slot / remote
// lock go again. Pure apart from that file, unit-tested
// (test/tools/heavy_offload_rival_test.dart).
import 'dart:async';
import 'dart:io';

import 'dist_plan.dart';
import 'heavy_lease.dart';
import 'heavy_offload.dart';

/// How long a queued run waits between two attempts on the other machines.
/// An attempt that finds every one busy costs a working-tree snapshot and an
/// ssh `lock` per worker slot, so not much more often than this.
const Duration kHeavyOffloadAskEvery = Duration(minutes: 1);

/// One run's claim: the side that creates [path] first runs it.
class HeavyOffloadClaim {
  HeavyOffloadClaim(this.path);

  final String path;
  bool _mine = false;

  /// This side created the file.
  bool get mine => _mine;

  /// Takes the run for this side: true when this side has it (now or
  /// before), false when the other side took it first.
  bool take() {
    if (_mine) return true;
    try {
      File(path).createSync(exclusive: true);
      _mine = true;
      return true;
    } on FileSystemException {
      // Lost to the other side; any other failure (no directory) is a bug
      // that must not leave the run to nobody.
      if (File(path).existsSync()) return false;
      rethrow;
    }
  }

  /// The other side took the run.
  bool get takenByOther => !_mine && File(path).existsSync();

  void delete() {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Never created, or already gone.
    }
  }
}

/// What heavy.dart does after a dist_test attempt ended with [code].
enum HeavyOffloadNext {
  /// That is the run's result: exit with it (green / red tests, analyze,
  /// a green compile check, 124 / 130).
  done,

  /// Nobody took it but only because the other machines were busy
  /// ([kDistOffloadBusy]): queue here and ask again.
  askAgain,

  /// Run it here and stop asking: declined for good ([kDistOffloadDeclined]:
  /// no worker config, a prepare that failed after taking it, ...) or a
  /// compile check red there (another machine's toolchain).
  runHere,
}

HeavyOffloadNext heavyOffloadNext(int code, HeavyOffloadKind kind) {
  if (code == 124 || code == 130) return HeavyOffloadNext.done;
  if (code == kDistOffloadBusy) return HeavyOffloadNext.askAgain;
  if (code == kDistOffloadDeclined) return HeavyOffloadNext.runHere;
  if (kind == HeavyOffloadKind.build && code != 0) {
    return HeavyOffloadNext.runHere;
  }
  return HeavyOffloadNext.done;
}

/// One dist_test attempt as the rival sees it.
abstract interface class HeavyOffloadAttempt {
  Future<int> get exitCode;
}

/// Asks the other machines every [every] while the run waits here (the
/// [HeavyLeaseRival] of acquireHeavyLease). [ask] starts one dist_test
/// attempt bound to the claim it is given.
class HeavyOffloadRival implements HeavyLeaseRival {
  HeavyOffloadRival({
    required this.claims,
    required this.ask,
    this.every = kHeavyOffloadAskEvery,
    void Function(String line)? log,
  }) : _log = log ?? ((String _) {});

  /// Where the claim files go (created when missing).
  final Directory claims;
  final HeavyOffloadAttempt Function(HeavyOffloadClaim claim) ask;
  final Duration every;
  final void Function(String) _log;

  static int _seq = 0;

  Timer? _timer;
  HeavyOffloadClaim? _claim;
  HeavyOffloadAttempt? _attempt;
  Future<void>? _running;
  bool _stopped = false;
  bool _here = false;

  /// Attempts started so far.
  int get asks => _asks;
  int _asks = 0;

  /// The first attempt goes out after [every]: the caller has just asked.
  void start() => _schedule();

  void _schedule() {
    if (_stopped || _here) return;
    _timer?.cancel();
    _timer = Timer(every, _askNow);
  }

  void _askNow() {
    _timer = null;
    if (_stopped || _here || _running != null) return;
    claims.createSync(recursive: true);
    final HeavyOffloadClaim claim = HeavyOffloadClaim(
      '${claims.path}/$pid-${_seq++}.claim',
    )..delete(); // a dead process's leftover under a reused pid
    _claim = claim;
    _asks++;
    final HeavyOffloadAttempt attempt = ask(claim);
    _attempt = attempt;
    _running = attempt.exitCode.then(
      (int code) => _ended(claim, code),
      onError: (Object e) => _ended(claim, kDistOffloadDeclined),
    );
  }

  void _ended(HeavyOffloadClaim claim, int code) {
    _running = null;
    // Taken there: the caller follows that attempt ([taken]); nothing more
    // to ask.
    if (claim.takenByOther) return;
    if (!claim.mine) claim.delete();
    if (code == kDistOffloadBusy) {
      _schedule();
      return;
    }
    if (!_stopped && !_here) {
      _log(
        'heavy: the other machines declined for good (dist_test exit $code); '
        'waiting for this machine only',
      );
    }
    _stopped = true;
  }

  /// The attempt that took the run elsewhere, once [tookIt].
  HeavyOffloadAttempt? get taken => tookIt ? _attempt : null;

  @override
  bool get tookIt => _claim?.takenByOther ?? false;

  @override
  bool claimHere() {
    final HeavyOffloadClaim? c = _claim;
    if (c != null && !c.take()) return false;
    _here = true;
    _timer?.cancel();
    _timer = null;
    return true;
  }

  /// No further attempts; completes when the one in flight (if any) ended.
  /// One that lost the claim to this machine backs out by itself
  /// (dist_test releases the remote checkout it locked).
  Future<void> close() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _running;
    final HeavyOffloadClaim? c = _claim;
    if (c != null && c.mine) c.delete();
  }
}

/// dist_test's side with `--offload-claim=<file>`: takes the claim when a
/// worker locked its remote checkout and works out what a run that ran
/// nothing exits with.
class DistOffloadTally {
  DistOffloadTally(this.claim);

  /// Null without `--offload-claim`: every decline is
  /// [kDistOffloadDeclined], as before.
  final HeavyOffloadClaim? claim;

  final Set<Object> _claimed = <Object>{};
  bool _final = false;
  bool _lost = false;

  /// The caller's machine admitted the run first: asking any worker again
  /// is pointless.
  bool get lost => _lost;

  /// [worker] holds its remote checkout: false when the caller's machine
  /// admitted the run first (the worker must back out before pushing).
  bool locked(Object worker) {
    final HeavyOffloadClaim? c = claim;
    if (c != null && !c.take()) {
      _lost = true;
      return false;
    }
    _claimed.add(worker);
    return true;
  }

  /// [worker] was dropped for something other than being busy (a failed
  /// push / prepare, infrastructure errors). Only counts once it took the
  /// claim: before that (lock busy, unreachable) it is "busy for now".
  void failed(Object worker) {
    if (_claimed.contains(worker)) _final = true;
  }

  /// A worker that will not take this kind of work whatever the time
  /// (no toolchain, an old shim, builds turned off).
  void cannotTake() => _final = true;

  /// The exit code of an off-machine run nothing of which ran elsewhere.
  int get declineCode =>
      claim != null && !_final ? kDistOffloadBusy : kDistOffloadDeclined;
}
