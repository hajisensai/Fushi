import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/shortcut_settings_page.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/utils/components/hibiki_material_components.dart';

/// 手柄绑定实时录键（快捷键设置重构批2）：编辑对话框的手柄通道与键盘/鼠标一致，
/// 提供「捕获区 + 显式停止」的实时录键；下拉菜单降级为「从列表选择」兜底。
///
/// 捕获区要接住两条真实分发路径：
/// 1. 桌面轮询（GamepadService._dispatchButton）——把按键作为
///    [GamepadButtonIntent] `Actions.maybeInvoke` 到主焦点上下文；
/// 2. Android 原生按键——`gameButton*` KeyEvent 从焦点节点冒泡。
/// 两条路径都必须在捕获态被消费（阻断 A→Activate / B→返回 / 十字键移焦点），
/// 并复用 [_addGamepad] 的冲突/重分配流程。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  HibikiShortcutRegistry buildRegistry() =>
      HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  Future<void> pumpDialog(
    WidgetTester tester,
    HibikiShortcutRegistry registry, {
    ShortcutAction action = ShortcutAction.readerToggleFurigana,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ShortcutBindingEditDialog(
                action: action,
                registry: registry,
                initial: const ShortcutBindingSet(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> startGamepadCapture(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('shortcut_add_gamepad_capture')));
    await tester.pumpAndSettle();
    expect(find.text(t.shortcut_press_gamepad), findsOneWidget);
  }

  testWidgets('desktop poller path: GamepadButtonIntent records the button',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpDialog(tester, registry);
    await startGamepadCapture(tester);

    // 模拟 GamepadService._dispatchButton：向主焦点上下文分发 intent。
    // Select 在默认表未绑定，走无冲突直加路径。
    final BuildContext ctx = FocusManager.instance.primaryFocus!.context!;
    final Object? handled = Actions.maybeInvoke<GamepadButtonIntent>(
      ctx,
      const GamepadButtonIntent(GamepadButton.select),
    );
    await tester.pumpAndSettle();

    expect(handled, isTrue, reason: '捕获区必须消费 intent（阻断 A→Activate 等服务端回退）');
    expect(
      find.widgetWithText(HibikiTagChip, GamepadButton.select.label),
      findsOneWidget,
      reason: '捕获到的按钮应立即出现在手柄草稿 chips 中',
    );
    expect(find.text(t.shortcut_press_gamepad), findsNothing,
        reason: '录到一个按钮后捕获态应结束（对齐键盘捕获契约）');
  });

  testWidgets('Android native path: gameButton* key event records the button',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpDialog(tester, registry);
    await startGamepadCapture(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonSelect);
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(HibikiTagChip, GamepadButton.select.label),
      findsOneWidget,
    );
    expect(find.text(t.shortcut_press_gamepad), findsNothing);
  });

  testWidgets('keyboard keys during gamepad capture are swallowed, not bound',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpDialog(tester, registry);
    await startGamepadCapture(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();

    // 仍在捕获态，且没有把键盘 A 记成任何绑定。
    expect(find.text(t.shortcut_press_gamepad), findsOneWidget,
        reason: '键盘按键不结束手柄捕获（仅显式停止或录到手柄按钮）');
    expect(find.widgetWithText(HibikiTagChip, 'A'), findsNothing,
        reason: '键盘按键不得被记录为绑定');
  });

  testWidgets('stop button cancels capture; pick-list fallback stays available',
      (WidgetTester tester) async {
    final HibikiShortcutRegistry registry = buildRegistry();
    await pumpDialog(tester, registry);
    await startGamepadCapture(tester);

    await tester.tap(find.byKey(const Key('shortcut_stop_gamepad_capture')));
    await tester.pumpAndSettle();
    expect(find.text(t.shortcut_press_gamepad), findsNothing);

    // 兜底菜单仍在：无手柄在手也能从列表点选按钮。
    expect(find.text(t.shortcut_gamepad_pick_list), findsOneWidget);
    await tester.tap(find.text(t.shortcut_gamepad_pick_list));
    await tester.pumpAndSettle();
    // Select 排在菜单末尾，测试视口里可能在滚动区外——先滚到可见再点。
    await tester.ensureVisible(find.text(GamepadButton.select.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(GamepadButton.select.label).last);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(HibikiTagChip, GamepadButton.select.label),
      findsOneWidget,
    );
  });
}
