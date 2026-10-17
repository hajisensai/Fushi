import 'dart:convert';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// BUG-2948：macOS 上快捷键「无法识别」。
///
/// ① Shift+符号键的逻辑键在 macOS 上是**该修饰下产出的字符**（Mac 真机 NSEvent 实测：
///    Shift+/ → `question`，Shift+[ → `braceLeft`），Windows 同一按键是
///    `slash` / `bracketLeft`。录入、注册表解析、`toActivator` 三处必须按物理键收拢
///    回表内键，且存量 `#<keyId>` 绑定仍按原键精确命中。
/// ② macOS 默认里被系统先截走的两个键（Cmd+Space = Spotlight、F11 = 显示桌面）换成
///    Option+Space / Ctrl+Cmd+F，老用户没改过的旧默认经 v13 迁移换过来。
void main() {
  const InputBinding shiftSlash = InputBinding(
    key: LogicalKeyboardKey.slash,
    modifiers: <ModifierKey>{ModifierKey.shift},
  );

  group('normalizeCapturedKey 收拢表外逻辑键', () {
    test('macOS Shift+/ 的 question 收拢成 slash', () {
      expect(
        InputBinding.normalizeCapturedKey(
          logicalKey: LogicalKeyboardKey.question,
          physicalKey: PhysicalKeyboardKey.slash,
        ),
        LogicalKeyboardKey.slash,
      );
      expect(
        InputBinding.normalizeCapturedKey(
          logicalKey: LogicalKeyboardKey.braceLeft,
          physicalKey: PhysicalKeyboardKey.bracketLeft,
        ),
        LogicalKeyboardKey.bracketLeft,
      );
      expect(
        InputBinding.normalizeCapturedKey(
          // Shift+' 产出 "（Flutter 里叫 `quote`）；单引号键本身是 `quoteSingle`。
          logicalKey: LogicalKeyboardKey.quote,
          physicalKey: PhysicalKeyboardKey.quote,
        ),
        LogicalKeyboardKey.quoteSingle,
      );
    });

    test('表内逻辑键原样返回，布局的字母语义不被物理位覆盖', () {
      // AZERTY：物理 Q 位上是 A。
      expect(
        InputBinding.normalizeCapturedKey(
          logicalKey: LogicalKeyboardKey.keyA,
          physicalKey: PhysicalKeyboardKey.keyQ,
        ),
        LogicalKeyboardKey.keyA,
      );
    });

    test('物理键不在覆盖表里时原样返回，不猜', () {
      expect(
        InputBinding.normalizeCapturedKey(
          logicalKey: LogicalKeyboardKey.numpadAdd,
          physicalKey: PhysicalKeyboardKey.numpadAdd,
        ),
        LogicalKeyboardKey.numpadAdd,
      );
    });

    test('Quote / Backslash 有可读名，与 DOM code 同名', () {
      const InputBinding quote =
          InputBinding(key: LogicalKeyboardKey.quoteSingle);
      const InputBinding backslash =
          InputBinding(key: LogicalKeyboardKey.backslash);
      expect(quote.serialize(), 'Quote');
      expect(backslash.serialize(), 'Backslash');
      // 老快照里存成 #<keyId> 的同一个键照样读回同一个绑定。
      expect(
          InputBinding.deserialize('#${LogicalKeyboardKey.quoteSingle.keyId}'),
          quote);
      expect(InputBinding.deserialize('Quote'), quote);
    });
  });

  group('resolveKeyboard', () {
    FushiShortcutRegistry registryWith(InputBinding binding) {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.macOS);
      registry.updateBinding(
        ShortcutAction.readerToggleChrome,
        ShortcutBindingSet(keyboardBindings: <InputBinding>[binding]),
      );
      return registry;
    }

    test('macOS 事件 question+物理 slash 命中 Shift+Slash 绑定', () {
      final FushiShortcutRegistry registry = registryWith(shiftSlash);
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.question,
          modifiers: <ModifierKey>{ModifierKey.shift},
          scope: ShortcutScope.reader,
          physicalKey: PhysicalKeyboardKey.slash,
        ),
        ShortcutAction.readerToggleChrome,
      );
      // 文本框 composing 时调用方传 null：不回退。
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.question,
          modifiers: <ModifierKey>{ModifierKey.shift},
          scope: ShortcutScope.reader,
        ),
        isNull,
      );
    });

    test('存量 #<keyId> 绑定仍按原逻辑键精确命中', () {
      final FushiShortcutRegistry registry = registryWith(
        InputBinding.deserialize(
          'Shift+#${LogicalKeyboardKey.question.keyId}',
        )!,
      );
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.question,
          modifiers: <ModifierKey>{ModifierKey.shift},
          scope: ShortcutScope.reader,
          physicalKey: PhysicalKeyboardKey.slash,
        ),
        ShortcutAction.readerToggleChrome,
      );
    });
  });

  testWidgets('toActivator 认 macOS 的 Shift+/（question）', (
    WidgetTester tester,
  ) async {
    final InputBindingActivator activator = shiftSlash.toActivator();
    // 测试事件模拟器的平台键表里没有 `question`，故直接构造 macOS 嵌入层实际发出的
    // 事件（Mac 真机 NSEvent 实测：logical=question、physical=slash）喂给 activator；
    // 修饰键状态走真实 HardwareKeyboard。
    const KeyDownEvent macShiftSlash = KeyDownEvent(
      logicalKey: LogicalKeyboardKey.question,
      physicalKey: PhysicalKeyboardKey.slash,
      character: '?',
      timeStamp: Duration.zero,
    );
    const KeyDownEvent winShiftSlash = KeyDownEvent(
      logicalKey: LogicalKeyboardKey.slash,
      physicalKey: PhysicalKeyboardKey.slash,
      character: '?',
      timeStamp: Duration.zero,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    expect(activator.accepts(macShiftSlash, HardwareKeyboard.instance), isTrue,
        reason: 'macOS 上 Shift+/ 的逻辑键是 question，必须仍触发');
    expect(activator.accepts(winShiftSlash, HardwareKeyboard.instance), isTrue,
        reason: 'Windows 形态（逻辑键就是 slash）照旧');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    // 修饰键不符不触发：没按 Shift 的同一事件不是 Shift+/。
    expect(
        activator.accepts(macShiftSlash, HardwareKeyboard.instance), isFalse);
    // 抬起沿不触发。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    expect(
      activator.accepts(
        const KeyUpEvent(
          logicalKey: LogicalKeyboardKey.question,
          physicalKey: PhysicalKeyboardKey.slash,
          timeStamp: Duration.zero,
        ),
        HardwareKeyboard.instance,
      ),
      isFalse,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  });

  group('macOS 默认避开系统保留键', () {
    final Map<ShortcutAction, ShortcutBindingSet> mac =
        ShortcutDefaults.forPlatform(TargetPlatform.macOS);
    final Map<ShortcutAction, ShortcutBindingSet> win =
        ShortcutDefaults.forPlatform(TargetPlatform.windows);

    test('有声书播放/暂停 = Option+Space，全屏 = Ctrl+Cmd+F', () {
      expect(
          mac[ShortcutAction.audiobookPlayPause]!.keyboardBindings,
          const <InputBinding>[
            InputBinding(
              key: LogicalKeyboardKey.space,
              modifiers: <ModifierKey>{ModifierKey.alt},
            ),
          ]);
      expect(
          mac[ShortcutAction.globalToggleFullscreen]!.keyboardBindings,
          const <InputBinding>[
            InputBinding(
              key: LogicalKeyboardKey.keyF,
              modifiers: <ModifierKey>{ModifierKey.ctrl, ModifierKey.meta},
            ),
          ]);
      // 手柄通道照桌面默认。
      expect(mac[ShortcutAction.audiobookPlayPause]!.gamepadBindings,
          win[ShortcutAction.audiobookPlayPause]!.gamepadBindings);
    });

    test('macOS 默认里没有 Cmd+Space / Ctrl+Space / F11', () {
      const List<InputBinding> reserved = <InputBinding>[
        InputBinding(
          key: LogicalKeyboardKey.space,
          modifiers: <ModifierKey>{ModifierKey.meta},
        ),
        InputBinding(
          key: LogicalKeyboardKey.space,
          modifiers: <ModifierKey>{ModifierKey.ctrl},
        ),
        InputBinding(key: LogicalKeyboardKey.f11),
      ];
      for (final MapEntry<ShortcutAction, ShortcutBindingSet> e
          in mac.entries) {
        for (final InputBinding b in e.value.keyboardBindings) {
          expect(reserved, isNot(contains(b)), reason: '${e.key.key} = $b');
        }
      }
    });

    test('其它平台默认不变', () {
      expect(
          win[ShortcutAction.audiobookPlayPause]!.keyboardBindings,
          const <InputBinding>[
            InputBinding(
              key: LogicalKeyboardKey.space,
              modifiers: <ModifierKey>{ModifierKey.ctrl},
            ),
          ]);
      expect(win[ShortcutAction.globalToggleFullscreen]!.keyboardBindings,
          const <InputBinding>[InputBinding(key: LogicalKeyboardKey.f11)]);
    });
  });

  group('v13 迁移', () {
    String v12Snapshot({
      required List<InputBinding> playPause,
      required List<InputBinding> fullscreen,
    }) {
      return jsonEncode(<String, dynamic>{
        kShortcutSchemaVersionKey: 12,
        ShortcutAction.audiobookPlayPause.key: ShortcutBindingSet(
          keyboardBindings: playPause,
          // 用户改过的手柄键：迁移不得抹掉。
          gamepadBindings: const <GamepadBinding>[
            GamepadBinding(GamepadButton.start),
          ],
        ).toJson(),
        ShortcutAction.globalToggleFullscreen.key: ShortcutBindingSet(
          keyboardBindings: fullscreen,
        ).toJson(),
      });
    }

    const InputBinding cmdSpace = InputBinding(
      key: LogicalKeyboardKey.space,
      modifiers: <ModifierKey>{ModifierKey.meta},
    );
    const InputBinding f11 = InputBinding(key: LogicalKeyboardKey.f11);

    test('macOS 没改过的旧默认换成新默认，只换键盘', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadFromJsonString(
          v12Snapshot(
            playPause: const <InputBinding>[cmdSpace],
            fullscreen: const <InputBinding>[f11],
          ),
          TargetPlatform.macOS,
        );
      final ShortcutBindingSet playPause =
          registry.bindingsFor(ShortcutAction.audiobookPlayPause);
      expect(playPause.keyboardBindings, const <InputBinding>[
        InputBinding(
          key: LogicalKeyboardKey.space,
          modifiers: <ModifierKey>{ModifierKey.alt},
        ),
      ]);
      expect(playPause.gamepadBindings,
          const <GamepadBinding>[GamepadBinding(GamepadButton.start)]);
      expect(
        registry
            .bindingsFor(ShortcutAction.globalToggleFullscreen)
            .keyboardBindings,
        const <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.keyF,
            modifiers: <ModifierKey>{ModifierKey.ctrl, ModifierKey.meta},
          ),
        ],
      );
    });

    test('用户改过的键原样保留', () {
      const InputBinding custom = InputBinding(
        key: LogicalKeyboardKey.keyK,
        modifiers: <ModifierKey>{ModifierKey.meta},
      );
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadFromJsonString(
          v12Snapshot(
            playPause: const <InputBinding>[custom],
            fullscreen: const <InputBinding>[f11, custom],
          ),
          TargetPlatform.macOS,
        );
      expect(
        registry
            .bindingsFor(ShortcutAction.audiobookPlayPause)
            .keyboardBindings,
        const <InputBinding>[custom],
      );
      expect(
        registry
            .bindingsFor(ShortcutAction.globalToggleFullscreen)
            .keyboardBindings,
        const <InputBinding>[f11, custom],
      );
    });

    test('非 macOS 不迁移', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadFromJsonString(
          v12Snapshot(
            playPause: const <InputBinding>[cmdSpace],
            fullscreen: const <InputBinding>[f11],
          ),
          TargetPlatform.windows,
        );
      expect(
        registry
            .bindingsFor(ShortcutAction.audiobookPlayPause)
            .keyboardBindings,
        const <InputBinding>[cmdSpace],
      );
      expect(
        registry
            .bindingsFor(ShortcutAction.globalToggleFullscreen)
            .keyboardBindings,
        const <InputBinding>[f11],
      );
    });
  });
}
