import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/components/hibiki_reorderable_column.dart';

/// 把列表交给 [HibikiReorderableColumn]，并在 onReorder 时真正改顺序后重建——
/// 模拟真实调用方（对话框）的用法。
class _Harness extends StatefulWidget {
  const _Harness({
    required this.items,
    required this.onReorder,
    this.spacing = 0,
  });
  final List<String> items;
  final void Function(int from, int to) onReorder;
  final double spacing;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final List<String> _items = List<String>.of(widget.items);

  @override
  Widget build(BuildContext context) {
    return HibikiReorderableColumn(
      itemCount: _items.length,
      spacing: widget.spacing,
      keyForIndex: (int i) => ValueKey<String>(_items[i]),
      onReorder: (int from, int to) {
        setState(() {
          final String item = _items.removeAt(from);
          _items.insert(to, item);
        });
        widget.onReorder(from, to);
      },
      itemBuilder: (BuildContext context, int i) => SizedBox(
        height: 60,
        child: Center(child: Text(_items[i])),
      ),
    );
  }
}

Future<List<int>> _dragRowDownPastNext(
  WidgetTester tester, {
  required String label,
  required String nextLabel,
  required List<int> Function() readOrder,
}) async {
  final Offset start = tester.getCenter(find.text(label));
  final Offset next = tester.getCenter(find.text(nextLabel));
  // 长按起拖：按住不动越过 kLongPressTimeout。
  final TestGesture gesture = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 600));
  // 往下拖到「下一行中心」附近（越过其中点 → 触发交换）。分两步并 pump，贴近真实移动。
  final Offset mid = Offset.lerp(start, next, 0.6)!;
  await gesture.moveTo(mid);
  await tester.pump();
  await gesture.moveTo(next);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
  return readOrder();
}

/// 把 [label] 行从当前位置一路拖到列表最顶端（越过第一行中点），用于验证
/// 「拖到第一个」。鼠标即时拖（不需长按），移动到第一行 [firstLabel] 的中心上方，
/// 此时被拖行顶部被 clamp 到 0、其中心恰好落在第一行中点——正是等高行能否进入
/// 索引 0 的边界。
Future<void> _dragRowToTop(
  WidgetTester tester, {
  required String label,
  required String firstLabel,
}) async {
  final Offset start = tester.getCenter(find.text(label));
  final Offset first = tester.getCenter(find.text(firstLabel));
  final TestGesture gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  // 分两步往上拖，最终落到第一行中心（再往上 clamp 不变，已是边界）。
  await gesture.moveTo(Offset.lerp(start, first, 0.6)!);
  await tester.pump();
  await gesture.moveTo(first);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'drag the LAST row to the very top lands it at index 0 (BUG: equal-'
      'height rows could never reach the first slot — strict < midpoint test)',
      (WidgetTester tester) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: _Harness(
                items: order,
                onReorder: (int from, int to) {
                  final String item = order.removeAt(from);
                  order.insert(to, item);
                  calls.add(from);
                },
              ),
            ),
          ),
        ),
      ),
    );

    await _dragRowToTop(tester, label: 'C', firstLabel: 'A');

    expect(tester.takeException(), isNull);
    expect(calls, isNotEmpty, reason: 'a reorder should have fired');
    // C 被拖到最顶端：必须真正排到第一个，而不是卡在第二位（旧 bug 的表现）。
    expect(order, <String>['C', 'A', 'B'],
        reason: 'the dragged row must reach index 0, not stall at index 1');
  });

  testWidgets(
      'row spacing lives in the layout, NOT in the drag feedback (BUG-078 '
      'symptom 2: dragged row painted extra background below it)',
      (WidgetTester tester) async {
    const double rowH = 60;
    const double gap = 24;
    final List<String> order = <String>['A', 'B', 'C'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: _Harness(
                items: order,
                spacing: gap,
                onReorder: (int from, int to) {},
              ),
            ),
          ),
        ),
      ),
    );

    // 静止：行间距进入布局 → 列表总高 = N*行高 + (N-1)*间距。
    expect(tester.getSize(find.byType(HibikiReorderableColumn)).height,
        rowH * 3 + gap * 2);

    // 拖拽中：浮层只包住行内容，高度恰为单行高（不含行间距）。若有人把间距折回
    // 行自带 padding，浮层会变成 rowH+gap 高、底部多出一条背景 → 此断言守住。
    final Offset start = tester.getCenter(find.text('A'));
    final TestGesture gesture =
        await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();

    final Finder feedback =
        find.byWidgetPredicate((Widget w) => w is Material && w.elevation == 6);
    expect(feedback, findsOneWidget);
    expect(tester.getSize(feedback).height, rowH,
        reason: 'feedback must wrap only the row, not the inter-row spacing');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'drag the LAST row to the very top still reaches index 0 WITH row '
      'spacing (geometry stays correct once spacing moved into the column)',
      (WidgetTester tester) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: _Harness(
                items: order,
                spacing: 24,
                onReorder: (int from, int to) {
                  final String item = order.removeAt(from);
                  order.insert(to, item);
                  calls.add(from);
                },
              ),
            ),
          ),
        ),
      ),
    );

    await _dragRowToTop(tester, label: 'C', firstLabel: 'A');

    expect(tester.takeException(), isNull);
    expect(calls, isNotEmpty, reason: 'a reorder should have fired');
    expect(order, <String>['C', 'A', 'B'],
        reason: 'spacing must not break reaching index 0');
  });

  testWidgets('long-press drag reorders at default scale', (
    WidgetTester tester,
  ) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: _Harness(
                items: order,
                onReorder: (int from, int to) {
                  final String item = order.removeAt(from);
                  order.insert(to, item);
                  calls.add(from);
                },
              ),
            ),
          ),
        ),
      ),
    );

    await _dragRowDownPastNext(
      tester,
      label: 'A',
      nextLabel: 'B',
      readOrder: () => const <int>[],
    );

    expect(tester.takeException(), isNull);
    expect(calls, isNotEmpty, reason: 'a reorder should have fired');
    // A 拖到 B 下方：A 现在排在 B 之后。
    expect(order.indexOf('A'), greaterThan(order.indexOf('B')));
    expect(order.length, 3);
  });

  testWidgets(
      'long-press drag reorders under 0.5 UI scale without flying off (the '
      'whole point — SDK ReorderableListView fails here)', (
    WidgetTester tester,
  ) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HibikiAppUiScale(
            scale: 0.5,
            child: Center(
              child: SizedBox(
                width: 300,
                child: _Harness(
                  items: order,
                  onReorder: (int from, int to) {
                    final String item = order.removeAt(from);
                    order.insert(to, item);
                    calls.add(from);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await _dragRowDownPastNext(
      tester,
      label: 'A',
      nextLabel: 'B',
      readOrder: () => const <int>[],
    );

    expect(tester.takeException(), isNull);
    expect(calls, isNotEmpty,
        reason: 'drag must still reorder when the UI is scaled down');
    expect(order.indexOf('A'), greaterThan(order.indexOf('B')));
    expect(order.length, 3);
  });

  testWidgets(
      'a quick move without holding does NOT reorder (long-press gated)',
      (WidgetTester tester) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: _Harness(
                items: order,
                onReorder: (int from, int to) => calls.add(from),
              ),
            ),
          ),
        ),
      ),
    );

    final Offset start = tester.getCenter(find.text('A'));
    final Offset next = tester.getCenter(find.text('B'));
    // 不按住、立刻拖：不该进入长按拖拽。
    final TestGesture gesture = await tester.startGesture(start);
    await gesture.moveTo(next);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(calls, isEmpty);
    expect(order, <String>['A', 'B', 'C']);
  });

  testWidgets(
      'mouse press-and-drag reorders immediately WITHOUT a long-press hold '
      '(the Windows fix — desktop pointers must not wait ~500ms)', (
    WidgetTester tester,
  ) async {
    final List<int> calls = <int>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: _Harness(
                items: order,
                onReorder: (int from, int to) {
                  final String item = order.removeAt(from);
                  order.insert(to, item);
                  calls.add(from);
                },
              ),
            ),
          ),
        ),
      ),
    );

    final Offset start = tester.getCenter(find.text('A'));
    final Offset next = tester.getCenter(find.text('B'));
    // 鼠标按下后立即移动（不长按、不等待）：ImmediateMultiDragGestureRecognizer
    // 越过 slop 即接管 → 直接进入拖拽并重排。这正是旧 onLongPress 实现做不到的。
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, next, 0.6)!);
    await tester.pump();
    await gesture.moveTo(next);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(calls, isNotEmpty,
        reason: 'a mouse drag must reorder without any long-press hold');
    expect(order.indexOf('A'), greaterThan(order.indexOf('B')));
    expect(order.length, 3);
  });

  testWidgets(
      'clicking an interactive child in a row fires the child, NOT a reorder '
      '(immediate drag recognizer must not steal taps)', (
    WidgetTester tester,
  ) async {
    final List<int> reorders = <int>[];
    final List<String> taps = <String>[];
    final List<String> order = <String>['A', 'B', 'C'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: HibikiReorderableColumn(
                itemCount: order.length,
                keyForIndex: (int i) => ValueKey<String>(order[i]),
                onReorder: (int from, int to) => reorders.add(from),
                itemBuilder: (BuildContext context, int i) => SizedBox(
                  height: 60,
                  child: Center(
                    child: TextButton(
                      onPressed: () => taps.add(order[i]),
                      child: Text('btn-${order[i]}'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 鼠标点击行内按钮（按下→原地抬起，无移动）：应触发按钮 onPressed，不触发重排。
    await tester.tap(find.text('btn-A'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(taps, <String>['A'], reason: 'the button tap must go through');
    expect(reorders, isEmpty, reason: 'a stationary click must not reorder');
    expect(order, <String>['A', 'B', 'C']);
  });
}
