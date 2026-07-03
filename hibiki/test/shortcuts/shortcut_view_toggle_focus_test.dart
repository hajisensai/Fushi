import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/utils.dart';

/// TODO-942 残留缺口守卫：快捷键设置页顶部「列表 / 键盘皮肤」模式切换开关必须
/// 可被手柄 / 键盘焦点操作。修复前它是一个裸 `SegmentedButton<bool>` —— 由多个
/// 原生子按钮组成的簇，方向式 [HibikiFocusController]（只遍历已注册的
/// [HibikiFocusTarget]）会整个跳过它，纯手柄用户根本到不了键盘皮肤视图。
///
/// 修复后它被 [HibikiAdjustableSegmented]<bool> 包成**单一焦点停靠点**：
/// - 方向键 / D-pad 左右在 list(false) ↔ keyboard(true) 之间翻转；
/// - 内部 [SegmentedButton] 仍保留 `Key('shortcut_view_toggle')`，鼠标 / 触摸
///   可点、测试可寻址。
///
/// 这里复现源码里那一段 `HibikiAdjustableSegmented<bool>` + `SegmentedButton`
/// 组合，通过真实的 [HibikiFocusRoot] 焦点驱动（禁 tester.tap / 坐标点击），
/// 断言焦点可达且方向键 / 手柄能真正翻转选择。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  /// 与 `shortcut_settings_page.dart:_buildScopeSections` 里同构的开关组合，
  /// 由外层 [StatefulBuilder] 持有 `visualMode` 状态（镜像页面的 `_visualMode`
  /// setState 逻辑），套进真实焦点根 + 全局导航方向键处理器。
  Widget buildHarness({required ValueChanged<bool> onModeChanged}) {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    bool visualMode = false;
    return MaterialApp(
      navigatorKey: navKey,
      theme: ThemeData.light(useMaterial3: true),
      builder: (BuildContext context, Widget? child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
      home: Scaffold(
        body: HibikiFocusRoot(
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return Align(
                alignment: Alignment.centerLeft,
                child: HibikiAdjustableSegmented<bool>(
                  focusIdPrefix: 'shortcut-view-toggle',
                  values: const <bool>[false, true],
                  selected: visualMode,
                  onChanged: (bool value) {
                    setState(() => visualMode = value);
                    onModeChanged(value);
                  },
                  child: SegmentedButton<bool>(
                    key: const Key('shortcut_view_toggle'),
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<bool>>[
                      ButtonSegment<bool>(
                        value: false,
                        icon: Icon(Icons.list_outlined),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        icon: Icon(Icons.keyboard_outlined),
                      ),
                    ],
                    selected: <bool>{visualMode},
                    onSelectionChanged: (Set<bool> selection) {
                      setState(() => visualMode = selection.first);
                      onModeChanged(selection.first);
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  testWidgets(
      'view toggle registers as a single focus stop and arrow keys flip the '
      'view (TODO-942)', (WidgetTester tester) async {
    bool? lastMode;
    await tester
        .pumpWidget(buildHarness(onModeChanged: (bool m) => lastMode = m));
    await tester.pump();

    // 开关真的存在且可寻址（Key 保留 ⇒ 鼠标 / 触摸 / 测试仍可用）。
    expect(find.byKey(const Key('shortcut_view_toggle')), findsOneWidget);

    // 焦点根里只有这一个停靠点，ensureFocus 必然落在开关上（修复前它整个被
    // 方向式焦点控制器跳过，activeId 会是 null）。
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byKey(const Key('shortcut_view_toggle'))),
    );
    controller.ensureFocus();
    await tester.pump();
    expect(controller.activeId, isNotNull, reason: '模式开关必须注册为单一手柄/键盘焦点停靠点');

    // 方向键右 = 进到 keyboard 视图 (false -> true)。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(lastMode, isTrue, reason: '右方向键从列表翻到键盘皮肤视图');

    // 方向键左 = 回到 list 视图 (true -> false)。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(lastMode, isFalse, reason: '左方向键从键盘皮肤翻回列表视图');
  });

  testWidgets('D-pad left/right flips the view toggle in place (TODO-942)', (
    WidgetTester tester,
  ) async {
    bool? lastMode;
    await tester
        .pumpWidget(buildHarness(onModeChanged: (bool m) => lastMode = m));
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byKey(const Key('shortcut_view_toggle'))),
    );
    controller.ensureFocus();
    await tester.pump();
    expect(controller.activeId, isNotNull);

    // D-pad 右被开关消费（不移动焦点），list -> keyboard。
    expect(
      Actions.maybeInvoke<GamepadButtonIntent>(
        controller.activeContext!,
        const GamepadButtonIntent(GamepadButton.dpadRight),
      ),
      isTrue,
      reason: 'D-pad 右被模式开关消费，翻到键盘皮肤视图',
    );
    await tester.pump();
    expect(lastMode, isTrue);

    // D-pad 左翻回 list。
    Actions.maybeInvoke<GamepadButtonIntent>(
      controller.activeContext!,
      const GamepadButtonIntent(GamepadButton.dpadLeft),
    );
    await tester.pump();
    expect(lastMode, isFalse);
  });
}
