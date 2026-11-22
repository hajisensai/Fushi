import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tags/tag_chip_draggable.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;

/// BUG-4899 / BUG-5066 / BUG-5174：库页标签条（横向、鼠标可拖滚的
/// `HorizontalDragScrollable` 列表）里 chip 的拖动重排一律长按起拖——鼠标与
/// 触屏都是「按下就拖 = 横滚、长按后拖 = 重排、不动松开 = 单击」。鼠标长按容忍
/// 手抖（门槛 kTouchSlop，标签条横滚用同一门槛），不需要 chip 左侧的拖动柄。
void main() {
  const List<String> tags = <String>['a', 'b', 'c', 'd'];

  Widget harness({
    required bool adaptive,
    required ScrollController controller,
    required List<String> accepted,
    required List<String> tapped,
  }) {
    Widget label(String name) => GestureDetector(
      key: ValueKey<String>('label-$name'),
      onTap: () => tapped.add(name),
      child: SizedBox(width: 80, height: 36, child: Center(child: Text(name))),
    );
    Widget chip(String name) {
      final Widget target = DragTarget<String>(
        onWillAcceptWithDetails: (DragTargetDetails<String> d) =>
            d.data != name,
        onAcceptWithDetails: (DragTargetDetails<String> d) =>
            accepted.add('${d.data}->$name'),
        builder:
            (
              BuildContext context,
              List<String?> candidate,
              List<dynamic> rejected,
            ) => label(name),
      );
      if (adaptive) {
        return FushiTagChipDraggable<String>(
          data: name,
          feedback: Text(name),
          child: target,
        );
      }
      return LongPressDraggable<String>(
        data: name,
        feedback: Text(name),
        child: target,
      );
    }

    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 260,
            height: 48,
            child: HorizontalDragScrollable(
              mouseDragController: adaptive ? controller : null,
              child: ListView(
                controller: controller,
                scrollDirection: Axis.horizontal,
                children: <Widget>[for (final String name in tags) chip(name)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Finder labelOf(String name) => find.byKey(ValueKey<String>('label-$name'));

  testWidgets('根因复现：只有长按拖动时，鼠标手抖 2 px 就输给横滚，标签拖不动', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<String> accepted = <String>[];
    await tester.pumpWidget(
      harness(
        adaptive: false,
        controller: controller,
        accepted: accepted,
        tapped: <String>[],
      ),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(labelOf('a')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-2, 0));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(accepted, isEmpty, reason: '长按计时内 >1 px 的位移让长按拖动认输');
    expect(controller.offset, greaterThan(0), reason: '同一下位移被横滚认领');
  });

  testWidgets('鼠标长按 chip（计时内手抖 2 px）后拖到另一枚标签上触发重排，标签条不滚', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<String> accepted = <String>[];
    final List<String> tapped = <String>[];
    await tester.pumpWidget(
      harness(
        adaptive: true,
        controller: controller,
        accepted: accepted,
        tapped: tapped,
      ),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(labelOf('a')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(2, 0));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(labelOf('b')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(accepted, <String>['a->b']);
    expect(tapped, isEmpty);
    expect(controller.offset, 0, reason: '长按判胜后位移归拖动，不滚标签条');
  });

  testWidgets('鼠标在 chip 上按下就拖：横滚标签条且跟手，不起拖、不点选', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<String> accepted = <String>[];
    final List<String> tapped = <String>[];
    await tester.pumpWidget(
      harness(
        adaptive: true,
        controller: controller,
        accepted: accepted,
        tapped: tapped,
      ),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(labelOf('b')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    // 横滚已判胜：之后停够长按时长也不会改判成拖动。
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(accepted, isEmpty);
    expect(tapped, isEmpty);
    expect(controller.offset, closeTo(40, 0.01), reason: '门槛内的位移起滚时补上');
  });

  testWidgets('鼠标单击 chip（不移动）仍是点选，不起拖', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<String> accepted = <String>[];
    final List<String> tapped = <String>[];
    await tester.pumpWidget(
      harness(
        adaptive: true,
        controller: controller,
        accepted: accepted,
        tapped: tapped,
      ),
    );

    await tester.tapAt(
      tester.getCenter(labelOf('c')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(tapped, <String>['c']);
    expect(accepted, isEmpty);
  });

  testWidgets('触屏在 chip 上短滑归横滚，不起拖', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<String> accepted = <String>[];
    await tester.pumpWidget(
      harness(
        adaptive: true,
        controller: controller,
        accepted: accepted,
        tapped: <String>[],
      ),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(labelOf('b')),
    );
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(accepted, isEmpty);
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('触屏长按 chip 后拖到另一枚标签上触发重排', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<String> accepted = <String>[];
    await tester.pumpWidget(
      harness(
        adaptive: true,
        controller: controller,
        accepted: accepted,
        tapped: <String>[],
      ),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(labelOf('b')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(labelOf('a')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(accepted, <String>['b->a']);
    expect(controller.offset, 0);
  });
}
