import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart';

// TODO-814 回归守卫：平板/宽屏下底栏渲染成左侧竖向 nav rail（[adaptiveNavRail]）。
// 焦点停在 rail 的某个导航项，按「右」方向键必须跨出 rail 进入右侧内容区（书架），
// 绝不在 rail 内纵向遍历（往上/往下）。结构对齐 home_page._buildDesktopLayout：
// 左 rail（独立 FocusTraversalGroup + SingleChildScrollView 居中）+ VerticalDivider +
// 右 body（独立 FocusTraversalGroup + 内容网格，卡片为受管 HibikiFocusTarget）。
//
// 走真实分发路径 [gamepadMoveFocusInDirection]（键盘方向键与手柄 D-pad/摇杆共用），
// 覆盖 controller.move 几何 + 框架回退整链。
Widget _shell({required GlobalKey rootKey}) {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.search_outlined, label: '查词'),
    AdaptiveNavItem(icon: Icons.tune_outlined, label: '设置'),
  ];
  Widget card(String id) => HibikiFocusTarget(
        id: HibikiFocusId(id),
        child: const SizedBox(width: 200, height: 120),
      );
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
    home: Scaffold(
      body: HibikiFocusRoot(
        child: Row(
          key: rootKey,
          children: <Widget>[
            FocusTraversalGroup(
              child: Builder(
                builder: (BuildContext context) => adaptiveNavRail(
                  context: context,
                  currentIndex: 1,
                  onTap: (_) {},
                  items: items,
                ),
              ),
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              child: FocusTraversalGroup(
                child: GridView.count(
                  crossAxisCount: 3,
                  children: <Widget>[
                    for (int i = 0; i < 9; i++) card('content-$i'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'Right from a rail destination crosses into the content pane, never up '
      'within the rail (TODO-814)', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_shell(rootKey: rootKey));
    await tester.pump();
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    // 焦点停在 rail 中间项（nav-rail-1）。
    expect(controller.requestById(const HibikiFocusId('nav-rail-1')), isTrue);
    await tester.pump();

    gamepadMoveFocusInDirection(
        rootKey.currentContext!, TraversalDirection.right);
    await tester.pump();
    expect(
      controller.activeId?.value.startsWith('content-'),
      isTrue,
      reason: 'Right from a rail item must enter the content pane, '
          'never move within the rail',
    );
    expect(
      controller.activeId?.value.startsWith('nav-rail-'),
      isFalse,
      reason: 'Right must not stay/bounce inside the rail',
    );
  });

  testWidgets('Up/Down still steps within the rail (no regression)',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_shell(rootKey: rootKey));
    await tester.pump();
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(controller.requestById(const HibikiFocusId('nav-rail-0')), isTrue);
    await tester.pump();
    gamepadMoveFocusInDirection(
        rootKey.currentContext!, TraversalDirection.down);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('nav-rail-1'),
        reason: 'Down within the rail still steps to the next destination');
  });
}
