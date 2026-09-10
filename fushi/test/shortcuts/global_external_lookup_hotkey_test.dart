import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

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
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
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
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
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
      // 注册已表驱动（_osHotKeyActions 逐条 → _registerOneHotKey），故这里钉的是
      // 「绑定从 registry 里按动作取」这条语义本身，而不是某个动作名的字面量——
      // 后者在改成循环 / dart format 换行时都会假红，语义却一点没变。
      expect(
        RegExp(r'bindingsFor\(\s*action\s*[,)]').hasMatch(controllerSrc),
        isTrue,
        reason: 'controller 必须从 registry 取绑定，不得写死按键',
      );
      expect(
        controllerSrc.contains('addListener(_onRegistryChanged)'),
        isTrue,
      );
    });

    // globalExternal 的动作**不经 resolveKeyboard / 页面派发**，执行体只在
    // GlobalLookupController 的 _osHotKeyActions 表里登记。漏登记的表现是设置页
    // 照样渲染出可改键行、用户照样能录键保存，按下去什么都不发生——这是本仓
    // 反复出现的那类病，故按 scope 枚举正向核对，不逐个写死动作名。
    test('每个 globalExternal 动作都在控制器的执行体表里登记', () {
      final int tableStart = controllerSrc.indexOf('_osHotKeyActions =>');
      expect(tableStart, greaterThan(0),
          reason: 'OS 热键执行体表必须收口在 _osHotKeyActions 这一个地方');
      final int tableEnd = controllerSrc.indexOf('\n      };', tableStart);
      expect(tableEnd, greaterThan(tableStart));
      final String table = controllerSrc.substring(tableStart, tableEnd);

      final List<ShortcutAction> scoped = ShortcutAction.values
          .where((ShortcutAction a) => a.scope == ShortcutScope.globalExternal)
          .toList(growable: false);
      expect(scoped, isNotEmpty);
      for (final ShortcutAction action in scoped) {
        expect(
          table.contains('ShortcutAction.${action.name}:'),
          isTrue,
          reason: '${action.name} 是 globalExternal 动作，必须在 '
              '_osHotKeyActions 里登记执行体，否则「设置里能配、按了没反应」',
        );
      }
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
    // Labels moved into the shared shortcut_labels extensions (shortcut
    // settings refactor); the page renders via `action.label` / `scope.label`.
    final String labelsSrc = File(
      'lib/src/shortcuts/shortcut_labels.dart',
    ).readAsStringSync();
    final String pageSrc = File(
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ).readAsStringSync();

    test('ShortcutActionLabel covers globalExternalLookup', () {
      expect(
        labelsSrc.contains('case ShortcutAction.globalExternalLookup:'),
        isTrue,
      );
    });

    test('ShortcutScopeLabel covers globalExternal', () {
      expect(
        labelsSrc.contains('case ShortcutScope.globalExternal:'),
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
