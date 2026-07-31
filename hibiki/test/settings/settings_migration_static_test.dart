import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final Map<String, List<String>> migratedPages = <String, List<String>>{
    // anki_settings_page.dart 现在导出的是无脚手架的 AnkiSettingsBody（直接平铺
    // 进「制卡」设置 destination，见 SettingsDestination.body），因此不再含
    // AdaptiveSettingsScaffold；仍用 AdaptiveSettingsSection 组织正文。
    'anki_settings_page.dart': <String>[
      'AdaptiveSettingsSection',
    ],
    // switch_settings_page.dart：schema 重构后零引用的孤儿页，已删除
    //（设置开关统一走 SettingsSwitchItem schema 渲染）。
    // TODO-317: miscellaneous_settings_page.dart now exports the no-scaffold
    // MiscellaneousSettingsBody and projects it through the unified settings
    // detail shell (buildSettingsDetailShell), mirroring AnkiSettingsBody — so
    // it no longer carries its own AdaptiveSettingsScaffold; still organises the
    // body with AdaptiveSettingsSection.
    'miscellaneous_settings_page.dart': <String>[
      'AdaptiveSettingsSection',
    ],
    'custom_fonts_page.dart': <String>[
      'AdaptiveSettingsScaffold',
      'AdaptiveSettingsSection',
    ],
    'custom_theme_page.dart': <String>[
      'AdaptiveSettingsScaffold',
      'AdaptiveSettingsSection',
    ],
  };
  final Set<String> noLegacySwitchRows = <String>{
    'anki_settings_page.dart',
    'miscellaneous_settings_page.dart',
    'custom_fonts_page.dart',
    'custom_theme_page.dart',
  };

  test('settings pages use adaptive settings primitives', () {
    for (final MapEntry<String, List<String>> entry in migratedPages.entries) {
      final File file = File('lib/src/pages/implementations/${entry.key}');
      final String source = file.readAsStringSync();

      for (final String requiredToken in entry.value) {
        expect(
          source,
          contains(requiredToken),
          reason: '${entry.key} should use $requiredToken',
        );
      }
    }
  });

  test('settings pages do not use legacy switch rows', () {
    for (final String fileName in noLegacySwitchRows) {
      final File file = File('lib/src/pages/implementations/$fileName');
      final String source = file.readAsStringSync();

      expect(source, isNot(contains('SwitchListTile')),
          reason: '$fileName still uses SwitchListTile');
      expect(source, isNot(contains('adaptiveSwitch(')),
          reason: '$fileName still hand-rolls switch rows');
      // 带标识符边界：裸子串 `ListTile(` 会被共享组件 `HibikiListTile(` 命中
      // （`_withoutSharedComponentNames` 白名单里已把它列为合法共享组件），
      // 设置页哪天改用共享行组件就假红。Radio/Cupertino 变体在下面显式补回，
      // 保住原裸子串顺带盖住的范围。
      expect(containsIdentifierCall(source, 'ListTile'), isFalse,
          reason: '$fileName still uses ListTile instead of settings rows');
      expect(containsIdentifierCall(source, 'RadioListTile'), isFalse,
          reason:
              '$fileName still uses RadioListTile instead of settings rows');
      expect(containsIdentifierCall(source, 'CupertinoListTile'), isFalse,
          reason: '$fileName still uses CupertinoListTile');
      expect(source, isNot(contains('ExpansionTile(')),
          reason: '$fileName still uses ExpansionTile instead of sections');
      expect(source, isNot(contains('adaptiveSegmentedButton')),
          reason: '$fileName still hand-rolls segmented controls');
      expect(source, isNot(contains('adaptiveAppBar(')),
          reason: '$fileName still hand-rolls page scaffolding');
    }
  });
}
