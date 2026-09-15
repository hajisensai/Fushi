import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/page_scroll_registry.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// Android 手柄键事件链上的 LB/RB 整屏滚动（用户：「安卓的 xbox 的肩键没识别到」）。
///
/// 桌面轮询路径早有 `GamepadService._tryScrollPage` 兜底；Android 上引擎把手柄按钮
/// 送成 `gameButton*` KeyEvent，走的是 [wrapWithGlobalNavigation] 那条键链——它的
/// 页面滚动兜底 `_handleGlobalScroll` 之前**只解析键盘绑定**，于是默认绑在 LB/RB 上
/// 的 globalScrollPageUp/Down 在 Android 上没有任何执行体：首页 / 设置 / 统计页按
/// 肩键一律无反应。现在同一处兜底也按 global scope 解析手柄键。
///
/// 宿主结构照生产（同 global_keyboard_scroll_test）：wrapper 挂在
/// [MaterialApp.builder]、页面经 `home:` 挂进 Navigator，滚动目标由「Navigator 当前
/// 路由子树里的第一个纵向 Scrollable」兜底解析。
void main() {
  FushiShortcutRegistry androidRegistry() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.android);

  setUp(PageScrollRegistry.debugClear);

  Future<void> pumpApp(
    WidgetTester tester, {
    required Widget page,
    required FushiShortcutRegistry registry,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: page,
      builder: (BuildContext context, Widget? child) =>
          wrapWithGlobalNavigation(
        navigatorKey: navKey,
        registry: registry,
        focusNavigationEnabled: false,
        child: child!,
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 纯展示长列表页：零可聚焦子件、零登记、`primary: false`。
  Widget displayOnlyList(ScrollController controller) => Scaffold(
        body: ListView.builder(
          controller: controller,
          primary: false,
          itemCount: 200,
          itemExtent: 40,
          itemBuilder: (BuildContext context, int i) => Text('row $i'),
        ),
      );

  testWidgets('Android 键链：RB 整屏下滚、LB 整屏上滚（默认绑定）', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpApp(
      tester,
      page: displayOnlyList(controller),
      registry: androidRegistry(),
    );
    expect(controller.offset, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
    await tester.pumpAndSettle();
    final double afterRb = controller.offset;
    expect(afterRb, greaterThan(0), reason: 'RB 必须整屏下滚');

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(afterRb), reason: '再按一次继续滚');

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonLeft1);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(afterRb, 0.5), reason: 'LB 整屏上滚一屏');
  });

  testWidgets('按住 RB：OS 自动重复沿也滚（与键盘 PageDown 同款）', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpApp(
      tester,
      page: displayOnlyList(controller),
      registry: androidRegistry(),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonRight1);
    await tester.pumpAndSettle();
    final double afterDown = controller.offset;
    expect(afterDown, greaterThan(0));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.gameButtonRight1);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(afterDown), reason: '重复沿继续滚');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonRight1);
  });

  testWidgets('改键生效：LB/RB 从 global scope 解绑后不再滚', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final FushiShortcutRegistry registry = androidRegistry()
      ..updateBinding(
        ShortcutAction.globalScrollPageDown,
        const ShortcutBindingSet(),
      )
      ..updateBinding(
        ShortcutAction.globalScrollPageUp,
        const ShortcutBindingSet(),
      );
    await pumpApp(tester,
        page: displayOnlyList(controller), registry: registry);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonLeft1);
    await tester.pumpAndSettle();
    expect(controller.offset, 0, reason: '没绑定的肩键不能滚');
  });

  testWidgets('改键生效：把整屏下滚绑到 RT 后，RT 键事件（扳机合成键）也滚', (WidgetTester tester) async {
    // Android 原生侧把扳机轴合成为 KEYCODE_BUTTON_R2 → gameButtonRight2，
    // 走的正是这条键链；这里只验 Dart 侧的解析与执行体。
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final FushiShortcutRegistry registry = androidRegistry()
      ..updateBinding(
        ShortcutAction.globalScrollPageDown,
        const ShortcutBindingSet(
          gamepadBindings: <GamepadBinding>[GamepadBinding(GamepadButton.rt)],
        ),
      );
    await pumpApp(tester,
        page: displayOnlyList(controller), registry: registry);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight2);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('文本框聚焦时 LB/RB 不接管（与键盘滚页的让位规则一致）', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    final FocusNode field = FocusNode();
    addTearDown(field.dispose);
    await pumpApp(
      tester,
      page: Scaffold(
        body: Column(
          children: <Widget>[
            TextField(focusNode: field),
            Expanded(
              child: ListView.builder(
                controller: controller,
                primary: false,
                itemCount: 200,
                itemExtent: 40,
                itemBuilder: (BuildContext context, int i) => Text('row $i'),
              ),
            ),
          ],
        ),
      ),
      registry: androidRegistry(),
    );
    field.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
  });
}
