// Runs the bundled Bangumi plugin's own tests (plugins/tracking/bangumi/test,
// the tracking kit's harness: real sandbox runner, HTTP from fixtures, no
// network) with Node, like the other `*_js_test.dart` files.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Bangumi plugin tests pass under the kit harness', () async {
    final ProcessResult result = await Process.run(
      'node',
      <String>[
        '--test',
        '--test-reporter=tap',
        'plugins/tracking/bangumi/test/bangumi.test.mjs',
      ],
      workingDirectory: '..',
      runInShell: Platform.isWindows,
    );
    final String out = '${result.stdout}\n${result.stderr}';
    expect(result.exitCode, 0, reason: out);
    final RegExpMatch? pass = RegExp(
      r'^# pass (\d+)$',
      multiLine: true,
    ).firstMatch('${result.stdout}');
    expect(pass, isNotNull, reason: out);
    // Executed count, not just the exit code: zero tests would also exit 0.
    expect(int.parse(pass!.group(1)!), greaterThanOrEqualTo(14), reason: out);
    expect(out, contains('# fail 0'));
  });
}
