/// Measured per-suite run time, used to balance the CI file shards.
///
/// Byte size is a poor cost proxy: one suite that drives a real headless Chrome
/// or a 10-minute perf probe costs as much as hundreds of small unit suites of
/// the same size, so the byte-balanced shards ended up 33–42 minutes apart
/// (CI 2026-10-20). `suite_timings.json` holds the measured milliseconds of every
/// suite from the CI event logs (`unit-test-events-*` artifacts) and is refreshed
/// with `dart run tool/update_suite_timings.dart <flutter_test.jsonl>...`.
///
/// The file is checked in rather than fetched at CI time on purpose: every shard
/// must compute the identical partition, and a download could see a different
/// (newer) run from one shard to the next.
library;

import 'dart:convert';
import 'dart:io';

/// The checked-in timing table, relative to `fushi/`.
const String kSuiteTimingsPath = 'tool/test_flow/suite_timings.json';

/// Per-suite fixed cost (compile + isolate spin-up), in the same unit as the
/// byte-size weight, so a shard of many tiny suites is not under-counted.
const int kPerSuiteByteWeight = 4096;

/// Timings are stored in steps of this many milliseconds, so a refresh does not
/// rewrite every line for jitter.
const int kSuiteTimingResolutionMs = 100;

/// Reads `{"suites": {"test/a_test.dart": 1200, ...}}`; missing file → empty.
Map<String, int> readSuiteTimings(File file) {
  if (!file.existsSync()) return <String, int>{};
  final Object? decoded = jsonDecode(file.readAsStringSync());
  final Object? suites = decoded is Map<String, Object?>
      ? decoded['suites']
      : null;
  if (suites is! Map<String, Object?>) {
    throw FormatException('${file.path}: expected {"suites": {path: ms}}');
  }
  return <String, int>{
    for (final MapEntry<String, Object?> e in suites.entries)
      if (e.value is int) e.key: e.value! as int,
  };
}

/// Writes [timings] sorted by path, one suite per line (diff-friendly).
void writeSuiteTimings(File file, Map<String, int> timings) {
  final List<String> paths = timings.keys.toList()..sort();
  final StringBuffer out = StringBuffer('{\n  "suites": {\n');
  for (int i = 0; i < paths.length; i++) {
    final String comma = i == paths.length - 1 ? '' : ',';
    out.writeln('    ${jsonEncode(paths[i])}: ${timings[paths[i]]}$comma');
  }
  out.write('  }\n}\n');
  file.writeAsStringSync(out.toString());
}

/// Wall time of every suite in one `flutter test --reporter json` event stream:
/// first `testStart` (the hidden "loading" test included) to last `testDone`.
///
/// Suite paths in the events can be relative (`test/a_test.dart`) or absolute
/// (`/home/runner/.../fushi/test/a_test.dart`, faster-testing on Windows also
/// prefixes `/`); they are mapped onto [knownSuites] (paths relative to `fushi/`)
/// by suffix, and suites that match none are dropped.
///
/// The stream may hold several runs back to back (a batched shard, see
/// `splitIntoBatches`); test and suite IDs restart at every run's `start`
/// event, so they are only resolved within one run.
Map<String, int> suiteDurationsFromEvents(
  Iterable<Map<String, Object?>> events,
  Set<String> knownSuites,
) {
  final Map<int, String> suitePaths = <int, String>{};
  final Map<int, int> testSuite = <int, int>{};
  final Map<int, int> start = <int, int>{};
  final Map<int, int> end = <int, int>{};
  final Map<String, int> durations = <String, int>{};
  void closeRun() {
    for (final MapEntry<int, String> e in suitePaths.entries) {
      if (start[e.key] != null && end[e.key] != null) {
        durations[e.value] = end[e.key]! - start[e.key]!;
      }
    }
    suitePaths.clear();
    testSuite.clear();
    start.clear();
    end.clear();
  }

  for (final Map<String, Object?> event in events) {
    final Object? time = event['time'];
    switch (event['type']) {
      case 'start':
        closeRun();
      case 'suite':
        final Object? suite = event['suite'];
        if (suite is Map<String, Object?> &&
            suite['id'] is int &&
            suite['path'] is String) {
          final String? path = matchKnownSuite(
            suite['path']! as String,
            knownSuites,
          );
          if (path != null) suitePaths[suite['id']! as int] = path;
        }
      case 'testStart':
        final Object? test = event['test'];
        if (test is Map<String, Object?> &&
            test['id'] is int &&
            test['suiteID'] is int &&
            time is int) {
          final int suiteId = test['suiteID']! as int;
          testSuite[test['id']! as int] = suiteId;
          final int? first = start[suiteId];
          if (first == null || time < first) start[suiteId] = time;
        }
      case 'testDone':
        final int? suiteId = testSuite[event['testID']];
        if (suiteId != null && time is int) {
          final int? last = end[suiteId];
          if (last == null || time > last) end[suiteId] = time;
        }
    }
  }
  closeRun();
  return durations;
}

/// Maps an event's suite path (relative, absolute, or `/`-prefixed) onto
/// [knownSuites] (paths relative to `fushi/`) by suffix; null when none match.
String? matchKnownSuite(String rawPath, Set<String> knownSuites) {
  final String path = rawPath.replaceAll(r'\', '/');
  if (knownSuites.contains(path)) return path;
  for (
    int i = path.indexOf('test/');
    i >= 0;
    i = path.indexOf('test/', i + 1)
  ) {
    if (i > 0 && path[i - 1] != '/') continue;
    final String candidate = path.substring(i);
    if (knownSuites.contains(candidate)) return candidate;
  }
  return null;
}

/// Rounds a measured duration to the stored resolution (never below one step,
/// so a measured suite always outweighs nothing).
int roundSuiteTiming(int ms) {
  final int steps = (ms / kSuiteTimingResolutionMs).round();
  return (steps < 1 ? 1 : steps) * kSuiteTimingResolutionMs;
}

/// Shard weights in milliseconds for every suite in [fileBytes] (path → byte
/// size): measured time where [timings] has the suite, otherwise the size scaled
/// by the median ms-per-byte of the measured suites (new suites are rare and
/// usually small; the median keeps one Chrome suite from inflating them all).
/// Without any overlapping timing this degrades to the byte-size proxy.
Map<String, int> suiteShardWeights(
  Map<String, int> fileBytes,
  Map<String, int> timings,
) {
  int sizeWeight(String path) => fileBytes[path]! + kPerSuiteByteWeight;
  final List<double> ratios = <double>[
    for (final String path in fileBytes.keys)
      if (timings[path] != null) timings[path]! / sizeWeight(path),
  ]..sort();
  if (ratios.isEmpty) {
    return <String, int>{
      for (final String path in fileBytes.keys) path: sizeWeight(path),
    };
  }
  final double msPerByte = ratios[ratios.length ~/ 2];
  return <String, int>{
    for (final String path in fileBytes.keys)
      path: timings[path] ?? (sizeWeight(path) * msPerByte).round(),
  };
}
