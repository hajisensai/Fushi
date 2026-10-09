import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';

/// 库页浮动工具区在真实「外壳页签 + 页面自己的搜索 / 筛选行」叠法下的两条回归：
///
/// - BUG-3133：滚到下面工具区收起后删掉视频，列表缩短到一屏放得下——滚动位置被
///   版面夹回顶部，但夹紧只发 [ScrollMetricsNotification]、不发 ScrollUpdate，工具区
///   停在收起态；内容又滚不动了，用户再也唤不回顶部那一块（只能改缩放 / 重启）。
/// - BUG-3132：内容滚到工具区底下时，顶部遮罩只盖到外壳页签的上半，页面自己的
///   搜索 / 标签行（嵌套工具区）背后整片透出封面，看着很乱。
void main() {
  const Key nestedChromeKey = ValueKey<String>('nested-chrome');

  Widget harness(
    FushiFloatingChromeController controller,
    ValueNotifier<int> count,
  ) {
    return MaterialApp(
      home: Scaffold(
        body: FushiFloatingChromeScope(
          controller: controller,
          child: FushiFloatingChromeOverlay(
            chrome: const SizedBox(height: 56, child: Text('tabs')),
            child: NotificationListener<ScrollNotification>(
              onNotification: controller.handleScrollNotification,
              child: FushiFloatingChromeOverlay(
                chrome: const SizedBox(
                  key: nestedChromeKey,
                  height: 96,
                  child: Text('search + tags'),
                ),
                child: Builder(
                  builder: (BuildContext context) =>
                      ValueListenableBuilder<int>(
                        valueListenable: count,
                        builder: (BuildContext context, int n, Widget? _) =>
                            ListView.builder(
                              padding: EdgeInsets.only(
                                top: FushiFloatingChromeInset.of(context),
                              ),
                              itemCount: n,
                              itemBuilder: (BuildContext context, int i) =>
                                  SizedBox(height: 120, child: Text('item $i')),
                            ),
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('BUG-3133 列表缩短到一屏放得下：收起的工具区自己回来、遮罩撤掉', (
    WidgetTester tester,
  ) async {
    final FushiFloatingChromeController controller =
        FushiFloatingChromeController();
    addTearDown(controller.dispose);
    final ValueNotifier<int> count = ValueNotifier<int>(40);
    addTearDown(count.dispose);
    await tester.pumpWidget(harness(controller, count));

    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(controller.visible, isFalse, reason: '前提：往下滚后工具区收起');
    expect(controller.contentUnderTop, isTrue);

    // 删视频：列表缩到一屏装得下，滚动位置被夹回 0。
    count.value = 2;
    await tester.pumpAndSettle();
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable),
    );
    expect(scrollable.position.pixels, 0, reason: '前提：版面把位置夹回顶部');
    expect(controller.visible, isTrue, reason: '内容已滚不动，工具区必须自己回来，否则顶部那一块永远丢了');
    expect(controller.contentUnderTop, isFalse);
  });

  testWidgets('BUG-3132 内容滚到工具区底下时，顶部遮罩盖住整个工具区（含嵌套的搜索行）', (
    WidgetTester tester,
  ) async {
    final FushiFloatingChromeController controller =
        FushiFloatingChromeController();
    addTearDown(controller.dispose);
    final ValueNotifier<int> count = ValueNotifier<int>(40);
    addTearDown(count.dispose);
    await tester.pumpWidget(harness(controller, count));
    await tester.pumpAndSettle();

    // 往下滚一段再往回拉：工具区弹回，内容停在工具区底下。
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(controller.visible, isTrue);
    expect(controller.contentUnderTop, isTrue);

    final double chromeBottom = tester
        .getBottomLeft(find.byKey(nestedChromeKey))
        .dy;
    final Finder scrims = find.byType(FushiTopFadeScrim);
    expect(scrims, findsNWidgets(2), reason: '外壳一段 + 嵌套工具行一段');
    double reach = 0;
    for (final Element e in scrims.evaluate()) {
      final FushiTopFadeScrim w = e.widget as FushiTopFadeScrim;
      final double top = tester.getTopLeft(find.byWidget(w)).dy;
      reach = reach > top + w.solidHeight ? reach : top + w.solidHeight;
    }
    // 不透明段（肩）连起来至少盖到嵌套工具行的下沿，之后才开始渐隐。
    expect(
      reach,
      greaterThanOrEqualTo(chromeBottom - 0.5),
      reason: '搜索 / 标签行背后不能透出内容',
    );
    // 外壳那一段只盖到外壳工具区：嵌套工具行住在外壳的内容层里，外壳的遮罩若一路
    // 盖下去会把搜索 / 标签行本身也压成半透明。
    final FushiTopFadeScrim outerScrim = tester.widget<FushiTopFadeScrim>(
      scrims.last, // 外壳的遮罩在外壳 Stack 里后画，树序排最后。
    );
    expect(outerScrim.solidHeight, lessThanOrEqualTo(56.5));
    // 10-06 定的风格：不垫整块底色——工具行背后是半透明薄纱，只在最后一行
    // 工具栏下方短距离渐隐。
    for (final Element e in scrims.evaluate()) {
      final FushiTopFadeScrim w = e.widget as FushiTopFadeScrim;
      expect(w.shoulderOpacity, kFushiTopScrimOverlayOpacity);
      expect(w.fadeExtent, lessThanOrEqualTo(kFushiTopFadeExtent));
    }
    expect(
      tester.widget<FushiTopFadeScrim>(scrims.first).fadeExtent,
      kFushiTopFadeExtent,
      reason: '最深一层（嵌套工具行）负责最后那段短渐隐',
    );
    expect(
      find.descendant(
        of: find.byType(FushiFloatingChromeOverlay).last,
        matching: find.byType(FushiTopFadeScrim),
      ),
      findsOneWidget,
      reason: '嵌套工具行那一段画在它自己的工具区之下',
    );
  });

  testWidgets('BUG-3132 工具区收起后遮罩跟着收回顶边，不留整块底色', (WidgetTester tester) async {
    final FushiFloatingChromeController controller =
        FushiFloatingChromeController();
    addTearDown(controller.dispose);
    final ValueNotifier<int> count = ValueNotifier<int>(40);
    addTearDown(count.dispose);
    await tester.pumpWidget(harness(controller, count));
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(controller.visible, isFalse);
    for (final Element e in find.byType(FushiTopFadeScrim).evaluate()) {
      expect((e.widget as FushiTopFadeScrim).solidHeight, lessThan(1));
    }
  });
}
