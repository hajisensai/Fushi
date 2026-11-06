import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';

/// [FushiReorderableRow]（横向重排）放在横向 SingleChildScrollView 里，onReorder
/// 时真正改顺序后重建——与浏览器顶部标签条同形。
class _Harness extends StatefulWidget {
  const _Harness({
    required this.order,
    this.onReorder,
    this.onTap,
    this.touchDragEnabled = true,
    this.controller,
  });

  final List<String> order;
  final void Function(int from, int to)? onReorder;
  final ValueChanged<String>? onTap;
  final bool touchDragEnabled;
  final ScrollController? controller;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 40,
    child: SingleChildScrollView(
      controller: widget.controller,
      scrollDirection: Axis.horizontal,
      child: FushiReorderableRow(
        itemCount: widget.order.length,
        touchDragEnabled: widget.touchDragEnabled,
        keyForIndex: (int i) => ValueKey<String>(widget.order[i]),
        onReorder: (int from, int to) {
          setState(() {
            final String item = widget.order.removeAt(from);
            widget.order.insert(to, item);
          });
          widget.onReorder?.call(from, to);
        },
        itemBuilder: (BuildContext context, int i) {
          final String label = widget.order[i];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onTap?.call(label),
            child: SizedBox(width: 100, child: Center(child: Text(label))),
          );
        },
      ),
    ),
  );
}

Widget _app(Widget child, {double scale = 1}) => MaterialApp(
  home: Scaffold(
    body: FushiAppUiScale(
      scale: scale,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 600, child: child),
      ),
    ),
  ),
);

Finder _feedbackOf(String label) => find.descendant(
  of: find.byType(FushiReorderDragProxy),
  matching: find.text(label),
);

void main() {
  testWidgets('鼠标横拖越过下一项中点即横向重排（无需长按）', (WidgetTester tester) async {
    final List<String> order = <String>['A', 'B', 'C'];
    final List<(int, int)> calls = <(int, int)>[];
    await tester.pumpWidget(
      _app(
        _Harness(
          order: order,
          onReorder: (int from, int to) => calls.add((from, to)),
        ),
      ),
    );

    final Offset start = tester.getCenter(find.text('A'));
    final Offset target = tester.getCenter(find.text('C'));
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, target, 0.5)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(calls, <(int, int)>[(0, 2)]);
    expect(order, <String>['B', 'C', 'A']);
  });

  for (final double scale in <double>[0.5, 1.5]) {
    testWidgets('祖先 Transform.scale=$scale 下浮层跟手、落点正确（BUG-778 横向）', (
      WidgetTester tester,
    ) async {
      final List<String> order = <String>['A', 'B', 'C'];
      await tester.pumpWidget(_app(_Harness(order: order), scale: scale));

      final Offset start = tester.getCenter(find.text('A'));
      final Offset target = tester.getCenter(find.text('B'));
      final TestGesture gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(Offset.lerp(start, target, 0.5)!);
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();

      // 浮层在列表自身 Stack 里、指针经 globalToLocal 消掉缩放：抓的是项中心，
      // 浮层中心应正好在指针下（SDK Overlay 代理在这里会按 (1-s)×距离 漂移）。
      final Offset feedback = tester.getCenter(_feedbackOf('A'));
      expect(feedback.dx, moreOrLessEquals(target.dx, epsilon: 0.5));
      expect(feedback.dy, moreOrLessEquals(target.dy, epsilon: 0.5));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(order, <String>['B', 'A', 'C']);
    });
  }

  testWidgets('鼠标单击不起拖：项自己的点击照常', (WidgetTester tester) async {
    final List<String> order = <String>['A', 'B', 'C'];
    final List<String> taps = <String>[];
    final List<(int, int)> calls = <(int, int)>[];
    await tester.pumpWidget(
      _app(
        _Harness(
          order: order,
          onTap: taps.add,
          onReorder: (int from, int to) => calls.add((from, to)),
        ),
      ),
    );

    await tester.tap(find.text('B'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(taps, <String>['B']);
    expect(calls, isEmpty);
    expect(order, <String>['A', 'B', 'C']);
  });

  testWidgets('touchDragEnabled=false：触屏长按后拖不重排，横滑交给外层滚动', (
    WidgetTester tester,
  ) async {
    final List<String> order = <String>['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];
    final List<(int, int)> calls = <(int, int)>[];
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        _Harness(
          order: order,
          controller: controller,
          touchDragEnabled: false,
          onReorder: (int from, int to) => calls.add((from, to)),
        ),
      ),
    );

    // 长按后拖：不起拖（触屏长按留给项自己的菜单）。
    final Offset a = tester.getCenter(find.text('A'));
    final TestGesture hold = await tester.startGesture(a);
    await tester.pump(const Duration(milliseconds: 700));
    await hold.moveTo(tester.getCenter(find.text('C')));
    await tester.pump();
    await hold.up();
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.byType(FushiReorderDragProxy), findsNothing);

    // 快速横滑：外层横向滚动接手。
    controller.jumpTo(0);
    await tester.pump();
    await tester.drag(find.text('C'), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(calls, isEmpty);
    expect(order, <String>['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']);
  });
}
