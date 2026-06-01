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
