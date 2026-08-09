import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('popup hides redirect-only glossaries using their data shape', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File('test/pages/popup_redirect_entry_filter_test.js');
    expect(jsTest.existsSync(), isTrue);
    final ProcessResult result = await Process.run(
      nodeExe,
      <String>[jsTest.path],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'redirect filter behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });

  test('every glossary grouping/render path applies the redirect predicate',
      () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    expect(js, contains('function isRedirectGlossary(glossary)'));
    expect(
      RegExp(r'if \(isRedirectGlossary\(g\)\) return;').allMatches(js).length,
      4,
      reason: 'display, mining, main grouping, and incremental grouping must '
          'share the same redirect filtering behavior',
    );
  });

  test('all shipped popup.js mirrors remain byte-identical', () {
    final List<File> mirrors = <File>[
      File('assets/popup/popup.js'),
      File('assets/browser_extension/vendor/popup.js'),
      File('../tools/browser-extension/vendor/popup.js'),
    ];
    final List<List<int>> bytes =
        mirrors.map((File file) => file.readAsBytesSync()).toList();
    expect(bytes[1], orderedEquals(bytes[0]));
    expect(bytes[2], orderedEquals(bytes[0]));
  });
}

String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}
