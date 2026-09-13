import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// BUG-2205：分页 `scrollToCharOffset` 的 ±1 page-stable hint 在锚字被缩字号 / 减边距 /
/// 减行高推到前一页时仍保原页 → 新页首字越过锚字 → 用户丢一页正文，且随后的进度刷新把
/// 「锚字 → 新页首」当新读到计入统计（分页 progress 节点粒度 + 水位只升不降 = 单向棘轮）。
///
/// 修复：`charPage < origPage` 时先落原页实测 `getFirstVisibleCharOffset()`，> 锚字即锚已丢，
/// 改落锚字所在页。真实渲染行为由 headless 探针 `tool/reader_pitch_headless/
/// font_shrink_reanchor_probe.mjs` 断言（修前 22→19px 一步 drift 315 字，修后全程页首字
/// ≤ 锚字）；CI 跑不到真 WebView，这里只锁源码形状：hint 分支必须带「页首字不越锚」复核。
void main() {
  test('分页 scrollToCharOffset 的 hint 分支：保原页前必须复核页首字不越过锚字', () {
    final String shell = ReaderPaginationScripts.paginatedShellSource();
    final int fnStart = shell.indexOf(
      'scrollToCharOffset: function(charOffset, hintScroll)',
    );
    expect(fnStart, greaterThan(0), reason: '分页 shell 缺 scrollToCharOffset');
    final int fnEnd = shell.indexOf('setChromeInsets: function', fnStart);
    final String fn = shell.substring(fnStart, fnEnd);

    expect(
      fn,
      contains('if (charPage < origPage) {'),
      reason: '锚字落到前一页（缩字号 / 减边距）是唯一会让原页页首字越过锚字的方向，必须单独复核',
    );
    expect(
      fn,
      contains('var firstOnOrig = this.getFirstVisibleCharOffset();'),
      reason: '复核判据必须是落页后实测页首字，不能用像素容差（横排末行 collapsed range 的 x 不可靠）',
    );
    expect(
      fn,
      contains(
        'if (firstOnOrig > charOffset) aligned = charPage * context.pageSize;',
      ),
      reason: '原页页首字 > 锚字 = 锚已丢 → 改落锚字所在页',
    );
    // 旧形态（三目一把梭 ±1 保原页）不得回潮。
    expect(
      fn,
      isNot(contains('aligned = (Math.abs(charPage - origPage) <= 1)')),
      reason: '旧 ±1 无条件保原页的形态不得回潮（BUG-2205）',
    );
  });
}
