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

    test(
        'iOS defaults cover all actions and match the mobile (android) mapping',
        () {
      // iOS routes to Cupertino but mounts the same shortcut-wired pages, and
      // forPlatform maps both iOS and android to the _mobile profile, so their
      // default bindings must be identical for every action.
      final ios = ShortcutDefaults.forPlatform(TargetPlatform.iOS);
      final android = ShortcutDefaults.forPlatform(TargetPlatform.android);
      for (final action in ShortcutAction.values) {
        expect(ios.containsKey(action), isTrue,
            reason: 'Missing iOS default for ${action.key}');
        final ShortcutBindingSet iosSet = ios[action]!;
        final ShortcutBindingSet androidSet = android[action]!;
        expect(
          iosSet.keyboardBindings.map((b) => b.serialize()).toList(),
          androidSet.keyboardBindings.map((b) => b.serialize()).toList(),
          reason: 'iOS keyboard bindings differ from android for ${action.key}',
        );
        expect(
          iosSet.gamepadBindings.map((b) => b.serialize()).toList(),
          androidSet.gamepadBindings.map((b) => b.serialize()).toList(),
          reason: 'iOS gamepad bindings differ from android for ${action.key}',
        );
      }
    });

    test('iOS home actions have empty keyboard bindings (mobile profile)', () {
      final ios = ShortcutDefaults.forPlatform(TargetPlatform.iOS);
      expect(ios[ShortcutAction.homeTabBooks]!.keyboardBindings, isEmpty);
    });

    test(
        'globalBack has no gamepad binding by default (avoids Android B=back double-trigger)',
        () {
      final win = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final globalBack = win[ShortcutAction.globalBack]!;
      expect(globalBack.gamepadBindings, isEmpty);
    });

    test(
        'audiobook sentence navigation has no gamepad default (would be shadowed '
        'by reader RB/LB page-turn on the reader page)', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.linux,
      ]) {
        final defaults = ShortcutDefaults.forPlatform(platform);
        expect(defaults[ShortcutAction.audiobookNextSentence]!.gamepadBindings,
            isEmpty,
            reason: 'next sentence on $platform');
        expect(defaults[ShortcutAction.audiobookPrevSentence]!.gamepadBindings,
            isEmpty,
            reason: 'prev sentence on $platform');
      }
    });

    test(
        'no reader-group gamepad button is owned by more than one action '
        '(no shadowed gamepad default on the reader page)', () {
      final defaults = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final seen = <GamepadButton, ShortcutAction>{};
      for (final scope in ShortcutScope.reader.coactiveScopes) {
        for (final action in ShortcutAction.actionsForScope(scope)) {
          for (final gp in defaults[action]!.gamepadBindings) {
            expect(seen.containsKey(gp.button), isFalse,
                reason: '${gp.button} bound to both ${seen[gp.button]?.key} '
                    'and ${action.key} — the later one is shadowed');
            seen[gp.button] = action;
          }
        }
      }
    });

    test('global scroll-page actions bind to RB (down) and LB (up)', () {
      final win = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      expect(
        win[ShortcutAction.globalScrollPageDown]!
            .gamepadBindings
            .map((b) => b.button),
        contains(GamepadButton.rb),
      );
      expect(
        win[ShortcutAction.globalScrollPageUp]!
            .gamepadBindings
            .map((b) => b.button),
        contains(GamepadButton.lb),
      );
    });

    test(
        'global scroll-page RB/LB are not a reader-group conflict '
        '(they live in the [home, global] group)', () {
      // RB/LB are reader page-turn in the reader group; global scroll lives in
      // the [home, global] group, so scanning the reader group must still see
      // RB/LB owned ONLY by reader page-turn (no global action leaked in).
      final defaults = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final seen = <GamepadButton, ShortcutAction>{};
      for (final scope in ShortcutScope.reader.coactiveScopes) {
        for (final action in ShortcutAction.actionsForScope(scope)) {
          for (final gp in defaults[action]!.gamepadBindings) {
            seen[gp.button] = action;
          }
        }
      }
      expect(seen[GamepadButton.rb], ShortcutAction.readerPageForward);
      expect(seen[GamepadButton.lb], ShortcutAction.readerPageBackward);
    });

    test('home tab prev/next cycle on LT/RT and focus-search on Y', () {
      final defaults = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      expect(
        defaults[ShortcutAction.homeTabPrev]!
            .gamepadBindings
            .map((b) => b.button),
        contains(GamepadButton.lt),
      );
      expect(
        defaults[ShortcutAction.homeTabNext]!
            .gamepadBindings
            .map((b) => b.button),
        contains(GamepadButton.rt),
      );
      expect(
        defaults[ShortcutAction.homeFocusSearch]!
            .gamepadBindings
            .map((b) => b.button),
        contains(GamepadButton.y),
      );
    });
  });
}
