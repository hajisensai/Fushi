import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-594 / TODO-1229（第 5 次复诉）源码/生成产物守卫：章节翻页初始正确后
/// 异步跳过章首插图。
///
/// 根因：`scrollToCharOffset` 只走文本节点（createWalker=SHOW_TEXT）。以插图页开篇
/// 的章节里首个文本字符位于插图之后的下一页，故 `scrollToCharOffset(0)` 落到「首个
/// 文本页」跳过插图。前进翻到下一章初始 `restoreProgress(0)` 落插图页（正确），随后
/// 一个 charOffset 重锚（如 `_syncPageSize` 宽变重导以 `getFirstVisibleCharOffset()==0`
/// 重锚）走 `restoreToCharOffset(0)` → `scrollToCharOffset(0)` → 跳过插图（过一下跳错）。
///
/// 修复：`restoreToCharOffset` 把 `charOffset<=0` 归一为章节绝对起点——分页走
/// `scrollToProgressPaged(context, 0)`（=minScroll，firstContentEdge 已含前导 block 图），
/// 连续走 `scrollToChapterStart()`（滚到顶含前导图），与 `restoreProgress(0)` 章首语义
/// 一致；charOffset>0 精确锚不变。谁把判据回退成 `charOffset < 0`（漏掉 0）本测试红。
///
/// 真实渲染层复现/验证：`tool/reader_pitch_headless/matrix_probe.mjs`（headless Chrome
/// 注入真 shell，image fwd renavChar 修复前跳 1 页、修复后归零）；CI 跑不到真 WebView。
void main() {
  final String js = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();

  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ');
  final String n = norm(js);

  test('分页 restoreToCharOffset 把 charOffset<=0 当章首走 scrollToProgressPaged(0)',
      () {
    // 分页恢复入口：<=0 或越界 → scrollToProgressPaged(context, 0)（含前导插图的 minScroll）。
    expect(
      n.contains(
          'if (charOffset <= 0 || !this.charOffsetInRange(charOffset)) { this.scrollToProgressPaged(context, 0); } else { this.scrollToCharOffset(charOffset); }'),
      isTrue,
      reason:
          '分页 restoreToCharOffset 必须以 charOffset<=0 判据落章首（minScroll，不越章首插图），'
          '不得回退成 charOffset<0（漏掉 0 → scrollToCharOffset(0) 跳过插图）',
    );
  });

  test('连续 restoreToCharOffset 把 charOffset<=0 当章首走 scrollToChapterStart()',
      () {
    expect(
      n.contains('if (charOffset <= 0) { this.scrollToChapterStart(); }'),
      isTrue,
      reason: '连续 restoreToCharOffset 必须以 charOffset<=0 判据落章首（滚到顶含前导图）',
    );
  });

  test('回归护栏：不得存在把 charOffset<0 作为唯一章首判据的 restoreToCharOffset', () {
    // 修复前的两处 `charOffset < 0` 章首判据必须已升级到 `<= 0`。
    expect(
      n.contains('if (charOffset < 0) { this.scrollToChapterStart(); }'),
      isFalse,
      reason: '连续 restoreToCharOffset 的旧 `charOffset < 0` 判据会漏掉 0 → 跳过章首插图',
    );
    expect(
      n.contains(
          'if (charOffset < 0 || !this.charOffsetInRange(charOffset)) { this.scrollToProgressPaged(context, 0); }'),
      isFalse,
      reason: '分页 restoreToCharOffset 的旧 `charOffset < 0` 判据会漏掉 0 → 跳过章首插图',
    );
  });

  test('charOffset>0 精确锚路径保留（scrollToCharOffset 仍被 restoreToCharOffset 调用）',
      () {
    // 修复只归一 <=0；正段落走精确 scrollToCharOffset 不变。
    expect(js.contains('this.scrollToCharOffset(charOffset)'), isTrue,
        reason: 'charOffset>0 必须仍走精确 scrollToCharOffset');
  });
}
