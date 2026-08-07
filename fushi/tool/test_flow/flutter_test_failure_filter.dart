import 'dart:convert';

class FlutterTestRunSummary {
  const FlutterTestRunSummary({
    required this.errors,
    required this.success,
    required this.testsCompleted,
  });

  final List<FlutterTestErrorEvent> errors;

  /// `true` / `false` from the reporter's `done` event, `null` when the run
  /// never reached a verdict (the harness died before the suite finished).
  final bool? success;

  /// Number of non-hidden `testDone` events observed.
  final int testsCompleted;

  /// Why this run must not be reported as green, or `null` when it is green.
  ///
  /// A run only passes when the reporter reached `done: success` *and* at
  /// least [minimumTests] tests actually completed. "Nothing ran" is a
  /// failure, not a pass: otherwise a build / native-assets failure that
  /// executes zero tests is indistinguishable from a clean suite.
  String? failureReason({int minimumTests = 1}) {
    if (success == null) {
      return 'The Flutter test harness never reported a result (no "done" '
          'event). The run aborted before finishing, typically a compile, '
          'asset or native-assets build failure. '
          'Tests completed: $testsCompleted.';
    }
    if (success == false) {
      return 'The Flutter test harness reported failures '
          '(${errors.length} error event(s), $testsCompleted test(s) '
          'completed).';
    }
    if (errors.isNotEmpty) {
      return 'The Flutter test harness emitted ${errors.length} error '
          'event(s) despite a successful "done" event.';
    }
    if (testsCompleted < minimumTests) {
      return 'Only $testsCompleted test(s) ran, expected at least '
          '$minimumTests. A run that executes no tests is not a passing run.';
    }
    return null;
  }

  bool hasFailuresFor({int minimumTests = 1}) =>
      failureReason(minimumTests: minimumTests) != null;

  bool get hasFailures => hasFailuresFor();
}

/// Prefix of the single line that states whether a run really passed.
///
/// It is printed to stdout as the very last line by
/// `tool/flutter_test_failures.dart` so that it survives the pipelines callers
/// habitually use (`... 2>&1 | tail -n 20`), which discard the exit code.
const String kFlutterTestVerdictPrefix = 'FLUTTER TEST VERDICT:';

/// Single decision point for "did this run actually pass?".
///
/// Returns `null` when the run is green, otherwise a human-readable reason.
/// A non-zero [flutterExitCode] always fails, and so does a run that produced
/// no verdict or executed fewer than [minimumTests] tests: a build failure
/// that runs zero tests must never be reportable as a pass.
String? resolveFlutterTestVerdictFailure({
  required int flutterExitCode,
  required FlutterTestRunSummary summary,
  int minimumTests = 1,
}) {
  final String? summaryFailure =
      summary.failureReason(minimumTests: minimumTests);
  if (flutterExitCode != 0) {
    return 'flutter test exited with $flutterExitCode. '
        '${summaryFailure ?? 'See the stderr log for the underlying error.'}';
  }
  return summaryFailure;
}

class FlutterTestErrorEvent {
  const FlutterTestErrorEvent({
    required this.testName,
    required this.suitePath,
    required this.error,
    required this.stackTrace,
  });

  final String testName;
  final String suitePath;
  final String error;
  final String stackTrace;
}

class _TestInfo {
  const _TestInfo({
    required this.name,
    required this.suiteId,
  });

  final String name;
  final int? suiteId;
}

FlutterTestRunSummary parseFlutterTestJsonEvents(Iterable<String> lines) {
  final Map<int, String> suitePaths = <int, String>{};
  final Map<int, _TestInfo> tests = <int, _TestInfo>{};
  final List<FlutterTestErrorEvent> errors = <FlutterTestErrorEvent>[];
  final Set<int> hiddenTestIds = <int>{};
  int testsCompleted = 0;
  bool? success;

  for (final String line in lines) {
    if (line.trim().isEmpty) continue;

    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;

    switch (decoded['type']) {
      case 'suite':
        final Object? suite = decoded['suite'];
        if (suite is Map<String, Object?>) {
          final Object? id = suite['id'];
          if (id is int) {
            suitePaths[id] = (suite['path'] as String?) ?? '<unknown suite>';
          }
        }
      case 'testStart':
        final Object? test = decoded['test'];
        if (test is Map<String, Object?>) {
          final Object? id = test['id'];
          if (id is int) {
            tests[id] = _TestInfo(
              name: (test['name'] as String?) ?? '<unnamed test>',
              suiteId: test['suiteID'] as int?,
            );
            if (_isHiddenTestName((test['name'] as String?) ?? '')) {
              hiddenTestIds.add(id);
            }
          }
        }
      case 'testDone':
        final Object? testId = decoded['testID'];
        final bool hidden = decoded['hidden'] == true ||
            (testId is int && hiddenTestIds.contains(testId));
        if (!hidden) {
          testsCompleted++;
        }
      case 'error':
        final Object? testId = decoded['testID'];
        final _TestInfo? test = testId is int ? tests[testId] : null;
        errors.add(FlutterTestErrorEvent(
          testName: test?.name ?? '<load error>',
          suitePath: test?.suiteId == null
              ? '<unknown suite>'
              : suitePaths[test!.suiteId!] ?? '<unknown suite>',
          error: (decoded['error'] as String?) ?? '<no error message>',
          stackTrace: (decoded['stackTrace'] as String?) ?? '',
        ));
      case 'done':
        success = decoded['success'] as bool?;
    }
  }

  return FlutterTestRunSummary(
    errors: errors,
    success: success,
    testsCompleted: testsCompleted,
  );
}

/// `package:test` emits synthetic per-suite bookkeeping tests whose names are
/// `loading <path>` / `compiling <path>`. They must not count as executed
/// tests, otherwise a suite that fails to load would look like it "ran".
bool _isHiddenTestName(String name) =>
    name.startsWith('loading ') || name.startsWith('compiling ');

String renderFlutterTestFailureSummary(
  FlutterTestRunSummary summary, {
  String? logPath,
  String? stderrLogPath,
  int maxMessageLines = 24,
  int minimumTests = 1,
}) {
  final StringBuffer buffer = StringBuffer()..writeln('Flutter test failures:');

  final String? reason = summary.failureReason(minimumTests: minimumTests);
  if (reason != null) {
    buffer.writeln('- $reason');
  }

  if (summary.errors.isEmpty) {
    buffer.writeln('- No explicit error event was emitted.');
  } else {
    for (final FlutterTestErrorEvent error in summary.errors) {
      buffer
        ..writeln('- ${error.testName}')
        ..writeln('  suite: ${error.suitePath}')
        ..write(_indentLimited(error.error, maxMessageLines));
      if (error.stackTrace.trim().isNotEmpty) {
        buffer
          ..writeln()
          ..write(_indentLimited(error.stackTrace, maxMessageLines));
      }
      buffer.writeln();
    }
  }

  if (logPath != null && logPath.isNotEmpty) {
    buffer.writeln('Full JSON log: $logPath');
  }
  if (stderrLogPath != null && stderrLogPath.isNotEmpty) {
    buffer.writeln('Full stderr log: $stderrLogPath');
  }
  return buffer.toString().trimRight();
}

String _indentLimited(String value, int maxLines) {
  final List<String> lines = value.trimRight().split('\n');
  final int visibleCount =
      lines.length < maxLines ? lines.length : maxLines.clamp(0, lines.length);
  final StringBuffer buffer = StringBuffer();
  for (final String line in lines.take(visibleCount)) {
    buffer.writeln('  ${line.trimRight()}');
  }
  final int omitted = lines.length - visibleCount;
  if (omitted > 0) {
    buffer.writeln('  ... omitted $omitted lines');
  }
  return buffer.toString().trimRight();
}
