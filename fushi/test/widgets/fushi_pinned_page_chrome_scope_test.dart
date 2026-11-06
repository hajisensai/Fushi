// FushiPinnedPageChromeScope：作用域里的滚动区不驱动页头收起；作用域外照常收起。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
import 'package:material_ui/material_ui.dart';

Widget _harness(FushiScrollAwayController chrome) => MaterialApp(
  home: Scaffold(
    body: NotificationListener<Notification>(
      onNotification: chrome.handleNotification,
      child: Row(
        children: <Widget>[
          Expanded(
            child: FushiPinnedPageChromeScope(
              child: ListView.builder(
                key: const ValueKey<String>('pinned'),
                itemExtent: 60,
                itemCount: 100,
                itemBuilder: (BuildContext c, int i) => Text('P$i'),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              key: const ValueKey<String>('free'),
              itemExtent: 60,
              itemCount: 100,
              itemBuilder: (BuildContext c, int i) => Text('F$i'),
            ),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('作用域里拖动长列表往下滚 >200px：页头不收起；作用域外的列表照常收起', (
    WidgetTester tester,
  ) async {
    final FushiScrollAwayController chrome = FushiScrollAwayController();
    addTearDown(chrome.dispose);
    await tester.pumpWidget(_harness(chrome));

    final TestGesture pinned = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('pinned'))),
    );
    await pinned.moveBy(const Offset(0, -60));
    await tester.pump();
    await pinned.moveBy(const Offset(0, -150));
    await tester.pump();
    await pinned.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(chrome.hidden, isFalse, reason: '钉住页头的滚动区不参与');
    await pinned.up();
    await tester.pumpAndSettle();
    expect(chrome.hidden, isFalse);

    final TestGesture free = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('free'))),
    );
    await free.moveBy(const Offset(0, -60));
    await tester.pump();
    await free.moveBy(const Offset(0, -150));
    await tester.pump();
    await free.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(chrome.hidden, isTrue, reason: '对照组：作用域外滚下去照常收起');
    await free.up();
    await tester.pumpAndSettle();
  });

  testWidgets('作用域里的滚动把已收起的页头叫出来（hidden 置 false）', (WidgetTester tester) async {
    final FushiScrollAwayController chrome = FushiScrollAwayController();
    addTearDown(chrome.dispose);
    await tester.pumpWidget(_harness(chrome));
    chrome.hidden = true;
    final TestGesture pinned = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('pinned'))),
    );
    await pinned.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(chrome.hidden, isFalse);
    await pinned.up();
    await tester.pumpAndSettle();
  });
}
