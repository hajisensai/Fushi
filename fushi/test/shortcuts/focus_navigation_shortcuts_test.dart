import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/shortcuts/focus_navigation_shortcuts.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/utils/components/fushi_focus_ring.dart';

/// 反馈 bjPjRHsaUy：焦点导航（上 / 下 / 左 / 右 / 确认）进快捷键体系。
///
/// 用户场景：带左右按钮、又把 ←/→ 用作「上一句 / 下一句」的界面里，方向键被句子
/// 导航占用，焦点没法左右移到两侧按钮；而焦点导航键此前是硬编码，设置里改不了。
///
/// 所有者拍板的语义（这里逐条钉死）：
///   * 页面 scope 优先——裸 → 在这种页面里**仍是**下一句（默认行为不变）；
///   * 用户给焦点导航加一枚页面没占用的备选键（Shift+→ / D）后，在同一页面里按它
///     焦点移到右侧按钮；
///   * 文本框持焦时 WASD 不被吞（照常交给输入框）；
///   * 「确认」可加备选键，裸 Enter 仍只激活一次（不与框架的 Enter 双重确认）。
void main() {
  Set<ModifierKey> pressedModifiers() {
    final HardwareKeyboard hw = HardwareKeyboard.instance;
    return <ModifierKey>{
      if (hw.isControlPressed) ModifierKey.ctrl,
      if (hw.isShiftPressed) ModifierKey.shift,
      if (hw.isAltPressed) ModifierKey.alt,
      if (hw.isMetaPressed) ModifierKey.meta,
    };
  }

  /// Windows 默认表 + 用户把「上一句 / 下一句」改绑成裸 ←/→（反馈里的形态）。
  FushiShortcutRegistry sentenceArrowRegistry() {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    registry
      ..updateBinding(
        ShortcutAction.audiobookNextSentence,
        const ShortcutBindingSet(
          keyboardBindings: <InputBinding>[
            InputBinding(key: LogicalKeyboardKey.arrowRight),
          ],
        ),
      )
      ..updateBinding(
        ShortcutAction.audiobookPrevSentence,
        const ShortcutBindingSet(
          keyboardBindings: <InputBinding>[
            InputBinding(key: LogicalKeyboardKey.arrowLeft),
          ],
        ),
      );
    return registry;
  }

  /// 一个「句子导航」页面：页面根的 [Focus] 按 audiobook scope 解析按键（与阅读器
  /// 页 `_handleKeyEvent` 同构——页面先解析、命中即消费），子树是一排三个按钮
  /// （上一句 / 播放 / 下一句）。app 根挂 [wrapWithGlobalNavigation]。
  Future<
    ({
      List<FocusNode> buttons,
      List<String> sentenceLog,
      List<String> pressed,
      FocusNode fieldNode,
      TextEditingController field,
    })
  >
  pumpSentencePage(
    WidgetTester tester,
    FushiShortcutRegistry registry, {
    required bool focusNavigationEnabled,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final List<FocusNode> buttons = <FocusNode>[
      FocusNode(debugLabel: 'prev'),
      FocusNode(debugLabel: 'play'),
      FocusNode(debugLabel: 'next'),
    ];
    final FocusNode fieldNode = FocusNode(debugLabel: 'field');
    final TextEditingController field = TextEditingController();
    addTearDown(() {
      for (final FocusNode node in buttons) {
        node.dispose();
      }
      fieldNode.dispose();
      field.dispose();
    });
    final List<String> sentenceLog = <String>[];
    final List<String> pressed = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: FushiFocusRoot(
          child: FushiFocusRing(
            child: wrapWithGlobalNavigation(
              navigatorKey: navKey,
              registry: registry,
              focusNavigationEnabled: focusNavigationEnabled,
              child: Scaffold(
                body: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: (FocusNode node, KeyEvent event) {
                    if (event is! KeyDownEvent) return KeyEventResult.ignored;
                    final ShortcutAction? action = registry.resolveKeyboard(
                      event.logicalKey,
                      modifiers: pressedModifiers(),
                      scope: ShortcutScope.audiobook,
                    );
                    if (action == ShortcutAction.audiobookNextSentence) {
                      sentenceLog.add('next');
                      return KeyEventResult.handled;
                    }
                    if (action == ShortcutAction.audiobookPrevSentence) {
                      sentenceLog.add('prev');
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Column(
                    children: <Widget>[
                      SizedBox(
                        width: 400,
                        child: TextField(
                          focusNode: fieldNode,
                          controller: field,
                        ),
                      ),
                      const SizedBox(height: 80),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          for (final (int i, String label) in <(int, String)>[
                            (0, 'prev'),
                            (1, 'play'),
                            (2, 'next'),
                          ])
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: TextButton(
                                focusNode: buttons[i],
                                onPressed: () => pressed.add(label),
                                child: Text(label),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (
      buttons: buttons,
      sentenceLog: sentenceLog,
      pressed: pressed,
      fieldNode: fieldNode,
      field: field,
    );
  }

  Future<bool> pressShift(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final bool handled = await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    return handled;
  }

  for (final bool focusNavigationEnabled in <bool>[false, true]) {
    final String mode = focusNavigationEnabled ? '实验焦点导航开' : '默认安装（实验焦点导航关）';

    testWidgets('$mode：Shift+→ 备选键在句子导航页里移焦，裸 → 仍是下一句', (
      WidgetTester tester,
    ) async {
      final FushiShortcutRegistry registry = sentenceArrowRegistry();
      setFocusNavigationPreset(
        registry,
        FocusNavigationPreset.shiftArrows,
        enabled: true,
      );
      final page = await pumpSentencePage(
        tester,
        registry,
        focusNavigationEnabled: focusNavigationEnabled,
      );
      page.buttons[1].requestFocus();
      await tester.pump();
      expect(page.buttons[1].hasPrimaryFocus, isTrue);

      expect(await pressShift(tester, LogicalKeyboardKey.arrowRight), isTrue);
      expect(
        page.buttons[2].hasPrimaryFocus,
        isTrue,
        reason: 'Shift+→ 绑在「焦点右移」上：页面没占用它，落到焦点导航，移到右侧按钮',
      );
      expect(page.sentenceLog, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(page.sentenceLog, <String>[
        'next',
      ], reason: '裸 → 在本页是「下一句」：页面 scope 优先，默认行为不变');
      expect(page.buttons[2].hasPrimaryFocus, isTrue, reason: '下一句不动焦点');

      expect(await pressShift(tester, LogicalKeyboardKey.arrowLeft), isTrue);
      expect(await pressShift(tester, LogicalKeyboardKey.arrowLeft), isTrue);
      expect(page.buttons[0].hasPrimaryFocus, isTrue);
      expect(page.sentenceLog, <String>['next']);
    });
  }

  testWidgets('未开预设时 Shift+→ 不移焦（默认绑定行为不变）', (WidgetTester tester) async {
    final page = await pumpSentencePage(
      tester,
      sentenceArrowRegistry(),
      focusNavigationEnabled: true,
    );
    page.buttons[1].requestFocus();
    await tester.pump();

    expect(await pressShift(tester, LogicalKeyboardKey.arrowRight), isFalse);
    expect(page.buttons[1].hasPrimaryFocus, isTrue);
    expect(page.sentenceLog, isEmpty);
  });

  testWidgets('WASD 预设：按钮持焦时 D 右移焦点；文本框持焦时 W/A/S/D 不被吞', (
    WidgetTester tester,
  ) async {
    final FushiShortcutRegistry registry = sentenceArrowRegistry();
    setFocusNavigationPreset(
      registry,
      FocusNavigationPreset.wasd,
      enabled: true,
    );
    final page = await pumpSentencePage(
      tester,
      registry,
      focusNavigationEnabled: false,
    );

    page.buttons[0].requestFocus();
    await tester.pump();
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyD), isTrue);
    await tester.pump();
    expect(page.buttons[1].hasPrimaryFocus, isTrue);

    page.fieldNode.requestFocus();
    await tester.pump();
    for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyD,
    ]) {
      expect(
        await tester.sendKeyEvent(key),
        isFalse,
        reason: '文本框持焦：${key.keyLabel} 必须放行给输入框打字，不能被焦点导航吞掉',
      );
      await tester.pump();
      expect(page.fieldNode.hasPrimaryFocus, isTrue);
    }
    // Shift+方向键在文本框里是扩选，同样放行（Shift+← 不是 WASD 预设，但
    // 同一条「文本框持焦一律放行」判据）。
    setFocusNavigationPreset(
      registry,
      FocusNavigationPreset.shiftArrows,
      enabled: true,
    );
    page.field.value = const TextEditingValue(
      text: 'abc',
      selection: TextSelection.collapsed(offset: 3),
    );
    await tester.pump();
    await pressShift(tester, LogicalKeyboardKey.arrowLeft);
    expect(page.fieldNode.hasPrimaryFocus, isTrue);
    expect(
      page.field.selection,
      const TextSelection(baseOffset: 3, extentOffset: 2),
      reason: 'Shift+← 归文本框扩选，焦点导航不得抢走',
    );
  });

  testWidgets('确认可加备选键；裸 Enter 仍只激活一次', (WidgetTester tester) async {
    final FushiShortcutRegistry registry = sentenceArrowRegistry();
    registry.updateBinding(
      ShortcutAction.focusActivate,
      registry
          .bindingsFor(ShortcutAction.focusActivate)
          .copyWith(
            keyboardBindings: <InputBinding>[
              ...registry
                  .bindingsFor(ShortcutAction.focusActivate)
                  .keyboardBindings,
              const InputBinding(key: LogicalKeyboardKey.keyQ),
            ],
          ),
    );
    final page = await pumpSentencePage(
      tester,
      registry,
      focusNavigationEnabled: false,
    );
    page.buttons[2].requestFocus();
    await tester.pump();

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyQ), isTrue);
    await tester.pump();
    expect(page.pressed, <String>['next']);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(page.pressed, <String>['next', 'next'], reason: 'Enter 只激活一次');

    // 文本框持焦时 Q 是打字，不触发确认。
    page.fieldNode.requestFocus();
    await tester.pump();
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyQ), isFalse);
    expect(page.pressed, <String>['next', 'next']);
  });

  group('默认表 / 预设 / 迁移', () {
    test('焦点导航默认 = 改造前的硬编码键（行为不变），且开放键盘 + 手柄通道', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      expect(ShortcutScope.gamepad.channels, <ShortcutChannel>{
        ShortcutChannel.keyboard,
        ShortcutChannel.gamepad,
      });
      final Map<ShortcutAction, (LogicalKeyboardKey, GamepadButton)> expected =
          <ShortcutAction, (LogicalKeyboardKey, GamepadButton)>{
            ShortcutAction.dpadUp: (
              LogicalKeyboardKey.arrowUp,
              GamepadButton.dpadUp,
            ),
            ShortcutAction.dpadDown: (
              LogicalKeyboardKey.arrowDown,
              GamepadButton.dpadDown,
            ),
            ShortcutAction.dpadLeft: (
              LogicalKeyboardKey.arrowLeft,
              GamepadButton.dpadLeft,
            ),
            ShortcutAction.dpadRight: (
              LogicalKeyboardKey.arrowRight,
              GamepadButton.dpadRight,
            ),
            ShortcutAction.focusActivate: (
              LogicalKeyboardKey.enter,
              GamepadButton.a,
            ),
          };
      for (final MapEntry<ShortcutAction, (LogicalKeyboardKey, GamepadButton)>
          entry
          in expected.entries) {
        final ShortcutBindingSet set = registry.bindingsFor(entry.key);
        expect(set.keyboardBindings, <InputBinding>[
          InputBinding(key: entry.value.$1),
        ], reason: entry.key.name);
        expect(set.gamepadBindings, <GamepadBinding>[
          GamepadBinding(entry.value.$2),
        ], reason: entry.key.name);
      }
      for (final FocusNavigationPreset preset in FocusNavigationPreset.values) {
        expect(
          isFocusNavigationPresetEnabled(registry, preset),
          isFalse,
          reason: '${preset.name} 预设默认关闭',
        );
      }
    });

    test('预设开 / 关只增删自己那几枚键，同组冲突键从别的焦点动作上摘掉', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      // 用户先把 W 绑给了「确认」——WASD 预设打开时 W 归「焦点上移」。
      registry.updateBinding(
        ShortcutAction.focusActivate,
        const ShortcutBindingSet(
          keyboardBindings: <InputBinding>[
            InputBinding(key: LogicalKeyboardKey.enter),
            InputBinding(key: LogicalKeyboardKey.keyW),
          ],
        ),
      );
      setFocusNavigationPreset(
        registry,
        FocusNavigationPreset.wasd,
        enabled: true,
      );
      expect(
        isFocusNavigationPresetEnabled(registry, FocusNavigationPreset.wasd),
        isTrue,
      );
      expect(
        registry.bindingsFor(ShortcutAction.dpadUp).keyboardBindings,
        const <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.arrowUp),
          InputBinding(key: LogicalKeyboardKey.keyW),
        ],
      );
      expect(
        registry.bindingsFor(ShortcutAction.focusActivate).keyboardBindings,
        const <InputBinding>[InputBinding(key: LogicalKeyboardKey.enter)],
      );
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.keyD,
          modifiers: const <ModifierKey>{},
          scope: ShortcutScope.gamepad,
        ),
        ShortcutAction.dpadRight,
      );

      setFocusNavigationPreset(
        registry,
        FocusNavigationPreset.wasd,
        enabled: false,
      );
      expect(
        isFocusNavigationPresetEnabled(registry, FocusNavigationPreset.wasd),
        isFalse,
      );
      expect(
        registry.bindingsFor(ShortcutAction.dpadUp).keyboardBindings,
        const <InputBinding>[InputBinding(key: LogicalKeyboardKey.arrowUp)],
        reason: '关闭只移除预设键，方向键原样保留',
      );
    });

    test('v14 快照迁移：焦点四向补上方向键，用户改过的手柄 dpad 原样保留', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      final Map<String, dynamic> snapshot = <String, dynamic>{
        kShortcutSchemaVersionKey: 14,
        ShortcutAction.dpadUp.key: const ShortcutBindingSet(
          gamepadBindings: <GamepadBinding>[
            GamepadBinding(GamepadButton.dpadUp),
          ],
        ).toJson(),
        // 用户把「左」改绑到了 LT（v14 时代唯一能改的通道）。
        ShortcutAction.dpadLeft.key: const ShortcutBindingSet(
          gamepadBindings: <GamepadBinding>[GamepadBinding(GamepadButton.lt)],
        ).toJson(),
      };
      registry.loadFromJsonString(jsonEncode(snapshot), TargetPlatform.windows);

      expect(
        registry.bindingsFor(ShortcutAction.dpadUp).keyboardBindings,
        const <InputBinding>[InputBinding(key: LogicalKeyboardKey.arrowUp)],
      );
      final ShortcutBindingSet left = registry.bindingsFor(
        ShortcutAction.dpadLeft,
      );
      expect(left.keyboardBindings, const <InputBinding>[
        InputBinding(key: LogicalKeyboardKey.arrowLeft),
      ]);
      expect(left.gamepadBindings, const <GamepadBinding>[
        GamepadBinding(GamepadButton.lt),
      ]);
      expect(
        registry.bindingsFor(ShortcutAction.focusActivate).gamepadBindings,
        const <GamepadBinding>[GamepadBinding(GamepadButton.a)],
        reason: '全新 action 由 loadDefaults 播种',
      );
    });

    test('动作 → 方向映射', () {
      expect(
        focusNavigationDirectionOf(ShortcutAction.dpadUp),
        TraversalDirection.up,
      );
      expect(
        focusNavigationDirectionOf(ShortcutAction.dpadRight),
        TraversalDirection.right,
      );
      expect(focusNavigationDirectionOf(ShortcutAction.focusActivate), isNull);
      expect(focusNavigationDirectionOf(null), isNull);
    });
  });
}
