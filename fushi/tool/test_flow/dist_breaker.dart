// A machine that cannot take work is not asked again for a while
// (2026-11-15).
//
// Every offloaded run asked every configured machine: 292 runs logged between
// 10-31 and 11-11 spent 5 s (p90 33 s) each on a friend's machine that closed
// the connection (152 of 236 asks) or was out of disk (the same answer for
// days), and those machines did 0.5 of 5.8 hours of work. The breaker
// remembers such an answer in one small file shared by every checkout on this
// machine; a run reads it once at its start and leaves that machine out
// until the hold is over, then the next run asks it again (and doubles the
// hold when the answer is the same).
//
// "The same answer again" is an answer to an ask that began after the last
// hold was over. Runs that were already asking when the machine went away
// (each waits in its queue for minutes) all get that one outage as their
// answer: five of them used to count five failures in a row and hold the
// machine for an hour after a 30-second network drop.
//
// Only answers that have nothing to do with the run trip it: no connection,
// no disk. "In use by another run", "paused" and a failed prepare do not --
// the first two end by themselves within minutes and the queue on the worker
// (worker_slot.sh) is what waits for them; the last one may be the snapshot.
//
// Pure apart from the file; unit-tested (test/tools/dist_breaker_test.dart).
import 'dart:convert';
import 'dart:io';

import 'dist_workers.dart';

/// The first hold; doubled per failure in a row up to [kDistBreakerMaxHold].
const Duration kDistBreakerFirstHold = Duration(minutes: 5);
const Duration kDistBreakerMaxHold = Duration(hours: 1);

/// File name under the heavy state directory.
const String kDistBreakerFile = 'dist-breaker.json';

/// How long a machine is left out after its [fails]-th failure in a row.
Duration distBreakerHold(int fails) {
  Duration hold = kDistBreakerFirstHold;
  for (int i = 1; i < fails && hold < kDistBreakerMaxHold; i++) {
    hold *= 2;
  }
  return hold > kDistBreakerMaxHold ? kDistBreakerMaxHold : hold;
}

/// Why a prepare that ended with [error] says the machine itself cannot take
/// work for a while, or null when the breaker has nothing to learn from it.
String? distBreakerReason(Object error) {
  if (error is DistWorkerUnreachable) return 'unreachable';
  // The link to it died mid-push (kDistPushStall): asked again a minute
  // later from heavy.dart's queue, it would hang the same 120 s every time.
  if (error is DistWorkerStalled) return 'push stalled';
  if (error is DistWorkerBusy && error.message.contains('free disk')) {
    return 'short of disk';
  }
  return null;
}

/// Whether a prepare that ended with [error] (null: it went through) is the
/// machine answering with nothing the breaker holds against it: its
/// failures in a row end here. A checkout in use and a pause are such
/// answers; short of disk is not (it would start every count at one), and a
/// failed prepare says nothing either way.
bool distBreakerAnswered(Object? error) =>
    error == null ||
    (error is DistWorkerBusy && distBreakerReason(error) == null);

/// One machine's entry.
class DistBreakerEntry {
  const DistBreakerEntry({
    required this.until,
    required this.fails,
    required this.why,
  });

  final DateTime until;
  final int fails;
  final String why;

  /// When the failure that began this hold was recorded.
  DateTime get since => until.subtract(distBreakerHold(fails));
}

class DistBreaker {
  DistBreaker(this.file, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final File file;
  final DateTime Function() _now;

  Map<String, DistBreakerEntry> _read() {
    final Map<String, DistBreakerEntry> entries = <String, DistBreakerEntry>{};
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) return entries;
      for (final MapEntry<String, Object?> e in decoded.entries) {
        final Object? v = e.value;
        if (v is! Map<String, Object?>) continue;
        final Object? until = v['until'];
        final Object? fails = v['fails'];
        final Object? why = v['why'];
        if (until is! int || fails is! int || why is! String) continue;
        entries[e.key] = DistBreakerEntry(
          until: DateTime.fromMillisecondsSinceEpoch(until),
          fails: fails,
          why: why,
        );
      }
    } on Object {
      // Missing or damaged: nobody is held.
    }
    return entries;
  }

  void _write(Map<String, DistBreakerEntry> entries) {
    try {
      file.parent.createSync(recursive: true);
      final File tmp = File('${file.path}.$pid.tmp');
      tmp.writeAsStringSync(
        jsonEncode(<String, Object?>{
          for (final MapEntry<String, DistBreakerEntry> e in entries.entries)
            e.key: <String, Object?>{
              'until': e.value.until.millisecondsSinceEpoch,
              'fails': e.value.fails,
              'why': e.value.why,
            },
        }),
      );
      tmp.renameSync(file.path);
    } on FileSystemException {
      // Another run wrote at the same moment, or the directory is not
      // writable: the machine is asked once more, nothing worse.
    }
  }

  /// The entry that keeps [machine] out right now, or null.
  DistBreakerEntry? held(String machine) {
    final DistBreakerEntry? e = _read()[machine];
    return e != null && e.until.isAfter(_now()) ? e : null;
  }

  /// An ask of [machine] that began at [asked] failed for [why]: left out
  /// for [distBreakerHold] of its failures in a row. Returns the entry that
  /// keeps it out now, or null when nothing does.
  ///
  /// A failure only follows the last one when its ask began after that
  /// one's hold was over. While the hold runs, and for an ask that began
  /// before the last failure was recorded, it is the same outage seen by
  /// another run (or by this machine's other slot): nothing is added and
  /// the hold is not extended. That also makes two runs writing at the same
  /// moment harmless -- whichever is second finds the first one's entry.
  DistBreakerEntry? trip(
    String machine,
    String why, {
    required DateTime asked,
  }) {
    final Map<String, DistBreakerEntry> entries = _read();
    final DateTime now = _now();
    final DistBreakerEntry? last = entries[machine];
    if (last != null) {
      if (last.until.isAfter(now)) return last;
      if (asked.isBefore(last.since)) return null;
    }
    final int fails = (last?.fails ?? 0) + 1;
    final DistBreakerEntry entry = DistBreakerEntry(
      until: now.add(distBreakerHold(fails)),
      fails: fails,
      why: why,
    );
    entries[machine] = entry;
    _write(entries);
    return entry;
  }

  /// [machine] answered: its failures are forgotten.
  void reset(String machine) {
    final Map<String, DistBreakerEntry> entries = _read();
    if (entries.remove(machine) != null) _write(entries);
  }

  /// What a prepare on [machine] that ended with [error] (null: it went
  /// through) means here -- the one place that decides it: [reset] for an
  /// answer ([distBreakerAnswered]), [trip] for a reason
  /// ([distBreakerReason]), nothing otherwise. Returns the entry that keeps
  /// the machine out after a failure, else null.
  DistBreakerEntry? learn(String machine, Object? error) {
    if (distBreakerAnswered(error)) {
      reset(machine);
      return null;
    }
    final String? why = distBreakerReason(error!);
    if (why == null) return null;
    return trip(
      machine,
      why,
      asked: _now().subtract(
        error is DistWorkerError ? error.waited : Duration.zero,
      ),
    );
  }
}
