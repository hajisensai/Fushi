import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tags/tag_drag_handle.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;

/// BUG-4899：库页标签条（横向、鼠标可拖滚的 `HorizontalDragScrollable` 列表）里
/// 只靠长按拖动重排，桌面鼠标 1 px 的 hit slop 下长按必输给横滚；「⋮⋮」拖动柄
/// 按下即拖，越过 slop 的同一帧先认领，横滚抢不到。
void main() {
  const List<String> tags = <String>['a', 'b', 'c', 'd'];

  Widget harness({
    required bool useHandle,
    required ScrollController controller,
    required List<String> accepted,
  }) {
    Widget label(String name) => SizedBox(
      key: ValueKey<String>('label-$name'),
      width: 80,
      height: 36,
      child: Center(child: Text(name)),
    );
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 260,
            height: 48,
            child: HorizontalDragScrollable(
              child: ListView(
                controller: controller,
                scrollDirection: Axis.horizontal,
                children: <Widget>[
                  for (final String name in tags)
                    DragTarget<String>(
                      onWillAcceptWithDetails: (DragTargetDetails<String> d) =>
                          d.data != name,
                      onAcceptWithDetails: (DragTargetDetails<String> d) =>
                          accepted.add('${d.data}->$name'),
                      builder:
                          (
                            BuildContext context,
                            List<String?> candidate,
                            List<dynamic> rejected,
                          ) => Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (useHandle) ...<Widget>[
                                FushiTagDragHandle<String>(
                                  key: ValueKey<String>('handle-$name'),
                                  data: name,
                                  feedback: Text(name),
                                ),
                                label(name),
                              ] else
                                LongPressDraggable<String>(
                                  key: ValueKey<String>('chip-$name'),
                                  data: name,
                                  feedback: Text(name),
                                  child: SizedBox(
                                    width: FushiTagDragHandle.width + 80,
                                    child: label(name),
                                  ),
                                ),
                            ],
                          ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('根因复现：长按拖动的 chip 在鼠标手抖 2 px 后输给横滚，标签拖不动', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<String> accepted = <String>[];
    await tester.pumpWidget(
      harness(useHandle: false, controller: controller, accepted: accepted),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('label-a'))),
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

  testWidgets('拖动柄：鼠标按下即拖，横滚抢不到，放到另一枚标签上触发重排', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<String> accepted = <String>[];
    await tester.pumpWidget(
      harness(useHandle: true, controller: controller, accepted: accepted),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('handle-a'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(2, 0));
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey<String>('label-b'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(accepted, <String>['a->b']);
    expect(controller.offset, 0, reason: '拖动柄上的位移不滚动标签条');
  });

  testWidgets('拖动柄：触屏同样按下即拖', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final List<String> accepted = <String>[];
    await tester.pumpWidget(
      harness(useHandle: true, controller: controller, accepted: accepted),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('handle-b'))),
    );
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey<String>('label-a'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(accepted, <String>['b->a']);
    expect(controller.offset, 0);
  });
}
