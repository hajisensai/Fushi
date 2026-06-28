import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/components/hibiki_reorderable_grid.dart';

/// 把列表交给 [HibikiReorderableGrid]，onReorder 时真改顺序后重建——模拟真实调用方
/// （重排页）的用法。固定 600x600 视口 + cellExtent 200 + aspect 1 → 3 列、格 200x200，
/// 命中几何完全可算，便于断言跨行 / 首位 / 末位 / 末行不满列。
class _GridHarness extends StatefulWidget {
  const _GridHarness({required this.items, required this.onReorder});
  final List<String> items;
  final void Function(int from, int to) onReorder;

  @override
  State<_GridHarness> createState() => _GridHarnessState();
}

class _GridHarnessState extends State<_GridHarness> {
  late final List<String> _items = List<String>.of(widget.items);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            height: 600,
            child: HibikiReorderableGrid(
              itemCount: _items.length,
              cellExtent: 200,
              childAspectRatio: 1,
              keyForIndex: (int i) => ValueKey<String>(_items[i]),
              onReorder: (int from, int to) {
                setState(() {
                  final String it = _items.removeAt(from);
                  _items.insert(to, it);
                });
                widget.onReorder(from, to);
              },
              itemBuilder: (BuildContext context, int i) => SizedBox(
                key: ValueKey<String>('cell_${_items[i]}'),
                child: Center(child: Text(_items[i])),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 鼠标即时拖：从 [label] 卡片中心拖到 [target] 全局坐标，分两步 pump 贴近真实移动。
Future<void> _dragTo(
  WidgetTester tester,
  String label,
  Offset target,
) async {
  final Offset start = tester.getCenter(find.text(label));
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
}

void main() {
  group('HibikiReorderableGrid 拖拽下标', () {
    testWidgets('跨行：第 0 个拖到第 4 个位置（同行换列 + 跨行）', (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      // 6 个：3 列 → 2 行满。下标布局 [0 1 2 / 3 4 5]。
      await tester.pumpWidget(_GridHarness(
        items: const <String>['a', 'b', 'c', 'd', 'e', 'f'],
        onReorder: (int from, int to) => reorders
          ..add(from)
          ..add(to),
      ));
      await tester.pumpAndSettle();
      // 把 a 拖到 e（下标 4）的中心。
      await _dragTo(tester, 'a', tester.getCenter(find.text('e')));
      expect(reorders, <int>[0, 4], reason: 'a(0) → e 位置(4)');
    });

    testWidgets('拖到首位：把 f(5) 拖到 a(0) 左上', (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      await tester.pumpWidget(_GridHarness(
        items: const <String>['a', 'b', 'c', 'd', 'e', 'f'],
        onReorder: (int from, int to) => reorders
          ..add(from)
          ..add(to),
      ));
      await tester.pumpAndSettle();
      await _dragTo(tester, 'f', tester.getCenter(find.text('a')));
      expect(reorders, <int>[5, 0], reason: 'f(5) → 首位(0)');
    });

    testWidgets('拖到末位：把 a(0) 拖到 f(5)', (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      await tester.pumpWidget(_GridHarness(
        items: const <String>['a', 'b', 'c', 'd', 'e', 'f'],
        onReorder: (int from, int to) => reorders
          ..add(from)
          ..add(to),
      ));
      await tester.pumpAndSettle();
      await _dragTo(tester, 'a', tester.getCenter(find.text('f')));
      expect(reorders, <int>[0, 5], reason: 'a(0) → 末位(5)');
    });

    testWidgets('末行不满列：7 项 [0 1 2 / 3 4 5 / 6]，把 a(0) 拖到末行右侧空槽不越界',
        (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      // 7 项：3 列 → [a b c / d e f / g]。末行只有 g(6) 一个，右边两槽空。
      await tester.pumpWidget(_GridHarness(
        items: const <String>['a', 'b', 'c', 'd', 'e', 'f', 'g'],
        onReorder: (int from, int to) => reorders
          ..add(from)
          ..add(to),
      ));
      await tester.pumpAndSettle();
      // g 的中心 + 一整格宽（落到末行第 2 列的空槽位置，本应是 index 7 → clamp 到 6）。
      final Offset gCenter = tester.getCenter(find.text('g'));
      final Offset emptySlot = gCenter + const Offset(200, 0);
      await _dragTo(tester, 'a', emptySlot);
      // 命中末行空槽 → clamp 到 itemCount-1=6（不越界、不抛、a 落到最后）。
      expect(reorders, <int>[0, 6], reason: '末行不满列空槽命中应 clamp 到 6');
    });

    testWidgets('原地松手不触发 onReorder', (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      await tester.pumpWidget(_GridHarness(
        items: const <String>['a', 'b', 'c', 'd', 'e', 'f'],
        onReorder: (int from, int to) => reorders
          ..add(from)
          ..add(to),
      ));
      await tester.pumpAndSettle();
      // 拖回自己中心（from==to）。
      await _dragTo(tester, 'b', tester.getCenter(find.text('b')));
      expect(reorders, isEmpty, reason: 'from==to 不提交');
    });

    testWidgets('祖先 Transform.scale（HibikiAppUiScale）下命中仍正确',
        (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: HibikiAppUiScale(
              scale: 0.5,
              child: SizedBox(
                width: 600,
                height: 600,
                child: _ScaledGrid(
                  onReorder: (int from, int to) => reorders
                    ..add(from)
                    ..add(to),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await _dragTo(tester, 'a', tester.getCenter(find.text('f')));
      expect(reorders, <int>[0, 5], reason: '缩放下 globalToLocal 抵消缩放，命中仍对');
    });
  });
}

/// 缩放用例的内层网格（与 _GridHarness 同配置，但直接被 HibikiAppUiScale 包裹）。
class _ScaledGrid extends StatefulWidget {
  const _ScaledGrid({required this.onReorder});
  final void Function(int from, int to) onReorder;
  @override
  State<_ScaledGrid> createState() => _ScaledGridState();
}

class _ScaledGridState extends State<_ScaledGrid> {
  final List<String> _items = <String>['a', 'b', 'c', 'd', 'e', 'f'];
  @override
  Widget build(BuildContext context) {
    return HibikiReorderableGrid(
      itemCount: _items.length,
      cellExtent: 200,
      childAspectRatio: 1,
      keyForIndex: (int i) => ValueKey<String>(_items[i]),
      onReorder: (int from, int to) {
        setState(() {
          final String it = _items.removeAt(from);
          _items.insert(to, it);
        });
        widget.onReorder(from, to);
      },
      itemBuilder: (BuildContext context, int i) =>
          Center(child: Text(_items[i])),
    );
  }
}
