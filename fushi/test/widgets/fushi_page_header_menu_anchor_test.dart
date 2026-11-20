import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_header_menu_anchor.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';

/// 库页「排序」菜单（[FushiPageHeader.menuAnchor] + [FushiHeaderMenuController]）
/// 从**触发控件**下沿弹出。
///
/// 回归 1：锚点曾作为页头下方的一行常驻在库页工具区里，而在首页外壳里页头
/// 动作被登记进外壳的浮动工具栏（窗口最上方），页头这一行只剩页签——菜单
/// 于是弹在排序按钮下方老远的地方（视频库截图：按钮在顶栏，菜单在列表区）。
///
/// 回归 2（BUG-4715）：锚点改成叠在动作组右下角的零尺寸盒子后，只要排序按钮
/// 不在动作组最右端（游戏库：排序后面还有筛选 / 管理标签 / 布局切换），菜单就
/// 弹在动作组右下角，与按钮对不上。
void main() {
  const ValueKey<String> itemKey = ValueKey<String>('menu-item');
  const ValueKey<String> sortKey = ValueKey<String>('sort');

  Widget anchorFor(FushiHeaderMenuController menu, {VoidCallback? onItem}) =>
      FushiHeaderMenuAnchor(
        controller: menu,
        menuChildren: <Widget>[
          MenuItemButton(
            key: itemKey,
            onPressed: onItem ?? () {},
            child: const Text('Name'),
          ),
        ],
      );

  /// 排序按钮排在**最前**，后面还有两颗动作：零尺寸右下角锚点会把菜单弹到
  /// 最后一颗动作下面。
  List<Widget> actions(
    FushiHeaderMenuController menu, {
    int sortPriority = 0,
  }) => <Widget>[
    FushiIconButton(
      key: sortKey,
      tooltip: 'sort',
      icon: Icons.sort,
      overflowPriority: sortPriority,
      onTap: menu.toggle,
    ),
    FushiIconButton(
      tooltip: 'add',
      icon: Icons.add,
      overflowPriority: 5,
      onTap: () {},
    ),
    FushiIconButton(
      tooltip: 'delete',
      icon: Icons.delete,
      overflowPriority: 5,
      onTap: () {},
    ),
  ];

  /// 菜单项在触发控件 [trigger] 正下方：上沿贴着它的下沿，水平方向与它重叠
  /// 且左沿对齐（MenuAnchor 从锚框左下角弹出，屏幕放得下就不挪）。
  void expectBelow(WidgetTester tester, Rect trigger, Rect item) {
    expect(
      item.top,
      inInclusiveRange(trigger.bottom - 1, trigger.bottom + 40),
      reason: '菜单应贴着触发控件下沿（$trigger）：$item',
    );
    expect(
      (item.left - trigger.left).abs(),
      lessThan(24),
      reason: '菜单左沿应对齐触发控件（$trigger），而不是动作组末端：$item',
    );
  }

  testWidgets('动作画在页头本行：菜单从排序按钮下方弹出，不是动作组右下角', (WidgetTester tester) async {
    final FushiHeaderMenuController menu = FushiHeaderMenuController();
    bool picked = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: 200),
              FushiPageHeader(
                title: 'Books',
                actions: actions(menu),
                menuAnchor: anchorFor(menu, onItem: () => picked = true),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect sort = tester.getRect(find.byKey(sortKey));
    await tester.tap(find.byKey(sortKey));
    await tester.pumpAndSettle();

    expect(menu.isOpen, isTrue);
    expectBelow(tester, sort, tester.getRect(find.byKey(itemKey)));

    // 锚框不吃指针，但菜单浮层照常可点。
    await tester.tap(find.byKey(itemKey));
    await tester.pumpAndSettle();
    expect(picked, isTrue);
    expect(menu.isOpen, isFalse);
  });

  testWidgets('动作交给外壳浮动工具栏：菜单从胶囊里的排序按钮下方弹出', (WidgetTester tester) async {
    final FushiShellActionsSlot slot = FushiShellActionsSlot();
    addTearDown(slot.dispose);
    final FushiHeaderMenuController menu = FushiHeaderMenuController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FushiShellTitleScope(
            title: 'Video',
            actionsSlot: slot,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Align(
                  alignment: Alignment.centerRight,
                  child: FushiFloatingActionsPill(slot: slot),
                ),
                // 页签行等页头上方内容：把页头这一行推到离外壳胶囊很远的地方。
                const SizedBox(height: 300),
                FushiPageHeader.customTitle(
                  title: const SizedBox.shrink(),
                  actions: actions(menu),
                  menuAnchor: anchorFor(menu),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect pill = tester.getRect(find.byType(FushiFloatingActionsPill));
    final Rect sort = tester.getRect(find.byKey(sortKey));
    expect(pill.contains(sort.center), isTrue, reason: '排序按钮画在外壳胶囊里');
    await tester.tap(find.byKey(sortKey));
    await tester.pumpAndSettle();

    expectBelow(tester, sort, tester.getRect(find.byKey(itemKey)));
  });

  testWidgets('排序按钮被收进 ⋯：从 ⋯ 菜单打开时菜单从 ⋯ 下方弹出', (WidgetTester tester) async {
    final FushiHeaderMenuController menu = FushiHeaderMenuController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: 200),
              Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  child: FushiPageHeader(
                    title: 'Books',
                    // 排序优先级最低，最先收进 ⋯。
                    actions: actions(menu, sortPriority: -1),
                    menuAnchor: anchorFor(menu),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(sortKey), findsNothing, reason: '排序按钮应已收进 ⋯');
    final Finder more = find.byKey(kFushiHeaderOverflowMenuKey);
    final Rect moreRect = tester.getRect(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('sort'));
    await tester.pumpAndSettle();

    expect(menu.isOpen, isTrue);
    expectBelow(tester, moreRect, tester.getRect(find.byKey(itemKey)));
  });

  testWidgets('没有触发控件（程序化打开）时锚在动作组末端下沿', (WidgetTester tester) async {
    final FushiHeaderMenuController menu = FushiHeaderMenuController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: 200),
              FushiPageHeader(
                title: 'Books',
                actions: actions(menu),
                menuAnchor: anchorFor(menu),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect sort = tester.getRect(find.byKey(sortKey));
    menu.open();
    await tester.pumpAndSettle();

    final Rect item = tester.getRect(find.byKey(itemKey));
    expect(item.top, inInclusiveRange(sort.bottom - 1, sort.bottom + 40));
    expect(item.right, lessThanOrEqualTo(800));
  });
}
