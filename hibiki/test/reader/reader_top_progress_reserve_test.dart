import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_chrome_floating.dart';

/// BUG-843：翻页挤压模式下，顶部阅读进度的毛玻璃 pill 压住正文首行（全端复现、
/// 未开悬浮进度）。
///
/// 根因：BUG-547 / TODO-1136 给 pill 加了 `EdgeInsets.symmetric(vertical: 3)` 毛玻璃
/// 内边距（上下共 6px），但顶部进度的预留高 `_infoStripHeight` 仍是裸
/// `_infoFontSize * 1.5`（18px），没把 pill 后加的内边距算进去。pill 实高 = 文字行盒
/// （真机字体约 14~16px）+ 6px 内边距 ≈ 20~22px > 18px 预留，超出的部分盖住正文首行。
/// 修复：预留高改为共享真相源 [kTopProgressStripHeight] = 行盒估计（font×1.5）+ 双边
/// pill 内边距（2 × [kTopProgressPillVerticalPadding]）。
///
/// headless 测试字体（Ahem）的行盒恰等于字号、不溢出 em 盒，复现不出真机字体的高度
/// 溢出，故用确定性算术不变量做主守卫；另配一个 widget 测量确认 pill 实测不超预留。
void main() {
  group('BUG-843 顶部进度预留必须容纳毛玻璃 pill', () {
    test('预留高 ≥ 文字行盒估计 + pill 双边内边距（回收被漏计的毛玻璃 padding）', () {
      // 铁律：pill 视觉高（行盒 + 双边内边距）绝不超预留高。旧值 18px 仅等于裸
      // `font×1.5`、漏掉 6px 内边距，此断言下必然失败；修复后 24px 满足。
      const double minReserve =
          kTopProgressFontSize * 1.5 + 2 * kTopProgressPillVerticalPadding;
      expect(
        kTopProgressStripHeight,
        greaterThanOrEqualTo(minReserve),
        reason: '顶部进度预留高必须同时覆盖文字行盒和毛玻璃 pill 的上下内边距；'
            '只要 pill 加了内边距而预留没跟着涨（BUG-843），此断言即失败',
      );
    });

    test('单一真相源：预留高确由字号与 pill 内边距推导，pill 与预留不再各算各的', () {
      // 若有人日后改 pill 内边距/字号而不同步预留，这三者的关系被打破即失败。
      expect(
        kTopProgressStripHeight,
        kTopProgressFontSize * 1.5 + 2 * kTopProgressPillVerticalPadding,
        reason: 'kTopProgressStripHeight 必须由 kTopProgressFontSize 与 '
            'kTopProgressPillVerticalPadding 推导，杜绝两个不同源常量漂移',
      );
    });

    testWidgets('实测 pill（毛玻璃内边距 + 进度文字）高度不超预留', (WidgetTester tester) async {
      const Key pillKey = Key('bug843_pill_probe');
      // 复刻 `_buildTopProgressBar` 里决定高度的子树：Container(上下内边距) > Text(字号)。
      // 毛玻璃的 ClipRRect/BackdropFilter 不改高度，测量时省略。
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: Container(
              key: pillKey,
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: kTopProgressPillVerticalPadding,
              ),
              child: const Text(
                '123456 / 999999  12.34%',
                style: TextStyle(fontSize: kTopProgressFontSize),
              ),
            ),
          ),
        ),
      );

      final double pillHeight = tester.getSize(find.byKey(pillKey)).height;
      expect(
        pillHeight,
        lessThanOrEqualTo(kTopProgressStripHeight),
        reason: 'pill 实测高度（$pillHeight）不得超过顶部进度预留高'
            '（$kTopProgressStripHeight），否则挤压模式下会压住正文首行',
      );
    });
  });

  test('kTopProgressStripHeight 是有限正值（防常量退化）', () {
    expect(kTopProgressStripHeight.isFinite, isTrue);
    expect(kTopProgressStripHeight, greaterThan(0));
    // 显式钉住期望数值，防止无意改动悄悄回落：12×1.5 + 2×3 = 24。
    expect(kTopProgressStripHeight, 24.0);
  });

  group('BUG-887 顶部进度毛玻璃只在悬浮态出现', () {
    test('挤压态（未开悬浮进度）不套毛玻璃', () {
      // 用户报告：没开悬浮顶部进度，pill 背后却有一层模糊贴住正文首行。挤压态 pill
      // 落在预留区（正文空白顶边距 = 主题背景）上，背后没有正文，毛玻璃无意义。
      expect(
        topProgressUsesFrostedGlass(floating: false),
        isFalse,
        reason: '挤压模式顶部进度必须是纯文字、无 BackdropFilter 模糊；'
            '一旦有人把毛玻璃改回无条件绘制（BUG-887 回归），此断言即失败',
      );
    });

    test('悬浮态才套毛玻璃（浮在正文之上需提升可读性）', () {
      expect(topProgressUsesFrostedGlass(floating: true), isTrue);
    });
  });
}
