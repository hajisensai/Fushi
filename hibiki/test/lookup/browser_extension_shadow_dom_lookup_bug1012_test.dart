import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1012: Hibiki 浏览器扩展的取词引擎 selection.js `getCaretRange` 只在顶层
/// `document` 上调用 `caretPositionFromPoint` / `elementFromPoint`，不穿透 open
/// Shadow DOM。B 站新版评论区用 Web Component（<bili-comments>，shadow root 渲染），
/// 这些 API 命中的是 shadow 宿主元素（元素节点）而非内部文字节点，`getCharacterAtPoint`
/// 在 `nodeType !== TEXT_NODE` 处直接 return null，取词失败（Yomitan 的 DOMTextScanner
/// 会沿 shadowRoot 下钻，所以能读）。
///
/// 根因修复：`getCaretRange` 消除「caret 命中非文本节点就死」的特殊情况，统一为
/// 「caret 命中文本直采，否则用 deepElementFromPoint 沿 element.shadowRoot 逐层下钻到
/// 最深元素，再 charRangeInContainer 逐字几何命中」。三份镜像同步。
///
/// 两层守护：
/// ① 行为级——用 node 真执行 selection.js，在含 shadow 宿主的 fake DOM 里断言
///    getCharacterAtPoint 穿透取到 shadow 内部文字（修复前此处为 null）。无 node 时 skip。
/// ② 源码级 + 三镜像一致——保证三份 selection.js 都含 shadow 穿透逻辑且逐字节一致。
void main() {
  const List<String> selectionCopies = <String>[
    'assets/popup/selection.js',
    'assets/browser_extension/vendor/selection.js',
    '../tools/browser-extension/vendor/selection.js',
  ];

  test(
    'BUG-1012: extension lookup penetrates shadow DOM (executes selection.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File(
        'test/lookup/browser_extension_shadow_dom_lookup_bug1012_test.js',
      );
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
        reason: 'BUG-1012 shadow-DOM lookup behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'),
          reason: 'behavior harness must reach its success marker');
    },
  );

  test('selection.js getCaretRange penetrates shadow DOM (source guard)', () {
    for (final String path in selectionCopies) {
      final String src = File(path).readAsStringSync();

      // 穿透 helper 必须存在并沿 element.shadowRoot 下钻。
      expect(src.contains('deepElementFromPoint'), isTrue,
          reason: '[$path] 必须有 deepElementFromPoint 穿透 shadow DOM');
      expect(src.contains('element.shadowRoot'), isTrue,
          reason: '[$path] deepElementFromPoint 必须沿 element.shadowRoot 下钻');
      expect(src.contains('shadowRoot.elementFromPoint'), isTrue,
          reason: '[$path] 必须在 shadowRoot 上继续 elementFromPoint 下探内部文字');

      // getCaretRange 必须在 caret 命中文本节点时才直采，否则继续下探（不再直接返回宿主 range）。
      expect(src.contains('pos.offsetNode.nodeType === Node.TEXT_NODE'), isTrue,
          reason: '[$path] caret 只在命中文本节点时采纳，命中元素（shadow 宿主）须继续下探');

      // getCaretRange 必须调用穿透 helper 与逐字几何命中。
      final int caretRangeIdx = src.indexOf('getCaretRange(x, y)');
      final int deepCallIdx = src.indexOf('this.deepElementFromPoint(x, y)');
      expect(caretRangeIdx >= 0 && deepCallIdx > caretRangeIdx, isTrue,
          reason: '[$path] getCaretRange 必须调用 deepElementFromPoint');
      expect(src.contains('this.charRangeInContainer('), isTrue,
          reason: '[$path] getCaretRange 必须用 charRangeInContainer 逐字几何命中');
    }
  });

  test('the three selection.js copies stay byte-identical (parity)', () {
    final String a = File(selectionCopies[0]).readAsStringSync();
    final String b = File(selectionCopies[1]).readAsStringSync();
    final String c = File(selectionCopies[2]).readAsStringSync();
    expect(a == b, isTrue, reason: 'assets/popup 与扩展 vendor 镜像必须逐字节一致');
    expect(a == c, isTrue, reason: 'assets/popup 与 tools 扩展镜像必须逐字节一致');
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
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
