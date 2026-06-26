import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

void main() {
  group('ModifierKey', () {
    test('fromKeyboardKey maps correctly', () {
      expect(
        ModifierKey.fromKeyboardKey(LogicalKeyboardKey.controlLeft),
        ModifierKey.ctrl,
      );
      expect(
        ModifierKey.fromKeyboardKey(LogicalKeyboardKey.shiftRight),
        ModifierKey.shift,
      );
      expect(
        ModifierKey.fromKeyboardKey(LogicalKeyboardKey.altLeft),
        ModifierKey.alt,
      );
      expect(
        ModifierKey.fromKeyboardKey(LogicalKeyboardKey.metaLeft),
        ModifierKey.meta,
      );
      expect(ModifierKey.fromKeyboardKey(LogicalKeyboardKey.keyA), isNull);
    });
  });

  group('InputBinding', () {
    test('serialize simple key', () {
      final binding = InputBinding(
        key: LogicalKeyboardKey.pageDown,
      );
      expect(binding.serialize(), 'PageDown');
    });

    test('serialize key with modifiers', () {
      final binding = InputBinding(
        key: LogicalKeyboardKey.keyD,
        modifiers: const {ModifierKey.ctrl},
      );
      expect(binding.serialize(), 'Ctrl+KeyD');
    });

    test('serialize key with multiple modifiers sorted', () {
      final binding = InputBinding(
        key: LogicalKeyboardKey.space,
        modifiers: const {ModifierKey.shift, ModifierKey.ctrl},
      );
      expect(binding.serialize(), 'Ctrl+Shift+Space');
    });

    test('deserialize simple key', () {
      final binding = InputBinding.deserialize('PageDown');
      expect(binding, isNotNull);
      expect(binding!.key, LogicalKeyboardKey.pageDown);
      expect(binding.modifiers, isEmpty);
    });

    test('deserialize key with modifier', () {
      final binding = InputBinding.deserialize('Ctrl+KeyD');
      expect(binding, isNotNull);
      expect(binding!.key, LogicalKeyboardKey.keyD);
      expect(binding.modifiers, {ModifierKey.ctrl});
    });

    test('deserialize returns null for empty string', () {
      expect(InputBinding.deserialize(''), isNull);
    });

    test('round-trip serialize/deserialize', () {
      final original = InputBinding(
        key: LogicalKeyboardKey.arrowRight,
        modifiers: const {ModifierKey.ctrl, ModifierKey.shift},
      );
      final serialized = original.serialize();
      final restored = InputBinding.deserialize(serialized);
      expect(restored, isNotNull);
      expect(restored!.key, original.key);
      expect(restored.modifiers, original.modifiers);
    });

    test('equality', () {
      final a = InputBinding(
        key: LogicalKeyboardKey.space,
        modifiers: const {ModifierKey.shift},
      );
      final b = InputBinding(
        key: LogicalKeyboardKey.space,
        modifiers: const {ModifierKey.shift},
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('non-whitelisted keys survive a serialize/deserialize round-trip', () {
      // Regression: keys outside the display whitelist (numpad, F13, media,
      // CapsLock, …) used to serialize to a label that deserialize could not
      // resolve, so the binding was silently dropped on the next launch. They
      // now persist by keyId behind a '#' sentinel.
      for (final key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.numpad1,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.f13,
        LogicalKeyboardKey.capsLock,
        LogicalKeyboardKey.mediaPlayPause,
      ]) {
        final original = InputBinding(
          key: key,
          modifiers: const {ModifierKey.ctrl},
        );
        final restored = InputBinding.deserialize(original.serialize());
        expect(restored, isNotNull, reason: '${key.keyLabel} dropped');
        expect(restored!.key, key);
        expect(restored.modifiers, {ModifierKey.ctrl});
      }
    });

    test('serialize keeps readable labels for whitelisted keys', () {
      // Whitelisted keys must NOT switch to the keyId sentinel, so existing
      // saved JSON stays valid and human-readable.
      expect(InputBinding(key: LogicalKeyboardKey.pageDown).serialize(),
          'PageDown');
      expect(
        InputBinding(
          key: LogicalKeyboardKey.keyD,
          modifiers: const {ModifierKey.ctrl},
        ).serialize(),
        'Ctrl+KeyD',
      );
    });

    test('deserialize still reads legacy label format', () {
      // Backward compatibility: JSON saved before the keyId change used labels.
      final b = InputBinding.deserialize('Ctrl+Shift+ArrowRight');
      expect(b, isNotNull);
      expect(b!.key, LogicalKeyboardKey.arrowRight);
      expect(b.modifiers, {ModifierKey.ctrl, ModifierKey.shift});
    });

    test('displayLabel is human-readable for non-whitelisted keys', () {
      // The persistence token may be '#<keyId>', but the UI must show a label.
      final binding = InputBinding(key: LogicalKeyboardKey.numpad1);
      expect(binding.serialize().startsWith('#'), isTrue);
      expect(binding.displayLabel, LogicalKeyboardKey.numpad1.keyLabel);
      expect(binding.displayLabel.startsWith('#'), isFalse);
    });

    test('deserialize returns null for malformed keyId token', () {
      expect(InputBinding.deserialize('#notanumber'), isNull);
    });
  });

  group('InputBinding.physicalKey (TODO-847 IME fallback)', () {
    // 与 input_binding.dart 的 _knownKeys 非 game* 键集对齐。私有 map 不可直接访问，
    // 故在测试侧显式列出同一集合作为 _knownKeys⊇ 守卫：每个键的 physicalKey 必须
    // 非 null，否则该键在 IME 改写 logicalKey 时仍会失效（物理回退漏键）。
    const List<LogicalKeyboardKey> nonGameKnownKeys = <LogicalKeyboardKey>[
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.pageUp,
      LogicalKeyboardKey.pageDown,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.mediaPlay,
      LogicalKeyboardKey.mediaPause,
      LogicalKeyboardKey.mediaPlayPause,
      LogicalKeyboardKey.delete,
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.end,
      LogicalKeyboardKey.f1,
      LogicalKeyboardKey.f2,
      LogicalKeyboardKey.f3,
      LogicalKeyboardKey.f4,
      LogicalKeyboardKey.f5,
      LogicalKeyboardKey.f6,
      LogicalKeyboardKey.f7,
      LogicalKeyboardKey.f8,
      LogicalKeyboardKey.f9,
      LogicalKeyboardKey.f10,
      LogicalKeyboardKey.f11,
      LogicalKeyboardKey.f12,
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyB,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyD,
      LogicalKeyboardKey.keyE,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.keyG,
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.keyI,
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.keyL,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.keyO,
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyQ,
      LogicalKeyboardKey.keyR,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyT,
      LogicalKeyboardKey.keyU,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyY,
      LogicalKeyboardKey.keyZ,
      LogicalKeyboardKey.bracketLeft,
      LogicalKeyboardKey.bracketRight,
      LogicalKeyboardKey.minus,
      LogicalKeyboardKey.equal,
      LogicalKeyboardKey.comma,
      LogicalKeyboardKey.period,
      LogicalKeyboardKey.slash,
      LogicalKeyboardKey.semicolon,
      LogicalKeyboardKey.backquote,
    ];

    test(
        'every non-game known key has a non-null physicalKey (no missing keys)',
        () {
      for (final key in nonGameKnownKeys) {
        expect(
          InputBinding(key: key).physicalKey,
          isNotNull,
          reason: '${key.keyLabel} missing from _logicalToPhysical — would '
              'still fail under IME',
        );
      }
    });

    test('physicalKey maps representative keys to the matching physical key',
        () {
      expect(InputBinding(key: LogicalKeyboardKey.pageDown).physicalKey,
          PhysicalKeyboardKey.pageDown);
      expect(InputBinding(key: LogicalKeyboardKey.keyM).physicalKey,
          PhysicalKeyboardKey.keyM);
      expect(InputBinding(key: LogicalKeyboardKey.digit1).physicalKey,
          PhysicalKeyboardKey.digit1);
      expect(InputBinding(key: LogicalKeyboardKey.arrowLeft).physicalKey,
          PhysicalKeyboardKey.arrowLeft);
      expect(InputBinding(key: LogicalKeyboardKey.space).physicalKey,
          PhysicalKeyboardKey.space);
    });

    test('physicalKey is null for keys outside the override set', () {
      // game* / numpad / F13+ 不在覆盖集 → null（IME 下不参与物理回退，符合预期）。
      expect(InputBinding(key: LogicalKeyboardKey.gameButtonA).physicalKey,
          isNull);
      expect(InputBinding(key: LogicalKeyboardKey.numpad1).physicalKey, isNull);
      expect(InputBinding(key: LogicalKeyboardKey.f13).physicalKey, isNull);
    });

    test('physicalKey does NOT change ==, hashCode, or serialize', () {
      // physicalKey 是派生 getter，绝不能污染相等/哈希/序列化（否则破坏 Set 去重、
      // 冲突检测、JSON 兼容）。两个 binding 不同 key 但都 physicalKey!=null，相等/
      // 序列化仍只看 key+modifiers。
      const a = InputBinding(
        key: LogicalKeyboardKey.keyD,
        modifiers: {ModifierKey.ctrl},
      );
      const b = InputBinding(
        key: LogicalKeyboardKey.keyD,
        modifiers: {ModifierKey.ctrl},
      );
      // 同 key → 相等、同 hash、同序列化（physicalKey 不参与）。
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a.serialize(), 'Ctrl+KeyD');
      expect(b.serialize(), 'Ctrl+KeyD');
      // physicalKey 非 null 但与序列化 token 无关。
      expect(a.physicalKey, isNotNull);
      expect(a.serialize().contains('Physical'), isFalse);
      // 不同 key 仍不等，序列化各自的 token 不变。
      const c = InputBinding(key: LogicalKeyboardKey.keyF);
      expect(a == c, isFalse);
      expect(c.serialize(), 'KeyF');
    });
  });

  group('GamepadBinding', () {
    test('serialize', () {
      expect(GamepadBinding(GamepadButton.a).serialize(), 'A');
      expect(GamepadBinding(GamepadButton.rb).serialize(), 'RB');
      expect(GamepadBinding(GamepadButton.dpadLeft).serialize(), 'DpadLeft');
    });

    test('deserialize', () {
      expect(GamepadBinding.deserialize('A')?.button, GamepadButton.a);
      expect(GamepadBinding.deserialize('RB')?.button, GamepadButton.rb);
      expect(GamepadBinding.deserialize('DpadLeft')?.button,
          GamepadButton.dpadLeft);
      expect(GamepadBinding.deserialize('L3')?.button, GamepadButton.thumbLeft);
      expect(
          GamepadBinding.deserialize('R3')?.button, GamepadButton.thumbRight);
      expect(GamepadBinding.deserialize('Mode')?.button, GamepadButton.mode);
    });

    test('deserialize returns null for unknown', () {
      expect(GamepadBinding.deserialize('UnknownButton'), isNull);
    });

    test('round-trip', () {
      for (final button in GamepadButton.values) {
        final binding = GamepadBinding(button);
        final restored = GamepadBinding.deserialize(binding.serialize());
        expect(restored?.button, button);
      }
    });

    test('fromLogicalKey maps gamepad keys correctly', () {
      expect(GamepadButton.fromLogicalKey(LogicalKeyboardKey.gameButtonA),
          GamepadButton.a);
      expect(GamepadButton.fromLogicalKey(LogicalKeyboardKey.gameButtonLeft1),
          GamepadButton.lb);
      expect(
          GamepadButton.fromLogicalKey(LogicalKeyboardKey.gameButtonThumbLeft),
          GamepadButton.thumbLeft);
      expect(GamepadButton.fromLogicalKey(LogicalKeyboardKey.gameButtonMode),
          GamepadButton.mode);
    });

    test('fromLogicalKey returns null for non-gamepad keys', () {
      expect(GamepadButton.fromLogicalKey(LogicalKeyboardKey.space), isNull);
      expect(GamepadButton.fromLogicalKey(LogicalKeyboardKey.escape), isNull);
    });

    test('fromLogicalKey maps D-Pad arrow keys (keyboard wins on conflict)',
        () {
      // D-Pad shares LogicalKeyboardKey with arrow keys. fromLogicalKey returns
      // the D-Pad button so a standalone D-Pad gamepad binding can resolve via
      // the gamepad fallback path. Keyboard arrow bindings still take priority
      // because resolveKeyboard runs first.
      expect(GamepadButton.fromLogicalKey(LogicalKeyboardKey.arrowUp),
          GamepadButton.dpadUp);
      expect(GamepadButton.fromLogicalKey(LogicalKeyboardKey.arrowDown),
          GamepadButton.dpadDown);
      expect(GamepadButton.fromLogicalKey(LogicalKeyboardKey.arrowLeft),
          GamepadButton.dpadLeft);
      expect(GamepadButton.fromLogicalKey(LogicalKeyboardKey.arrowRight),
          GamepadButton.dpadRight);
    });
  });

  group('ShortcutBindingSet', () {
    test('toJson and fromJson round-trip', () {
      final set = ShortcutBindingSet(
        keyboardBindings: const [
          InputBinding(key: LogicalKeyboardKey.pageDown),
          InputBinding(
            key: LogicalKeyboardKey.space,
            modifiers: {ModifierKey.shift},
          ),
        ],
        gamepadBindings: const [
          GamepadBinding(GamepadButton.rb),
        ],
      );
      final json = set.toJson();
      final restored = ShortcutBindingSet.fromJson(json);
      expect(restored.keyboardBindings.length, 2);
      expect(restored.gamepadBindings.length, 1);
      expect(restored.keyboardBindings[0].key, LogicalKeyboardKey.pageDown);
      expect(restored.gamepadBindings[0].button, GamepadButton.rb);
    });

    test('fromJson handles empty lists', () {
      final set = ShortcutBindingSet.fromJson(const {
        'keyboard': <String>[],
        'gamepad': <String>[],
      });
      expect(set.keyboardBindings, isEmpty);
      expect(set.gamepadBindings, isEmpty);
    });

    test('fromJson handles missing keys', () {
      final set = ShortcutBindingSet.fromJson(const <String, dynamic>{});
      expect(set.keyboardBindings, isEmpty);
      expect(set.gamepadBindings, isEmpty);
    });
  });
}
