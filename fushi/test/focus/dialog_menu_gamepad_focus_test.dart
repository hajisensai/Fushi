import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';

/// 手柄焦点重写：对话框 / 菜单里的原生控件与方向引擎。
///
/// 旧引擎只认登记目标：只有原生按钮的对话框弹出后，被动修复会把焦点从对话框
/// 路由 scope 拽到 Navigator 之上的兜底节点，第一次 D-pad 什么也不做、此后 A 键
/// 无人处理；菜单打开时方向键从菜单背后陈旧的受管目标出发，跳到页面行上。
void main() {
  late FocusNode pageRow0;
  late FocusNode pageRow1;

  setUp(() {
    pageRow0 = FocusNode(debugLabel: 'page-row-0');
    pageRow1 = FocusNode(debugLabel: 'page-row-1');
  });

  tearDown(() {
    pageRow0.dispose();
    pageRow1.dispose();
  });

  Widget page({required Widget trigger}) {
    return MaterialApp(
      builder: (BuildContext context, Widget? child) =>
          FushiFocusRoot(child: child!),
      home: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            trigger,
            FushiFocusTarget(
              id: const FushiFocusId('page-row-0'),
              focusNode: pageRow0,
              child: const SizedBox(width: 200, height: 40),
            ),
            FushiFocusTarget(
              id: const FushiFocusId('page-row-1'),
              focusNode: pageRow1,
              child: const SizedBox(width: 200, height: 40),
            ),
          ],
        ),
      ),
    );
  }

  bool primaryInside(WidgetTester tester, Finder finder) {
    final BuildContext? context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    bool inside = false;
    final Element target = tester.element(finder);
    if (identical(context, target)) return true;
    context.visitAncestorElements((Element element) {
      if (identical(element, target)) {
        inside = true;
        return false;
      }
      return true;
    });
    return inside;
  }

  testWidgets(
    'plain AlertDialog: passive repair keeps focus inside the dialog, D-pad '
    'enters its buttons and A activates them',
    (WidgetTester tester) async {
      int cancels = 0;
      int oks = 0;
      await tester.pumpWidget(
        page(
          trigger: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (BuildContext context) => AlertDialog(
                  title: const Text('dialog'),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => cancels += 1,
                      child: const Text('cancel'),
                    ),
                    TextButton(
                      onPressed: () => oks += 1,
                      child: const Text('ok'),
                    ),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final FushiFocusController controller = FushiFocusRoot.controllerOf(
        tester.element(find.text('dialog')),
      );
      // Passive repair (a page target re-registering under the dialog).
      controller.scheduleRepair();
      await tester.pump();
      await tester.pump();
      expect(
        controller.fallbackNode.hasPrimaryFocus,
        isFalse,
        reason: 'focus must not be dragged out of the dialog',
      );
      expect(
        ModalRoute.of(FocusManager.instance.primaryFocus!.context!),
        isA<DialogRoute<void>>(),
        reason: 'primary=${FocusManager.instance.primaryFocus}',
      );

      // First D-pad press lands on the dialog's first button in reading order.
      final BuildContext ctx = FocusManager.instance.primaryFocus!.context!;
      expect(gamepadMoveFocusInDirection(ctx, TraversalDirection.down), isTrue);
      await tester.pump();
      expect(
        primaryInside(tester, find.widgetWithText(TextButton, 'cancel')),
        isTrue,
        reason: 'primary=${FocusManager.instance.primaryFocus}',
      );

      // Right moves to the neighbouring dialog button, never behind the dialog.
      expect(
        gamepadMoveFocusInDirection(
          FocusManager.instance.primaryFocus!.context!,
          TraversalDirection.right,
        ),
        isTrue,
      );
      await tester.pump();
      expect(
        primaryInside(tester, find.widgetWithText(TextButton, 'ok')),
        isTrue,
      );
      expect(pageRow0.hasFocus || pageRow1.hasFocus, isFalse);

      Actions.maybeInvoke<ActivateIntent>(
        FocusManager.instance.primaryFocus!.context!,
        const ActivateIntent(),
      );
      await tester.pump();
      expect(oks, 1);
      expect(cancels, 0);
    },
  );

  testWidgets(
    'open menu: D-pad stays inside the menu, not the page behind it',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        page(
          trigger: MenuAnchor(
            menuChildren: <Widget>[
              MenuItemButton(onPressed: () {}, child: const Text('item-a')),
              MenuItemButton(onPressed: () {}, child: const Text('item-b')),
            ],
            builder:
                (BuildContext context, MenuController menu, Widget? child) =>
                    TextButton(
                      onPressed: () => menu.open(),
                      child: const Text('menu'),
                    ),
          ),
        ),
      );
      await tester.pump();
      // A managed page row was the last managed focus (stale activeId source).
      pageRow1.requestFocus();
      await tester.pump();
      await tester.tap(find.text('menu'));
      await tester.pumpAndSettle();
      final Finder itemA = find.widgetWithText(MenuItemButton, 'item-a');
      final FocusNode itemANode = Focus.of(tester.element(find.text('item-a')));
      itemANode.requestFocus();
      await tester.pump();
      expect(primaryInside(tester, itemA), isTrue);

      expect(
        gamepadMoveFocusInDirection(
          FocusManager.instance.primaryFocus!.context!,
          TraversalDirection.down,
        ),
        isTrue,
      );
      await tester.pump();
      expect(
        primaryInside(tester, find.widgetWithText(MenuItemButton, 'item-b')),
        isTrue,
        reason: 'primary=${FocusManager.instance.primaryFocus}',
      );
      expect(pageRow0.hasFocus || pageRow1.hasFocus, isFalse);
    },
  );

  testWidgets('controller is resolvable from the fallback node context', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: FushiFocusRoot(child: Center(child: Text('passive'))),
      ),
    );
    await tester.pump();
    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.text('passive')),
    );
    expect(controller.fallbackNode.hasPrimaryFocus, isTrue);
    expect(
      FushiFocusRoot.maybeControllerOf(controller.fallbackNode.context!),
      same(controller),
    );
  });
}
