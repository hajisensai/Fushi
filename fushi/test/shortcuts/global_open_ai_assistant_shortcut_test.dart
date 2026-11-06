import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:material_ui/material_ui.dart';

/// 全局快捷键「呼出 AI 助手」（spec `2026-10-26-ai-operations-agent-design.md`
/// D4 ②）：global scope、桌面 Ctrl+J / macOS ⌘J、手柄留空；app 根认领后交给注入
/// 的执行面，执行面不认领（AI 模块关着）时按键照常冒泡。
void main() {
  const InputBinding ctrlJ = InputBinding(
    key: LogicalKeyboardKey.keyJ,
    modifiers: <ModifierKey>{ModifierKey.ctrl},
  );
  const InputBinding cmdJ = InputBinding(
    key: LogicalKeyboardKey.keyJ,
    modifiers: <ModifierKey>{ModifierKey.meta},
  );

  test('动作登记在 global scope，持久化 key 稳定，设置页按 scope 列出', () {
    expect(ShortcutAction.globalOpenAiAssistant.scope, ShortcutScope.global);
    expect(
      ShortcutAction.globalOpenAiAssistant.key,
      'global_open_ai_assistant',
    );
    expect(
      ShortcutAction.actionsForScope(ShortcutScope.global),
      contains(ShortcutAction.globalOpenAiAssistant),
    );
    expect(
      ShortcutAction.globalOpenAiAssistant.channels,
      ShortcutScope.global.channels,
      reason: '键盘 / 手柄 / 鼠标三条通道在 app 根都有执行体',
    );
  });

  group('默认绑定', () {
    test('Windows / Linux：Ctrl+J，手柄留空', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
          platform,
        )[ShortcutAction.globalOpenAiAssistant]!;
        expect(set.keyboardBindings, const <InputBinding>[ctrlJ]);
        expect(set.gamepadBindings, isEmpty);
      }
    });

    test('macOS：⌘J（Ctrl→Meta）', () {
      final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
        TargetPlatform.macOS,
      )[ShortcutAction.globalOpenAiAssistant]!;
      expect(set.keyboardBindings, const <InputBinding>[cmdJ]);
      expect(set.gamepadBindings, isEmpty);
    });

    test('移动端不给键盘 / 手柄默认（global scope 在移动端只留鼠标）', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
          platform,
        )[ShortcutAction.globalOpenAiAssistant]!;
        expect(set.keyboardBindings, isEmpty);
        expect(set.gamepadBindings, isEmpty);
      }
    });

    // 阅读器 / 漫画 / 视频页先解析自己的 scope，同键会在页面里被吃掉、到不了
    // app 根；app 外查词热键走 OS 级 RegisterHotKey，同键会被系统截走。所以默认键
    // 不只核 home+global 同组，而是核**全部** scope 的默认表。
    test('默认键在全部 scope 的桌面 / macOS 默认表里都没有被别的动作占用', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        final Map<ShortcutAction, ShortcutBindingSet> defaults =
            ShortcutDefaults.forPlatform(platform);
        final List<InputBinding> mine =
            defaults[ShortcutAction.globalOpenAiAssistant]!.keyboardBindings;
        expect(mine, isNotEmpty);
        final List<String> clashes = <String>[
          for (final MapEntry<ShortcutAction, ShortcutBindingSet> entry
              in defaults.entries)
            if (entry.key != ShortcutAction.globalOpenAiAssistant)
              for (final InputBinding binding in entry.value.keyboardBindings)
                if (mine.contains(binding)) '${platform.name}:${entry.key.key}',
        ];
        expect(clashes, isEmpty, reason: '默认键撞了别的动作：$clashes');
      }
    });

    test('注册表冲突检测（同 co-active 组）也查不出冲突', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.keyJ,
          modifiers: <ModifierKey>{ModifierKey.ctrl},
          scope: ShortcutScope.global,
        ),
        ShortcutAction.globalOpenAiAssistant,
      );
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.keyJ,
          modifiers: <ModifierKey>{ModifierKey.ctrl},
          scope: ShortcutScope.home,
        ),
        isNull,
        reason: 'home 页先解析 home scope，Ctrl+J 不能被首页动作截走',
      );
    });
  });

  group('app 根执行', () {
    Future<void> pumpApp(
      WidgetTester tester, {
      required GlobalOpenAiAssistant? open,
      FushiShortcutRegistry? registry,
    }) async {
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Text('home')),
          builder: (BuildContext context, Widget? child) =>
              wrapWithGlobalNavigation(
                navigatorKey: navKey,
                registry:
                    registry ??
                    (FushiShortcutRegistry()
                      ..loadDefaults(TargetPlatform.windows)),
                focusNavigationEnabled: false,
                openAiAssistant: open,
                child: child!,
              ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<bool> pressCtrlJ(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final bool handled = await tester.sendKeyDownEvent(
        LogicalKeyboardKey.keyJ,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      return handled;
    }

    testWidgets('Ctrl+J 交给执行面并被认领（实验性焦点导航关闭的默认安装）', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      await pumpApp(
        tester,
        open: () {
          calls++;
          return true;
        },
      );
      expect(await pressCtrlJ(tester), isTrue);
      expect(calls, 1);
    });

    testWidgets('执行面不认领（AI 模块关着）时按键不被吞', (WidgetTester tester) async {
      int calls = 0;
      await pumpApp(
        tester,
        open: () {
          calls++;
          return false;
        },
      );
      expect(await pressCtrlJ(tester), isFalse);
      expect(calls, 1);
    });

    testWidgets('改绑后旧键不再触发', (WidgetTester tester) async {
      int calls = 0;
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows)
        ..updateBinding(
          ShortcutAction.globalOpenAiAssistant,
          const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(key: LogicalKeyboardKey.f8),
            ],
          ),
        );
      await pumpApp(
        tester,
        registry: registry,
        open: () {
          calls++;
          return true;
        },
      );
      expect(await pressCtrlJ(tester), isFalse);
      expect(calls, 0);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.f8), isTrue);
      expect(calls, 1);
    });
  });
}
