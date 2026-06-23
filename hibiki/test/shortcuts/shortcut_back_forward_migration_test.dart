import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// TODO-700 T2 必做回归闸门：删硬绑手柄 B 返回后，老用户持久化 JSON 里若 globalBack /
/// 句子导航没有手柄槽，加载时必须经 v1→v2 前向迁移补回新默认（B/X），否则纯手柄用户
/// 既退不了书、又按不出上/下一句。这套测试钉死该不变式。
void main() {
  bool hasGamepad(ShortcutBindingSet set, GamepadButton button) =>
      set.gamepadBindings.any((GamepadBinding b) => b.button == button);

  /// 构造一份「老版本（schema v1）」快照：globalBack 仅键盘 Alt+Left（无手柄），
  /// 句子导航仅键盘 Ctrl+Arrow（无手柄）—— 即 T2 之前的默认全集。
  String oldV1Snapshot() {
    return jsonEncode(<String, dynamic>{
      kShortcutSchemaVersionKey: 1,
      ShortcutAction.globalBack.key: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.arrowLeft,
            modifiers: <ModifierKey>{ModifierKey.alt},
          ),
        ],
      ).toJson(),
      ShortcutAction.audiobookPrevSentence.key: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.arrowLeft,
            modifiers: <ModifierKey>{ModifierKey.ctrl},
          ),
        ],
      ).toJson(),
      ShortcutAction.audiobookNextSentence.key: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.arrowRight,
            modifiers: <ModifierKey>{ModifierKey.ctrl},
          ),
        ],
      ).toJson(),
    });
  }

  test('老快照 (v1) 加载后 globalBack 自动补回手柄 B（必做回归闸门）', () {
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
    registry.loadFromJsonString(oldV1Snapshot(), TargetPlatform.windows);
    expect(
      hasGamepad(
          registry.bindingsFor(ShortcutAction.globalBack), GamepadButton.b),
      isTrue,
      reason: '老用户没动过返回键 → 迁移必须补回 B，否则纯手柄退不了书',
    );
  });

  test('老快照 (v1) 加载后句子导航补回 B(prev)/X(next)', () {
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
    registry.loadFromJsonString(oldV1Snapshot(), TargetPlatform.windows);
    expect(
      hasGamepad(registry.bindingsFor(ShortcutAction.audiobookPrevSentence),
          GamepadButton.b),
      isTrue,
    );
    expect(
      hasGamepad(registry.bindingsFor(ShortcutAction.audiobookNextSentence),
          GamepadButton.x),
      isTrue,
    );
  });

  test('用户改过返回键（globalBack 键盘改成单 keyB）→ 迁移不动其绑定', () {
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
    final String snapshot = jsonEncode(<String, dynamic>{
      kShortcutSchemaVersionKey: 1,
      ShortcutAction.globalBack.key: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.keyB),
        ],
      ).toJson(),
    });
    registry.loadFromJsonString(snapshot, TargetPlatform.windows);
    final ShortcutBindingSet back =
        registry.bindingsFor(ShortcutAction.globalBack);
    expect(
      back.keyboardBindings.map((InputBinding b) => b.key),
      contains(LogicalKeyboardKey.keyB),
      reason: '用户改过的键盘绑定必须保留',
    );
    expect(
      hasGamepad(back, GamepadButton.b),
      isFalse,
      reason: '用户动过返回键 → 不补默认手柄 B（不覆盖用户改键）',
    );
  });

  test('macOS 老快照：键盘默认是 Meta+Ctrl 变体仍能识别 untouched 并补回手柄', () {
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
    // macOS 上 Ctrl→Meta；globalBack 的 Alt+Left 不含 Ctrl 故不变。句子导航 Ctrl→Meta。
    final String snapshot = jsonEncode(<String, dynamic>{
      kShortcutSchemaVersionKey: 1,
      ShortcutAction.audiobookPrevSentence.key: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.arrowLeft,
            modifiers: <ModifierKey>{ModifierKey.meta},
          ),
        ],
      ).toJson(),
    });
    registry.loadFromJsonString(snapshot, TargetPlatform.macOS);
    expect(
      hasGamepad(registry.bindingsFor(ShortcutAction.audiobookPrevSentence),
          GamepadButton.b),
      isTrue,
      reason: 'macOS 键盘默认随平台变体，untouched 判据须用当前平台默认键盘',
    );
  });
}
