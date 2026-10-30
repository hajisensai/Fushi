import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 释义（弹窗 WebView）里点词，嵌套查词要带上被点文本的来源振假名：
/// `assets/popup/selection.js` 的 `selectFromPosition` 产出 `selection.rubyReadings`，
/// 并作为 `textSelected` 的第 3 参交给宿主。
///
/// 行为级：用 node 在 fake DOM 里真执行该资产。无 node 时 skip。
void main() {
  test('popup selection.js reports source ruby readings as the 3rd '
      'textSelected argument (executes selection.js via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final File jsTest = File(
      'test/dictionary/popup_selection_ruby_readings_test.js',
    );
    expect(
      jsTest.existsSync(),
      isTrue,
      reason: 'behavior harness ${jsTest.path} must exist',
    );
    final ProcessResult result = await Process.run(nodeExe, <String>[
      jsTest.path,
    ], workingDirectory: Directory.current.path);
    expect(
      result.exitCode,
      0,
      reason:
          'popup ruby readings behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout.toString(),
      contains('all assertions passed'),
      reason: 'behavior harness must reach its success marker',
    );
  });

  test(
    'the browser-extension copies stay byte-identical to the popup asset',
    () {
      final List<int> popup = File(
        'assets/popup/selection.js',
      ).readAsBytesSync();
      for (final String copy in <String>[
        'assets/browser_extension/vendor/selection.js',
        '../tools/browser-extension/vendor/selection.js',
      ]) {
        expect(File(copy).readAsBytesSync(), popup, reason: '$copy drifted');
      }
    },
  );
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
