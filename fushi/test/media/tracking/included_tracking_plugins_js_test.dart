// Runs the tests of the plugins included with Fushi (plugins/tracking/anilist
// and plugins/tracking/mangabaka; the tracking kit's harness: real sandbox
// runner, HTTP from fixtures, no network) with Node, like the other
// `*_js_test.dart` files.
import 'dart:io';

import 'package:test/test.dart';

/// Test file -> the least number of tests it must run.
const Map<String, int> _suites = <String, int>{
  'plugins/tracking/anilist/test/anilist.test.mjs': 10,
  'plugins/tracking/mangabaka/test/mangabaka.test.mjs': 9,
};

void main() {
  for (final MapEntry<String, int> suite in _suites.entries) {
    test('${suite.key} passes under the kit harness', () async {
      final ProcessResult result = await Process.run(
        'node',
        <String>['--test', '--test-reporter=tap', suite.key],
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
      expect(int.parse(pass!.group(1)!), greaterThanOrEqualTo(suite.value));
      expect(out, contains('# fail 0'));
    });
  }
}
