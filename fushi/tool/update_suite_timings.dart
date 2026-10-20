import 'dart:convert';
import 'dart:io';

import 'test_flow/suite_timings.dart';
import 'test_flow/test_file_shards.dart';

/// Refreshes tool/test_flow/suite_timings.json from `flutter test --reporter
/// json` event logs (the `unit-test-events-*` artifacts of main.yml /
/// release.yml unit-test shards). Run from `fushi/`:
///
///   gh run download <run-id> --repo hajisensai/Fushi --pattern 'unit-test-events-*' --dir ../.codex-test/events
///   dart run tool/update_suite_timings.dart ../.codex-test/events
///
/// Arguments are `.jsonl` files or directories searched recursively for them.
/// Suites measured in the logs replace their old entry; suites no longer on
/// disk are dropped; the rest keep their previous time.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/update_suite_timings.dart '
      '<flutter_test.jsonl | dir>...',
    );
    exit(64);
  }
  final Map<String, int> bytes = <String, int>{
    for (final FileSystemEntity e in Directory(
      'test',
    ).listSync(recursive: true, followLinks: false))
      if (e is File && e.path.endsWith('_test.dart'))
        e.path.replaceAll(r'\', '/'): e.lengthSync(),
  };
  final File table = File(kSuiteTimingsPath);
  final Map<String, int> timings = readSuiteTimings(table)
    ..removeWhere((String path, int _) => !bytes.containsKey(path));

  final List<File> logs = <File>[
    for (final String arg in args)
      if (FileSystemEntity.isDirectorySync(arg))
        ...Directory(arg)
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.jsonl'))
      else
        File(arg),
  ];
  int measured = 0;
  for (final File log in logs) {
    final Map<String, int> durations = suiteDurationsFromEvents(
      _readEvents(log),
      bytes.keys.toSet(),
    );
    stdout.writeln('${log.path}: ${durations.length} suites');
    for (final MapEntry<String, int> e in durations.entries) {
      timings[e.key] = roundSuiteTiming(e.value);
    }
    measured += durations.length;
  }
  if (measured == 0) {
    stderr.writeln(
      'No suite timings found in ${logs.length} log(s); '
      '${table.path} left unchanged.',
    );
    exit(1);
  }
  writeSuiteTimings(table, timings);

  final Map<String, int> weights = suiteShardWeights(bytes, timings);
  final List<MapEntry<String, int>> slowest = weights.entries.toList()
    ..sort(
      (MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value),
    );
  stdout
    ..writeln(
      'Wrote ${table.path}: ${timings.length} of ${bytes.length} '
      'suites measured.',
    )
    ..writeln('Slowest suites:');
  for (final MapEntry<String, int> e in slowest.take(15)) {
    stdout.writeln(
      '  ${(e.value / 1000).toStringAsFixed(1).padLeft(7)} s  '
      '${e.key}',
    );
  }
  const int shards = 4;
  stdout.writeln('Predicted suite-minutes per shard ($shards shards):');
  for (int i = 0; i < shards; i++) {
    final int ms = selectTestFileShard(
      weights,
      TestFileShard(i, shards),
    ).fold<int>(0, (int sum, String path) => sum + weights[path]!);
    stdout.writeln('  $i: ${(ms / 60000).toStringAsFixed(1)}');
  }
}

Iterable<Map<String, Object?>> _readEvents(File log) sync* {
  for (final String line in log.readAsLinesSync()) {
    if (!line.startsWith('{')) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is Map<String, Object?>) yield decoded;
  }
}
