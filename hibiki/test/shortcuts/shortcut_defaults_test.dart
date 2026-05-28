import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart' hide ModifierKey;
import 'package:hibiki/src/shortcuts/input_binding.dart' as bindings
    show ModifierKey;

void main() {
  group('ShortcutDefaults', () {
    test('windowsDefaults covers all actions', () {
      final defaults = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      for (final action in ShortcutAction.values) {
        expect(defaults.containsKey(action), isTrue,
            reason: 'Missing default for ${action.key}');
      }
    });

    test('macosDefaults covers all actions', () {
      final defaults = ShortcutDefaults.forPlatform(TargetPlatform.macOS);
      for (final action in ShortcutAction.values) {
        expect(defaults.containsKey(action), isTrue,
            reason: 'Missing default for ${action.key}');
      }
    });

    test('linuxDefaults equals windowsDefaults', () {
      final win = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final linux = ShortcutDefaults.forPlatform(TargetPlatform.linux);
      expect(win.keys.toSet(), linux.keys.toSet());
    });

    test('macOS uses meta instead of ctrl for modified shortcuts', () {
      final mac = ShortcutDefaults.forPlatform(TargetPlatform.macOS);
      final homeBooks = mac[ShortcutAction.homeTabBooks]!;
      expect(
        homeBooks.keyboardBindings
            .any((b) => b.modifiers.contains(bindings.ModifierKey.meta)),
        isTrue,
      );
      expect(
        homeBooks.keyboardBindings
            .any((b) => b.modifiers.contains(bindings.ModifierKey.ctrl)),
        isFalse,
      );
    });

    test('windows uses ctrl for modified shortcuts', () {
      final win = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final homeBooks = win[ShortcutAction.homeTabBooks]!;
      expect(
        homeBooks.keyboardBindings
            .any((b) => b.modifiers.contains(bindings.ModifierKey.ctrl)),
        isTrue,
      );
    });

    test('android defaults have empty keyboard bindings for home actions', () {
      final android = ShortcutDefaults.forPlatform(TargetPlatform.android);
      final homeBooks = android[ShortcutAction.homeTabBooks]!;
      expect(homeBooks.keyboardBindings, isEmpty);
    });
  });
}
