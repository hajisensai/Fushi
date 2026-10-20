// 随滚动收起的栏 / 页头：版面把滚动位置夹回顶部（列表缩短到一屏放得下、窗口
// 变大）只发 ScrollMetricsNotification、不发 ScrollUpdate。只认 ScrollUpdate 的
// 状态会停在收起态，而列表已经滚不动，用户再也唤不回来（首页右上角排行榜 /
// 统计等按钮整条消失，2026-10-20 用户截图；库页同款 BUG-3133）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';

/// 可缩短的竖向列表；[onNotification] 收到列表冒泡出来的全部通知。
class _ShrinkableList extends StatelessWidget {
  const _ShrinkableList({
    required this.itemCount,
    required this.controller,
    required this.onNotification,
  });

  final ValueNotifier<int> itemCount;
  final ScrollController controller;
  final bool Function(Notification notification) onNotification;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: NotificationListener<Notification>(
          onNotification: onNotification,
          child: ValueListenableBuilder<int>(
            valueListenable: itemCount,
            builder: (BuildContext context, int count, Widget? _) =>
                ListView.builder(
                  controller: controller,
                  itemExtent: 60,
                  itemCount: count,
                  itemBuilder: (BuildContext context, int index) =>
                      Text('Row $index'),
                ),
          ),
        ),
      ),
    );
  }
}

/// 用户拖动把列表往下滚 [distance]（逻辑 px）。
Future<void> _dragUp(WidgetTester tester, double distance) async {
  final TestGesture gesture = await tester.startGesture(
    tester.getCenter(find.byType(ListView)),
  );
  for (double moved = 0; moved < distance; moved += 20) {
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('首页浮动栏：列表缩短被夹回顶部后栏弹回', (WidgetTester tester) async {
    final HomeToolbarScrollState state = HomeToolbarScrollState();
    final ScrollController scroll = ScrollController();
    final ValueNotifier<int> count = ValueNotifier<int>(100);
    addTearDown(state.dispose);
    addTearDown(scroll.dispose);
    addTearDown(count.dispose);
    int updatesAfterShrink = 0;
    bool shrunk = false;
    await tester.pumpWidget(
      _ShrinkableList(
        itemCount: count,
        controller: scroll,
        onNotification: (Notification n) {
          if (shrunk && n is ScrollUpdateNotification) updatesAfterShrink++;
          if (n is ScrollMetricsNotification) return state.handleMetrics(n);
          if (n is ScrollNotification) return state.handle(n);
          return false;
        },
      ),
    );

    await _dragUp(tester, 400);
    expect(scroll.offset, greaterThan(kHomeToolbarExtent));
    expect(state.visible, isFalse);
    expect(state.pastHero, isTrue);

    shrunk = true;
    count.value = 2;
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(
      updatesAfterShrink,
      0,
      reason: '前提：夹回顶部不发 ScrollUpdate，只能靠 metrics 通知恢复',
    );
    expect(state.visible, isTrue);
    expect(state.pastHero, isFalse);
  });

  testWidgets('随滚动收起的页头：列表缩短被夹回顶部后页头弹回', (WidgetTester tester) async {
    final FushiScrollAwayController chrome = FushiScrollAwayController();
    final ScrollController scroll = ScrollController();
    final ValueNotifier<int> count = ValueNotifier<int>(100);
    addTearDown(chrome.dispose);
    addTearDown(scroll.dispose);
    addTearDown(count.dispose);
    await tester.pumpWidget(
      _ShrinkableList(
        itemCount: count,
        controller: scroll,
        onNotification: chrome.handleNotification,
      ),
    );

    await _dragUp(tester, 400);
    expect(chrome.hidden, isTrue);

    count.value = 2;
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(chrome.hidden, isFalse);
  });

  testWidgets('随滚动收起的页头：metrics 通知不在顶部时不改变收起态', (WidgetTester tester) async {
    final FushiScrollAwayController chrome = FushiScrollAwayController();
    final ScrollController scroll = ScrollController();
    final ValueNotifier<int> count = ValueNotifier<int>(100);
    addTearDown(chrome.dispose);
    addTearDown(scroll.dispose);
    addTearDown(count.dispose);
    await tester.pumpWidget(
      _ShrinkableList(
        itemCount: count,
        controller: scroll,
        onNotification: chrome.handleNotification,
      ),
    );

    await _dragUp(tester, 400);
    expect(chrome.hidden, isTrue);

    // 列表变长（加载更多）也发 metrics 通知，但位置没回顶部：保持收起。
    count.value = 200;
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(chrome.hidden, isTrue);
  });
  // 嵌套的竖向小列表（shrinkWrap + 禁止滚动）第一次布局也发 ScrollMetricsNotification，
  // 且它自己的位置恒为 0：不按滚动区深度过滤，用户往下滚时懒加载出它的那一帧就被当成
  // 「主列表回到了顶部」，页头弹回（同库页 BUG-3133 的 _ownerDepth 判据）。
  testWidgets('随滚动收起的页头：懒加载出的嵌套竖向列表不当成主列表回顶', (WidgetTester tester) async {
    final FushiScrollAwayController chrome = FushiScrollAwayController();
    final ScrollController scroll = ScrollController();
    addTearDown(chrome.dispose);
    addTearDown(scroll.dispose);
    int nestedMetrics = 0;
    // 只看终态抓不到：误弹回后余下的拖动又会把页头收起。记下「收起后又弹回」。
    bool wasHidden = false;
    bool flashedBack = false;
    chrome.addListener(() {
      if (chrome.hidden) {
        wasHidden = true;
      } else if (wasHidden) {
        flashedBack = true;
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationListener<Notification>(
            onNotification: (Notification n) {
              if (n is ScrollMetricsNotification && n.depth > 0) {
                nestedMetrics++;
              }
              return chrome.handleNotification(n);
            },
            child: ListView.builder(
              controller: scroll,
              itemExtent: 60,
              itemCount: 100,
              itemBuilder: (BuildContext context, int index) => index == 30
                  ? ListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: const <Widget>[Text('Nested')],
                    )
                  : Text('Row $index'),
            ),
          ),
        ),
      ),
    );

    await _dragUp(tester, 1400);
    expect(scroll.offset, greaterThan(FushiScrollAwayController.revealZone));
    expect(nestedMetrics, greaterThan(0), reason: '前提：嵌套列表确实冒出了 metrics 通知');
    expect(chrome.hidden, isTrue);
    expect(flashedBack, isFalse, reason: '一路往下滚，页头不该中途弹回');
  });
}
