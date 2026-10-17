import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';

/// 顶部悬浮条按宽度自适应溢出（2026-10-06）：宽时全部平铺、不画「⋯」；骤缩到
/// 窄宽时**第一帧**就收进「⋯」且不溢出（HBK034：AnimatedSize 收缩时保留旧宽度
/// 一帧，760 → 320 右侧溢出 276px）。
void main() {
  final List<FushiToolbarItem> actions = List<FushiToolbarItem>.generate(
    10,
    (int index) => FushiToolbarItem(
      icon: Icons.settings,
      label: 'Action $index',
      onPressed: () {},
    ),
  );

  Widget host(double width) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: FushiFloatingTopBar(
            leading: <FushiToolbarItem>[
              FushiToolbarItem(
                icon: Icons.arrow_back,
                label: 'Back',
                onPressed: () {},
              ),
            ],
            title: 'Book',
            actions: <List<FushiToolbarItem>>[actions],
          ),
        ),
      ),
    ),
  );

  final Finder more = find.byKey(
    const ValueKey<String>('fushi_floating_toolbar_overflow'),
  );

  testWidgets('HBK034: 760 → 320 骤缩第一帧即收进 ⋯ 且不溢出', (WidgetTester tester) async {
    await tester.pumpWidget(host(760));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(more, findsNothing, reason: '宽度够时全部平铺，不画 ⋯');

    await tester.pumpWidget(host(320));
    expect(more, findsOneWidget);
    expect(tester.takeException(), isNull, reason: '收缩的第一帧不得溢出');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('拆分：按优先级平铺前 k 颗，其余（含 overflow）进 ⋯', () {
    final FushiToolbarItem a = FushiToolbarItem(
      icon: Icons.add,
      label: 'a',
      onPressed: () {},
    );
    final FushiToolbarItem b = FushiToolbarItem(
      icon: Icons.add,
      label: 'b',
      onPressed: () {},
    );
    final FushiToolbarItem c = FushiToolbarItem(
      icon: Icons.add,
      label: 'c',
      onPressed: () {},
    );
    final split = fushiTopBarSplitActions(
      <List<FushiToolbarItem>>[
        <FushiToolbarItem>[a, b],
      ],
      <FushiToolbarItem>[c],
      1,
    );
    expect(split.groups, <List<FushiToolbarItem>>[
      <FushiToolbarItem>[a],
    ]);
    expect(split.overflow, <FushiToolbarItem>[b, c]);
  });

  test('menu 常驻：⋯ 恒占一格，测宽按它算', () {
    final List<List<FushiToolbarItem>> groups = <List<FushiToolbarItem>>[
      actions.sublist(0, 2),
    ];
    final double plain = fushiTopBarActionsWidth(groups, const [], 2);
    final double pinned = fushiTopBarActionsWidth(
      groups,
      const [],
      2,
      pinnedMenu: true,
    );
    expect(pinned, greaterThan(plain));
    // 预算刚好放下两颗、不够再放「⋯」时，常驻菜单要让出一颗。
    expect(fushiTopBarFitCount(groups, const [], 2, plain), 2);
    expect(
      fushiTopBarFitCount(groups, const [], 2, plain, pinnedMenu: true),
      1,
    );
  });

  testWidgets('menu 宽窗也不平铺；actionsFollowLeading 让动作紧跟返回键', (
    WidgetTester tester,
  ) async {
    final FushiToolbarItem menuItem = FushiToolbarItem(
      key: const ValueKey<String>('menu_item'),
      icon: Icons.delete,
      label: 'Clear',
      onPressed: () {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 900,
              child: FushiFloatingTopBar(
                actionsFollowLeading: true,
                leading: <FushiToolbarItem>[
                  FushiToolbarItem(
                    key: const ValueKey<String>('back'),
                    icon: Icons.arrow_back,
                    label: 'Back',
                    onPressed: () {},
                  ),
                ],
                actions: <List<FushiToolbarItem>>[
                  <FushiToolbarItem>[
                    FushiToolbarItem(
                      key: const ValueKey<String>('filter'),
                      icon: Icons.movie,
                      label: 'Filter',
                      selected: true,
                      onPressed: () {},
                    ),
                  ],
                ],
                menu: <FushiToolbarItem>[menuItem],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('menu_item')), findsNothing);
    expect(more, findsOneWidget, reason: 'menu 非空时 ⋯ 恒在');
    final double backRight = tester
        .getRect(find.byKey(const ValueKey<String>('back')))
        .right;
    final double filterLeft = tester
        .getRect(find.byKey(const ValueKey<String>('filter')))
        .left;
    expect(filterLeft - backRight, lessThan(40), reason: '筛选紧跟返回键');
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Clear'), findsOneWidget);
  });

  group('inlineLabels 逐级降档', () {
    FushiToolbarItem item(String label, {bool selected = false}) =>
        FushiToolbarItem(
          icon: Icons.movie,
          label: label,
          selected: selected,
          onPressed: () {},
        );
    final List<FushiToolbarItem> items = <FushiToolbarItem>[
      item('a'),
      item('b'),
      item('c', selected: true),
      item('d'),
    ];
    double width(FushiToolbarItem _) => 100;
    FushiTopBarLabeledLayout at(double budget) => fushiTopBarLabeledLayout(
      items: items,
      labeledWidth: width,
      budget: budget,
      pinnedMenu: true,
    );

    test('宽：全部带字', () {
      final FushiTopBarLabeledLayout l = at(1000);
      expect(l.labeled, items.toSet());
      expect(l.hidden, isEmpty);
    });

    test('中：只有选中项带字，全部平铺', () {
      // 8 + 104 + 3×52 + 52 = 320
      final FushiTopBarLabeledLayout l = at(320);
      expect(l.labeled, <FushiToolbarItem>{items[2]});
      expect(l.shown, items);
    });

    test('窄：选中项带字恒平铺，其余按优先级收进 ⋯', () {
      // 8 + 104 + 52(⋯) + 1×52 = 216
      final FushiTopBarLabeledLayout l = at(216);
      expect(l.labeled, <FushiToolbarItem>{items[2]});
      expect(l.shown, <FushiToolbarItem>[items[0], items[2]]);
      expect(l.hidden, <FushiToolbarItem>[items[1], items[3]]);
    });

    test('极窄：退成纯图标自适应溢出', () {
      final FushiTopBarLabeledLayout l = at(120);
      expect(l.labeled, isEmpty);
      expect(l.shown, <FushiToolbarItem>[items[0]]);
    });
  });

  group('actionsFollowLeading 的宽度预算与排法一致', () {
    final List<FushiToolbarItem> three = actions.sublist(0, 3);
    final double need = fushiTopBarActionsWidth(
      <List<FushiToolbarItem>>[three],
      const <FushiToolbarItem>[],
      3,
    );

    Widget follow(double width, {required bool withLeading}) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: FushiFloatingTopBar(
              actionsFollowLeading: true,
              leading: <FushiToolbarItem>[
                if (withLeading)
                  FushiToolbarItem(
                    icon: Icons.arrow_back,
                    label: 'Back',
                    onPressed: () {},
                  ),
              ],
              actions: <List<FushiToolbarItem>>[three],
            ),
          ),
        ),
      ),
    );

    testWidgets('有前置胶囊：动作组前没有行尾间距，恰好放得下就全部平铺', (WidgetTester tester) async {
      // 前置胶囊一格 56 + 其后 8；动作组紧跟其后，前面不再有 8 间距。
      await tester.pumpWidget(follow(64 + need, withLeading: true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(more, findsNothing, reason: '恰好放得下，不该收进 ⋯');
    });

    testWidgets('无前置胶囊：预算 = 整行宽，不多算 8（少 1px 就收起且不溢出）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(follow(need, withLeading: false));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(more, findsNothing);

      await tester.pumpWidget(follow(need - 1, withLeading: false));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '预算多算会溢出');
      expect(more, findsOneWidget);
    });
  });
}
