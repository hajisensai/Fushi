/// Verdict over all batches of a `tool/dist_test.dart` run.
///
/// Same bar as `tool/flutter_test_failures.dart` (non-zero exit, no `done`,
/// zero tests → red), plus the distribution-specific one: every suite a batch
/// was given must show up in that batch's event stream. A suite with no
/// `suite` event never even started loading, and must not pass as green.
library;

import 'dart:convert';

import 'flutter_test_failure_filter.dart';
import 'suite_timings.dart';

/// What came back from running one batch to the end on one worker.
class DistBatchResult {
  DistBatchResult({
    required this.batchId,
    required this.worker,
    required this.files,
    required this.exitCode,
    required this.lines,
    required this.elapsed,
    this.infraError,
  });

  final int batchId;
  final String worker;
  final List<String> files;
  final int exitCode;

  /// Raw `--reporter json` stdout lines.
  final List<String> lines;
  final Duration elapsed;

  /// Set when the batch never got a fair run (ssh dropped, timed out, the
  /// worker died) and retries were exhausted.
  final String? infraError;

  /// One summary over every `flutter test` process of the batch (the local
  /// worker may run a batch as several; IDs restart at each `start` event).
  late final FlutterTestRunSummary summary =
      FlutterTestRunSummary.merge(<FlutterTestRunSummary>[
        for (final List<String> run in splitEventRuns(lines))
          parseFlutterTestJsonEvents(run),
      ]);

  /// Suites of [files] that have no `suite` event in [lines].
  late final List<String> missingSuites = _missingSuites();

  List<String> _missingSuites() {
    final Set<String> seen = <String>{};
    final Set<String> wanted = files.toSet();
    for (final String line in lines) {
      if (!line.startsWith('{')) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, Object?> || decoded['type'] != 'suite') {
        continue;
      }
      final Object? suite = decoded['suite'];
      if (suite is! Map<String, Object?> || suite['path'] is! String) continue;
      final String? path = matchKnownSuite(suite['path']! as String, wanted);
      if (path != null) seen.add(path);
    }
    return <String>[
      for (final String f in files)
        if (!seen.contains(f)) f,
    ];
  }

  /// Why this batch is red, or null.
  String? get failure {
    if (infraError != null) return infraError;
    final String? verdict = resolveFlutterTestVerdictFailure(
      flutterExitCode: exitCode,
      summary: summary,
    );
    if (verdict != null) return verdict;
    if (missingSuites.isNotEmpty) {
      return '${missingSuites.length} suite(s) produced no events: '
          '${missingSuites.take(5).join(', ')}'
          '${missingSuites.length > 5 ? ', ...' : ''}';
    }
    return null;
  }
}

/// Splits a json-reporter stream holding several runs back to back at each
/// run's `start` event. A stream with no `start` at all is one run.
List<List<String>> splitEventRuns(List<String> lines) {
  final List<List<String>> runs = <List<String>>[];
  List<String> current = <String>[];
  for (final String line in lines) {
    if (line.contains('"type":"start"') && current.isNotEmpty) {
      runs.add(current);
      current = <String>[];
    }
    current.add(line);
  }
  if (current.isNotEmpty || runs.isEmpty) runs.add(current);
  return runs;
}

/// The whole run.
class DistRunVerdict {
  DistRunVerdict({required this.results, required this.unplaced});

  final List<DistBatchResult> results;

  /// Suites no live worker could take (platform / capability), never run.
  final List<String> unplaced;

  List<DistBatchResult> get failedBatches => <DistBatchResult>[
    for (final DistBatchResult r in results)
      if (r.failure != null) r,
  ];

  int get testsCompleted => results.fold<int>(
    0,
    (int sum, DistBatchResult r) => sum + r.summary.testsCompleted,
  );

  /// Null when green.
  String? get failure {
    final List<DistBatchResult> failed = failedBatches;
    if (results.isEmpty) return 'no batch ran';
    if (failed.isNotEmpty) {
      return '${failed.length} of ${results.length} batch(es) failed';
    }
    if (unplaced.isNotEmpty) {
      return '${unplaced.length} suite(s) had no eligible worker and never '
          'ran';
    }
    return null;
  }
}

/// Per-worker totals for the summary table.
class DistWorkerStats {
  int batches = 0;
  int suites = 0;
  int tests = 0;
  int estimatedMs = 0;
  Duration busy = Duration.zero;
}

Map<String, DistWorkerStats> distWorkerStats(
  List<DistBatchResult> results,
  Map<int, int> estimatedMsByBatch,
) {
  final Map<String, DistWorkerStats> stats = <String, DistWorkerStats>{};
  for (final DistBatchResult r in results) {
    final DistWorkerStats s = stats.putIfAbsent(
      r.worker,
      () => DistWorkerStats(),
    );
    s.batches++;
    s.suites += r.files.length;
    s.tests += r.summary.testsCompleted;
    s.estimatedMs += estimatedMsByBatch[r.batchId] ?? 0;
    s.busy += r.elapsed;
  }
  return stats;
}

/// Markdown summary written to `<output>/summary.md`.
String renderDistSummary({
  required DistRunVerdict verdict,
  required Map<int, int> estimatedMsByBatch,
  required Duration wall,
  required String snapshot,
}) {
  final StringBuffer out = StringBuffer()
    ..writeln('# dist_test summary')
    ..writeln()
    ..writeln('- snapshot: `$snapshot`')
    ..writeln('- wall: ${_fmt(wall)}')
    ..writeln('- tests completed: ${verdict.testsCompleted}')
    ..writeln(
      '- verdict: ${verdict.failure == null ? 'PASSED' : 'FAILED - '
                '${verdict.failure}'}',
    )
    ..writeln()
    ..writeln(
      '| worker | batches | suites | tests | busy | model weight '
      '| wall / weight |',
    )
    ..writeln('|---|---|---|---|---|---|---|');
  final Map<String, DistWorkerStats> stats = distWorkerStats(
    verdict.results,
    estimatedMsByBatch,
  );
  for (final String name in stats.keys.toList()..sort()) {
    final DistWorkerStats s = stats[name]!;
    final String speed = s.estimatedMs == 0
        ? '-'
        : (s.busy.inMilliseconds / s.estimatedMs).toStringAsFixed(2);
    out.writeln(
      '| $name | ${s.batches} | ${s.suites} | ${s.tests} '
      '| ${_fmt(s.busy)} | ${_fmt(Duration(milliseconds: s.estimatedMs))} '
      '| $speed |',
    );
  }
  final List<DistBatchResult> failed = verdict.failedBatches;
  if (failed.isNotEmpty) {
    out
      ..writeln()
      ..writeln('## Failed batches');
    for (final DistBatchResult r in failed) {
      out
        ..writeln()
        ..writeln('### batch ${r.batchId} on ${r.worker}')
        ..writeln()
        ..writeln(r.failure)
        ..writeln();
      for (final FlutterTestErrorEvent e in r.summary.errors.take(20)) {
        final String firstLine = e.error.trim().split('\n').first;
        out.writeln('- `${e.suitePath}` :: ${e.testName} — $firstLine');
      }
    }
  }
  if (verdict.unplaced.isNotEmpty) {
    out
      ..writeln()
      ..writeln('## Never ran (no eligible worker)')
      ..writeln();
    for (final String path in verdict.unplaced) {
      out.writeln('- `$path`');
    }
  }
  return out.toString();
}

String _fmt(Duration d) {
  final int s = d.inSeconds;
  return s >= 60
      ? '${s ~/ 60}m${(s % 60).toString().padLeft(2, '0')}s'
      : '${s}s';
}
