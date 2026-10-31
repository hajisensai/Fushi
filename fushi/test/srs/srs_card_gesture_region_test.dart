// 原生卡面的手势识别区（SrsCardGestureRegion）：与 WebView 卡面页内脚本同一套判据。
//
// - 没绑双击时单击立即回报（不为等第二击推迟）；绑了才等，第二击成双击、不再报单击。
// - 长按只认空白、只认触屏；按在字上（SelectionArea 选词）不算。
// - 滑动只认触屏、只认开着的轴；卡面还能往手指方向滚时是滚动、不接管；被圈出的子树
//   （释义 WebView）上的一概归页内脚本。
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/srs/srs_review_gestures.dart';
import 'package:material_ui/material_ui.dart';

const Key _blank = ValueKey<String>('blank');
const Key _text = ValueKey<String>('text');
const Key _webview = ValueKey<String>('webview');

Future<List<SrsCardGestureEvent>> _pump(
  WidgetTester tester, {
  SrsCardGestureArming arming = SrsCardGestureArming.none,
}) async {
  final List<SrsCardGestureEvent> events = <SrsCardGestureEvent>[];
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SrsCardGestureRegion(
          onGesture: events.add,
          arming: arming,
          tapTookLookup: () => false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const ColoredBox(
                key: _blank,
                color: Color(0xFFFFFFFF),
                child: SizedBox(width: 400, height: 200),
              ),
              const SizedBox(
                width: 400,
                height: 60,
                child: Text('図書館', key: _text),
              ),
              SrsCardGestureRegion.excluded(
                child: const ColoredBox(
                  key: _webview,
                  color: Color(0xFFEEEEEE),
                  child: SizedBox(width: 400, height: 200),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return events;
}

List<SrsCardGestureKind> _kinds(List<SrsCardGestureEvent> events) =>
    <SrsCardGestureKind>[for (final SrsCardGestureEvent e in events) e.kind];

Future<void> _swipe(
  WidgetTester tester,
  Offset from,
  Offset by, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final TestGesture g = await tester.startGesture(from, kind: kind);
  for (int i = 1; i <= 8; i++) {
    await g.moveTo(from + by * (i / 8));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pump();
}

void main() {
  testWidgets('没绑双击：单击空白抬起即回报（带落点），不推迟', (WidgetTester tester) async {
    final List<SrsCardGestureEvent> events = await _pump(tester);
    await tester.tapAt(const Offset(30, 40));
    expect(events, <SrsCardGestureEvent>[
      const SrsCardGestureEvent(
        SrsCardGestureKind.tap,
        position: Offset(30, 40),
      ),
    ]);
  });

  testWidgets('绑了双击：两下成双击且不报单击；单独一下等满时限再报单击', (WidgetTester tester) async {
    final List<SrsCardGestureEvent> events = await _pump(
      tester,
      arming: const SrsCardGestureArming(doubleTap: true),
    );
    await tester.tapAt(const Offset(30, 40));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(const Offset(36, 44));
    await tester.pump(kDoubleTapTimeout * 2);
    expect(_kinds(events), <SrsCardGestureKind>[SrsCardGestureKind.doubleTap]);

    events.clear();
    await tester.tapAt(const Offset(200, 100));
    expect(events, isEmpty, reason: '还在等第二击');
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 10));
    expect(_kinds(events), <SrsCardGestureKind>[SrsCardGestureKind.tap]);

    events.clear();
    // 第二下离得太远：两下各算单击。
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(const Offset(390, 190));
    await tester.pump(kDoubleTapTimeout * 2);
    expect(_kinds(events), <SrsCardGestureKind>[
      SrsCardGestureKind.tap,
      SrsCardGestureKind.tap,
    ]);
  });

  testWidgets('长按空白（触屏）回报一次、松手不再报单击；按在字上 / 鼠标 / 没绑都不算', (
    WidgetTester tester,
  ) async {
    List<SrsCardGestureEvent> events = await _pump(
      tester,
      arming: const SrsCardGestureArming(longPress: true),
    );
    TestGesture g = await tester.startGesture(const Offset(50, 50));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(_kinds(events), <SrsCardGestureKind>[SrsCardGestureKind.longPress]);
    await g.up();
    await tester.pump();
    expect(_kinds(events), <SrsCardGestureKind>[SrsCardGestureKind.longPress]);

    events.clear();
    g = await tester.startGesture(tester.getCenter(find.byKey(_text)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(events, isEmpty, reason: '字上的长按归选词');
    await g.up();

    events.clear();
    g = await tester.startGesture(
      const Offset(50, 50),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(_kinds(events), isNot(contains(SrsCardGestureKind.longPress)));
    await g.up();

    events = await _pump(tester);
    g = await tester.startGesture(const Offset(50, 50));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(events, isEmpty, reason: '没绑长按就不识别');
    await g.up();
  });

  testWidgets('横向滑动（触屏）：途中报拖动、松手带位移；没开横轴 / 鼠标拖都不接管、也不算点按', (
    WidgetTester tester,
  ) async {
    List<SrsCardGestureEvent> events = await _pump(
      tester,
      arming: const SrsCardGestureArming(swipeHorizontal: true),
    );
    await _swipe(tester, const Offset(300, 100), const Offset(-160, 6));
    expect(events.first.kind, SrsCardGestureKind.drag);
    expect(events.last.kind, SrsCardGestureKind.release);
    expect(events.last.delta, const Offset(-160, 6));
    expect(
      srsClassifySwipe(events.last.delta, events.last.velocity),
      SrsReviewGesture.swipeLeft,
    );

    events.clear();
    await _swipe(
      tester,
      const Offset(300, 100),
      const Offset(-160, 0),
      kind: PointerDeviceKind.mouse,
    );
    expect(events, isEmpty, reason: '鼠标拖动是拖选');

    events.clear();
    await _swipe(tester, const Offset(200, 20), const Offset(0, 150));
    expect(events, isEmpty, reason: '竖轴没开');

    events = await _pump(tester);
    await _swipe(tester, const Offset(300, 100), const Offset(-160, 0));
    expect(events, isEmpty, reason: '没绑滑动就不接管拖动');
  });

  testWidgets('被圈出的子树（释义 WebView）上的手势归页内脚本', (WidgetTester tester) async {
    final List<SrsCardGestureEvent> events = await _pump(
      tester,
      arming: const SrsCardGestureArming(
        swipeHorizontal: true,
        longPress: true,
      ),
    );
    final Offset web = tester.getCenter(find.byKey(_webview));
    await tester.tapAt(web);
    await _swipe(tester, web, const Offset(-160, 0));
    final TestGesture g = await tester.startGesture(web);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.up();
    expect(events, isEmpty);
  });

  testWidgets('竖直滑动与卡面滚动：还能往手指方向滚就是滚动，滚到头才算滑动', (WidgetTester tester) async {
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    final List<SrsCardGestureEvent> events = <SrsCardGestureEvent>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 400,
          height: 400,
          child: SrsCardGestureRegion(
            onGesture: events.add,
            arming: const SrsCardGestureArming(swipeVertical: true),
            tapTookLookup: () => false,
            scrollController: scroll,
            child: SingleChildScrollView(
              controller: scroll,
              physics: const ClampingScrollPhysics(),
              child: const ColoredBox(
                color: Color(0xFFFFFFFF),
                child: SizedBox(width: 400, height: 1200),
              ),
            ),
          ),
        ),
      ),
    );
    // 在顶端往上划（内容往下滚）：是滚动。
    await _swipe(tester, const Offset(200, 300), const Offset(0, -200));
    expect(scroll.offset, greaterThan(0));
    expect(_kinds(events), isNot(contains(SrsCardGestureKind.release)));
    expect(_kinds(events), isNot(contains(SrsCardGestureKind.drag)));

    // 回到顶端后往下划：已经滚不动了，是滑动。
    scroll.jumpTo(0);
    await tester.pump();
    events.clear();
    await _swipe(tester, const Offset(200, 50), const Offset(0, 200));
    expect(scroll.offset, 0);
    expect(events.last.kind, SrsCardGestureKind.release);
    expect(
      srsClassifySwipe(events.last.delta, events.last.velocity),
      SrsReviewGesture.swipeDown,
    );

    // 中途：两个方向都还能滚，都是滚动。
    scroll.jumpTo(300);
    await tester.pump();
    events.clear();
    await _swipe(tester, const Offset(200, 50), const Offset(0, 200));
    expect(scroll.offset, lessThan(300));
    expect(_kinds(events), isNot(contains(SrsCardGestureKind.release)));
  });

  testWidgets('滑动途中第二根手指落下：作废（回报 cancel），不触发', (WidgetTester tester) async {
    final List<SrsCardGestureEvent> events = await _pump(
      tester,
      arming: const SrsCardGestureArming(swipeHorizontal: true),
    );
    final TestGesture a = await tester.startGesture(const Offset(300, 100));
    await a.moveBy(const Offset(-60, 0));
    await tester.pump();
    final TestGesture b = await tester.startGesture(
      const Offset(100, 100),
      pointer: 7,
    );
    await a.moveBy(const Offset(-60, 0));
    await a.up();
    await b.up();
    await tester.pump();
    expect(_kinds(events).last, SrsCardGestureKind.cancel);
    expect(_kinds(events), isNot(contains(SrsCardGestureKind.release)));
  });
}
