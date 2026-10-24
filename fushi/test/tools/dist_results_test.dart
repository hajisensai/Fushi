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
}
