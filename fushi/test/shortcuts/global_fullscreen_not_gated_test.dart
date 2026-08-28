import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// BUG-1886 回归：窗口级全屏（默认 F11）不得被实验性焦点导航开关门控。
///
/// 根因与 BUG-1266（手柄分发 / 注册表 globalBack）完全同构：
/// [wrapWithGlobalNavigation] 里 `_handleGlobalToggleFullscreen` 的调用点曾整块压在
/// `if (focusNavigationEnabled)` 内，而 experimental_focus_navigation_enabled
/// **默认关闭**（preferences_repository.dart）——于是默认安装上按 F11 完全没反应，
/// 等于「快捷键设置里配了 F11，运行时却永不解析」。全屏改键是正式功能，与
/// 「方向键 / 摇杆移焦」这套实验能力无关，不该共用一个开关。
///
/// 断言的是 [KeyEventResult]：全局层认领 F11 即 handled。真正的窗口 toggle 走
/// WindowManager platform channel，widget 测试里没有实现，由执行体自己的 try/catch
/// 吞掉（见 global_navigation.dart 的 `_toggleWindowFullscreen`），不影响 handled 判定。
void main() {
  FushiShortcutRegistry desktopRegistry() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  Future<void> pumpApp(
    WidgetTester tester, {
    required FushiShortcutRegistry registry,
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
    await tester.pumpAndSettle();
  }

  group('BUG-1886：F11 不再挂在实验性焦点导航开关上', () {
    testWidgets('焦点导航关闭（默认安装）时 F11 仍被全局层认领',
        (WidgetTester tester) async {
      await pumpApp(
        tester,
        registry: desktopRegistry(),
        focusNavigationEnabled: false,
      );

      final bool handled = await tester.sendKeyEvent(LogicalKeyboardKey.f11);

      expect(
        handled,
        isTrue,
        reason: '默认安装（实验性焦点导航关闭）下按 F11 必须解析到 '
            'globalToggleFullscreen 并被消费；被门控吞掉时这里会是 false',
      );
    });

    testWidgets('焦点导航开启时 F11 照常认领（不回归）', (WidgetTester tester) async {
      await pumpApp(
        tester,
        registry: desktopRegistry(),
        focusNavigationEnabled: true,
      );

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.f11), isTrue);
    });

    testWidgets('改键后：全屏改绑 F10，焦点导航关闭时 F10 生效、F11 不再认领',
        (WidgetTester tester) async {
      final FushiShortcutRegistry registry = desktopRegistry()
        ..updateBinding(
          ShortcutAction.globalToggleFullscreen,
          const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(key: LogicalKeyboardKey.f10),
            ],
          ),
        );
      await pumpApp(
        tester,
        registry: registry,
        focusNavigationEnabled: false,
      );

      expect(
        await tester.sendKeyEvent(LogicalKeyboardKey.f10),
        isTrue,
        reason: '用户把全屏改绑到 F10，F10 就该生效',
      );
      expect(
        await tester.sendKeyEvent(LogicalKeyboardKey.f11),
        isFalse,
        reason: 'F11 已不是全屏键，全局层不该再认领它',
      );
    });
  });
}
