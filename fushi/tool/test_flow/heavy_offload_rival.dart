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
import 'pid_alive.dart';

/// How long a queued run waits between two attempts on the other machines.
/// An attempt that finds every one busy costs a working-tree snapshot and an
/// ssh `lock` per worker slot, so not much more often than this. Since
/// 2026-11-15 an attempt made while the run queues here stays in the
/// workers' own queues for [kHeavyOffloadQueuedBusyRetries] rounds
/// (heavy_offload.dart), so this is only the gap between two such waits.
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

/// Deletes the claim files of processes that no longer run: a heavy.dart
/// that was killed never reached its own delete. Claims are named
/// `<pid>-<n>.claim`; a live process's are left alone, so this is safe next
/// to any number of runs asking at the same time. Returns how many went.
///
/// 2026-11-20: the directory held 362 files, none of them in use.
int sweepDeadOffloadClaims(
  Directory claims, {
  bool Function(int pid) alive = pidAlive,
}) {
  if (!claims.existsSync()) return 0;
  int swept = 0;
  final Map<int, bool> known = <int, bool>{};
  for (final FileSystemEntity e in claims.listSync(followLinks: false)) {
    if (e is! File) continue;
    final String name = e.uri.pathSegments.last;
    final RegExpMatch? m = RegExp(r'^(\d+)-[^/\\]*\.claim$').firstMatch(name);
    if (m == null) continue;
    final int owner = int.parse(m.group(1)!);
    if (owner == pid || (known[owner] ??= alive(owner))) continue;
    try {
      e.deleteSync();
      swept++;
    } on FileSystemException {
      // Another run swept it first.
    }
  }
  return swept;
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
    if (_asks == 0) sweepDeadOffloadClaims(claims);
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
    // to ask. The file goes in [close], once nobody reads it any more.
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
  ///
  /// The claim file goes whoever took it: with the attempt ended, neither
  /// side reads it again. (Until 2026-11-20 one taken there stayed for
  /// good: 265 of the 358 files found then were those.)
  Future<void> close() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _running;
    _claim?.delete();
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
  /// is pointless. Seen at a worker's lock, or in the claim file itself
  /// while a worker still waits in its queue for one.
  bool get lost => _lost || (claim?.takenByOther ?? false);

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
