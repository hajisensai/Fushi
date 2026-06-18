import 'package:flutter/services.dart' hide ModifierKey;
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

    test(
        'no reader-group keyboard binding is owned by more than one action '
        '(no shadowed keyboard default on the reader page)', () {
      // Mirrors the gamepad guard above. The Esc=exit bug came from Escape
      // being double-bound to readerToggleChrome AND readerDismissDict; enum
      // order silently picked one and the other never fired. Keyed on the full
      // InputBinding (key+modifiers) so Space vs Shift+Space stay distinct.
      final defaults = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final seen = <String, ShortcutAction>{};
      for (final scope in ShortcutScope.reader.coactiveScopes) {
        for (final action in ShortcutAction.actionsForScope(scope)) {
          for (final kb in defaults[action]!.keyboardBindings) {
            final key = kb.serialize();
            expect(seen.containsKey(key), isFalse,
                reason: '$key bound to both ${seen[key]?.key} and '
                    '${action.key} — the later one is shadowed');
            seen[key] = action;
          }
        }
      }
    });

    test(
        'reader bottom-bar toggle is on M (keyboard) and Y (gamepad); '
        'Esc is the reader back key, not the bar toggle', () {
      final win = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final toggle = win[ShortcutAction.readerToggleChrome]!;
      final dismiss = win[ShortcutAction.readerDismissDict]!;
      expect(toggle.keyboardBindings.map((b) => b.key),
          contains(LogicalKeyboardKey.keyM));
      expect(toggle.keyboardBindings.map((b) => b.key),
          isNot(contains(LogicalKeyboardKey.escape)));
      expect(toggle.gamepadBindings.map((b) => b.button),
          contains(GamepadButton.y));
      expect(dismiss.keyboardBindings.map((b) => b.key),
          contains(LogicalKeyboardKey.escape));
      expect(dismiss.gamepadBindings.map((b) => b.button),
          contains(GamepadButton.b));
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
      expect(seen[GamepadButton.dpadRight], ShortcutAction.readerPageForward);
      expect(seen[GamepadButton.dpadLeft], ShortcutAction.readerPageBackward);
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

    test('reader furigana toggle binds to R3 (thumbRight)', () {
      final defaults = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      expect(
        defaults[ShortcutAction.readerToggleFurigana]!
            .gamepadBindings
            .map((b) => b.button),
        contains(GamepadButton.thumbRight),
      );
    });

    test('reader lookup/card creation actions have configurable defaults', () {
      final defaults = ShortcutDefaults.forPlatform(TargetPlatform.windows);
      expect(
        defaults[ShortcutAction.readerLookupAtCursor]!.keyboardBindings,
        contains(const InputBinding(key: LogicalKeyboardKey.enter)),
      );
      expect(
        defaults[ShortcutAction.readerLookupAtCursor]!
            .gamepadBindings
            .map((b) => b.button),
        contains(GamepadButton.a),
      );
      expect(
        defaults[ShortcutAction.readerShiftLookup]!.keyboardBindings,
        contains(
          const InputBinding(
            key: LogicalKeyboardKey.enter,
            modifiers: <bindings.ModifierKey>{bindings.ModifierKey.shift},
          ),
        ),
      );
      expect(
        defaults[ShortcutAction.readerCreateCardFromPopup]!.keyboardBindings,
        contains(
          const InputBinding(
            key: LogicalKeyboardKey.enter,
            modifiers: <bindings.ModifierKey>{bindings.ModifierKey.ctrl},
          ),
        ),
      );
    });

    test(
        'video fullscreen toggle binds to both F and F12 on every platform '
        '(TODO-302: F12 is an additional fullscreen key)', () {
      for (final p in const <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final keys = ShortcutDefaults.forPlatform(
                p)[ShortcutAction.videoToggleFullscreen]!
            .keyboardBindings
            .map((b) => b.key)
            .toList();
        expect(keys, contains(LogicalKeyboardKey.keyF), reason: '$p');
        expect(keys, contains(LogicalKeyboardKey.f12), reason: '$p');
      }
    });

    test(
        'seek-to-clicked-sentence defaults to middle mouse on desktop & mobile',
        () {
      for (final p in const <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final set = ShortcutDefaults.forPlatform(
            p)[ShortcutAction.audiobookSeekToClickedSentence];
        expect(set, isNotNull, reason: '$p');
        expect(set!.mouseBindings, const [MouseBinding(1)], reason: '$p');
      }
    });
  });
}
