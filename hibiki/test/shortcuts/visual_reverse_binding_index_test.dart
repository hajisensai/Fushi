import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:hibiki/src/shortcuts/visual/reverse_binding_index.dart';

void main() {
  HibikiShortcutRegistry buildRegistry() =>
      HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  group('ReverseBindingIndex (TODO-612 stage 0)', () {
    test('reverses keyboard defaults into key -> actions for the scope', () {
      final HibikiShortcutRegistry registry = buildRegistry();
      final ReverseBindingIndex index = ReverseBindingIndex.fromRegistry(
        registry,
        ShortcutScope.reader,
      );

      // Spot-check a known reader default: readerToggleBookmark binds Ctrl+D.
      final ShortcutBindingSet bookmark =
          registry.bindingsFor(ShortcutAction.readerToggleBookmark);
      expect(bookmark.keyboardBindings, isNotEmpty,
          reason: 'precondition: bookmark has a default keyboard binding');
      final LogicalKeyboardKey boundKey = bookmark.keyboardBindings.first.key;

      expect(index.isKeyboardBound(boundKey), isTrue);
      expect(
        index.actionsForKey(boundKey),
        contains(ShortcutAction.readerToggleBookmark),
      );
    });

    test('unbound key reports not bound and empty action list', () {
      final ReverseBindingIndex index = ReverseBindingIndex.fromRegistry(
        buildRegistry(),
        ShortcutScope.home,
      );
      // F9 is not a home-scope default.
      expect(index.isKeyboardBound(LogicalKeyboardKey.f9), isFalse);
      expect(index.actionsForKey(LogicalKeyboardKey.f9), isEmpty);
    });

    test('includes co-active scope bindings (reader + audiobook)', () {
      final HibikiShortcutRegistry registry = buildRegistry();
      final ReverseBindingIndex index = ReverseBindingIndex.fromRegistry(
        registry,
        ShortcutScope.reader,
      );
      // audiobook is co-active with reader; its play/pause keyboard default
      // must surface in the reader-view reverse index.
      final ShortcutBindingSet play =
          registry.bindingsFor(ShortcutAction.audiobookPlayPause);
      for (final InputBinding kb in play.keyboardBindings) {
        expect(index.actionsForKey(kb.key),
            contains(ShortcutAction.audiobookPlayPause),
            reason: 'co-active audiobook keyboard binding must appear');
      }
    });

    test('reverses gamepad bindings into button -> actions', () {
      final HibikiShortcutRegistry registry = buildRegistry();
      // Find any action with a gamepad default and assert the reverse mapping.
      GamepadButton? sample;
      ShortcutAction? owner;
      for (final ShortcutAction action
          in ShortcutAction.actionsForScope(ShortcutScope.reader)) {
        final ShortcutBindingSet set = registry.bindingsFor(action);
        if (set.gamepadBindings.isNotEmpty) {
          sample = set.gamepadBindings.first.button;
          owner = action;
          break;
        }
      }
      expect(sample, isNotNull,
          reason: 'precondition: a reader action has a gamepad default');
      final ReverseBindingIndex index =
          ReverseBindingIndex.fromRegistry(registry, ShortcutScope.reader);
      expect(index.isGamepadBound(sample!), isTrue);
      expect(index.actionsForButton(sample), contains(owner));
    });

    test('keyboardBindingsFor preserves modifiers', () {
      final HibikiShortcutRegistry registry = buildRegistry();
      // Bind Ctrl+KeyG to a reader action explicitly, then reverse.
      const InputBinding ctrlG = InputBinding(
        key: LogicalKeyboardKey.keyG,
        modifiers: <ModifierKey>{ModifierKey.ctrl},
      );
      registry.updateBinding(
        ShortcutAction.readerToggleChrome,
        const ShortcutBindingSet(keyboardBindings: <InputBinding>[ctrlG]),
      );
      final ReverseBindingIndex index =
          ReverseBindingIndex.fromRegistry(registry, ShortcutScope.reader);
      final List<InputBinding> bindings =
          index.keyboardBindingsFor(LogicalKeyboardKey.keyG);
      expect(bindings, contains(ctrlG));
      expect(bindings.first.modifiers, contains(ModifierKey.ctrl));
    });
  });

  group('GamepadGlyphs (TODO-612 stage 0)', () {
    test('brand switch never changes GamepadButton serialization', () {
      // The persistence contract is button.serialize() == button.label, brand
      // independent. Switching brand must not touch serialization for ANY button.
      for (final GamepadButton button in GamepadButton.values) {
        final String token = GamepadBinding(button).serialize();
        // Glyph lookups for both brands must not mutate the enum/label.
        GamepadGlyphs.glyphFor(button, GamepadBrand.xbox);
        GamepadGlyphs.glyphFor(button, GamepadBrand.playstation);
        expect(GamepadBinding(button).serialize(), token,
            reason: 'serialization for $button must be brand-independent');
        expect(token, button.label);
      }
    });

    test('face buttons differ by brand symbol but share the enum', () {
      // A on Xbox shows "A"; on PlayStation shows the cross glyph. Same enum.
      final GamepadButtonGlyph xbox =
          GamepadGlyphs.glyphFor(GamepadButton.a, GamepadBrand.xbox);
      final GamepadButtonGlyph ps =
          GamepadGlyphs.glyphFor(GamepadButton.a, GamepadBrand.playstation);
      expect(xbox.symbol, 'A');
      expect(ps.symbol, isNot('A'));
      // Both still serialize as "A".
      expect(GamepadBinding(GamepadButton.a).serialize(), 'A');
    });

    test('non-face buttons reuse the enum label across brands', () {
      // Shoulder/trigger/dpad/start etc. are brand-neutral: same label, no accent.
      for (final GamepadButton button in <GamepadButton>[
        GamepadButton.lb,
        GamepadButton.rt,
        GamepadButton.dpadUp,
        GamepadButton.start,
        GamepadButton.thumbLeft,
      ]) {
        final GamepadButtonGlyph xbox =
            GamepadGlyphs.glyphFor(button, GamepadBrand.xbox);
        final GamepadButtonGlyph ps =
            GamepadGlyphs.glyphFor(button, GamepadBrand.playstation);
        expect(xbox.symbol, button.label);
        expect(ps.symbol, button.label);
        expect(xbox.accent, isNull);
        expect(ps.accent, isNull);
      }
    });
  });
}
