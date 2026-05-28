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
        modifiers: {ModifierKey.ctrl},
      );
      expect(binding.serialize(), 'Ctrl+KeyD');
    });

    test('serialize key with multiple modifiers sorted', () {
      final binding = InputBinding(
        key: LogicalKeyboardKey.space,
        modifiers: {ModifierKey.shift, ModifierKey.ctrl},
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
        modifiers: {ModifierKey.ctrl, ModifierKey.shift},
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
        modifiers: {ModifierKey.shift},
      );
      final b = InputBinding(
        key: LogicalKeyboardKey.space,
        modifiers: {ModifierKey.shift},
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
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
      expect(GamepadBinding.deserialize('DpadLeft')?.button, GamepadButton.dpadLeft);
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
  });

  group('ShortcutBindingSet', () {
    test('toJson and fromJson round-trip', () {
      final set = ShortcutBindingSet(
        keyboardBindings: [
          InputBinding(key: LogicalKeyboardKey.pageDown),
          InputBinding(
            key: LogicalKeyboardKey.space,
            modifiers: {ModifierKey.shift},
          ),
        ],
        gamepadBindings: [
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
      final set = ShortcutBindingSet.fromJson({
        'keyboard': <String>[],
        'gamepad': <String>[],
      });
      expect(set.keyboardBindings, isEmpty);
      expect(set.gamepadBindings, isEmpty);
    });

    test('fromJson handles missing keys', () {
      final set = ShortcutBindingSet.fromJson(<String, dynamic>{});
      expect(set.keyboardBindings, isEmpty);
      expect(set.gamepadBindings, isEmpty);
    });
  });
}
