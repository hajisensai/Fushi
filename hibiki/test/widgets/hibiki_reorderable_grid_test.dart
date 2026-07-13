import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/components/hibiki_reorderable_grid.dart';

/// 把列表交给 [HibikiReorderableGrid]，onReorder 时真正改顺序后重建——模拟真实调用方
/// （合集详情页）用法。固定 300 宽、3 列、方形单元（cellW=cellH=100，无间距），几何
/// 确定：A@(50,50) B@(150,50) C@(250,50)，第二行 D/E/F。
class _Harness extends StatefulWidget {
  const _Harness({
    required this.items,
    this.onReorder,
    this.onActivate,
    this.onContextMenu,
  });
  final List<String> items;
  final void Function(int from, int to)? onReorder;
  final void Function(int index)? onActivate;
  final void Function(int index, Offset pos)? onContextMenu;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final List<String> _items = List<String>.of(widget.items);

  @override
  Widget build(BuildContext context) {
    return HibikiReorderableGrid(
      itemCount: _items.length,
      crossAxisCount: 3,
      childAspectRatio: 1,
      keyForIndex: (int i) => ValueKey<String>(_items[i]),
      onReorder: (int from, int to) {
        setState(() {
          final String item = _items.removeAt(from);
          _items.insert(to, item);
        });
        widget.onReorder?.call(from, to);
      },
      onActivateItem: widget.onActivate,
      onContextMenu: widget.onContextMenu,
      itemBuilder: (BuildContext context, int i) => SizedBox(
        width: 100,
        height: 100,
        child: Center(child: Text(_items[i])),
      ),
    );
  }
}

Future<void> _pumpGrid(
  WidgetTester tester, {
  required List<String> order,
  void Function(int from, int to)? onReorder,
  void Function(int index)? onActivate,
  void Function(int index, Offset pos)? onContextMenu,
  double scale = 1.0,
}) async {
  Widget grid = Center(
    child: SizedBox(
      width: 300,
      child: _Harness(
        items: order,
        onReorder: onReorder,
        onActivate: onActivate,
        onContextMenu: onContextMenu,
      ),
    ),
  );
  if (scale != 1.0) {
    grid = HibikiAppUiScale(scale: scale, child: grid);
  }
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: grid)));
}

void main() {
  testWidgets('mouse press-and-drag reorders immediately (no long-press hold)',
      (WidgetTester tester) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await _pumpGrid(
      tester,
      order: order,
      onReorder: (int from, int to) {
        final String item = order.removeAt(from);
        order.insert(to, item);
        calls.add(from);
      },
    );

    final Offset start = tester.getCenter(find.text('A'));
    final Offset target = tester.getCenter(find.text('C'));
    final TestGesture gesture =
        await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, target, 0.5)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(calls, isNotEmpty, reason: 'a mouse drag must reorder without hold');
    // A 拖到 C 位置：A 现在排在 C 之后。
    expect(order.indexOf('A'), greaterThan(order.indexOf('C')));
    expect(order, <String>['B', 'C', 'A']);
  });

  testWidgets('touch long-press + move reorders', (WidgetTester tester) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await _pumpGrid(
      tester,
      order: order,
      onReorder: (int from, int to) {
        final String item = order.removeAt(from);
        order.insert(to, item);
        calls.add(from);
      },
    );

    final Offset start = tester.getCenter(find.text('A'));
    final Offset target = tester.getCenter(find.text('C'));
    final TestGesture gesture = await tester.startGesture(start);
    // 长按越过 kLongPressTimeout。
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(calls, isNotEmpty, reason: 'touch long-press drag must reorder');
    expect(order.indexOf('A'), greaterThan(order.indexOf('C')));
  });

  testWidgets(
      'touch long-press released in place fires context menu, NOT a reorder',
      (WidgetTester tester) async {
    final List<int> reorders = <int>[];
    final List<int> menus = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await _pumpGrid(
      tester,
      order: order,
      onReorder: (int from, int to) => reorders.add(from),
      onContextMenu: (int index, Offset pos) => menus.add(index),
    );

    final Offset start = tester.getCenter(find.text('B'));
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    // 原地松手（未移动）→ 上下文菜单，不重排。
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(reorders, isEmpty,
        reason: 'a stationary long-press must not reorder');
    expect(menus, <int>[1],
        reason: 'long-press release must fire context menu');
    expect(order, <String>['A', 'B', 'C']);
  });

  testWidgets('right-click (secondary tap) fires context menu',
      (WidgetTester tester) async {
    final List<int> menus = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await _pumpGrid(
      tester,
      order: order,
      onContextMenu: (int index, Offset pos) => menus.add(index),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('C')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(menus, <int>[2], reason: 'right-click must fire the context menu');
  });

  testWidgets('primary tap fires onActivate, NOT a reorder',
      (WidgetTester tester) async {
    final List<int> reorders = <int>[];
    final List<int> activations = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await _pumpGrid(
      tester,
      order: order,
      onReorder: (int from, int to) => reorders.add(from),
      onActivate: (int index) => activations.add(index),
    );

    await tester.tap(find.text('B'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(activations, <int>[1], reason: 'a stationary tap must activate');
    expect(reorders, isEmpty, reason: 'a stationary tap must not reorder');
  });

  testWidgets('a mouse press+up without move does NOT reorder (only activates)',
      (WidgetTester tester) async {
    final List<int> reorders = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await _pumpGrid(
      tester,
      order: order,
      onReorder: (int from, int to) => reorders.add(from),
    );

    final Offset start = tester.getCenter(find.text('A'));
    final TestGesture gesture =
        await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(reorders, isEmpty);
    expect(order, <String>['A', 'B', 'C']);
  });

  testWidgets('a cancelled drag does NOT commit a reorder',
      (WidgetTester tester) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await _pumpGrid(
      tester,
      order: order,
      onReorder: (int from, int to) {
        final String item = order.removeAt(from);
        order.insert(to, item);
        calls.add(from);
      },
    );

    final Offset start = tester.getCenter(find.text('A'));
    final Offset target = tester.getCenter(find.text('C'));
    final TestGesture gesture =
        await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    // 竞技场夺走指针 / 系统取消：放弃本次拖拽，绝不提交 onReorder。
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(calls, isEmpty,
        reason: 'a cancelled drag must not commit a reorder');
    expect(order, <String>['A', 'B', 'C'],
        reason: 'order must revert to the original on cancel');
  });

  testWidgets(
      'mouse drag reorders under 0.5 UI scale without flying off (de-scale — '
      'SDK/pub Reorderable grids fail here, BUG-757)',
      (WidgetTester tester) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await _pumpGrid(
      tester,
      scale: 0.5,
      order: order,
      onReorder: (int from, int to) {
        final String item = order.removeAt(from);
        order.insert(to, item);
        calls.add(from);
      },
    );

    final Offset start = tester.getCenter(find.text('A'));
    final Offset target = tester.getCenter(find.text('C'));
    final TestGesture gesture =
        await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, target, 0.5)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(calls, isNotEmpty,
        reason: 'drag must still reorder when the UI is scaled down');
    expect(order.indexOf('A'), greaterThan(order.indexOf('C')));
  });

  testWidgets(
      'a system-cancelled TOUCH long-press drag reverts and clears the ghost '
      'overlay (PointerCancel: notification pull-down / call / backgrounding)',
      (WidgetTester tester) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await _pumpGrid(
      tester,
      order: order,
      onReorder: (int from, int to) {
        final String item = order.removeAt(from);
        order.insert(to, item);
        calls.add(from);
      },
    );

    final Offset start = tester.getCenter(find.text('A'));
    final Offset target = tester.getCenter(find.text('C'));
    // 触摸（默认 kind）长按越过阈值 → 起拖 → 移动腾位。
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    // 拖拽中：幽灵浮层存在。
    expect(find.byKey(const ValueKey<String>('__reorder_grid_feedback__')),
        findsOneWidget);
    // 系统取消指针（PointerCancel，非松手）。旧实现只接 start/move/end，取消后
    // _dragOriginal/_display 残留 → 幽灵浮层 + 下次错序提交。
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(calls, isEmpty,
        reason:
            'a touch drag cancelled by the system must not commit a reorder');
    expect(order, <String>['A', 'B', 'C'],
        reason: 'order must revert to the original on cancel');
    expect(find.byKey(const ValueKey<String>('__reorder_grid_feedback__')),
        findsNothing,
        reason: 'the ghost feedback overlay must be cleared after a cancel');
  });

  testWidgets(
      'touch drag held at the bottom viewport edge auto-scrolls the enclosing '
      'SingleChildScrollView (members past one screen become reachable)',
      (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    // 3 列 × 15 项 = 5 行、cellH=100 → 内容高 500、视口 240 → 需自动滚动才够得到底部。
    final List<String> order = <String>[for (int i = 0; i < 15; i++) 'i$i'];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 240,
            child: SingleChildScrollView(
              controller: controller,
              child: _Harness(items: order),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(controller.offset, 0);

    final Rect viewport = tester.getRect(find.byType(SingleChildScrollView));
    final Offset start = tester.getCenter(find.text('i0'));
    final TestGesture gesture = await tester.startGesture(start); // touch
    await tester.pump(const Duration(milliseconds: 600)); // 长按起拖
    // 按住在视口底边缘带内（不再移动，靠帧步进自动滚动推进）。
    await gesture.moveTo(Offset(viewport.center.dx, viewport.bottom - 8));
    await tester.pump(); // 处理 move → 排下一帧的自动滚动
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.offset, greaterThan(0),
        reason: '指针按在底边缘带应驱动最近 Scrollable 自动向下滚动');
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
