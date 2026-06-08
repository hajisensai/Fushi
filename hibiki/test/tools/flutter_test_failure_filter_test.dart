import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/flutter_test_failure_filter.dart';

void main() {
  group('flutter test failure filter', () {
    test('renders only error events and omits passing tests', () {
      final FlutterTestRunSummary summary = parseFlutterTestJsonEvents(
        <String>[
          '{"type":"suite","suite":{"id":0,"path":"test/pass_test.dart"}}',
          '{"type":"testStart","test":{"id":1,"name":"passing test","suiteID":0}}',
          '{"type":"testDone","testID":1,"result":"success"}',
          '{"type":"suite","suite":{"id":1,"path":"test/fail_test.dart"}}',
          '{"type":"testStart","test":{"id":2,"name":"failing test","suiteID":1}}',
          '{"type":"error","testID":2,"error":"Expected: true\\n  Actual: false","stackTrace":"package:test/fail_test.dart 10:3","isFailure":true}',
          '{"type":"testDone","testID":2,"result":"failure"}',
          '{"type":"done","success":false}',
        ],
      );

      final String rendered = renderFlutterTestFailureSummary(
        summary,
        logPath: '.codex-test/flutter-test/run.jsonl',
        stderrLogPath: '.codex-test/flutter-test/stderr.log',
      );

      expect(rendered, contains('failing test'));
      expect(rendered, contains('test/fail_test.dart'));
      expect(rendered, contains('Expected: true'));
      expect(rendered, contains('.codex-test/flutter-test/run.jsonl'));
      expect(rendered, contains('.codex-test/flutter-test/stderr.log'));
      expect(rendered, isNot(contains('passing test')));
      expect(rendered, isNot(contains('test/pass_test.dart')));
    });

    test('renders a load error without a test id', () {
      final FlutterTestRunSummary summary = parseFlutterTestJsonEvents(
        <String>[
          '{"type":"error","error":"Failed to load test file","stackTrace":"loader.dart 1:1"}',
          '{"type":"done","success":false}',
        ],
      );

      final String rendered = renderFlutterTestFailureSummary(summary);

      expect(rendered, contains('<load error>'));
      expect(rendered, contains('Failed to load test file'));
    });

    test('caps very large failure output but keeps the log path', () {
      final StringBuffer longError = StringBuffer();
      for (int i = 0; i < 80; i++) {
        longError.writeln('line $i');
      }
      final FlutterTestRunSummary summary = parseFlutterTestJsonEvents(
        <String>[
          '{"type":"testStart","test":{"id":1,"name":"large failure"}}',
          '{"type":"error","testID":1,"error":${jsonEncode(longError.toString())},"stackTrace":"","isFailure":true}',
          '{"type":"done","success":false}',
        ],
      );

      final String rendered = renderFlutterTestFailureSummary(
        summary,
        logPath: '.codex-test/flutter-test/full.jsonl',
        maxMessageLines: 3,
      );

      expect(rendered, contains('line 0'));
      expect(rendered, contains('line 2'));
      expect(rendered, isNot(contains('line 20')));
      expect(rendered, contains('omitted'));
      expect(rendered, contains('.codex-test/flutter-test/full.jsonl'));
    });
  });
}
