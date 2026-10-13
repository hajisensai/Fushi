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

  testWidgets('BUG-3283 工具区收起后没有遮罩段悬在内容中间（嵌套层不得从外层固定 inset 起画）', (
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
    expect(controller.visible, isFalse);
    expect(controller.contentUnderTop, isTrue);

    // 收起 = 工具区整个滑出画面：此时任何遮罩的顶边都必须贴着视口顶边。嵌套层
    // 曾按外层「恒定 inset」（外壳页签高度）定位，收起后在页签高度处凭空画出一条
    // 顶端 0.72 不透明的硬边（实机：书架继续阅读卡 / 漫画发现横幅中间一条亮带）。
    final Finder scrims = find.byType(FushiTopFadeScrim);
    for (final Element e in scrims.evaluate()) {
      final Finder f = find.byWidget(e.widget);
      expect(tester.getTopLeft(f).dy, lessThan(1), reason: '收起后遮罩不得悬在内容中间');
    }
  });

  testWidgets('BUG-3283 嵌套遮罩顶边始终接在外层可见下沿（展开 / 收起一路连续）', (
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
    // 弹回：动画中途逐帧核对，嵌套遮罩（若在画）顶边 == 外壳页签此刻的可见下沿。
    controller.show();
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final Finder nestedScrim = find.descendant(
        of: find.byType(FushiFloatingChromeOverlay).last,
        matching: find.byType(FushiTopFadeScrim),
      );
      if (nestedScrim.evaluate().isEmpty) continue;
      final double top = tester.getTopLeft(nestedScrim).dy;
      final double outerBottom = tester.getBottomLeft(find.text('tabs')).dy;
      expect(
        top,
        lessThanOrEqualTo(outerBottom + 12),
        reason: '嵌套遮罩顶边不得落到外层页签可见下沿之下（第 $i 帧）',
      );
    }
    await tester.pumpAndSettle();
  });
}
