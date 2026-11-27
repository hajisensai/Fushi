import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:material_ui/material_ui.dart';

/// 应用内反馈 OElRvCndxk：全局快捷键「打开待发卡片」。用户拍板：进注册表、默认不绑键，
/// 不在播放器 / 阅读器工具栏常驻按钮。执行体与「呼出 AI 助手」同一个
/// [runGlobalCommandAction]：app 根的键盘 / Android 手柄键事件 / 鼠标，加上桌面手柄的
/// GamepadService 兜底（BUG-5556：桌面手柄按钮不是键事件，以前到不了 app 根）。
void main() {
  setUp(MouseBindingDispatch.resetForTest);
  tearDown(MouseBindingDispatch.resetForTest);

  test('动作登记在 global scope，持久化 key 稳定，三条通道都开', () {
    expect(ShortcutAction.globalOpenPendingCards.scope, ShortcutScope.global);
    expect(
      ShortcutAction.globalOpenPendingCards.key,
      'global_open_pending_cards',
    );
    expect(
      ShortcutAction.actionsForScope(ShortcutScope.global),
      contains(ShortcutAction.globalOpenPendingCards),
    );
    expect(
      ShortcutAction.globalOpenPendingCards.channels,
      ShortcutScope.global.channels,
    );
  });

  test('五个平台默认都不绑（用户自己绑）', () {
    for (final TargetPlatform platform in TargetPlatform.values) {
      final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
        platform,
      )[ShortcutAction.globalOpenPendingCards]!;
      expect(set.keyboardBindings, isEmpty, reason: '$platform');
      expect(set.gamepadBindings, isEmpty, reason: '$platform');
      expect(set.mouseBindings, isEmpty, reason: '$platform');
    }
  });

  FushiShortcutRegistry registryWith(ShortcutBindingSet bindings) =>
      FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows)
        ..updateBinding(ShortcutAction.globalOpenPendingCards, bindings);

  Future<GlobalKey<NavigatorState>> pumpApp(
    WidgetTester tester, {
    required FushiShortcutRegistry registry,
    required GlobalOpenPendingCards open,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Center(child: Text('home'))),
        builder: (BuildContext context, Widget? child) =>
            wrapWithGlobalNavigation(
              navigatorKey: navKey,
              registry: registry,
              focusNavigationEnabled: false,
              openPendingCards: open,
              child: child!,
            ),
      ),
    );
    await tester.pumpAndSettle();
    return navKey;
  }

  group('app 根（键盘 / 鼠标）', () {
    testWidgets('默认不绑：随便按都不打开', (WidgetTester tester) async {
      int calls = 0;
      await pumpApp(
        tester,
        registry: FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows),
        open: () {
          calls++;
          return true;
        },
      );
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.f8), isFalse);
      expect(calls, 0);
    });

    testWidgets('用户绑了键：按下打开并认领；执行面不认领时不吞键', (WidgetTester tester) async {
      int calls = 0;
      bool claim = true;
      await pumpApp(
        tester,
        registry: registryWith(
          const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(key: LogicalKeyboardKey.f8),
            ],
          ),
        ),
        open: () {
          calls++;
          return claim;
        },
      );
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.f8), isTrue);
      expect(calls, 1);
      claim = false;
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.f8), isFalse);
      expect(calls, 2);
    });

    testWidgets('绑在鼠标侧键上：按下打开', (WidgetTester tester) async {
      int calls = 0;
      await pumpApp(
        tester,
        registry: registryWith(
          const ShortcutBindingSet(
            mouseBindings: <MouseBinding>[MouseBinding(3)],
          ),
        ),
        open: () {
          calls++;
          return true;
        },
      );
      final Offset at = tester.getCenter(find.text('home'));
      final TestGesture gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      );
      await gesture.downWithCustomEvent(
        at,
        PointerDownEvent(
          position: at,
          kind: PointerDeviceKind.mouse,
          buttons: kBackMouseButton,
        ),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(calls, 1);
    });
  });

  testWidgets('桌面手柄：页面没消费的按钮绑到它时经 GamepadService 打开（BUG-5556）', (
    WidgetTester tester,
  ) async {
    int calls = 0;
    final FushiShortcutRegistry registry = registryWith(
      const ShortcutBindingSet(
        gamepadBindings: <GamepadBinding>[
          GamepadBinding(GamepadButton.thumbRight),
        ],
      ),
    );
    final GlobalKey<NavigatorState> navKey = await pumpApp(
      tester,
      registry: registry,
      open: () => false,
    );
    final GamepadService service = GamepadService(
      navigatorKey: navKey,
      registry: registry,
    );
    service.debugDispatchButton(GamepadButton.thumbRight);
    expect(calls, 0, reason: '没装执行面：跳过，不崩');

    service.runGlobalCommand = (ShortcutAction action) =>
        runGlobalCommandAction(
          action,
          openPendingCards: () {
            calls++;
            return true;
          },
        );
    service.debugDispatchButton(GamepadButton.thumbRight);
    expect(calls, 1);
    // 别的按钮不触发。
    service.debugDispatchButton(GamepadButton.thumbLeft);
    expect(calls, 1);
  });

  test('runGlobalCommandAction 只认领「直接做一件事」的动作', () {
    int pending = 0;
    int ai = 0;
    bool run(ShortcutAction action) => runGlobalCommandAction(
      action,
      openAiAssistant: () {
        ai++;
        return true;
      },
      openPendingCards: () {
        pending++;
        return true;
      },
    );
    expect(run(ShortcutAction.globalOpenPendingCards), isTrue);
    expect(run(ShortcutAction.globalOpenAiAssistant), isTrue);
    expect(run(ShortcutAction.globalScrollPageDown), isFalse);
    expect(run(ShortcutAction.globalBack), isFalse);
    expect((pending, ai), (1, 1));
    expect(
      runGlobalCommandAction(ShortcutAction.globalOpenPendingCards),
      isFalse,
      reason: '执行面没装：不认领',
    );
  });
}
