// What every heavy.dart run cost in waiting (2026-11-15).
//
// The lease printed `waited N s, ran M s` on the run's last line and kept
// nothing: when the queue felt slow there was no way to tell how long runs
// had waited here, or how many went to another machine. One JSON line per
// finished run under the heavy state directory answers that
// (`dart tool/heavy.dart --stats`).
//
// Pure apart from the file; unit-tested (test/tools/heavy_history_test.dart).
import 'dart:convert';
import 'dart:io';

/// File name under the heavy state directory.
const String kHeavyHistoryFile = 'history.jsonl';

/// Past this size the older half is dropped (about 20 000 runs fit).
const int kHeavyHistoryMaxBytes = 4 * 1024 * 1024;

/// tool/heavy.dart's exit code (and the history's) for a run cancelled
/// because whoever started it is gone (heavy_lease.dart HeavyCallerWatch):
/// it left the queue, never started, or was killed while it ran. Before
/// 2026-11-20 such runs were admitted anyway and their command died at once
/// with -1073741502 (0xC0000142), which the history kept as a crash.
const int kHeavyCallerGoneExit = 78;

/// Where a run ended up.
enum HeavyRanWhere {
  /// On this machine, under a slot of the lease.
  here,

  /// Handed to another machine by dist_test.
  elsewhere,
}

class HeavyHistoryEntry {
  const HeavyHistoryEntry({
    required this.at,
    required this.kind,
    required this.label,
    required this.where,
    required this.queued,
    required this.ran,
    required this.exitCode,
    this.bookMb,
    this.staticMb,
    this.peakMb,
  });

  /// When the run ended.
  final DateTime at;

  /// `test` / `analyze` / `build` / ... ([HeavyKind]'s name).
  final String kind;

  /// The first words of the command.
  final String label;
  final HeavyRanWhere where;

  /// From the command's start until it began to run anywhere: asking the
  /// other machines plus the queue here.
  final Duration queued;

  /// The run itself (for one that ran elsewhere: prepare there included).
  final Duration ran;
  final int exitCode;
  final int? bookMb;

  /// What the run's kind and import closure book before any measurement
  /// (heavy_budget.dart testBookMb / the kind's booking): the class its peak
  /// is a sample of ([heavyMeasuredBookMb]). Null in lines written before
  /// bookings were measured; [bookMb] was that value then.
  final int? staticMb;
  final int? peakMb;

  /// The booking class this run's peak is a sample of.
  int? get bookingClassMb => staticMb ?? bookMb;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toUtc().toIso8601String(),
    'kind': kind,
    'label': label,
    'where': where.name,
    'queuedS': queued.inSeconds,
    'ranS': ran.inSeconds,
    'exit': exitCode,
    if (bookMb != null) 'bookMb': bookMb,
    if (staticMb != null) 'staticMb': staticMb,
    if (peakMb != null) 'peakMb': peakMb,
  };

  /// Null for a line that is not an entry (cut off, another format).
  static HeavyHistoryEntry? tryParse(String line) {
    final Object? j;
    try {
      j = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (j is! Map<String, Object?>) return null;
    final Object? at = j['at'];
    final Object? kind = j['kind'];
    final Object? where = j['where'];
    final Object? queued = j['queuedS'];
    final Object? ran = j['ranS'];
    final Object? code = j['exit'];
    if (at is! String ||
        kind is! String ||
        where is! String ||
        queued is! int ||
        ran is! int ||
        code is! int) {
      return null;
    }
    final DateTime? when = DateTime.tryParse(at);
    final HeavyRanWhere? place = HeavyRanWhere.values
        .where((HeavyRanWhere w) => w.name == where)
        .firstOrNull;
    if (when == null || place == null) return null;
    final Object? label = j['label'];
    final Object? book = j['bookMb'];
    final Object? fixed = j['staticMb'];
    final Object? peak = j['peakMb'];
    return HeavyHistoryEntry(
      at: when,
      kind: kind,
      label: label is String ? label : '',
      where: place,
      queued: Duration(seconds: queued),
      ran: Duration(seconds: ran),
      exitCode: code,
      bookMb: book is int ? book : null,
      staticMb: fixed is int ? fixed : null,
      peakMb: peak is int ? peak : null,
    );
  }
}

/// Appends [entry] to [stateDir]'s history. Never throws: a run's result
/// does not depend on its bookkeeping.
void appendHeavyHistory(
  Directory stateDir,
  HeavyHistoryEntry entry, {
  int maxBytes = kHeavyHistoryMaxBytes,
}) {
  try {
    stateDir.createSync(recursive: true);
    final File file = File('${stateDir.path}/$kHeavyHistoryFile');
    if (file.existsSync() && file.lengthSync() > maxBytes) {
      // Keep the newer half, from a line start.
      final List<String> lines = file.readAsLinesSync();
      file.writeAsStringSync(
        '${lines.sublist(lines.length ~/ 2).join('\n')}\n',
        flush: true,
      );
    }
    // One short write in append mode: lines of runs ending at the same
    // moment do not interleave.
    file.writeAsStringSync(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  } on FileSystemException {
    // Not writable: the run's own last line still says what it waited.
  }
}

/// The entries of [stateDir]'s history that ended at or after [since].
List<HeavyHistoryEntry> readHeavyHistory(
  Directory stateDir, {
  DateTime? since,
}) {
  final File file = File('${stateDir.path}/$kHeavyHistoryFile');
  if (!file.existsSync()) return <HeavyHistoryEntry>[];
  final List<HeavyHistoryEntry> entries = <HeavyHistoryEntry>[];
  for (final String line in file.readAsLinesSync()) {
    final HeavyHistoryEntry? e = HeavyHistoryEntry.tryParse(line);
    if (e != null && (since == null || !e.at.isBefore(since))) entries.add(e);
  }
  return entries;
}

// Bookings measured from this file (2026-11-18). The budget adds up what
// each run books, so a booking above what the runs use keeps the machine
// idle while runs queue, and one below it promises memory twice. The fixed
// numbers went stale both ways: analyze booked 8 GB (the p90 of 11-10) while
// 202 runs of 11-15..18 peaked at p95 5.6 GB, two of them holding half the
// 32 GB budget and leaving room for two tests in three slots; a small-closure
// test booked 4 GB and peaked at p95 5.4 GB, a `dart test` 2 GB against
// 2.7 GB. A class with enough recent runs here books what they measured.

/// The kinds whose runs of one booking class are alike enough to measure:
/// a test class is its import-closure bucket and tester count, analyze is
/// one job. Builds are not (a gradle unit test and a release build book the
/// same) and keep their ceiling.
const Set<String> kHeavyMeasuredKinds = <String>{'test', 'analyze'};

/// Fewer measured runs than this in the window: the fixed booking stands.
const int kHeavyMeasuredMinSamples = 20;

/// Only the newest runs of a class count, and none older than the window.
const int kHeavyMeasuredMaxSamples = 200;
const Duration kHeavyMeasuredWindow = Duration(days: 14);

/// A run shorter than this died before it compiled anything; its peak says
/// nothing about the class.
const Duration kHeavyMeasuredMinRun = Duration(seconds: 20);

/// What a run of [kind] whose fixed booking is [staticMb] books when the
/// [history] holds enough runs of that class on this machine: the 95th
/// percentile of their Job peaks plus a tenth, rounded up to 256 MB, at
/// least half of [staticMb] and at most the Job ceiling [capMb]. Null (the
/// fixed booking stands) for other kinds and for a class with fewer than
/// [kHeavyMeasuredMinSamples] runs since [now] minus [kHeavyMeasuredWindow].
int? heavyMeasuredBookMb(
  Iterable<HeavyHistoryEntry> history, {
  required String kind,
  required int staticMb,
  required int capMb,
  required DateTime now,
}) {
  if (!kHeavyMeasuredKinds.contains(kind)) return null;
  final DateTime since = now.subtract(kHeavyMeasuredWindow);
  final List<HeavyHistoryEntry> runs = <HeavyHistoryEntry>[
    for (final HeavyHistoryEntry e in history)
      if (e.where == HeavyRanWhere.here &&
          // Killed part way through when its caller went: a peak of half a
          // run says nothing about the class.
          e.exitCode != kHeavyCallerGoneExit &&
          e.kind == kind &&
          e.bookingClassMb == staticMb &&
          e.peakMb != null &&
          e.ran >= kHeavyMeasuredMinRun &&
          !e.at.isBefore(since) &&
          e.at.isBefore(now))
        e,
  ]..sort((HeavyHistoryEntry a, HeavyHistoryEntry b) => a.at.compareTo(b.at));
  if (runs.length < kHeavyMeasuredMinSamples) return null;
  final int from = runs.length > kHeavyMeasuredMaxSamples
      ? runs.length - kHeavyMeasuredMaxSamples
      : 0;
  final int p95 = heavyPercentile(<int>[
    for (final HeavyHistoryEntry e in runs.skip(from)) e.peakMb!,
  ], 0.95);
  final int padded = ((p95 * 11 / 10) / 256).ceil() * 256;
  final int floor = staticMb ~/ 2;
  final int ceiling = capMb < floor ? floor : capMb;
  return padded.clamp(floor, ceiling);
}

/// Nearest-rank percentile [p] (0..1) of [values]; 0 for none.
int heavyPercentile(List<int> values, double p) {
  if (values.isEmpty) return 0;
  final List<int> sorted = List<int>.of(values)..sort();
  final int rank = (p * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

String _span(int seconds) => seconds < 120
    ? '${seconds}s'
    : seconds < 7200
    ? '${seconds ~/ 60}m${(seconds % 60).toString().padLeft(2, '0')}s'
    : '${seconds ~/ 3600}h${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}m';

/// The report of `heavy.dart --stats`: per kind and place, how many runs,
/// how long they queued and ran.
/// Runs cancelled because their caller was gone ([kHeavyCallerGoneExit]) are
/// counted on a line of their own and left out of the rest: nobody waited for
/// them, so their queueing is not what a caller waits.
String renderHeavyStats(List<HeavyHistoryEntry> all, {required int days}) {
  final StringBuffer out = StringBuffer();
  final List<HeavyHistoryEntry> gone = <HeavyHistoryEntry>[
    for (final HeavyHistoryEntry e in all)
      if (e.exitCode == kHeavyCallerGoneExit) e,
  ];
  final List<HeavyHistoryEntry> entries = <HeavyHistoryEntry>[
    for (final HeavyHistoryEntry e in all)
      if (e.exitCode != kHeavyCallerGoneExit) e,
  ];
  if (gone.isNotEmpty) {
    out.writeln(
      'heavy: ${gone.length} run(s) cancelled because their caller was gone '
      '(exit $kHeavyCallerGoneExit), '
      '${_span(gone.fold<int>(0, (int s, HeavyHistoryEntry e) => s + e.queued.inSeconds))} '
      'queued by them; left out below',
    );
  }
  if (entries.isEmpty) {
    out.writeln('heavy: no finished run recorded in the last $days day(s)');
    return out.toString();
  }
  final int elsewhere = entries
      .where((HeavyHistoryEntry e) => e.where == HeavyRanWhere.elsewhere)
      .length;
  final int queuedTotal = entries.fold<int>(
    0,
    (int s, HeavyHistoryEntry e) => s + e.queued.inSeconds,
  );
  out
    ..writeln(
      'heavy: ${entries.length} run(s) in the last $days day(s), '
      '$elsewhere on another machine '
      '(${(100 * elsewhere / entries.length).round()}%), '
      '${_span(queuedTotal)} queued in all',
    )
    ..writeln(
      '  kind      where      runs  queued p50 / p90 / max        '
      'ran p50 / p90',
    );
  final Map<String, List<HeavyHistoryEntry>> groups =
      <String, List<HeavyHistoryEntry>>{};
  for (final HeavyHistoryEntry e in entries) {
    groups
        .putIfAbsent('${e.kind}\t${e.where.name}', () => <HeavyHistoryEntry>[])
        .add(e);
  }
  for (final String key in groups.keys.toList()..sort()) {
    final List<HeavyHistoryEntry> g = groups[key]!;
    final List<int> queued = <int>[
      for (final HeavyHistoryEntry e in g) e.queued.inSeconds,
    ];
    final List<int> ran = <int>[
      for (final HeavyHistoryEntry e in g) e.ran.inSeconds,
    ];
    final List<String> k = key.split('\t');
    out.writeln(
      '  ${k[0].padRight(9)} ${k[1].padRight(10)} '
      '${'${g.length}'.padLeft(4)}  '
      '${'${_span(heavyPercentile(queued, 0.5))} / '
          '${_span(heavyPercentile(queued, 0.9))} / '
          '${_span(queued.reduce((int a, int b) => a > b ? a : b))}'.padRight(30)}'
      '${_span(heavyPercentile(ran, 0.5))} / '
      '${_span(heavyPercentile(ran, 0.9))}',
    );
  }
  return out.toString();
}
