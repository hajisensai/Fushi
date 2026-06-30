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

    // TODO-947：编辑排序/整理态下点书不得进书籍详情。重排页把书架/视频既有卡片
    // （内含 InkWell.onTap = openMedia）原样塞进网格，旧实现网格只装拖拽识别器、不
    // 拦裸 tap → 裸 tap 穿透到卡片内 InkWell 触发打开书。本用例给格子内卡片绑一个
    // onTap 计数器，断言「干净点击」不触发它（被网格吸收），仅拖拽才走 onReorder。
    testWidgets('编辑排序态：干净点击卡片不触发卡片内 onTap（不进书籍详情）',
        (WidgetTester tester) async {
      int innerTaps = 0;
      final List<int> reorders = <int>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              height: 600,
              child: HibikiReorderableGrid(
                itemCount: 3,
                cellExtent: 200,
                childAspectRatio: 1,
                keyForIndex: (int i) => ValueKey<String>('k$i'),
                onReorder: (int from, int to) => reorders
                  ..add(from)
                  ..add(to),
                // 模拟书架/视频卡片：整张卡是一个 InkWell.onTap（= 打开书）。
                itemBuilder: (BuildContext context, int i) => Material(
                  child: InkWell(
                    onTap: () => innerTaps++,
                    child: SizedBox(
                      key: ValueKey<String>('cell_$i'),
                      child: Center(child: Text('item$i')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 干净点击第一张卡所在坐标（按下即抬起、不移动）：旧实现裸 tap 穿透到卡片内
      // InkWell → innerTaps++（打开书）；新实现卡片被 IgnorePointer 屏蔽，点击落空。
      // 用原始 down/up 手势贴近真实点击，避免 find 命中 InkWell 的子树。
      final TestGesture tap = await tester.startGesture(
        tester.getCenter(find.text('item0')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tap.up();
      await tester.pumpAndSettle();
      expect(innerTaps, 0, reason: '编辑排序态下点书不得触发卡片 onTap（不进书籍详情）');
      expect(reorders, isEmpty, reason: '纯点击不是拖拽，不提交重排');
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

  group('HibikiReorderableGrid 合并手势（TODO-947 PR1 基建）', () {
    testWidgets(
        '拖到目标格中心 + canMergeInto=true → onMergeIntoTarget 触发、onReorder 不触发',
        (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      final List<List<int>> merges = <List<int>>[];
      await tester.pumpWidget(_MergeHarness(
        items: const <String>['a', 'b', 'c', 'd', 'e', 'f'],
        canMergeInto: (int from, int target) => true,
        onMergeIntoTarget: (int from, int target) =>
            merges.add(<int>[from, target]),
        onReorder: (int from, int to) => reorders
          ..add(from)
          ..add(to),
      ));
      await tester.pumpAndSettle();
      // a(0) 拖到 e(4) 的正中心：落在目标格中心 mergeRadius 区内 → 合并而非重排。
      await _dragTo(tester, 'a', tester.getCenter(find.text('e')));
      expect(
          merges,
          <List<int>>[
            <int>[0, 4]
          ],
          reason: 'a(0) 合并进 e(4)');
      expect(reorders, isEmpty, reason: '合并落点不得走 onReorder');
    });

    testWidgets('拖到格间隙（远离任何格中心）→ onReorder 触发、onMergeIntoTarget 不触发',
        (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      final List<List<int>> merges = <List<int>>[];
      await tester.pumpWidget(_MergeHarness(
        items: const <String>['a', 'b', 'c', 'd', 'e', 'f'],
        canMergeInto: (int from, int target) => true,
        onMergeIntoTarget: (int from, int target) =>
            merges.add(<int>[from, target]),
        onReorder: (int from, int to) => reorders
          ..add(from)
          ..add(to),
      ));
      await tester.pumpAndSettle();
      // 格 200x200、mergeRadius = 200*0.30 = 60。把 a 拖到 b(下标1) 与 c(下标2) 之间
      // 的边界缝隙：b 中心在 x=300，c 中心在 x=500，两格交界 x=400。浮层中心落 x≈400
      // 距任一格中心 100 > 60 → 不构成合并，命中仍按 floor 落到某格 → 走 onReorder。
      final Offset bCenter = tester.getCenter(find.text('b'));
      final Offset gap = bCenter + const Offset(100, 0); // x≈400，落 b/c 交界缝
      await _dragTo(tester, 'a', gap);
      expect(merges, isEmpty, reason: '格间隙落点不构成合并');
      expect(reorders, isNotEmpty, reason: '格间隙落点必须走普通重排');
    });

    testWidgets('不传合并回调（null）→ 任何拖放都只走 onReorder（纯重排零回归守卫）',
        (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      // 用与「合并」用例完全相同的落点（目标格正中心），但不传 canMergeInto /
      // onMergeIntoTarget：必须退化为今天的纯重排，一次合并都不会发生。
      await tester.pumpWidget(_GridHarness(
        items: const <String>['a', 'b', 'c', 'd', 'e', 'f'],
        onReorder: (int from, int to) => reorders
          ..add(from)
          ..add(to),
      ));
      await tester.pumpAndSettle();
      await _dragTo(tester, 'a', tester.getCenter(find.text('e')));
      expect(reorders, <int>[0, 4], reason: '不传回调时拖到格中心仍是纯重排 a(0)→e位置(4)');
    });

    testWidgets('canMergeInto 返回 false → 即便落在格中心也走 onReorder',
        (WidgetTester tester) async {
      final List<int> reorders = <int>[];
      final List<List<int>> merges = <List<int>>[];
      await tester.pumpWidget(_MergeHarness(
        items: const <String>['a', 'b', 'c', 'd', 'e', 'f'],
        canMergeInto: (int from, int target) => false, // 业务禁止合并
        onMergeIntoTarget: (int from, int target) =>
            merges.add(<int>[from, target]),
        onReorder: (int from, int to) => reorders
          ..add(from)
          ..add(to),
      ));
      await tester.pumpAndSettle();
      await _dragTo(tester, 'a', tester.getCenter(find.text('e')));
      expect(merges, isEmpty, reason: 'canMergeInto=false 不得合并');
      expect(reorders, <int>[0, 4], reason: 'canMergeInto=false 退化为重排');
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

/// 与 [_GridHarness] 同视口/几何，但额外暴露 canMergeInto / onMergeIntoTarget，用于
/// 合并手势用例。onReorder 仍真改顺序（贴近真实调用方），合并回调只记录不改列表
/// （PR1 不接线书架，合并落库是 PR2 的事）。
class _MergeHarness extends StatefulWidget {
  const _MergeHarness({
    required this.items,
    required this.onReorder,
    required this.canMergeInto,
    required this.onMergeIntoTarget,
  });
  final List<String> items;
  final void Function(int from, int to) onReorder;
  final bool Function(int draggingIndex, int targetIndex) canMergeInto;
  final void Function(int draggingIndex, int targetIndex) onMergeIntoTarget;

  @override
  State<_MergeHarness> createState() => _MergeHarnessState();
}

class _MergeHarnessState extends State<_MergeHarness> {
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
              canMergeInto: widget.canMergeInto,
              onMergeIntoTarget: widget.onMergeIntoTarget,
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
