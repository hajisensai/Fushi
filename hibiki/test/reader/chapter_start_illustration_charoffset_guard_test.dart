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

  // ── TODO-1229 第 6 次复诉（残留第二跳）：重锚保位（不越过前导 / 不弹回前导）─────────
  //
  // 第 5 次只补了 restoreToCharOffset 一个调用者，但两模式的重锚
  // （setChromeInsets / commitUiScaleReanchor / commitStyleReanchor）都以
  // getFirstVisibleCharOffset()==0 裸调 scrollToCharOffset（restoreToCharOffset 的 <=0 守卫
  // 拦不到它们）→ 初始落插图页后二次跳到首文本。charOffset<=0（fvco 归 0）二义：「用户在章顶
  // 前导插图」与「用户在首文本页（char0 正在视口首边）」都报 0，唯有重锚前采到的位置 hint 判开。
  //
  //   · 分页版（charOffset, hintScroll）：旧 ±1 page-stable hint 只在「前导恰占 1 页」时兜住；
  //     前导跨 ≥2 页时 charPage 与 origPage 差 ≥2、±1 失效 → 越过整段前导跳首文本。根治：<=0 时
  //     保住用户当前页（有 hint 走 origPage=round(hint/pageSize)，无 hint 落 contentFirstPageScroll
  //     =章首含前导），绝不按字符页跳。
  //   · 连续版（charOffset, endCharOffset, hintScroll）：裸 scrollToChapterStart 会把「停在首文本
  //     页」的用户弹回章顶前导。根治：<=0 时有正 hint（用户已滚离章顶）→ _writeContinuousScroll
  //     保住滚动位；hint 缺席/<=0（章顶 / Dart 直调求章首）→ scrollToChapterStart 滚到顶。
  //
  // headless 复现/验证：tool/reader_pitch_headless/chapter_start_reanchor_probe.mjs（含单页 / 多页
  // 前导两几何、三条重锚路径、firstTextPage 保位守卫；CI 跑不到真 WebView）。

  test(
      '分页 scrollToCharOffset(<=0) 保住当前页（hint→origPage / 无 hint→contentFirstPageScroll），不按字符页跳',
      () {
    expect(
      n.contains('scrollToCharOffset: function(charOffset, hintScroll) {'),
      isTrue,
      reason: '分页 scrollToCharOffset 签名须为 (charOffset, hintScroll)',
    );
    // <=0 保住当前页：有 hint 走 origPage 网格量化，无 hint 落章首含前导，随即 return（不触达走查）。
    expect(
      n.contains('Math.round(hintScroll / ctx0.pageSize) * ctx0.pageSize'),
      isTrue,
      reason: '分页 <=0 有 hint 必须量化到当前页 origPage（保住用户所在前导页 / 首文本页）',
    );
    expect(
      n.contains(
          'this.contentFirstPageScroll(ctx0)); } return; } var walker = this.createWalker();'),
      isTrue,
      reason:
          '分页 <=0 无 hint 落 contentFirstPageScroll（章首含前导），且 return 在 walker 之前——'
          '绝不让 <=0 掉进走查按字符页跳（越过前导）',
    );
  });

  test(
      '连续 scrollToCharOffset(<=0) 有正 hint 保住滚动位、否则 scrollToChapterStart（signature 带 hintScroll）',
      () {
    // 连续版签名升级为 (charOffset, endCharOffset, hintScroll)：hintScroll 仅在 <=0 章首区消歧用。
    expect(
      n.contains(
          'scrollToCharOffset: function(charOffset, endCharOffset, hintScroll) {'),
      isTrue,
      reason: '连续 scrollToCharOffset 签名须带第 3 参 hintScroll（<=0 章首区保位 hint）',
    );
    expect(
      n.contains(
          'this._writeContinuousScroll(hintScroll); } else { this.scrollToChapterStart(); } return; }'),
      isTrue,
      reason: '连续 <=0：有正 hint 保住滚动位（_writeContinuousScroll，不弹回章顶前导），'
          '否则 scrollToChapterStart 滚到顶——两分支后 return，绝不掉进走查跳首文本',
    );
    // TODO-1308 问题②（BUG-696 根因③）：连续滚动位横排是 scrollTop（>=0），竖排是
    // window.scrollX（vertical-rl 滚离章顶后为负——scrollToChapterEnd 用 -1e9）。旧判据
    // `hintScroll > 0` 在竖排永假 → 保位分支在竖排是死代码，任何重锚把 fvco 采成 0 就
    // 把用户钉回章首。判据必须轴向归一：非零即已滚离章顶（两轴章顶都是 0）。
    expect(
      n.contains("typeof hintScroll === 'number' && Math.abs(hintScroll) > 0"),
      isTrue,
      reason: '连续 <=0 的保位判据必须轴向归一（Math.abs——竖排 hint 为负 scrollX）',
    );
    expect(
      n.contains("typeof hintScroll === 'number' && hintScroll > 0)"),
      isFalse,
      reason: '不得回退成 `hintScroll > 0` 裸判据——竖排（负 scrollX）下保位分支永假，'
          '重锚会把竖排用户钉回章首（BUG-696 根因③）',
    );
  });

  test('两模式重锚调用点都把「重锚前采到的位置」透传给 scrollToCharOffset（否则 <=0 无 hint 弹章顶）', () {
    // 分页 setChromeInsets 传 scrollBefore（page-stable hint）。
    expect(js.contains('self.scrollToCharOffset(charOffset, scrollBefore);'),
        isTrue,
        reason: '分页 setChromeInsets 必须把 scrollBefore 作 hint 传入');
    // 连续三条重锚透传 raw scroll（第 3 参 hintScroll）。
    expect(
      js.contains(
          'self.scrollToCharOffset(charOffset, undefined, scrollBefore);'),
      isTrue,
      reason: '连续 setChromeInsets 必须把 scrollBefore 作第 3 参 hint 传入',
    );
    expect(
      js.contains(
          'this.scrollToCharOffset(off, undefined, this._uiScaleReanchorScroll);'),
      isTrue,
      reason: '连续 commitUiScaleReanchor 必须透传 begin 采到的滚动位',
    );
    expect(
      js.contains('this.scrollToCharOffset(off, undefined, hint);'),
      isTrue,
      reason:
          '连续 commitStyleReanchor 必须把 raw scroll 作第 3 参 hint 透传（不占用 endCharOffset）',
    );
  });

  test(
      '回归护栏：连续 scrollToCharOffset 不得退回裸 <=0→scrollToChapterStart（丢 hint 保位则弹回前导）',
      () {
    // 若把连续 <=0 退回成不看 hint 的裸 scrollToChapterStart（第 6 次复诉初修的形态），停在首文本
    // 页的用户会被重锚弹回章顶前导（headless continuous firstTextPage 守卫红）。
    expect(
      n.contains(
          'scrollToCharOffset: function(charOffset, endCharOffset, hintScroll) { if (charOffset <= 0) { this.scrollToChapterStart(); return; }'),
      isFalse,
      reason: '连续 <=0 必须先看 hint 保位，不得裸滚到章顶（否则首文本页用户被弹回前导）',
    );
  });
}
