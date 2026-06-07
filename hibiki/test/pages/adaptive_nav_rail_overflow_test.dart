import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart';

/// 复现「左侧导航栏在矮窗口下底部 overflow」：rail 的 tile 列固定高度、不可滚动，
/// 当窗口高度 < 所有 tile 总高时 Column 溢出（BOTTOM OVERFLOWED BY N PIXELS）。
void main() {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.movie_outlined, label: '视频'),
    AdaptiveNavItem(icon: Icons.search_outlined, label: '查词'),
    AdaptiveNavItem(icon: Icons.link_outlined, label: '文本钩子'),
    AdaptiveNavItem(icon: Icons.tune_outlined, label: '设置'),
  ];

  Widget harness(double height) => MaterialApp(
        home: Scaffold(
          body: Row(
            children: <Widget>[
              SizedBox(
                height: height,
                child: Builder(
                  builder: (BuildContext context) => adaptiveNavRail(
                    context: context,
                    currentIndex: 1,
                    onTap: (_) {},
                    items: items,
                  ),
                ),
              ),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      );

  testWidgets('矮窗口下导航 rail 不溢出', (WidgetTester tester) async {
    await tester.pumpWidget(harness(260));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'rail 在矮窗口下应可滚动而非 RenderFlex overflow');
  });
}
