import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// TODO-1309①: Ctrl+F must be a live reader-scope shortcut that opens the reader
/// navigation surface. Before this, Ctrl+F was only bound to the *home*-scope
/// `homeFocusSearch`, and the reader page only resolves the reader+audiobook
/// co-active group — so Ctrl+F was a dead key inside a book. The new
/// `readerOpenNavigation` action gives the reader page its own Ctrl+F that opens
/// the quick-settings sheet straight to the `location` (navigation) sub-page.
void main() {
  group('readerOpenNavigation (TODO-1309①)', () {
    test('lives in the reader scope', () {
      expect(ShortcutAction.readerOpenNavigation.scope, ShortcutScope.reader);
    });

    test('default-binds keyboard Ctrl+F on every desktop platform, no gamepad',
        () {
      for (final TargetPlatform p in const <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
            p)[ShortcutAction.readerOpenNavigation]!;
        expect(
          set.keyboardBindings,
          contains(const InputBinding(
            key: LogicalKeyboardKey.keyF,
            modifiers: <ModifierKey>{ModifierKey.ctrl},
          )),
          reason: 'Ctrl+F on $p',
        );
        expect(set.gamepadBindings, isEmpty,
            reason: 'no gamepad default on $p');
      }
    });

    test('macOS default swaps Ctrl for Meta (Cmd+F)', () {
      final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
          TargetPlatform.macOS)[ShortcutAction.readerOpenNavigation]!;
      expect(
        set.keyboardBindings,
        contains(const InputBinding(
          key: LogicalKeyboardKey.keyF,
          modifiers: <ModifierKey>{ModifierKey.meta},
        )),
      );
      expect(
        set.keyboardBindings.any((b) => b.modifiers.contains(ModifierKey.ctrl)),
        isFalse,
      );
    });

    test('mobile reader profile keeps the Ctrl+F keyboard binding', () {
      // The reader scope keeps keyboard bindings on mobile (Android tablets /
      // external keyboards), so Ctrl+F must survive the mobile profile.
      for (final TargetPlatform p in const <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
            p)[ShortcutAction.readerOpenNavigation]!;
        expect(
          set.keyboardBindings.map((b) => b.key),
          contains(LogicalKeyboardKey.keyF),
          reason: 'Ctrl+F survives the mobile reader profile on $p',
        );
      }
    });

    test('registry resolves Ctrl+F to readerOpenNavigation in the reader scope',
        () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
      registry.loadDefaults(TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.keyF,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
          scope: ShortcutScope.reader,
        ),
        ShortcutAction.readerOpenNavigation,
      );
    });

    test(
        'Ctrl+F stays home-scope search too: the two live in DISJOINT co-active '
        'groups so there is no real conflict', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
      registry.loadDefaults(TargetPlatform.windows);
      // Same physical chord, different co-active group → resolves to the
      // scope-appropriate action on each page (the reader page never resolves
      // the home group, and vice versa).
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.keyF,
          modifiers: const <ModifierKey>{ModifierKey.ctrl},
          scope: ShortcutScope.home,
        ),
        ShortcutAction.homeFocusSearch,
      );
      // The reader co-active group and the home co-active group must not
      // overlap, which is exactly why Ctrl+F can be reused across them.
      final Set<ShortcutScope> readerGroup =
          ShortcutScope.reader.coactiveScopes.toSet();
      final Set<ShortcutScope> homeGroup =
          ShortcutScope.home.coactiveScopes.toSet();
      expect(readerGroup.intersection(homeGroup), isEmpty);
    });

    test('no other reader co-active action shadows Ctrl+F', () {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      const InputBinding ctrlF = InputBinding(
        key: LogicalKeyboardKey.keyF,
        modifiers: <ModifierKey>{ModifierKey.ctrl},
      );
      for (final ShortcutScope scope in ShortcutScope.reader.coactiveScopes) {
        for (final ShortcutAction action
            in ShortcutAction.actionsForScope(scope)) {
          if (action == ShortcutAction.readerOpenNavigation) continue;
          expect(
            defaults[action]!.keyboardBindings.map((b) => b.serialize()),
            isNot(contains(ctrlF.serialize())),
            reason: '${action.key} also binds Ctrl+F — would shadow '
                'readerOpenNavigation',
          );
        }
      }
    });
  });
}
