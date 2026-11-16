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
  final int? peakMb;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toUtc().toIso8601String(),
    'kind': kind,
    'label': label,
    'where': where.name,
    'queuedS': queued.inSeconds,
    'ranS': ran.inSeconds,
    'exit': exitCode,
    if (bookMb != null) 'bookMb': bookMb,
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
String renderHeavyStats(List<HeavyHistoryEntry> entries, {required int days}) {
  final StringBuffer out = StringBuffer();
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
