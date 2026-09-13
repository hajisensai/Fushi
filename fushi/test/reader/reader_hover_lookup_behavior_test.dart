import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hover deduplicates matched words and permits the next word', () async {
    final ProcessResult result = await Process.run(
      Platform.isWindows ? 'node.exe' : 'node',
      <String>['test/reader/reader_hover_lookup_behavior_test.js'],
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('all assertions passed'));
  });
}
