// Contract: a dist_test run off this machine (tool/heavy.dart's --offload /
// --analyze / --build) that cannot get going because of the setup -- a bad or
// missing worker config -- declines with kDistOffloadDeclined and says why,
// so heavy.dart runs the command here. It is never a red verdict on the code
// (before: exit 64, and every offloaded test / analyze came back red with
// zero tests run). Without --offload the same mistake stays a usage error.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/dist_plan.dart';
import '../../tool/test_flow/flutter_sdk_executables.dart';

void main() {
  late Directory scratch;
  setUpAll(() {
    scratch = Directory.systemTemp.createTempSync('dist_decline_');
  });
  tearDownAll(() => scratch.deleteSync(recursive: true));

  Future<ProcessResult> distTest(List<String> args) => Process.run(
    FlutterSdkExecutables.current().dart(),
    <String>['tool/dist_test.dart', ...args],
    runInShell: Platform.isWindows,
  );

  String config(String name, String text) {
    final File f = File('${scratch.path}/$name')..writeAsStringSync(text);
    return f.path;
  }

  test(
    'a bad worker config off this machine declines with the reason',
    () async {
      final String invalid = config('invalid.json', '{"workers": 3}');
      final String notJson = config('broken.json', '{');
      for (final List<String> args in <List<String>>[
        <String>['--offload', '--config=$invalid', 'test/tools'],
        <String>['--offload', '--config=$notJson', 'test/tools'],
        <String>['--analyze', '--config=$invalid'],
        <String>['--offload', '--config=${scratch.path}/missing.json'],
        <String>[
          '--build',
          '--config=$invalid',
          '--',
          'flutter',
          'build',
          'apk',
          '--debug',
        ],
      ]) {
        final ProcessResult r = await distTest(args);
        expect(
          r.exitCode,
          kDistOffloadDeclined,
          reason: '${args.first}\n${r.stderr}',
        );
        expect(
          '${r.stdout}',
          contains('DIST OFFLOAD: declined: '),
          reason: args.join(' '),
        );
        expect(
          '${r.stdout}${r.stderr}',
          isNot(contains('DIST TEST VERDICT: FAILED')),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('without --offload a bad config is a usage error', () async {
    final ProcessResult r = await distTest(<String>[
      '--config=${config('invalid2.json', '{"workers": 3}')}',
      '--dry-run',
    ]);
    expect(r.exitCode, 64, reason: '${r.stderr}');
    expect('${r.stdout}', isNot(contains('DIST OFFLOAD')));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
