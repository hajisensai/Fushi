import 'dart:convert';

class FlutterTestRunSummary {
  const FlutterTestRunSummary({
    required this.errors,
    required this.success,
  });

  final List<FlutterTestErrorEvent> errors;
  final bool? success;

  bool get hasFailures => success == false || errors.isNotEmpty;
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
          }
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

  return FlutterTestRunSummary(errors: errors, success: success);
}

String renderFlutterTestFailureSummary(
  FlutterTestRunSummary summary, {
  String? logPath,
  String? stderrLogPath,
  int maxMessageLines = 24,
}) {
  final StringBuffer buffer = StringBuffer()..writeln('Flutter test failures:');

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
