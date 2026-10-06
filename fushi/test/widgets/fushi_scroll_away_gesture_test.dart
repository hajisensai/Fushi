import 'package:flutter/material.dart';
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
}
