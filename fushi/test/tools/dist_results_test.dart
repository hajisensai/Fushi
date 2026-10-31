// Contract of the dist_test verdict: a batch is only green with exit 0, a
// `done: success`, at least one test, and an event for every suite it was given.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/dist_results.dart';

/// One json-reporter run where every suite in [suites] passes one test.
List<String> _run(List<String> suites, {bool success = true}) {
  final List<String> lines = <String>[
    jsonEncode(<String, Object?>{'type': 'start', 'protocolVersion': '0.1.1'}),
  ];
  int id = 0;
  for (int i = 0; i < suites.length; i++) {
    lines
      ..add(
        jsonEncode(<String, Object?>{
          'type': 'suite',
          'suite': <String, Object?>{
            'id': i,
            'path': '/abs/fushi/${suites[i]}',
          },
        }),
      )
      ..add(
        jsonEncode(<String, Object?>{
          'type': 'testStart',
          'test': <String, Object?>{'id': ++id, 'name': 't$i', 'suiteID': i},
          'time': 1,
        }),
      )
      ..add(
        jsonEncode(<String, Object?>{
          'type': 'testDone',
          'testID': id,
          'result': 'success',
          'hidden': false,
          'time': 2,
        }),
      );
  }
  lines.add(jsonEncode(<String, Object?>{'type': 'done', 'success': success}));
  return lines;
}

DistBatchResult _result(
  List<String> files,
  List<String> lines, {
  int exitCode = 0,
  String? infra,
}) => DistBatchResult(
  batchId: 1,
  worker: 'w',
  files: files,
  exitCode: exitCode,
  lines: lines,
  elapsed: Duration.zero,
  infraError: infra,
);

void main() {
  const List<String> files = <String>['test/a_test.dart', 'test/b_test.dart'];

  test('all suites reported and passing: green', () {
    final DistBatchResult r = _result(files, _run(files));
    expect(r.failure, isNull);
    expect(r.summary.testsCompleted, 2);
  });

  test('a suite with no events is red even though the run passed', () {
    final DistBatchResult r = _result(files, _run(<String>[files.first]));
    expect(r.missingSuites, <String>['test/b_test.dart']);
    expect(r.failure, contains('produced no events'));
  });

  test('integration test suites are matched by their whole path', () {
    const List<String> itest = <String>['integration_test/a_test.dart'];
    expect(_result(itest, _run(itest)).failure, isNull);
    // `.../integration_test/a_test.dart` is not `test/a_test.dart`.
    expect(
      _result(<String>['test/a_test.dart'], _run(itest)).missingSuites,
      <String>['test/a_test.dart'],
    );
  });

  test('an integration test launch report becomes a suite of its own', () {
    const List<String> itests = <String>[
      'integration_test/a_test.dart',
      'integration_test/b_test.dart',
    ];
    final List<String> lines = expandDistItestReports(<String>[
      'Building macOS application...',
      distItestReport(path: itests[0], exitCode: 0, ms: 9000),
      distItestReport(
        path: itests[1],
        exitCode: 1,
        ms: 12000,
        tail: 'Failure in method: opens the reader',
      ),
    ]);
    final DistBatchResult r = _result(itests, lines, exitCode: 1);
    expect(r.missingSuites, isEmpty);
    expect(r.summary.testsCompleted, 2);
    expect(failedSuitesOf(r), <String>['integration_test/b_test.dart']);
    expect(lines.join('\n'), contains('Failure in method: opens the reader'));
    expect(lines.first, 'Building macOS application...');

    // drive exits 0 when every test skipped: nothing ran, so it is red.
    const String allSkipped =
        'flutter: 00:00 +0: plays a video\n'
        'flutter: 00:00 +0 ~1: (tearDownAll)\n'
        'flutter: 00:00 +1 ~1: All tests passed!';
    expect(driveProgressOf(allSkipped), (tests: 1, skipped: 1));
    expect(
      failedSuitesOf(
        _result(
          <String>[itests[0]],
          expandDistItestReports(<String>[
            distItestReport(
              path: itests[0],
              exitCode: 0,
              ms: 1,
              tail: allSkipped,
            ),
          ]),
        ),
      ),
      <String>[itests[0]],
    );
    // Some skipped, the rest ran: green, and the skip is reported.
    const String someSkipped =
        'flutter: 00:00 +0: a\n'
        'flutter: 00:04 +1: b\n'
        'flutter: 00:05 +1 ~1: (tearDownAll)\n'
        'flutter: 00:05 +2 ~1: All tests passed!';
    expect(driveProgressOf(someSkipped), (tests: 2, skipped: 1));
    // Windows prints the same lines without the `flutter: ` prefix.
    expect(driveProgressOf(allSkipped.replaceAll('flutter: ', '')), (
      tests: 1,
      skipped: 1,
    ));
    final DistBatchResult partly = _result(
      <String>[itests[0]],
      expandDistItestReports(<String>[
        distItestReport(path: itests[0], exitCode: 0, ms: 1, tail: someSkipped),
      ]),
    );
    expect(partly.failure, isNull);
    expect(platformSkipsOf(partly), hasLength(1));
    expect(
      _result(
        <String>[itests[0]],
        expandDistItestReports(<String>[
          distItestReport(path: itests[0], exitCode: 0, ms: 1),
        ]),
      ).failure,
      isNull,
    );
  });

  test('non-zero exit, no done, zero tests, infra error: all red', () {
    expect(_result(files, _run(files), exitCode: 1).failure, isNotNull);
    expect(_result(files, _run(files)..removeLast()).failure, isNotNull);
    expect(_result(files, const <String>[]).failure, isNotNull);
    expect(
      _result(files, _run(files), infra: 'ssh dropped').failure,
      'ssh dropped',
    );
  });

  test('several back-to-back runs (a chunked local batch) merge', () {
    final List<String> lines = <String>[
      ..._run(<String>[files.first]),
      ..._run(<String>[files.last]),
    ];
    expect(splitEventRuns(lines), hasLength(2));
    final DistBatchResult r = _result(files, lines);
    expect(r.failure, isNull);
    expect(r.summary.testsCompleted, 2);

    final DistBatchResult second = _result(files, <String>[
      ..._run(<String>[files.first]),
      ..._run(<String>[files.last], success: false),
    ]);
    expect(second.failure, isNotNull);
  });

  test('run verdict: unplaced suites and failed batches are red', () {
    final DistBatchResult ok = _result(files, _run(files));
    expect(
      DistRunVerdict(
        results: <DistBatchResult>[ok],
        unplaced: <String>[],
      ).failure,
      isNull,
    );
    expect(
      DistRunVerdict(
        results: <DistBatchResult>[ok],
        unplaced: <String>['test/c_test.dart (windows)'],
      ).failure,
      contains('no eligible worker'),
    );
    expect(
      DistRunVerdict(
        results: <DistBatchResult>[],
        unplaced: <String>[],
      ).failure,
      isNotNull,
    );
  });

  group('name / tag filter (heavy.dart --name/--plain-name/--tags)', () {
    // What `flutter test --plain-name=x a b` reports when neither suite has a
    // test named x (seen 2026-10-31): both suites load, `done: success`, no
    // test, exit 79 (package:test's "no tests ran").
    List<String> unmatched(List<String> suites) => <String>[
      jsonEncode(<String, Object?>{
        'type': 'start',
        'protocolVersion': '0.1.1',
      }),
      for (int i = 0; i < suites.length; i++)
        jsonEncode(<String, Object?>{
          'type': 'suite',
          'suite': <String, Object?>{
            'id': i,
            'path': '/abs/fushi/${suites[i]}',
          },
        }),
      jsonEncode(<String, Object?>{'type': 'done', 'success': true}),
    ];
    DistBatchResult filtered(
      List<String> lines, {
      int exitCode = 0,
      List<String> suites = files,
    }) => DistBatchResult(
      batchId: 1,
      worker: 'w',
      files: suites,
      exitCode: exitCode,
      lines: lines,
      elapsed: Duration.zero,
      filtered: true,
    );

    test('which options count as a filter', () {
      expect(distTestFilterActive(<String>['--plain-name=x']), isTrue);
      expect(distTestFilterActive(<String>['--name=x']), isTrue);
      expect(distTestFilterActive(<String>['--tags=x']), isTrue);
      expect(
        distTestFilterActive(<String>['--exclude-tags', 'golden']),
        isTrue,
      );
      expect(distTestFilterActive(<String>['-n', 'x']), isTrue);
      expect(distTestFilterActive(<String>['--coverage']), isFalse);
      expect(distTestFilterActive(const <String>[]), isFalse);
    });

    test('a batch whose suites match nothing is green under a filter', () {
      final DistBatchResult none = filtered(
        unmatched(files),
        exitCode: kTestNoTestsRanExitCode,
      );
      expect(none.failure, isNull);
      // ... but the same stream without a filter stays red (zero tests).
      expect(
        _result(
          files,
          unmatched(files),
          exitCode: kTestNoTestsRanExitCode,
        ).failure,
        isNotNull,
      );
      // A chunked local batch: one process matched, the other did not.
      expect(
        filtered(<String>[
          ..._run(<String>[files.first]),
          ...unmatched(<String>[files.last]),
        ], exitCode: kTestNoTestsRanExitCode).failure,
        isNull,
      );
    });

    test('a filter does not hide a real failure', () {
      // Another exit code, a failed `done`, no `done` at all, a suite that
      // never loaded: all still red.
      expect(filtered(unmatched(files), exitCode: 1).failure, isNotNull);
      expect(
        filtered(
          _run(files, success: false),
          exitCode: kTestNoTestsRanExitCode,
        ).failure,
        isNotNull,
      );
      expect(
        filtered(
          unmatched(files)..removeLast(),
          exitCode: kTestNoTestsRanExitCode,
        ).failure,
        isNotNull,
      );
      expect(
        filtered(
          unmatched(<String>[files.first]),
          exitCode: kTestNoTestsRanExitCode,
        ).failure,
        contains('produced no events'),
      );
      expect(filtered(const <String>[], exitCode: 1).failure, isNotNull);
    });

    test('the run as a whole must still run a test', () {
      final DistBatchResult none = filtered(
        unmatched(files),
        exitCode: kTestNoTestsRanExitCode,
      );
      final DistBatchResult some = filtered(_run(files));
      expect(
        DistRunVerdict(
          results: <DistBatchResult>[none, some],
          unplaced: <String>[],
          filtered: true,
        ).failure,
        isNull,
      );
      expect(
        DistRunVerdict(
          results: <DistBatchResult>[none],
          unplaced: <String>[],
          filtered: true,
        ).failure,
        contains('no test matched'),
      );
    });
  });

  group('classification re-runs', () {
    // An `error` event on the test of suite [index] in a [_run] stream.
    List<String> failing(List<String> suites, int index) {
      final List<String> lines = _run(suites, success: false);
      return <String>[
        ...lines.sublist(0, lines.length - 1),
        jsonEncode(<String, Object?>{
          'type': 'error',
          'testID': index + 1,
          'error': 'boom',
          'stackTrace': '',
        }),
        lines.last,
      ];
    }

    test('red suites are the erroring and the silent ones', () {
      final DistBatchResult r = _result(
        <String>[...files, 'test/c_test.dart'],
        failing(files, 1),
        exitCode: 1,
      );
      expect(failedSuitesOf(r), <String>[
        'test/b_test.dart',
        'test/c_test.dart',
      ]);
    });

    test('a red batch with nothing to pin it on names every file', () {
      expect(failedSuitesOf(_result(files, _run(files), exitCode: 1)), files);
    });

    test('green and infrastructure-failed batches have no red suites', () {
      expect(failedSuitesOf(_result(files, _run(files))), isEmpty);
      expect(
        failedSuitesOf(_result(files, const <String>[], infra: 'ssh dropped')),
        isEmpty,
      );
    });

    test('outcome of the re-run', () {
      const List<String> one = <String>['test/a_test.dart'];
      expect(
        classifyRerun(_result(one, failing(one, 0), exitCode: 1)),
        DistRerunOutcome.redOnBoth,
      );
      expect(
        classifyRerun(_result(one, _run(one))),
        DistRerunOutcome.onlyOriginal,
      );
      expect(
        classifyRerun(_result(one, const <String>[], infra: 'timed out')),
        DistRerunOutcome.rerunInfra,
      );
    });

    test('the report says which, and that the verdict stands', () {
      final String text = renderDistFollowUp(
        reruns: const <DistRerun>[
          DistRerun(
            path: 'test/a_test.dart',
            redOn: 'self-win',
            rerunOn: 'self-mac',
            outcome: DistRerunOutcome.onlyOriginal,
          ),
        ],
        notRerun: const <DistNotRerun>[
          (path: 'test/w_test.dart', redOn: 'self-win', why: 'no other'),
        ],
        skips: const <DistPlatformSkip>[],
      );
      expect(text, contains('verdict above stands'));
      expect(text, contains('only red on self-win'));
      expect(text, contains('not re-run: no other'));
      expect(
        renderDistFollowUp(
          reruns: const <DistRerun>[],
          notRerun: const <DistNotRerun>[],
          skips: const <DistPlatformSkip>[],
        ),
        isEmpty,
      );
    });
  });

  test('platform-worded skips are reported with their suite', () {
    String skipped(int suiteId, int id, String reason) =>
        jsonEncode(<String, Object?>{
          'type': 'testStart',
          'test': <String, Object?>{
            'id': id,
            'name': 'skipped $id',
            'suiteID': suiteId,
            'metadata': <String, Object?>{'skip': true, 'skipReason': reason},
          },
          'time': 1,
        });
    final List<String> lines = _run(files);
    lines.insertAll(lines.length - 1, <String>[
      skipped(1, 90, 'needs Windows (WebView2)'),
      skipped(0, 91, 'slow; run with --run-skipped'),
      skipped(0, 92, 'not supported on this platform'),
    ]);
    final List<DistPlatformSkip> skips = platformSkipsOf(_result(files, lines));
    expect(skips.map((DistPlatformSkip s) => '${s.path}|${s.test}'), <String>[
      'test/b_test.dart|skipped 90',
      'test/a_test.dart|skipped 92',
    ]);
    expect(
      renderDistFollowUp(
        reruns: const <DistRerun>[],
        notRerun: const <DistNotRerun>[],
        skips: skips,
      ),
      contains('dist_affinity.json'),
    );
  });
}
