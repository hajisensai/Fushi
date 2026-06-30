import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// BUG-461：连续(滚动)模式收藏句跳转「句尾被切（五五开）」的根因守卫。
///
/// 根因（连续模式，非分页——用户明确「这是滚动模式」）：旧的连续 `scrollToCharOffset`
/// 只把收藏句**句首**字符对齐到内容顶，完全不看句尾。长句被滚到句首贴顶后，句尾溢出
/// 可见区底沿（连续模式可见区 = `clip-path inset` 的 `[chromeTopInset,
/// viewportSize − chromeBottomInset]`，底部被阅读底栏盖住）→「句尾被切」。是否切随句长 /
/// 字号 / 落点变化 → 用户感知的「五五开」。
///
/// 修复把跳转目标当作**字符区间** `[start, end]`：先句首贴顶，若句尾溢出可见区底沿且整句
/// 放得下，多滚把句尾拉进可见区底沿（整句完整可见）；放不下则维持句首贴顶（尽力而为）。
///
/// 这是连续 JS `scrollToCharOffset` 句尾区间对齐的纯 Dart 影子（headless WebView 不可用，
/// 按项目测试范式：纯函数单测锁算法，几何效果留真机）。
void main() {
  // 典型连续布局：句首字符顶边正好落在内容顶（startTop==contentTopPad），currentScroll 任意。
  const double contentTopPad = 100; // marginTop vh + chromeTopInset
  const double bandTop = 56; // chromeTopInset
  const double bandBottom = 600; // viewportSize - chromeBottomInset
  // 可见区高 = bandBottom - bandTop = 544。

  double jump({
    required double sentenceExtent,
    double startTopInViewport = contentTopPad,
    double currentScroll = 4000,
  }) {
    return ReaderPaginationScripts.continuousFavoriteJumpScrollForTesting(
      startTopInViewport: startTopInViewport,
      sentenceExtent: sentenceExtent,
      currentScroll: currentScroll,
      contentTopPad: contentTopPad,
      bandTop: bandTop,
      bandBottom: bandBottom,
    );
  }

  group('continuousFavoriteJumpScroll', () {
    test('短句完整落在可见区内：句首贴顶，不额外下滚（与旧行为一致）', () {
      // 句首贴顶后句尾底沿 = contentTopPad + 200 = 300 < bandBottom(600) → 不溢出。
      final double target = jump(sentenceExtent: 200);
      // startAligned = currentScroll + (startTop - contentTopPad) = 4000 + 0 = 4000。
      expect(target, 4000);
    });

    test('长句句尾溢出可见区底沿（旧行为会切尾）：多下滚把句尾拉到可见区底沿', () {
      // 句首贴顶后句尾底沿 = contentTopPad + 520 = 620 > bandBottom(600) → 溢出 20px。
      // 整句高 520 <= 可见区高 544 → 放得下 → 多滚 20px。
      const double oldStartAligned = 4000.0;
      final double target = jump(sentenceExtent: 520);
      expect(target, oldStartAligned + 20);
      // 验证整句此时完整可见：句尾在视口的位置 = (contentTopPad + extent) - overflow = bandBottom。
      expect(contentTopPad + 520 - (target - oldStartAligned), bandBottom);
    });

    test('句子比可见区还高（放不下）：维持句首贴顶（尽力而为，本就无落点能整句显示）', () {
      // 整句高 700 > 可见区高 544 → 不能整句显示 → 维持句首贴顶（不下滚把句首推出顶）。
      final double target = jump(sentenceExtent: 700);
      expect(target, 4000);
    });

    test('无句长（老收藏 / 制卡行，extent<=0）：维持句首贴顶（旧行为，向后兼容）', () {
      expect(jump(sentenceExtent: 0), 4000);
      expect(jump(sentenceExtent: -1), 4000);
    });

    test('句尾正好贴可见区底沿（边界，不溢出）：不额外下滚', () {
      // 句尾底沿 = contentTopPad + 500 = 600 == bandBottom → overflow 0。
      expect(jump(sentenceExtent: 500), 4000);
    });

    test('句尾恰好溢出一行：按一行高度下滚（覆盖用户「刚好句子在页面外一行」）', () {
      const double lineH = 34;
      // 整句 = 可见区高 + 不到一行：extent = 544 - 10 = 534，句尾底沿 = 100+534 = 634 溢出 34。
      // 但 534 <= 544 放得下 → 多滚 34。
      final double target = jump(sentenceExtent: 544 - 10);
      expect(target, 4000 + (contentTopPad + (544 - 10) - bandBottom));
      // 溢出量 = 100 + 534 - 600 = 34 == 一行高。
      expect(target - 4000, lineH);
    });

    test('结果非负（句首在章首附近时不产生负 scrollTop）', () {
      // currentScroll 很小 + 句首在视口上方（startTop < contentTopPad）→ startAligned 可能负。
      final double target = jump(
        sentenceExtent: 200,
        startTopInViewport: 0,
        currentScroll: 10,
      );
      // startAligned = 10 + (0 - 100) = -90 → clamp 到 0。
      expect(target, 0);
    });

    test('tail overflow helper：溢出/不溢出', () {
      expect(
        ReaderPaginationScripts.continuousSentenceTailOverflow(620, 600),
        20,
      );
      expect(
        ReaderPaginationScripts.continuousSentenceTailOverflow(580, 600),
        0,
      );
      expect(
        ReaderPaginationScripts.continuousSentenceTailOverflow(600, 600),
        0,
      );
    });
  });
}
