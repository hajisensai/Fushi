import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/highlight_bridge.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

/// BUG-3323：iOS / macOS 分页阅读器里长按拖选、查词、收藏、搜索高亮全部不画，只剩
/// 选区手柄（issue #2108 图二）。
///
/// 根因：BUG-2761 的 WebKit 分页页顶注音预留给每个 `p` 加了 `display:block` 的
/// `p::after`，段落正文因此落进**匿名块**；WebKit 对匿名块里的文本节点**不绘制任何
/// `::highlight()`**（选择器怎么写都不行；文本父级是行内元素就正常；Blink 不受影响）。
///
/// 修法：每个 CSS Highlight 写入点在建 Range **之前**调
/// `window.__fushiEnsureHighlightPaintable(textNode)`，把处在该位置的文本节点原样移进
/// 无样式行内包装元素（节点身份、偏移不变；包装不产生盒子）。
///
/// 覆盖边界：助手的判定与搬移行为由同名 `.js` 用 node 真跑生产代码验证；这里钉「每个
/// 写入点都先调助手、再建 Range」的装配契约。WebKit 真绘制只能在 WebKit 里验，像素证据
/// （Playwright WebKit + iOS 26.5 模拟器修复前后对照）记在 bug 文件。
void main() {
  test('助手行为：node 真跑生产安装器', () async {
    final ProcessResult result = await Process.run(
      Platform.isWindows ? 'node.exe' : 'node',
      <String>['test/reader/reader_highlight_paintable_bug3277_test.js'],
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('all assertions passed'));
  });

  /// [source] 里 [anchor] 之后第一个 `document.createRange()` 之前必须出现助手调用。
  void expectPaintableBeforeRange(String source, String anchor, String where) {
    final int at = source.indexOf(anchor);
    expect(at, isNonNegative, reason: '$where：找不到锚点 $anchor');
    final int range = source.indexOf('document.createRange()', at);
    expect(range, greaterThan(at), reason: '$where：锚点后没有 createRange');
    final String between = source.substring(at, range);
    expect(
      between,
      contains('__fushiEnsureHighlightPaintable('),
      reason:
          '$where：建 Range 前必须先让文本可被 ::highlight 绘制（BUG-3323）；'
          '先建 Range 再搬节点会让这个活 Range 塌缩',
    );
  }

  test('选区脚本定义助手（幂等安装）', () {
    final String js = ReaderSelectionScripts.source();
    expect(
      js,
      contains(
        "if (typeof window.__fushiEnsureHighlightPaintable !== 'function')",
      ),
    );
    expect(
      js.indexOf('window.__fushiEnsureHighlightPaintable = '),
      lessThan(js.indexOf('window.fushiSelection = {')),
      reason: '助手要在 fushiSelection 之前装好，其它脚本才能随时调用',
    );
  });

  test('查词 / 拖选高亮：highlightSelection 建 Range 前先过助手', () {
    expectPaintableBeforeRange(
      ReaderSelectionScripts.source(),
      'var ruby = this.rubyForNode(seg.node);',
      'highlightSelection',
    );
  });

  test('收藏高亮：高亮桥建 Range 前先过助手', () {
    expectPaintableBeforeRange(
      HighlightBridge.debugScriptSource,
      'var ruby = _rubyForNode(groups[g].node);',
      'HighlightBridge CSS 分支',
    );
  });

  test('搜索高亮：分页 / 连续与 VN 两处建 Range 前先过助手', () {
    for (final (String name, String shell) in <(String, String)>[
      ('分页', ReaderPaginationScripts.paginatedShellSource()),
      ('连续', ReaderPaginationScripts.continuousShellSource()),
    ]) {
      expectPaintableBeforeRange(
        shell,
        'if (!startNode || !endNode) return null;',
        '$name shell scrollToSearchMatch',
      );
    }
    expectPaintableBeforeRange(
      ReaderVisualNovelScripts.vnShellScript(),
      'if (!startNode || !endNode) return false;',
      'VN 搜索',
    );
  });
}
