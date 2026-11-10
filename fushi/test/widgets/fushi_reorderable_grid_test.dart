import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_grid.dart';

/// 把列表交给 [FushiReorderableGrid]，onReorder 时真正改顺序后重建——模拟真实调用方
/// （合集详情页）用法。固定 300 宽、3 列、方形单元（cellW=cellH=100，无间距），几何
/// 确定：A@(50,50) B@(150,50) C@(250,50)，第二行 D/E/F。
class _Harness extends StatefulWidget {
  const _Harness({
    required this.items,
    this.onReorder,
    this.onActivate,
    this.onContextMenu,
    this.reordering = false,
  });
  final List<String> items;
  final bool reordering;
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
    return FushiReorderableGrid(
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
      reordering: widget.reordering,
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
  bool reordering = false,
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
        reordering: reordering,
      ),
    ),
  );
  if (scale != 1.0) {
    grid = FushiAppUiScale(scale: scale, child: grid);
  }
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: grid)));
}

void main() {
  testWidgets(
    'mouse press-and-drag reorders immediately (no long-press hold)',
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
      expect(
        calls,
        isNotEmpty,
        reason: 'a mouse drag must reorder without hold',
      );
      // A 拖到 C 位置：A 现在排在 C 之后。
      expect(order.indexOf('A'), greaterThan(order.indexOf('C')));
      expect(order, <String>['B', 'C', 'A']);
    },
  );

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
    'touch long-press opens the context menu on timeout, before release, '
    'and never starts a drag (same timing as library cards)',
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
      // 手指还按着：菜单已经弹出，不等松手。
      expect(menus, <int>[1], reason: 'long-press must open menu on timeout');
      // 继续拖动也不起拖。
      await gesture.moveTo(tester.getCenter(find.text('C')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(menus, <int>[1], reason: 'release must not fire a second menu');
      expect(reorders, isEmpty, reason: 'touch must not drag outside reorder');
      expect(order, <String>['A', 'B', 'C']);
    },
  );

  testWidgets(
    'reordering mode: a short touch hold lifts and drags; tap and menu are off',
    (WidgetTester tester) async {
      final List<int> menus = <int>[];
      final List<int> activations = <int>[];
      final List<String> order = <String>['A', 'B', 'C'];
      await _pumpGrid(
        tester,
        order: order,
        reordering: true,
        onReorder: (int from, int to) {
          final String item = order.removeAt(from);
          order.insert(to, item);
        },
        onActivate: activations.add,
        onContextMenu: (int index, Offset pos) => menus.add(index),
      );

      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(activations, isEmpty, reason: 'tap must not open while sorting');

      final Offset start = tester.getCenter(find.text('A'));
      final Offset target = tester.getCenter(find.text('C'));
      final TestGesture gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(menus, isEmpty, reason: 'no menu while sorting');
      expect(order, <String>['B', 'C', 'A']);
    },
  );

  testWidgets('right-click (secondary tap) fires context menu', (
    WidgetTester tester,
  ) async {
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

  testWidgets('right-click exposes the pointer anchor during the callback; '
      'touch long-press release does not', (WidgetTester tester) async {
    // 条目菜单（showMediaItemActions）凭 activeContextMenuAnchor 区分「指针处
    // 右键菜单」与「长按抽屉 / 对话框」；网格右键不暴露锚点时，合集里右键与长按
    // 弹出同一种容器（用户实报）。
    final List<Offset?> anchors = <Offset?>[];
    await _pumpGrid(
      tester,
      order: <String>['A', 'B', 'C'],
      onContextMenu: (int index, Offset pos) =>
          anchors.add(activeContextMenuAnchor),
    );

    final Offset c = tester.getCenter(find.text('C'));
    final TestGesture mouse = await tester.startGesture(
      c,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();

    final TestGesture touch = await tester.startGesture(
      tester.getCenter(find.text('B')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await touch.up();
    await tester.pumpAndSettle();

    expect(anchors, hasLength(2));
    expect(anchors[0], isNotNull, reason: 'right-click must carry the anchor');
    expect((anchors[0]! - c).distance, lessThan(1));
    expect(
      anchors[1],
      isNull,
      reason: 'long-press release must not look like a right-click',
    );
    expect(activeContextMenuAnchor, isNull);
  });

  testWidgets('primary tap fires onActivate, NOT a reorder', (
    WidgetTester tester,
  ) async {
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

  testWidgets(
    'a mouse press+up without move does NOT reorder (only activates)',
    (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      final List<String> order = <String>['A', 'B', 'C'];
      await _pumpGrid(
        tester,
        order: order,
        onReorder: (int from, int to) => reorders.add(from),
      );

      final Offset start = tester.getCenter(find.text('A'));
      final TestGesture gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(reorders, isEmpty);
      expect(order, <String>['A', 'B', 'C']);
    },
  );

  testWidgets('a cancelled drag does NOT commit a reorder', (
    WidgetTester tester,
  ) async {
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
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, target, 0.6)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    // 竞技场夺走指针 / 系统取消：放弃本次拖拽，绝不提交 onReorder。
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      calls,
      isEmpty,
      reason: 'a cancelled drag must not commit a reorder',
    );
    expect(order, <String>[
      'A',
      'B',
      'C',
    ], reason: 'order must revert to the original on cancel');
  });

  testWidgets(
    'mouse drag reorders under 0.5 UI scale without flying off (de-scale — '
    'SDK/pub Reorderable grids fail here, BUG-778)',
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
      expect(
        calls,
        isNotEmpty,
        reason: 'drag must still reorder when the UI is scaled down',
      );
      expect(order.indexOf('A'), greaterThan(order.indexOf('C')));
    },
  );

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
      expect(
        find.byKey(const ValueKey<String>('__reorder_grid_feedback__')),
        findsOneWidget,
      );
      // 系统取消指针（PointerCancel，非松手）。旧实现只接 start/move/end，取消后
      // _dragOriginal/_display 残留 → 幽灵浮层 + 下次错序提交。
      await gesture.cancel();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        calls,
        isEmpty,
        reason:
            'a touch drag cancelled by the system must not commit a reorder',
      );
      expect(order, <String>[
        'A',
        'B',
        'C',
      ], reason: 'order must revert to the original on cancel');
      expect(
        find.byKey(const ValueKey<String>('__reorder_grid_feedback__')),
        findsNothing,
        reason: 'the ghost feedback overlay must be cleared after a cancel',
      );
    },
  );

  testWidgets(
    'touch drag held at the bottom viewport edge auto-scrolls the enclosing '
    'SingleChildScrollView (members past one screen become reachable)',
    (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      // 3 列 × 15 项 = 5 行、cellH=100 → 内容高 500、视口 240 → 需自动滚动才够得到底部。
      final List<String> order = <String>[for (int i = 0; i < 15; i++) 'i$i'];
      await tester.pumpWidget(
        MaterialApp(
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
        ),
      );
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
      expect(
        controller.offset,
        greaterThan(0),
        reason: '指针按在底边缘带应驱动最近 Scrollable 自动向下滚动',
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  group('viewport window (only rows near the viewport are built)', () {
    // 3 列 × 60 项 = 20 行、cellH=100 → 内容高 2000；视口 240，上下各外扩半屏
    //（120）→ 首帧只建 0..3 行（0–360）。
    Future<ScrollController> pumpScrolling(WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 240,
                child: SingleChildScrollView(
                  controller: controller,
                  child: _Harness(
                    items: <String>[for (int i = 0; i < 60; i++) 'i$i'],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return controller;
    }

    Finder built(String label) => find.text(label, skipOffstage: false);

    testWidgets('first frame builds only the rows around the viewport', (
      WidgetTester tester,
    ) async {
      await pumpScrolling(tester);
      expect(built('i0'), findsOneWidget);
      expect(built('i11'), findsOneWidget, reason: 'row 3 is in the cache');
      expect(built('i12'), findsNothing, reason: 'row 4 starts at 400 > 360');
      expect(built('i59'), findsNothing);
    });

    testWidgets('scrolling builds the newly reached rows and drops far ones', (
      WidgetTester tester,
    ) async {
      final ScrollController controller = await pumpScrolling(tester);
      controller.jumpTo(1000);
      await tester.pump(); // 布局到新位置，帧末重量窗口
      await tester.pump(); // 按新窗口重建
      expect(built('i30'), findsOneWidget, reason: 'row 10 is at 1000–1100');
      expect(built('i0'), findsNothing);
      expect(tester.getTopLeft(built('i30')).dy, lessThan(500));
    });

    testWidgets('a grid that moves without scrolling re-measures its window', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<double> header = ValueNotifier<double>(1000);
      addTearDown(header.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 240,
                child: SingleChildScrollView(
                  child: Column(
                    children: <Widget>[
                      ValueListenableBuilder<double>(
                        valueListenable: header,
                        builder: (_, double h, _) => SizedBox(height: h),
                      ),
                      _Harness(
                        items: <String>[for (int i = 0; i < 60; i++) 'i$i'],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // 网格在视口下方 1000 处：首帧估算建了前几行，实测后一行也不在窗口里。
      await tester.pump();
      expect(built('i0'), findsNothing);
      // 上方内容收起（不是滚动）→ 网格上移到视口内 → 行必须补建。
      header.value = 0;
      await tester.pump();
      await tester.pump();
      expect(built('i0'), findsOneWidget);
    });

    testWidgets('the dragged cell stays built after auto-scroll leaves its row '
        'outside the window (its recognizer owns the active drag)', (
      WidgetTester tester,
    ) async {
      final ScrollController controller = await pumpScrolling(tester);
      final Rect viewport = tester.getRect(find.byType(SingleChildScrollView));
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.text('i0')),
      ); // touch
      await tester.pump(const Duration(milliseconds: 600)); // 长按起拖
      await gesture.moveTo(Offset(viewport.center.dx, viewport.bottom - 8));
      await tester.pump();
      for (int i = 0; i < 60 && controller.offset < 700; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.offset, greaterThanOrEqualTo(700));
      expect(
        find.byKey(const ValueKey<String>('__reorder_grid_feedback__')),
        findsOneWidget,
        reason: 'the drag must still be alive',
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('without a vertical Scrollable every cell is built', (
      WidgetTester tester,
    ) async {
      await _pumpGrid(
        tester,
        order: <String>[for (int i = 0; i < 60; i++) 'i$i'],
      );
      expect(built('i59'), findsOneWidget);
    });
  });
}
