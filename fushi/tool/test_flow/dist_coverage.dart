/// Coverage of a distributed `flutter test --coverage` (`dist_test.dart
/// --coverage`): every batch's lcov comes back inside its event stream as
/// `{"type":"fushiCoverage","lcov":"<base64>"}` lines (worker_run.sh; the
/// local worker reads its own file), is checked here like any other data from
/// a worker, and merged into one lcov.info on this machine.
library;

import 'dart:convert';

/// The event type worker_run.sh writes a batch's lcov under.
const String kDistCoverageEvent = 'fushiCoverage';

/// Hit counts by source file (`lib/...`, relative to the package) and line.
typedef DistCoverage = Map<String, Map<int, int>>;

/// [lines] without the coverage lines, and the lcov texts those carried.
({List<String> lines, List<String> lcov}) splitDistCoverage(
  List<String> lines,
) {
  final List<String> rest = <String>[];
  final List<String> lcov = <String>[];
  for (final String line in lines) {
    if (!line.startsWith('{"type":"$kDistCoverageEvent"')) {
      rest.add(line);
      continue;
    }
    try {
      final Object? decoded = jsonDecode(line);
      final Object? data = decoded is Map<String, Object?>
          ? decoded['lcov']
          : null;
      if (data is String) {
        lcov.add(utf8.decode(base64.decode(data), allowMalformed: true));
      }
    } on FormatException {
      // A cut-off line (the batch was killed mid-write): no coverage from it.
    }
  }
  return (lines: rest, lcov: lcov);
}

final RegExp _sourcePath = RegExp(r'^lib/[A-Za-z0-9_./-]+\.dart$');
final RegExp _da = RegExp(r'^DA:(\d+),(\d+)');

/// [raw] as `lib/...` of [package] (`fushi` or `packages/<name>`), or null:
/// flutter writes paths relative to the package, but an absolute one from
/// another machine's checkout is cut at `<package name>/lib/`.
String? _sourceOf(String raw, String package) {
  String p = raw.trim().replaceAll(r'\', '/');
  if (!p.startsWith('lib/')) {
    final String marker = '/${package.split('/').last}/lib/';
    final int at = p.lastIndexOf(marker);
    if (at < 0) return null;
    p = p.substring(at + marker.length - 'lib/'.length);
  }
  if (!_sourcePath.hasMatch(p) || p.split('/').contains('..')) return null;
  return p;
}

/// Adds the line hits of [lcov] into [into]. Only `SF:` records of [package]'s
/// lib/ and their `DA:` lines are taken (LF / LH are recomputed when
/// rendering); returns how many records were dropped.
int mergeLcov(DistCoverage into, String lcov, {required String package}) {
  int dropped = 0;
  Map<int, int>? current;
  for (final String line in const LineSplitter().convert(lcov)) {
    if (line.startsWith('SF:')) {
      final String? source = _sourceOf(line.substring(3), package);
      if (source == null) dropped++;
      current = source == null
          ? null
          : into.putIfAbsent(source, () => <int, int>{});
    } else if (line == 'end_of_record') {
      current = null;
    } else if (current != null) {
      final RegExpMatch? m = _da.firstMatch(line);
      if (m == null) continue;
      final int lineNo = int.parse(m.group(1)!);
      current[lineNo] = (current[lineNo] ?? 0) + int.parse(m.group(2)!);
    }
  }
  return dropped;
}

/// [coverage] as lcov, files and lines sorted.
String renderLcov(DistCoverage coverage) {
  final StringBuffer out = StringBuffer();
  for (final String source in coverage.keys.toList()..sort()) {
    final Map<int, int> hits = coverage[source]!;
    final List<int> lines = hits.keys.toList()..sort();
    out.writeln('SF:$source');
    for (final int l in lines) {
      out.writeln('DA:$l,${hits[l]}');
    }
    out
      ..writeln('LF:${lines.length}')
      ..writeln('LH:${lines.where((int l) => hits[l]! > 0).length}')
      ..writeln('end_of_record');
  }
  return out.toString();
}
