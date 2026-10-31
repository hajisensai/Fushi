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
    this.filtered = false,
  });

  /// The run selects tests by name / tag ([distTestFilterActive]): a suite
  /// with no matching test is fine, so this batch may run none of its tests
  /// (the whole run must still run one, [DistRunVerdict.failure]).
  final bool filtered;

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
    // Under a filter, package:test's "no tests ran" exit of a batch whose
    // suites all loaded and reported `done: success` without an error is the
    // filter matching nothing here, not a failure: a local run of the same
    // files passes as long as some other suite matched. A load / compile
    // failure is still a failed test or a missing `done`, so it stays red.
    final bool nothingMatched =
        filtered &&
        exitCode == kTestNoTestsRanExitCode &&
        summary.success == true &&
        summary.errors.isEmpty;
    final String? verdict = resolveFlutterTestVerdictFailure(
      flutterExitCode: nothingMatched ? 0 : exitCode,
      summary: summary,
      minimumTests: filtered ? 0 : 1,
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

/// package:test's exit code when no test ran (`flutter test` / `dart test`
/// pass it on): with a name / tag filter, "no test of these suites matched".
const int kTestNoTestsRanExitCode = 79;

/// `flutter test` / `dart test` options that select tests by name or tag.
const Set<String> _kTestFilterOptions = <String>{
  '--name',
  '-n',
  '--plain-name',
  '--tags',
  '-t',
  '--exclude-tags',
  '-x',
};

/// Whether [testArgs] select tests by name or tag, so a suite (and with it a
/// batch) may legitimately run none of its tests.
bool distTestFilterActive(List<String> testArgs) => testArgs.any((String a) {
  final int eq = a.indexOf('=');
  return _kTestFilterOptions.contains(eq < 0 ? a : a.substring(0, eq));
});

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

/// `type` of the one line an integration test launch reports (worker_run.sh
/// itest mode, and the local worker): `flutter drive` has no json reporter.
const String kDistItestReportType = 'fushiItest';

/// The json reporter's first event of a run.
const String _kStartEventType = 'start';

/// The report line of one integration test launch; [tail] is the end of
/// drive's output (the failure, when there is one).
String distItestReport({
  required String path,
  required int exitCode,
  required int ms,
  String tail = '',
}) => jsonEncode(<String, Object?>{
  'type': kDistItestReportType,
  'path': path,
  'exitCode': exitCode,
  'ms': ms,
  'tail': base64Encode(utf8.encode(tail)),
});

/// The app's progress lines in `flutter drive` output:
/// `flutter: 00:04 +1 ~1: <test name>` on macOS, without the `flutter: `
/// prefix on Windows.
final RegExp kDriveProgressLine = RegExp(
  r'^(?:flutter: )?\d+:\d+ \+\d+(?: ~(\d+))?(?: -\d+)?: (.*)$',
  multiLine: true,
);

/// The tests one `flutter drive` launch ran and skipped, from the app's
/// progress lines ([kDriveProgressLine]): `+N` also counts the binding's
/// hidden `(tearDownAll)`, so tests are the distinct names.
({int tests, int skipped}) driveProgressOf(String output) {
  final Set<String> names = <String>{};
  int skipped = 0;
  for (final RegExpMatch m in kDriveProgressLine.allMatches(output)) {
    skipped = int.tryParse(m.group(1) ?? '') ?? 0;
    final String name = m.group(2)!.trim();
    if (const <String>{
      '(setUpAll)',
      '(tearDownAll)',
      'All tests passed!',
      'Some tests failed.',
    }.contains(name)) {
      continue;
    }
    names.add(name);
  }
  return (tests: names.length, skipped: skipped);
}

/// Turns every [distItestReport] line into a json-reporter run of its own
/// (one suite, one test named after the file: green on exit 0, otherwise an
/// error carrying the output tail), so the verdict, the timings and the
/// re-runs treat integration tests like any other suite. Other lines pass
/// through.
List<String> expandDistItestReports(List<String> lines) {
  final List<String> out = <String>[];
  for (final String line in lines) {
    Object? decoded;
    if (line.startsWith('{"type":"$kDistItestReportType"')) {
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        decoded = null;
      }
    }
    if (decoded is! Map<String, Object?>) {
      out.add(line);
      continue;
    }
    final String path = '${decoded['path']}';
    final int exitCode = (decoded['exitCode'] as num?)?.toInt() ?? -1;
    final int ms = (decoded['ms'] as num?)?.toInt() ?? 0;
    String tail;
    try {
      tail = utf8.decode(
        base64Decode('${decoded['tail'] ?? ''}'),
        allowMalformed: true,
      );
    } on FormatException {
      tail = '';
    }
    final ({int tests, int skipped}) progress = driveProgressOf(tail);
    // drive passes a launch whose every test skipped; nothing ran, so the
    // manifest lists the file for a platform it does not run on.
    final bool allSkipped =
        exitCode == 0 &&
        progress.skipped > 0 &&
        progress.skipped >= progress.tests;
    final bool ok = exitCode == 0 && !allSkipped;
    out.addAll(<String>[
      jsonEncode(<String, Object?>{
        'type': _kStartEventType,
        'protocolVersion': '0.1.1',
        'time': 0,
      }),
      jsonEncode(<String, Object?>{
        'type': 'suite',
        'suite': <String, Object?>{'id': 0, 'platform': 'app', 'path': path},
        'time': 0,
      }),
      jsonEncode(<String, Object?>{
        'type': 'testStart',
        'test': <String, Object?>{
          'id': 1,
          'name': path,
          'suiteID': 0,
          'groupIDs': <int>[],
          'metadata': <String, Object?>{'skip': false, 'skipReason': null},
        },
        'time': 0,
      }),
      if (!ok)
        jsonEncode(<String, Object?>{
          'type': 'error',
          'testID': 1,
          'error': allSkipped
              ? 'every test of this file skipped on this platform '
                    '(${progress.skipped}): nothing ran; list it in '
                    'dist_itests.json only for platforms it runs on\n$tail'
              : 'flutter drive exited $exitCode\n$tail',
          'stackTrace': '',
          'isFailure': true,
          'time': ms,
        }),
      jsonEncode(<String, Object?>{
        'type': 'testDone',
        'testID': 1,
        'result': ok ? 'success' : 'failure',
        'skipped': false,
        'hidden': false,
        'time': ms,
      }),
      // Some skipped, the rest ran: reported (platform skip report).
      if (ok && progress.skipped > 0) ...<String>[
        jsonEncode(<String, Object?>{
          'type': 'testStart',
          'test': <String, Object?>{
            'id': 2,
            'name': '$path (${progress.skipped} skipped)',
            'suiteID': 0,
            'groupIDs': <int>[],
            'metadata': <String, Object?>{
              'skip': true,
              'skipReason':
                  '${progress.skipped} test(s) skipped on this platform',
            },
          },
          'time': ms,
        }),
        jsonEncode(<String, Object?>{
          'type': 'testDone',
          'testID': 2,
          'result': 'success',
          'skipped': true,
          'hidden': false,
          'time': ms,
        }),
      ],
      jsonEncode(<String, Object?>{'type': 'done', 'success': ok, 'time': ms}),
    ]);
  }
  return out;
}

/// The whole run.
class DistRunVerdict {
  DistRunVerdict({
    required this.results,
    required this.unplaced,
    this.filtered = false,
  });

  final List<DistBatchResult> results;

  /// Tests are selected by name / tag: single batches may run none, the run
  /// as a whole must still run at least one (as `flutter test` here would).
  final bool filtered;

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
    if (filtered && testsCompleted == 0) {
      return 'no test matched the name / tag filter in any suite';
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

/// Suites of [result] that failed: the ones with an error event, plus the
/// ones that never produced events. Empty for an infrastructure failure (the
/// batch never got a fair run) or a green batch. A red batch whose failure
/// cannot be pinned to a suite (crash before any error event) names all its
/// files.
List<String> failedSuitesOf(DistBatchResult result) {
  if (result.infraError != null || result.failure == null) {
    return const <String>[];
  }
  final Set<String> files = result.files.toSet();
  final Set<String> failed = <String>{
    for (final FlutterTestErrorEvent e in result.summary.errors)
      ?matchKnownSuite(e.suitePath, files),
    ...result.missingSuites,
  };
  if (failed.isEmpty) return List<String>.of(result.files);
  return <String>[
    for (final String f in result.files)
      if (failed.contains(f)) f,
  ];
}

/// At most this many red suites are re-run for classification; beyond that
/// the run is broken in a way one re-run each will not explain.
const int kDistMaxReruns = 20;

enum DistRerunOutcome {
  /// Red again on the other machine: a real red.
  redOnBoth,

  /// Green on the other machine: red only where it first ran. Still red for
  /// the verdict; classify it per docs/agent/fast-workflow.md (concurrency
  /// false reds) before calling it flaky.
  onlyOriginal,

  /// The re-run itself never got a fair run (ssh dropped, timed out).
  rerunInfra,
}

/// One red suite and what its re-run on another machine said. Only for the
/// report: the run's verdict never changes because of a re-run.
class DistRerun {
  const DistRerun({
    required this.path,
    required this.redOn,
    required this.rerunOn,
    required this.outcome,
  });

  final String path;
  final String redOn;
  final String rerunOn;
  final DistRerunOutcome outcome;
}

/// A red suite that got no classification re-run, and why.
typedef DistNotRerun = ({String path, String redOn, String why});

/// The outcome of re-running [path] (red on another worker) as [rerun].
DistRerunOutcome classifyRerun(DistBatchResult rerun) {
  if (rerun.infraError != null) return DistRerunOutcome.rerunInfra;
  return rerun.failure == null
      ? DistRerunOutcome.onlyOriginal
      : DistRerunOutcome.redOnBoth;
}

/// A test the worker skipped with a reason that names a platform: the static
/// scan placed its suite on a machine where (part of) it does not run, so that
/// coverage silently went missing. Reported, never written back: a host
/// dependency is fixed at the root, and `dist_affinity.json` takes a pin by
/// hand with its reason (see the spec).
class DistPlatformSkip {
  const DistPlatformSkip({
    required this.path,
    required this.test,
    required this.reason,
    required this.worker,
  });

  final String path;
  final String test;
  final String reason;
  final String worker;
}

final RegExp _platformWords = RegExp(
  r'\b(windows|mac ?os|macos|darwin|linux|platform|host)\b',
  caseSensitive: false,
);

/// Platform-worded skips in [result]'s event streams.
List<DistPlatformSkip> platformSkipsOf(DistBatchResult result) {
  final Set<String> files = result.files.toSet();
  final List<DistPlatformSkip> skips = <DistPlatformSkip>[];
  for (final List<String> run in splitEventRuns(result.lines)) {
    final Map<int, String> suites = <int, String>{};
    for (final String line in run) {
      if (!line.startsWith('{')) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      if (decoded['type'] == 'suite') {
        final Object? suite = decoded['suite'];
        if (suite is Map<String, Object?> &&
            suite['id'] is int &&
            suite['path'] is String) {
          final String? path = matchKnownSuite(suite['path']! as String, files);
          if (path != null) suites[suite['id']! as int] = path;
        }
        continue;
      }
      if (decoded['type'] != 'testStart') continue;
      final Object? test = decoded['test'];
      if (test is! Map<String, Object?>) continue;
      final Object? metadata = test['metadata'];
      if (metadata is! Map<String, Object?> || metadata['skip'] != true) {
        continue;
      }
      final Object? reason = metadata['skipReason'];
      if (reason is! String || !_platformWords.hasMatch(reason)) continue;
      final String? path = suites[test['suiteID']];
      if (path == null) continue;
      skips.add(
        DistPlatformSkip(
          path: path,
          test: '${test['name']}',
          reason: reason,
          worker: result.worker,
        ),
      );
    }
  }
  return skips;
}

/// The report sections for [reruns] and [skips] (empty when there is nothing
/// to say), appended to `summary.md`.
String renderDistFollowUp({
  required List<DistRerun> reruns,
  required List<DistNotRerun> notRerun,
  required List<DistPlatformSkip> skips,
}) {
  final StringBuffer out = StringBuffer();
  if (reruns.isNotEmpty || notRerun.isNotEmpty) {
    out
      ..writeln()
      ..writeln('## Red suites re-run on another machine')
      ..writeln()
      ..writeln(
        'For classification only; the verdict above stands. "only red on" '
        'still needs the false-red triage of docs/agent/fast-workflow.md.',
      )
      ..writeln()
      ..writeln('| suite | red on | re-run on | result |')
      ..writeln('|---|---|---|---|');
    for (final DistRerun r in reruns) {
      final String result = switch (r.outcome) {
        DistRerunOutcome.redOnBoth => 'red on both: real red',
        DistRerunOutcome.onlyOriginal => 'only red on ${r.redOn}',
        DistRerunOutcome.rerunInfra => 're-run did not complete',
      };
      out.writeln('| `${r.path}` | ${r.redOn} | ${r.rerunOn} | $result |');
    }
    for (final DistNotRerun n in notRerun) {
      out.writeln('| `${n.path}` | ${n.redOn} | - | not re-run: ${n.why} |');
    }
  }
  if (skips.isNotEmpty) {
    out
      ..writeln()
      ..writeln('## Skipped for a platform reason')
      ..writeln()
      ..writeln(
        'These ran where (part of) them skips; the scan did not see the '
        'host dependency. Fix it at the root, or pin the suite by hand in '
        'tool/test_flow/dist_affinity.json with the reason.',
      )
      ..writeln();
    for (final DistPlatformSkip s in skips) {
      out.writeln('- `${s.path}` on ${s.worker}: ${s.test} — ${s.reason}');
    }
  }
  return out.toString();
}
