import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `{popup-selection-html}`（反馈 aBgKMjhfut / BUG-4049 方案 B）的 popup.js 行为守卫：
/// node 真执行 popup.js 抽出的 snapshotSelectionHtml / serializeSelectionHtml /
/// sanitizeSelectionHtmlTree / snapshotSelection / clearSelectionSnapshot，断言选区片段
/// 带词典作用域与 scoped CSS、交互件与危险内容被净化、快照与纯文本同生同灭。
/// Dart 侧渲染见 `packages/fushi_anki/test/popup_selection_html_test.dart`；三镜像逐字节
/// 一致由 `browser_extension_popup_parity_guard_test.dart` 守。无 node 时 skip。
void main() {
  test('popup selection html is scoped, styled and sanitized '
      '(executes popup.js via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File('test/anki/popup_selection_html_test.js');
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
          'popup selection html behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout.toString(),
      contains('all assertions passed'),
      reason: 'behavior harness must reach its success marker',
    );
  });
}

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
