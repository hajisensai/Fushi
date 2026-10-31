// The whole repo is dart-formatted and a CI gate keeps it so (2026-11-01).
// This pins the wiring: the gate workflow runs tool/dart_format.sh check after
// pub get and triggers on every Dart file, and the script keeps its documented
// exclusions (vendored upstream, forks, generator output) and Windows-safe
// batching.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String root = Directory.current.parent.path;
  String read(String rel) => File('$root/$rel').readAsStringSync();

  test('dart-format.yml runs the check after pub get on every Dart change', () {
    final String wf = read('.github/workflows/dart-format.yml');
    final int pubGet = wf.indexOf('flutter pub get');
    final int check = wf.indexOf('bash tool/dart_format.sh check');
    expect(pubGet, isNonNegative);
    expect(check, greaterThan(pubGet));
    // Both triggers (pull_request and push) watch all Dart files and the script.
    expect(RegExp(r"- '\*\*\.dart'").allMatches(wf).length, 2);
    expect(RegExp(r"- 'tool/dart_format\.sh'").allMatches(wf).length, 2);
  });

  test('tool/dart_format.sh keeps its scope and batching', () {
    final String sh = read('tool/dart_format.sh');
    for (final String excluded in <String>[
      "':(exclude)third_party/**'",
      "':(exclude)references/**'",
      "':(exclude)ci/patches/**'",
      "':(exclude)packages/flutter_inappwebview_linux/**'",
      "':(exclude)packages/flutter_inappwebview_windows/**'",
      "':(exclude,glob)**/*.g.dart'",
    ]) {
      expect(sh, contains(excluded), reason: excluded);
    }
    expect(sh, contains('--set-exit-if-changed'));
    // dart.bat goes through cmd.exe (8191-char command line): bounded batches.
    expect(sh, contains('xargs -0 -s 7000 dart format'));
  });
}
