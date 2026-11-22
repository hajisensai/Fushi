import 'dart:convert';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 2026-11-22 手柄查词统一（docs/specs/2026-11-22-gamepad-lookup-unification-design.md）
/// 在快捷键层的后果：
///  * 光标模式的三个入口（videoEnterCaret / readerEnterCaret /
///    readerLookupAtCursor）没有手柄通道、没有手柄默认，老快照里的自定义手柄绑定
///    装载时剥掉（键盘绑定不动）；
///  * 视频整句扫词动作删除，老快照里的 `video_lookup_next_word` /
///    `video_lookup_prev_word` 装载时忽略、不回写。
void main() {
  const List<ShortcutAction> caretEntries = <ShortcutAction>[
    ShortcutAction.videoEnterCaret,
    ShortcutAction.readerEnterCaret,
    ShortcutAction.readerLookupAtCursor,
  ];
  const List<TargetPlatform> platforms = <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ];

  Map<String, dynamic> snapshot(Map<String, dynamic> entries) =>
      <String, dynamic>{
        kShortcutSchemaVersionKey: kShortcutSchemaVersion,
        ...entries,
      };

  FushiShortcutRegistry load(Map<String, dynamic> json) =>
      FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows)
        ..loadFromJsonString(jsonEncode(json), TargetPlatform.windows);

  group('光标入口没有手柄通道', () {
    test('channels 去掉 gamepad，键盘通道保留', () {
      for (final ShortcutAction action in caretEntries) {
        expect(
          action.channels,
          isNot(contains(ShortcutChannel.gamepad)),
          reason: action.key,
        );
        expect(
          action.channels,
          contains(ShortcutChannel.keyboard),
          reason: action.key,
        );
      }
    });

    test('各平台默认：无手柄绑定，键盘 Enter 不变', () {
      for (final TargetPlatform p in platforms) {
        final Map<ShortcutAction, ShortcutBindingSet> table =
            ShortcutDefaults.forPlatform(p);
        for (final ShortcutAction action in caretEntries) {
          expect(
            table[action]!.gamepadBindings,
            isEmpty,
            reason: '${action.key} on $p',
          );
        }
      }
      final Map<ShortcutAction, ShortcutBindingSet> win =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      for (final ShortcutAction action in caretEntries) {
        expect(
          win[action]!.keyboardBindings.map((InputBinding b) => b.key),
          contains(LogicalKeyboardKey.enter),
          reason: action.key,
        );
      }
    });

    test('老快照里的自定义手柄绑定装载时剥掉，键盘绑定保留', () {
      final FushiShortcutRegistry registry = load(
        snapshot(<String, dynamic>{
          for (final ShortcutAction action in caretEntries)
            action.key: const ShortcutBindingSet(
              keyboardBindings: <InputBinding>[
                InputBinding(key: LogicalKeyboardKey.f8),
              ],
              gamepadBindings: <GamepadBinding>[
                GamepadBinding(GamepadButton.select),
                GamepadBinding(GamepadButton.a),
              ],
            ).toJson(),
        }),
      );
      for (final ShortcutAction action in caretEntries) {
        final ShortcutBindingSet set = registry.bindingsFor(action);
        expect(set.gamepadBindings, isEmpty, reason: action.key);
        expect(set.keyboardBindings, const <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.f8),
        ], reason: '${action.key}：键盘通道不动');
      }
      expect(
        registry.resolveGamepad(
          GamepadButton.select,
          scope: ShortcutScope.video,
        ),
        isNull,
      );
      expect(
        registry.resolveGamepad(GamepadButton.a, scope: ShortcutScope.reader),
        isNull,
      );
    });

    test('通道开着的动作，快照里的手柄绑定原样保留', () {
      final FushiShortcutRegistry registry = load(
        snapshot(<String, dynamic>{
          ShortcutAction.videoTogglePlayPause.key: const ShortcutBindingSet(
            gamepadBindings: <GamepadBinding>[
              GamepadBinding(GamepadButton.select),
            ],
          ).toJson(),
        }),
      );
      expect(
        registry.resolveGamepad(
          GamepadButton.select,
          scope: ShortcutScope.video,
        ),
        ShortcutAction.videoTogglePlayPause,
      );
    });
  });

  group('已删除的整句扫词 key', () {
    test('动作不存在', () {
      expect(ShortcutAction.fromKey('video_lookup_next_word'), isNull);
      expect(ShortcutAction.fromKey('video_lookup_prev_word'), isNull);
      expect(kRetiredShortcutActionKeys, <String>{
        'video_lookup_next_word',
        'video_lookup_prev_word',
      });
    });

    test('装载时忽略、不报错、不回写；其它未知 key 照旧保留', () {
      const String futureKey = 'some_future_action';
      final Map<String, dynamic> binding = const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.f7),
        ],
        gamepadBindings: <GamepadBinding>[
          GamepadBinding(GamepadButton.thumbRight),
        ],
      ).toJson();
      late final FushiShortcutRegistry registry;
      expect(
        () => registry = load(
          snapshot(<String, dynamic>{
            'video_lookup_next_word': binding,
            'video_lookup_prev_word': binding,
            futureKey: binding,
          }),
        ),
        returnsNormally,
      );
      final Map<String, dynamic> out = registry.toJson();
      expect(out.containsKey('video_lookup_next_word'), isFalse);
      expect(out.containsKey('video_lookup_prev_word'), isFalse);
      expect(out.containsKey(futureKey), isTrue);
      // 别的动作照常装载（F7 没被挪给任何视频动作）。
      expect(
        registry.resolveGamepad(
          GamepadButton.thumbRight,
          scope: ShortcutScope.video,
        ),
        isNull,
      );
    });
  });
}
