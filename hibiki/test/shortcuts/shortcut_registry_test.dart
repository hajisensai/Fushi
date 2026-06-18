import 'dart:convert';

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
        keyboardBindings: const [
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

    test(
        'updateBindingWithReassignments moves keyboard binding from old action',
        () {
      const binding = InputBinding(key: LogicalKeyboardKey.escape);
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.escape,
          modifiers: {},
          scope: ShortcutScope.reader,
        ),
        ShortcutAction.readerDismissDict,
      );

      registry.updateBindingWithReassignments(
        ShortcutAction.readerToggleBookmark,
        const ShortcutBindingSet(keyboardBindings: <InputBinding>[binding]),
        removeKeyboardConflicts: <InputBinding>[binding],
      );

      expect(
        registry.bindingsFor(ShortcutAction.readerDismissDict).keyboardBindings,
        isNot(contains(binding)),
      );
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.escape,
          modifiers: {},
          scope: ShortcutScope.reader,
        ),
        ShortcutAction.readerToggleBookmark,
      );
    });

    test('updateBindingWithReassignments moves gamepad binding from old action',
        () {
      const binding = GamepadBinding(GamepadButton.rb);
      expect(
        registry.resolveGamepad(GamepadButton.rb, scope: ShortcutScope.reader),
        ShortcutAction.readerPageForward,
      );

      registry.updateBindingWithReassignments(
        ShortcutAction.readerToggleBookmark,
        const ShortcutBindingSet(gamepadBindings: <GamepadBinding>[binding]),
        removeGamepadConflicts: <GamepadBinding>[binding],
      );

      expect(
        registry.bindingsFor(ShortcutAction.readerPageForward).gamepadBindings,
        isNot(contains(binding)),
      );
      expect(
        registry.resolveGamepad(GamepadButton.rb, scope: ShortcutScope.reader),
        ShortcutAction.readerToggleBookmark,
      );
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
        modifiers: const {ModifierKey.ctrl},
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
        modifiers: const {ModifierKey.ctrl},
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
        modifiers: const {ModifierKey.alt},
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
        modifiers: const {ModifierKey.ctrl},
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
      // Construct the conflict explicitly rather than rely on default overlap:
      // bind audiobookPlayPause to RB (which readerPageForward owns by default).
      // From the audiobook scope, RB must surface the reader binding as a
      // co-active conflict.
      registry.updateBinding(
        ShortcutAction.audiobookPlayPause,
        const ShortcutBindingSet(
          gamepadBindings: [GamepadBinding(GamepadButton.rb)],
        ),
      );
      const binding = GamepadBinding(GamepadButton.rb);
      expect(
        registry.hasGamepadConflict(
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

    test('resolveKeyboard Escape resolves to readerDismissDict (reader back)',
        () {
      // Regression: Escape used to be double-bound to BOTH readerToggleChrome
      // and readerDismissDict, and enum order made it resolve to
      // readerToggleChrome → Esc toggled the bottom bar instead of leaving the
      // book. Esc is now the reader's single "back" key (readerDismissDict);
      // readerToggleChrome moved to KeyM. So Esc must resolve to dismiss/back.
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.escape,
        modifiers: {},
        scope: ShortcutScope.reader,
      );
      expect(result, ShortcutAction.readerDismissDict);
    });

    test(
        'resolveKeyboard KeyM resolves to readerToggleChrome (open bottom bar)',
        () {
      final result = registry.resolveKeyboard(
        LogicalKeyboardKey.keyM,
        modifiers: {},
        scope: ShortcutScope.reader,
      );
      expect(result, ShortcutAction.readerToggleChrome);
    });

    test('Escape is owned by exactly one reader-group action (no double-bind)',
        () {
      // The original bug was a silent keyboard double-bind. Guard it: no two
      // reader-group actions may both own Escape, or enum order would again
      // decide which one wins and the loser would never fire.
      const escape = InputBinding(key: LogicalKeyboardKey.escape);
      final owners = <ShortcutAction>[];
      for (final scope in ShortcutScope.reader.coactiveScopes) {
        for (final action in ShortcutAction.actionsForScope(scope)) {
          if (registry.bindingsFor(action).keyboardBindings.contains(escape)) {
            owners.add(action);
          }
        }
      }
      expect(owners, [ShortcutAction.readerDismissDict]);
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
