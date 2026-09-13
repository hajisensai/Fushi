import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';

// 移动端底栏几何守卫。自绘的 Material 底栏曾用固定 SizedBox(height: 80)，叠上
// Android 手势条的 24dp bottom inset 后总高 104dp，标签底边离屏幕底 38dp —— 比
// MD3 标称的 80dp 容器还高，视觉上「浮」在底部而不是贴住底部。
//
// 现在内容区固定 kAdaptiveNavBarContentHeight(64)，inset 只作为系统手势区留白，
// 所以总高 = 64 + inset，内容与手势区之间只剩 kAdaptiveNavBarContentPadding(6)。
// 大字号下高度必须自适应增长（ConstrainedBox 的是 min 而非固定高），否则 tile
// 会 RenderFlex 溢出。
void main() {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: 'Books'),
    AdaptiveNavItem(icon: Icons.search, label: 'Dict'),
    AdaptiveNavItem(icon: Icons.tune, label: 'Settings'),
  ];

  Future<void> pumpBar(
    WidgetTester tester, {
    double bottomInset = 0,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(411.4, 914.3),
            devicePixelRatio: 2.625,
            textScaler: TextScaler.linear(textScale),
            padding: EdgeInsets.only(bottom: bottomInset),
            viewPadding: EdgeInsets.only(bottom: bottomInset),
          ),
          child: FushiFocusRoot(
            child: Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: Builder(
                builder: (BuildContext context) => adaptiveBottomBar(
                  context: context,
                  currentIndex: 0,
                  onTap: (_) {},
                  items: items,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('bottom bar content is 64dp tall without system inset', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester);

    final Rect bar = tester.getRect(find.byKey(fushiMaterialNavKey));
    expect(bar.height, kAdaptiveNavBarContentHeight);
  });

  testWidgets('system inset only adds gesture padding below the content', (
    WidgetTester tester,
  ) async {
    const double inset = 24;
    await pumpBar(tester, bottomInset: inset);

    final Rect bar = tester.getRect(find.byKey(fushiMaterialNavKey));
    // 总高 = 内容 64 + 手势区 24 = 88；旧实现是 80 + 24 = 104。
    expect(bar.height, kAdaptiveNavBarContentHeight + inset);

    // 标签底边只隔着内容内边距 + 手势区，不再多出 14dp 的空白。
    final Rect label = tester.getRect(find.text('Books'));
    expect(
      bar.bottom - label.bottom,
      kAdaptiveNavBarContentPadding + inset,
    );
  });

  testWidgets('bar grows instead of overflowing at large text scale', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, bottomInset: 24, textScale: 2);

    // 文字缩放被 clamp 到 1.3（与 stock NavigationBar 一致），高度按内容自适应
    // 增长；任何 RenderFlex 溢出都会让 pumpAndSettle 抛异常。
    final Rect bar = tester.getRect(find.byKey(fushiMaterialNavKey));
    expect(bar.height, greaterThanOrEqualTo(kAdaptiveNavBarContentHeight + 24));
    expect(bar.height, lessThan(kAdaptiveNavBarContentHeight + 24 + 20));
    expect(tester.takeException(), isNull);
  });
}
