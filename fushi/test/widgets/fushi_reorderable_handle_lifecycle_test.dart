import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';

double _effectiveOpacity(Finder content) => find
    .ancestor(of: content, matching: find.byType(Opacity))
    .evaluate()
    .fold<double>(
      1,
      (double opacity, Element element) =>
          opacity * (element.widget as Opacity).opacity,
    );

Widget _row(int index, {required bool handles, VoidCallback? onMenu}) =>
    SizedBox(
      height: 60,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: onMenu,
        child: Row(
          children: <Widget>[
            Expanded(child: Center(child: Text('row-$index'))),
            if (handles)
              FushiReorderableDragHandle(
                child: SizedBox(
                  width: 48,
                  height: 60,
                  child: Center(child: Text('handle-$index')),
                ),
              ),
          ],
        ),
      ),
    );

Future<void> _pumpHandleScrollList(
  WidgetTester tester, {
  required ScrollController controller,
  required void Function(int, int) onReorder,
  required VoidCallback onMenu,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 240,
            child: SingleChildScrollView(
              controller: controller,
              child: FushiReorderableColumn(
                useDragHandles: true,
                itemCount: 12,
                keyForIndex: (int index) => ValueKey<int>(index),
                onReorder: onReorder,
                itemBuilder: (BuildContext context, int index) =>
                    _row(index, handles: true, onMenu: onMenu),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final bool handles in <bool>[false, true]) {
    testWidgets(
      'early drag preserves visible entrance content (handles=$handles)',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: FushiEntranceScope(
                    child: FushiReorderableColumn(
                      useDragHandles: handles,
                      itemCount: 3,
                      keyForIndex: (int index) => ValueKey<int>(index),
                      onReorder: (int from, int to) {},
                      itemBuilder: (BuildContext context, int index) =>
                          FushiStaggeredEntrance(
                            index: index,
                            child: _row(index, handles: handles),
                          ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // 真实进场已可见，600ms scope 窗口还开着。不能 pumpAndSettle 后
        // 再起拖，那会跨过窗口、漏掉新挂载反馈把内容重新淡出的路径。
        await tester.pump(const Duration(milliseconds: 200));
        final double before = _effectiveOpacity(find.text('row-0'));
        expect(before, greaterThan(0.5));
        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(find.text(handles ? 'handle-0' : 'row-0')),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
        final Finder feedback = find.byType(FushiReorderDragProxy);
        expect(feedback, findsOneWidget);
        final Finder feedbackText = find.descendant(
          of: feedback,
          matching: find.text('row-0'),
        );
        expect(feedbackText, findsOneWidget);
        final double lifted = _effectiveOpacity(feedbackText);
        // 先清掉手势再断言，失败也不把活动指针/拖拽状态留给 teardown。
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          lifted,
          greaterThanOrEqualTo(before),
          reason: '抬起已经可见的行不能重新从透明开始播进场',
        );
      },
    );
  }

  testWidgets('cancelled handle drag removes feedback without committing', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<(int, int)> moves = <(int, int)>[];
    int menus = 0;
    await _pumpHandleScrollList(
      tester,
      controller: controller,
      onReorder: (int from, int to) => moves.add((from, to)),
      onMenu: () => menus++,
    );
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('handle-0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.text('handle-1')));
    await tester.pump();
    expect(find.byType(FushiReorderDragProxy), findsOneWidget);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(find.byType(FushiReorderDragProxy), findsNothing);
    expect(moves, isEmpty);
    expect(menus, 0);
    expect(
      tester.getTopLeft(find.text('row-0')).dy,
      lessThan(tester.getTopLeft(find.text('row-1')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('quick vertical swipe on handle scrolls its parent', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<(int, int)> moves = <(int, int)>[];
    int menus = 0;
    await _pumpHandleScrollList(
      tester,
      controller: controller,
      onReorder: (int from, int to) => moves.add((from, to)),
      onMenu: () => menus++,
    );
    await tester.drag(find.text('handle-2'), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(moves, isEmpty);
    expect(menus, 0);
    expect(find.byType(FushiReorderDragProxy), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
