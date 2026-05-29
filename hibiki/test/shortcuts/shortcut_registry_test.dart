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

    test('resolveGamepad finds action by button (mobile)', () {
      // Gamepad is mobile-only, so load the android defaults where RB is bound.
      final mobile = HibikiShortcutRegistry()
        ..loadDefaults(TargetPlatform.android);
      final result = mobile.resolveGamepad(
        GamepadButton.rb,
        scope: ShortcutScope.reader,
      );
      expect(result, ShortcutAction.readerPageForward);
    });

    test('resolveGamepad returns null on desktop even with a gamepad binding',
        () {
      // The windows registry from setUp reports no gamepad support. Force a
      // gamepad binding into the bindings map and confirm resolution still
      // short-circuits — the platform gate, not just empty defaults, is what
      // keeps desktop gamepad-free (covers synced/persisted mobile JSON and the
      // D-Pad↔arrow logical-key alias).
      registry.updateBinding(
        ShortcutAction.readerPageForward,
        const ShortcutBindingSet(
          gamepadBindings: [GamepadBinding(GamepadButton.rb)],
        ),
      );
      expect(registry.gamepadSupported, isFalse);
      expect(
        registry.resolveGamepad(GamepadButton.rb, scope: ShortcutScope.reader),
        isNull,
      );
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

    test('hasKeyboardConflict detects conflict across co-active scopes', () {
      // reader + audiobook resolve together on the reader page. Bind an
      // audiobook action's default key (Ctrl+Space = audiobookPlayPause) and
      // check from the reader scope: it must surface as a conflict, otherwise
      // the audiobook binding would silently never fire on the reader page.
      final binding = InputBinding(
        key: LogicalKeyboardKey.space,
        modifiers: {ModifierKey.ctrl},
      );
      expect(
        registry.hasKeyboardConflict(
          ShortcutScope.reader,
          binding,
          exclude: null,
        ),
        ShortcutAction.audiobookPlayPause,
      );
      // Symmetric: checking from the audiobook scope finds the reader binding.
      final readerBinding = InputBinding(key: LogicalKeyboardKey.pageDown);
      expect(
        registry.hasKeyboardConflict(
          ShortcutScope.audiobook,
          readerBinding,
          exclude: null,
        ),
        ShortcutAction.readerPageForward,
      );
    });

    test('hasKeyboardConflict detects conflict across home/global co-active',
        () {
      // home + global resolve together on the home page. globalBack default is
      // Alt+ArrowLeft; checking from the home scope must find it.
      final binding = InputBinding(
        key: LogicalKeyboardKey.arrowLeft,
        modifiers: {ModifierKey.alt},
      );
      expect(
        registry.hasKeyboardConflict(
          ShortcutScope.home,
          binding,
          exclude: null,
        ),
        ShortcutAction.globalBack,
      );
    });

    test('hasKeyboardConflict does not bridge unrelated scope groups', () {
      // reader group must not see home-group bindings. Ctrl+Digit1 is
      // homeTabBooks; from the reader scope it stays clear of conflict.
      final binding = InputBinding(
        key: LogicalKeyboardKey.digit1,
        modifiers: {ModifierKey.ctrl},
      );
      expect(
        registry.hasKeyboardConflict(
          ShortcutScope.reader,
          binding,
          exclude: null,
        ),
        isNull,
      );
    });

    test('hasGamepadConflict detects conflict across co-active scopes', () {
      // Gamepad defaults are mobile-only, so load android where readerPageForward
      // owns RB. Bind audiobookPlayPause to RB; from the audiobook scope, RB must
      // surface the reader binding as a co-active conflict.
      final mobile = HibikiShortcutRegistry()
        ..loadDefaults(TargetPlatform.android);
      mobile.updateBinding(
        ShortcutAction.audiobookPlayPause,
        const ShortcutBindingSet(
          gamepadBindings: [GamepadBinding(GamepadButton.rb)],
        ),
      );
      const binding = GamepadBinding(GamepadButton.rb);
      expect(
        mobile.hasGamepadConflict(
          ShortcutScope.audiobook,
          binding,
          exclude: ShortcutAction.audiobookPlayPause,
        ),
        ShortcutAction.readerPageForward,
      );
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
