import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/components/hibiki_reorderable_column.dart';

/// 把列表交给 [HibikiReorderableColumn]，并在 onReorder 时真正改顺序后重建——
/// 模拟真实调用方（对话框）的用法。
class _Harness extends StatefulWidget {
  const _Harness({required this.items, required this.onReorder});
  final List<String> items;
  final void Function(int from, int to) onReorder;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<String> _items = List<String>.of(widget.items);

  @override
  Widget build(BuildContext context) {
    return HibikiReorderableColumn(
      itemCount: _items.length,
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

void main() {
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
}
