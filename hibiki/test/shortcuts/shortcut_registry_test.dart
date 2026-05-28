import 'dart:convert';

import 'package:flutter/material.dart' hide HibikiShortcutRegistry;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

void main() {
  group('HibikiShortcutRegistry', () {
    late HibikiShortcutRegistry registry;

    setUp(() {
      registry = HibikiShortcutRegistry();
      registry.loadDefaults(TargetPlatform.windows);
    });

    test('loadDefaults populates all actions', () {
      for (final action in ShortcutAction.values) {
        expect(registry.bindingsFor(action), isNotNull);
      }
    });

    test('resolveKeyboard finds readerPageForward with PageDown', () {
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.pageDown,
        modifiers: {},
        scope: ShortcutScope.reader,
      );
      expect(result, ShortcutAction.readerPageForward);
    });

    test('resolveKeyboard returns null for unbound key', () {
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.f12,
        modifiers: {},
        scope: ShortcutScope.reader,
      );
      expect(result, isNull);
    });

    test('resolveKeyboard respects scope filter', () {
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.digit1,
        modifiers: {ModifierKey.ctrl},
        scope: ShortcutScope.reader,
      );
      expect(result, isNull);
    });

    test('resolveKeyboard finds home action in home scope', () {
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.digit1,
        modifiers: {ModifierKey.ctrl},
        scope: ShortcutScope.home,
      );
      expect(result, ShortcutAction.homeTabBooks);
    });

    test('resolveGamepad finds action by button', () {
      final result = registry.resolveGamepad(
        GamepadButton.rb,
        scope: ShortcutScope.reader,
      );
      expect(result, ShortcutAction.readerPageForward);
    });

    test('updateBinding replaces bindings', () {
      final newBindings = ShortcutBindingSet(
        keyboardBindings: [
          InputBinding(key: LogicalKeyboardKey.keyN),
        ],
      );
      registry.updateBinding(ShortcutAction.readerPageForward, newBindings);
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.keyN,
        modifiers: {},
        scope: ShortcutScope.reader,
      );
      expect(result, ShortcutAction.readerPageForward);
      final oldResult = registry.resolveKeyboard(
        LogicalKeyboardKey.pageDown,
        modifiers: {},
        scope: ShortcutScope.reader,
      );
      expect(oldResult, isNull);
    });

    test('hasKeyboardConflict detects conflict in same scope', () {
      final binding = InputBinding(key: LogicalKeyboardKey.pageDown);
      final conflict = registry.hasKeyboardConflict(
        ShortcutScope.reader,
        binding,
        exclude: null,
      );
      expect(conflict, ShortcutAction.readerPageForward);
    });

    test('hasKeyboardConflict ignores excluded action', () {
      final binding = InputBinding(key: LogicalKeyboardKey.pageDown);
      final conflict = registry.hasKeyboardConflict(
        ShortcutScope.reader,
        binding,
        exclude: ShortcutAction.readerPageForward,
      );
      expect(conflict, isNull);
    });

    test('hasKeyboardConflict ignores different scope', () {
      final binding = InputBinding(
        key: LogicalKeyboardKey.digit1,
        modifiers: {ModifierKey.ctrl},
      );
      final conflict = registry.hasKeyboardConflict(
        ShortcutScope.reader,
        binding,
        exclude: null,
      );
      expect(conflict, isNull);
    });

    test('toJson and loadFromJson round-trip', () {
      final json = registry.toJson();
      final jsonString = jsonEncode(json);
      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
      final restored = HibikiShortcutRegistry();
      restored.loadDefaults(TargetPlatform.windows);
      restored.loadFromJson(decoded);
      for (final action in ShortcutAction.values) {
        expect(
          restored.bindingsFor(action).keyboardBindings.length,
          registry.bindingsFor(action).keyboardBindings.length,
          reason: 'Mismatch for ${action.key}',
        );
      }
    });

    test('loadFromJson fills missing actions with defaults', () {
      final partial = <String, dynamic>{
        'reader_page_forward': {
          'keyboard': ['KeyN'],
          'gamepad': <String>[],
        },
      };
      final reg = HibikiShortcutRegistry();
      reg.loadDefaults(TargetPlatform.windows);
      reg.loadFromJson(partial);
      expect(
        reg.resolveKeyboard(LogicalKeyboardKey.keyN,
            modifiers: {}, scope: ShortcutScope.reader),
        ShortcutAction.readerPageForward,
      );
      expect(
        reg.resolveKeyboard(LogicalKeyboardKey.pageUp,
            modifiers: {}, scope: ShortcutScope.reader),
        ShortcutAction.readerPageBackward,
      );
    });

    test('resetToDefaults restores original bindings', () {
      registry.updateBinding(
        ShortcutAction.readerPageForward,
        const ShortcutBindingSet(keyboardBindings: []),
      );
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.pageDown,
          modifiers: {},
          scope: ShortcutScope.reader,
        ),
        isNull,
      );
      registry.resetToDefaults(TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.pageDown,
          modifiers: {},
          scope: ShortcutScope.reader,
        ),
        ShortcutAction.readerPageForward,
      );
    });

    test('resolveKeyboard Escape returns first matching action by enum order',
        () {
      // Both readerToggleChrome and readerDismissDict bind to Escape.
      // resolveKeyboard returns the first match in enum declaration order.
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.escape,
        modifiers: {},
        scope: ShortcutScope.reader,
      );
      expect(result, ShortcutAction.readerToggleChrome);
    });

    test('loadFromJson preserves unknown action keys for forward compatibility',
        () {
      final jsonWithUnknown = <String, dynamic>{
        'reader_page_forward': {
          'keyboard': ['PageDown'],
          'gamepad': <String>[],
        },
        'future_action_v99': {
          'keyboard': ['F13'],
          'gamepad': ['A'],
        },
      };
      final reg = HibikiShortcutRegistry();
      reg.loadDefaults(TargetPlatform.windows);
      reg.loadFromJson(jsonWithUnknown);

      final exported = reg.toJson();
      expect(exported.containsKey('future_action_v99'), isTrue);
      final preserved = exported['future_action_v99'] as Map<String, dynamic>;
      expect((preserved['keyboard'] as List).contains('F13'), isTrue);
    });

    test('resetToDefaults clears unknown entries', () {
      final jsonWithUnknown = <String, dynamic>{
        'future_action_v99': {
          'keyboard': ['F13'],
          'gamepad': <String>[],
        },
      };
      final reg = HibikiShortcutRegistry();
      reg.loadDefaults(TargetPlatform.windows);
      reg.loadFromJson(jsonWithUnknown);
      expect(reg.toJson().containsKey('future_action_v99'), isTrue);

      reg.resetToDefaults(TargetPlatform.windows);
      expect(reg.toJson().containsKey('future_action_v99'), isFalse);
    });

    test('loadFromJsonString reload fully swaps bindings (profile switch)', () {
      // Profile A: custom binding for readerPageForward.
      final profileA = jsonEncode({
        'reader_page_forward': {
          'keyboard': ['KeyN'],
          'gamepad': <String>[],
        },
      });
      registry.loadFromJsonString(profileA, TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.keyN,
            modifiers: {}, scope: ShortcutScope.reader),
        ShortcutAction.readerPageForward,
      );

      // Switch to Profile B with no custom shortcuts: reloading must drop
      // Profile A's KeyN binding and restore defaults.
      registry.loadFromJsonString('{}', TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.keyN,
            modifiers: {}, scope: ShortcutScope.reader),
        isNull,
      );
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.pageDown,
            modifiers: {}, scope: ShortcutScope.reader),
        ShortcutAction.readerPageForward,
      );
    });
  });
}
