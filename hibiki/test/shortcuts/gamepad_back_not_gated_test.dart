import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// BUG-1266 回归：手柄「返回」必须完全由快捷键注册表决定。
///
/// 两个根因各一组断言：
///  1. 手柄按钮分发曾整块压在 [wrapWithGlobalNavigation] 的 `focusNavigationEnabled`
///     门控里，而该开关（experimental_focus_navigation_enabled）**默认关闭**——于是
///     默认安装上注册表 globalBack 根本不参与解析。
///  2. 没人认领的手柄 B 会被 Android 的 `Generic.kcm`（`BUTTON_B` → `fallback BACK`）
///     合成成一个 KEYCODE_BACK，绕过注册表直接退页；用户把「返回」改绑到 RB 后 B
///     依旧返回，正是这条系统兜底路径。
void main() {
  KeyDownEvent keyDown(
    LogicalKeyboardKey key, [
    ui.KeyEventDeviceType deviceType = ui.KeyEventDeviceType.keyboard,
  ]) =>
      KeyDownEvent(
        physicalKey: const PhysicalKeyboardKey(0),
        logicalKey: key,
        timeStamp: Duration.zero,
        deviceType: deviceType,
      );

  KeyUpEvent keyUp(LogicalKeyboardKey key) => KeyUpEvent(
        physicalKey: const PhysicalKeyboardKey(0),
        logicalKey: key,
        timeStamp: Duration.zero,
      );

  HibikiShortcutRegistry registryWithBackOn(GamepadButton button) {
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
      ..loadDefaults(TargetPlatform.android)
      ..updateBinding(
        ShortcutAction.globalBack,
        ShortcutBindingSet(
          gamepadBindings: <GamepadBinding>[GamepadBinding(button)],
        ),
      );
    return registry;
  }

  /// 建一棵「首页 + 已 push 的第二页」，全局导航层按 [focusNavigationEnabled] 挂载。
  Future<GlobalKey<NavigatorState>> pumpTwoRoutes(
    WidgetTester tester, {
    required HibikiShortcutRegistry registry,
    required bool focusNavigationEnabled,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('home')),
      builder: (BuildContext context, Widget? child) =>
          wrapWithGlobalNavigation(
        navigatorKey: navKey,
        registry: registry,
        focusNavigationEnabled: focusNavigationEnabled,
        child: child!,
      ),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('second')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
    return navKey;
  }

  group('根因1：手柄绑定不再被实验性焦点导航开关吞掉', () {
    testWidgets('焦点导航关闭（默认安装）时，B 绑 globalBack 仍能返回',
        (WidgetTester tester) async {
      await pumpTwoRoutes(
        tester,
        registry: registryWithBackOn(GamepadButton.b),
        focusNavigationEnabled: false,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      await tester.pumpAndSettle();

      expect(
        find.text('second'),
        findsNothing,
        reason: '默认安装（焦点导航关闭）下 B 也必须经注册表 globalBack 返回',
      );
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('焦点导航关闭时，改绑到 RB 后按 RB 返回', (WidgetTester tester) async {
      await pumpTwoRoutes(
        tester,
        registry: registryWithBackOn(GamepadButton.rb),
        focusNavigationEnabled: false,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await tester.pumpAndSettle();

      expect(
        find.text('second'),
        findsNothing,
        reason: '用户把「返回」改绑到 RB，RB 就该返回',
      );
    });
  });

  group('根因2：改绑走的 B 不再有第二条隐形返回路径', () {
    testWidgets('返回改绑 RB 后，按 B 绝不返回', (WidgetTester tester) async {
      await pumpTwoRoutes(
        tester,
        registry: registryWithBackOn(GamepadButton.rb),
        focusNavigationEnabled: false,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      await tester.pumpAndSettle();

      expect(
        find.text('second'),
        findsOneWidget,
        reason: 'B 已不是返回键，按它必须留在当前页',
      );
    });

    testWidgets('未绑定的 B 被就地消费（不放行给 Android 的 BACK 兜底）',
        (WidgetTester tester) async {
      await pumpTwoRoutes(
        tester,
        registry: registryWithBackOn(GamepadButton.rb),
        focusNavigationEnabled: false,
      );

      final bool handled =
          await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);

      expect(
        handled,
        isTrue,
        reason: 'B 未被任何处理器认领时必须由全局层吞掉，'
            '否则 Android 会合成 KEYCODE_BACK 绕过注册表退页',
      );
    });
  });

  group('吞键边界：只吞 B，其余通道原样放行', () {
    test('B 的三个边沿都吞（返回动作发生在抬起边沿，只吞按下等于没修）', () {
      expect(
        gamepadBackMustBeSwallowed(keyDown(LogicalKeyboardKey.gameButtonB)),
        isTrue,
      );
      expect(
        gamepadBackMustBeSwallowed(keyUp(LogicalKeyboardKey.gameButtonB)),
        isTrue,
        reason: 'Android 的返回发生在 ACTION_UP，抬起边沿放行会照样合成出 BACK',
      );
      expect(
        gamepadBackMustBeSwallowed(
          KeyRepeatEvent(
            physicalKey: const PhysicalKeyboardKey(0),
            logicalKey: LogicalKeyboardKey.gameButtonB,
            timeStamp: Duration.zero,
          ),
        ),
        isTrue,
      );
    });

    test('A 不吞：它的系统兜底是 DPAD_CENTER（确认焦点控件），是有益能力', () {
      expect(
        gamepadBackMustBeSwallowed(keyDown(LogicalKeyboardKey.gameButtonA)),
        isFalse,
      );
    });

    test('手柄来源的 D-pad 不吞：仍须放行给方向焦点移动', () {
      for (final ui.KeyEventDeviceType source in <ui.KeyEventDeviceType>[
        ui.KeyEventDeviceType.gamepad,
        ui.KeyEventDeviceType.directionalPad,
        ui.KeyEventDeviceType.joystick,
      ]) {
        for (final LogicalKeyboardKey arrow in <LogicalKeyboardKey>[
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ]) {
          expect(
            gamepadBackMustBeSwallowed(keyDown(arrow, source)),
            isFalse,
            reason: '$source 的 $arrow 被吞会废掉手柄方向键移焦',
          );
        }
      }
    });

    test('键盘键一律不吞（含方向键与 Escape）', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.keyB,
      ]) {
        expect(gamepadBackMustBeSwallowed(keyDown(key)), isFalse);
      }
    });

    test('其它手柄键不吞（Generic.kcm 里它们没有 BACK 兜底）', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.gameButtonX,
        LogicalKeyboardKey.gameButtonY,
        LogicalKeyboardKey.gameButtonLeft1,
        LogicalKeyboardKey.gameButtonRight1,
        LogicalKeyboardKey.gameButtonStart,
        LogicalKeyboardKey.gameButtonSelect,
      ]) {
        expect(gamepadBackMustBeSwallowed(keyDown(key)), isFalse);
      }
    });
  });
}
