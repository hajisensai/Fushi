import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';

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
    expect(
      tester.takeException(),
      isNull,
      reason: 'rail 在矮窗口下应可滚动而非 RenderFlex overflow',
    );
  });

  // 反馈 #ChIDEam2hf：桌面上只溢出一点点也会立起一整条常驻滚动条，rail 不画滚动条。
  // 必须跑在桌面平台上：Material 的 ScrollBehavior 只在 Windows / macOS / Linux
  // 给纵向滚动视图自动包 Scrollbar，默认的 android 测试平台上本来就不画，断言恒真。
  testWidgets('溢出的导航 rail 不画滚动条', (WidgetTester tester) async {
    // 对照：同一平台下一个普通的可滚动视图确实会被自动包上 Scrollbar——证明下面的
    // findsNothing 是修复的结果，不是平台本来就不画。
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          height: 100,
          child: SingleChildScrollView(child: SizedBox(height: 1000)),
        ),
      ),
    );
    expect(find.byType(Scrollbar), findsOneWidget);

    await tester.pumpWidget(harness(260));
    await tester.pump();
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(
      find.descendant(of: find.byType(Row), matching: find.byType(Scrollbar)),
      findsNothing,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
