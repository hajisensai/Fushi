import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final Map<String, List<String>> migratedPages = <String, List<String>>{
    'anki_settings_page.dart': <String>[
      'AdaptiveSettingsScaffold',
      'AdaptiveSettingsSection',
    ],
    'switch_settings_page.dart': <String>[
      'AdaptiveSettingsSection',
      'AdaptiveSettingsSwitchRow',
    ],
    'miscellaneous_settings_page.dart': <String>[
      'AdaptiveSettingsScaffold',
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
    'switch_settings_page.dart',
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
      expect(source, isNot(contains('ListTile(')),
          reason: '$fileName still uses ListTile instead of settings rows');
      expect(source, isNot(contains('ExpansionTile(')),
          reason: '$fileName still uses ExpansionTile instead of sections');
      expect(source, isNot(contains('adaptiveSegmentedButton')),
          reason: '$fileName still hand-rolls segmented controls');
      expect(source, isNot(contains('adaptiveAppBar(')),
          reason: '$fileName still hand-rolls page scaffolding');
    }
  });
}
