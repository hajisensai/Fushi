import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 选中制卡高亮：制卡时在查词弹窗里选中的释义段，必须在导出的卡片释义里被
/// `<mark class="fushi-selection">` 标在同一位置上。
///
/// 三层守护，别混：
/// ① 算法级（本文件驱动）——node 真执行 popup.js 的
///    `applyGlossarySelectionHighlight`，断言区间切分/包裹、跨元素不压平结构、
///    图片子树不占文本流偏移、文本对不上时整棵树放弃。同时源级断言两个导出
///    构建器（constructGlossaryHtml / constructSingleGlossaryHtml）都应用了高亮，
///    且屏幕侧两个渲染分支都打了坐标锚点。无 node 时 skip。
/// ② 端到端（真 WebView / 真 Range）——
///    `integration_test/popup_selection_highlight_itest.dart`。「屏幕选区 →
///    字符区间」那一半依赖 `Range.comparePoint` / `compareBoundaryPoints` /
///    `intersectsNode` 的真实语义，手写 fake DOM 测它只会变成自证，故不在本层测。
/// ③ 三镜像逐字节一致由 `browser_extension_popup_parity_guard_test.dart` 守。
void main() {
  test(
    'selection made at mining time is marked inside the exported glossary '
    '(executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/anki/glossary_selection_highlight_test.js');
      expect(jsTest.existsSync(), isTrue,
          reason: 'behavior harness ${jsTest.path} must exist');

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'glossary selection highlight behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'),
          reason: 'behavior harness must reach its success marker');
    },
  );
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
