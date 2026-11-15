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
  if (error is DistWorkerBusy && error.message.contains('free disk')) {
    return 'short of disk';
  }
  return null;
}

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

  /// [machine] just failed for [why]: left out for [distBreakerHold] of its
  /// failures in a row. Returns the hold.
  Duration trip(String machine, String why) {
    final Map<String, DistBreakerEntry> entries = _read();
    final int fails = (entries[machine]?.fails ?? 0) + 1;
    final Duration hold = distBreakerHold(fails);
    entries[machine] = DistBreakerEntry(
      until: _now().add(hold),
      fails: fails,
      why: why,
    );
    _write(entries);
    return hold;
  }

  /// [machine] answered: its failures are forgotten.
  void reset(String machine) {
    final Map<String, DistBreakerEntry> entries = _read();
    if (entries.remove(machine) != null) _write(entries);
  }
}
