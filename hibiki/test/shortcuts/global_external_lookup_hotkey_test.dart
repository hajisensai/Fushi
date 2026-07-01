import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

// TODO-1066 / BUG-511 guards for the app-external global lookup hotkey.
void main() {
  group('globalExternalLookup exists in its own scope', () {
    test('enum has globalExternalLookup, scope=globalExternal', () {
      expect(
        ShortcutAction.values.map((ShortcutAction a) => a.name),
        contains('globalExternalLookup'),
      );
      expect(
        ShortcutAction.globalExternalLookup.scope,
        ShortcutScope.globalExternal,
      );
      expect(ShortcutAction.globalExternalLookup.key, 'global_external_lookup');
    });

    test('globalExternal is its own co-active group', () {
      expect(
        ShortcutScope.globalExternal.coactiveScopes,
        const <ShortcutScope>[ShortcutScope.globalExternal],
      );
      for (final ShortcutScope other in ShortcutScope.values) {
        if (other == ShortcutScope.globalExternal) continue;
        expect(
          other.coactiveScopes.contains(ShortcutScope.globalExternal),
          isFalse,
        );
      }
    });
  });

  group('defaults', () {
    test('desktop default == Ctrl+Alt+D', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
            platform)[ShortcutAction.globalExternalLookup]!;
        expect(set.keyboardBindings, hasLength(1));
        final InputBinding binding = set.keyboardBindings.first;
        expect(binding.key, LogicalKeyboardKey.keyD);
        expect(
          binding.modifiers,
          <ModifierKey>{ModifierKey.ctrl, ModifierKey.alt},
        );
        expect(binding.physicalKey, PhysicalKeyboardKey.keyD);
      }
    });

    test('macOS default swaps Ctrl for Meta', () {
      final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
          TargetPlatform.macOS)[ShortcutAction.globalExternalLookup]!;
      expect(set.keyboardBindings, hasLength(1));
      final InputBinding binding = set.keyboardBindings.first;
      expect(binding.key, LogicalKeyboardKey.keyD);
      expect(
        binding.modifiers,
        <ModifierKey>{ModifierKey.meta, ModifierKey.alt},
      );
    });

    test('mobile has no binding for this scope', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
            platform)[ShortcutAction.globalExternalLookup]!;
        expect(set.keyboardBindings, isEmpty);
        expect(set.gamepadBindings, isEmpty);
      }
    });

    test('all 3 platform tables register the action', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.android,
      ]) {
        expect(
          ShortcutDefaults.forPlatform(platform)
              .containsKey(ShortcutAction.globalExternalLookup),
          isTrue,
        );
      }
    });
  });

  group('schema migration', () {
    test('schema version bumped to >= 4', () {
      expect(kShortcutSchemaVersion, greaterThanOrEqualTo(4));
    });

    test('legacy snapshot without the key upgrades to default Ctrl+Alt+D', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
      const String legacyJson = '{'
          '"__schema_version__": 3,'
          '"reader_page_forward": {"keyboard": ["KeyN"], "gamepad": [], "mouse": []}'
          '}';
      registry.loadFromJsonString(legacyJson, TargetPlatform.windows);

      final ShortcutBindingSet set =
          registry.bindingsFor(ShortcutAction.globalExternalLookup);
      expect(set.keyboardBindings, hasLength(1));
      expect(set.keyboardBindings.first.key, LogicalKeyboardKey.keyD);
      expect(
        set.keyboardBindings.first.modifiers,
        <ModifierKey>{ModifierKey.ctrl, ModifierKey.alt},
      );

      final ShortcutBindingSet fwd =
          registry.bindingsFor(ShortcutAction.readerPageForward);
      expect(fwd.keyboardBindings, hasLength(1));
      expect(fwd.keyboardBindings.first.key, LogicalKeyboardKey.keyN);
    });

    test('user-cleared hotkey is not refilled on upgrade', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
      const String json = '{'
          '"__schema_version__": 4,'
          '"global_external_lookup": {"keyboard": [], "gamepad": [], "mouse": []}'
          '}';
      registry.loadFromJsonString(json, TargetPlatform.windows);
      expect(
        registry
            .bindingsFor(ShortcutAction.globalExternalLookup)
            .keyboardBindings,
        isEmpty,
      );
    });
  });

  group('controller hotkey source guard', () {
    final String controllerSrc = File(
      'lib/src/lookup/global_lookup_controller.dart',
    ).readAsStringSync();

    test('controller reads binding from registry (not hard-coded)', () {
      expect(
        controllerSrc.contains('ShortcutAction.globalExternalLookup'),
        isTrue,
      );
      expect(
        controllerSrc
            .contains('bindingsFor(ShortcutAction.globalExternalLookup)'),
        isTrue,
      );
      expect(
        controllerSrc.contains('addListener(_onRegistryChanged)'),
        isTrue,
      );
    });

    test('controller no longer hard-codes the Ctrl+Alt+D constant', () {
      expect(
        controllerSrc.contains('key: PhysicalKeyboardKey.keyD'),
        isFalse,
      );
      expect(
        controllerSrc.contains(
            'modifiers: <HotKeyModifier>[HotKeyModifier.control, HotKeyModifier.alt]'),
        isFalse,
      );
    });
  });

  group('settings page label exhaustiveness', () {
    final String pageSrc = File(
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ).readAsStringSync();

    test('_actionLabel covers globalExternalLookup', () {
      expect(
        pageSrc.contains('case ShortcutAction.globalExternalLookup:'),
        isTrue,
      );
    });

    test('_scopeLabel covers globalExternal', () {
      expect(
        pageSrc.contains('case ShortcutScope.globalExternal:'),
        isTrue,
      );
    });

    test('settings page still iterates ShortcutScope.values', () {
      expect(
        RegExp('for'
                r'\s*\(\s*final\s+ShortcutScope\s+scope\s+in\s+'
                r'ShortcutScope\.values')
            .hasMatch(pageSrc),
        isTrue,
      );
    });
  });
}
