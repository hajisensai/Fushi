import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';

Widget _scrollAwayHarness(
  FushiScrollAwayController chrome,
  ScrollController scroll,
) => MaterialApp(
  home: Scaffold(
    body: NotificationListener<ScrollNotification>(
      onNotification: chrome.handleNotification,
      child: ListView.builder(
        controller: scroll,
        itemExtent: 60,
        itemCount: 100,
        itemBuilder: (BuildContext context, int index) => Text('Row $index'),
      ),
    ),
  ),
);

void main() {
  testWidgets('one continuous drag from the top hides after the reveal zone', (
    WidgetTester tester,
  ) async {
    final FushiScrollAwayController chrome = FushiScrollAwayController();
    final ScrollController scroll = ScrollController();
    addTearDown(chrome.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_scrollAwayHarness(chrome, scroll));

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(scroll.offset, lessThan(FushiScrollAwayController.revealZone));
    expect(chrome.hidden, isFalse);

    // Keep the same pointer down: there is no second direction notification.
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    expect(scroll.offset, greaterThan(FushiScrollAwayController.revealZone));
    expect(chrome.hidden, isTrue);

    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(chrome.hidden, isFalse, reason: 'reversing reveals the header');
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('programmatic scrolling does not hide the header', (
    WidgetTester tester,
  ) async {
    final FushiScrollAwayController chrome = FushiScrollAwayController();
    final ScrollController scroll = ScrollController();
    addTearDown(chrome.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_scrollAwayHarness(chrome, scroll));

    scroll.jumpTo(200);
    await tester.pump();
    expect(chrome.hidden, isFalse);

    final Future<void> animation = scroll.animateTo(
      500,
      duration: const Duration(milliseconds: 200),
      curve: Curves.linear,
    );
    await tester.pumpAndSettle();
    await animation;
    expect(scroll.offset, 500);
    expect(chrome.hidden, isFalse);
  });

  testWidgets('拖动中的几 px 来回抖动不会让页头来回跳（滞回）', (WidgetTester tester) async {
    final FushiScrollAwayController chrome = FushiScrollAwayController();
    final ScrollController scroll = ScrollController();
    addTearDown(chrome.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_scrollAwayHarness(chrome, scroll));

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump();
    expect(chrome.hidden, isTrue);

    // 手指抖回 10px 再继续往下看：旧实现方向一变就叫出页头、再一变又收起。
    await gesture.moveBy(const Offset(0, 10));
    await tester.pump();
    expect(chrome.hidden, isTrue, reason: '回程不足滞回距离，页头保持收起');
    await gesture.moveBy(const Offset(0, -10));
    await tester.pump();
    expect(chrome.hidden, isTrue);

    // 真正往回滚过滞回距离才叫出。
    await gesture.moveBy(
      const Offset(0, FushiScrollAwayController.toggleDistance + 6),
    );
    await tester.pump();
    expect(chrome.hidden, isFalse);
    // 再抖 10px 往下：仍不收起。
    await gesture.moveBy(const Offset(0, -10));
    await tester.pump();
    expect(chrome.hidden, isFalse, reason: '同理，收起也要攒够滞回距离');
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
