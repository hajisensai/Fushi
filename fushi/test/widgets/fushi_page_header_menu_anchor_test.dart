import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';

/// 库页「排序」菜单的锚点跟着页头动作组走（[FushiPageHeader.menuAnchor]）。
///
/// 回归：锚点曾作为页头下方的一行常驻在库页工具区里，而在首页外壳里页头
/// 动作被登记进外壳的浮动工具栏（窗口最上方），页头这一行只剩页签——菜单
/// 于是弹在排序按钮下方老远的地方（视频库截图：按钮在顶栏，菜单在列表区）。
void main() {
  const ValueKey<String> itemKey = ValueKey<String>('menu-item');

  Widget anchorFor(MenuController menu) => FushiMenuAnchor(
    controller: menu,
    menuChildren: <Widget>[
      MenuItemButton(key: itemKey, onPressed: () {}, child: const Text('Name')),
    ],
    child: const SizedBox.shrink(),
  );

  List<Widget> actions() => <Widget>[
    FushiIconButton(
      key: const ValueKey<String>('sort'),
      tooltip: 'sort',
      icon: Icons.sort,
      onTap: () {},
    ),
  ];

  testWidgets('动作交给外壳浮动工具栏时，菜单从那枚胶囊下方弹出', (WidgetTester tester) async {
    final FushiShellActionsSlot slot = FushiShellActionsSlot();
    addTearDown(slot.dispose);
    final MenuController menu = MenuController();

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
                  actions: actions(),
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
    menu.open();
    await tester.pumpAndSettle();

    final Rect item = tester.getRect(find.byKey(itemKey));
    expect(
      item.top,
      inInclusiveRange(pill.bottom - 1, pill.bottom + 40),
      reason: '菜单应贴着外壳胶囊下沿（$pill），而不是页头那一行：$item',
    );
  });

  testWidgets('动作画在页头本行时，菜单从本行动作组下方弹出', (WidgetTester tester) async {
    final MenuController menu = MenuController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: 200),
              FushiPageHeader(
                title: 'Books',
                actions: actions(),
                menuAnchor: anchorFor(menu),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect sort = tester.getRect(
      find.byKey(const ValueKey<String>('sort')),
    );
    menu.open();
    await tester.pumpAndSettle();

    final Rect item = tester.getRect(find.byKey(itemKey));
    expect(
      item.top,
      inInclusiveRange(sort.bottom - 1, sort.bottom + 40),
      reason: '菜单应贴着动作组下沿（$sort）：$item',
    );
    expect(item.right, lessThanOrEqualTo(800));
  });
}
