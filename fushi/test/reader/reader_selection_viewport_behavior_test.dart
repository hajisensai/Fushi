import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Executes current worktree production JS, including shared methods and the
/// capture -> target event chain, forced navigation and pre-detach VN cleanup.
/// Node is required: a missing executable fails this test rather than silently
/// dropping the viewport-selection coverage.
void main() {
  test('scroll protects drags; navigation and rebuild clear', () async {
    final ProcessResult result = await Process.run(
      Platform.isWindows ? 'node.exe' : 'node',
      <String>['test/reader/reader_selection_viewport_behavior_test.js'],
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('all assertions passed'));
  });
}
