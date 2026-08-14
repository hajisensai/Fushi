import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1645：嵌套查词点不开英文注释里的单词（子卡恒「未找到搜索结果」），
/// 同一个词在顶层查词框输入却能正常查到。
///
/// 根因是两侧规则叠在一起：
/// ① `selection.js` 的 `selectFromPosition` 跨文本节点续扫时不认元素边界，把相邻
///    释义 `<li>acrid</li><li>pungent</li>` 粘成 `acridpungent`；
/// ② C++ `scan_candidates`（`native/fushidicts/fushidicts_src/scan/word_scan.cpp`）
///    明确禁止「在两个空格分词类字母之间切」，于是 `acridpungent` 只产出它自己，
///    永远还原不出 `acrid`。
/// 日语不受影响：CJK 不是空格分词脚本，任意码点处都可切，粘多了会被自然切掉。
///
/// 修复落在 ①：跨节点续扫前判断两节点之间有没有渲染断点（块盒/列表项边界，或
/// compact 释义模式下 `li::after { content: " | " }` 这种生成内容分隔符）。
///
/// 两层守护：
/// ① 行为级——用 node 真执行 selection.js，在带 CSS display / 伪元素的 fake DOM 里
///    断言四个场景（相邻释义断开、compact 分隔符断开、行内标记拆词不断、日语不回归）。
///    无 node 时 skip。
/// ② 源码级——三份 selection.js 镜像都必须带上这条边界判定（逐字节一致性由
///    `browser_extension_shadow_dom_lookup_bug1012_test.dart` 守）。
void main() {
  const List<String> selectionCopies = <String>[
    'assets/popup/selection.js',
    'assets/browser_extension/vendor/selection.js',
    '../tools/browser-extension/vendor/selection.js',
  ];

  test(
    'BUG-1645: nested lookup of a Latin word is not glued to the next glossary '
    '(executes selection.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/lookup/nested_latin_lookup_bug1645_test.js');
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
        reason: 'BUG-1645 nested Latin lookup behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'),
          reason: 'behavior harness must reach its success marker');
    },
  );

  test(
      'selection.js stops the cross-node scan at a render boundary '
      '(source guard, all three mirrors)', () {
    for (final String path in selectionCopies) {
      final File file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path must exist');
      final String source = file.readAsStringSync();
      // 断言字面量写进注释，变异测试时能定位（见 fast-workflow 的守卫纪律）。
      expect(source, contains('crossesRenderBoundary('),
          reason: '$path must define the render-boundary check');
      expect(source, contains('this.crossesRenderBoundary(scanNode, nextNode)'),
          reason: '$path must consult it before gluing the next text node');
      expect(source, contains('isInlineBox('),
          reason: '$path must classify boxes by computed display');
      expect(source, contains("hasGeneratedContent(el, '::after')"),
          reason: '$path must treat ::after separators as boundaries');
    }
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
