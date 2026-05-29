import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readNormalizedSource(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}

void main() {
  const Map<String, List<String>> requiredFiles = <String, List<String>>{
    'lib/src/settings/settings_context.dart': <String>[
      'class SettingsContext',
      'AppModel appModel',
      'WidgetRef ref',
    ],
    'lib/src/settings/settings_destination.dart': <String>[
      'enum SettingsDestinationId',
      'sealed class SettingsItem',
      'class SettingsSwitchItem',
      'class SettingsSegmentedItem',
      'class SettingsSliderItem',
      'class SettingsStepperItem',
      'class SettingsCustomItem',
    ],
    'lib/src/settings/settings_schema.dart': <String>[
      'List<SettingsDestination> buildSettingsSchema',
      'SettingsDestination buildReaderQuickSettingsDestination',
      'SettingsDestinationId.appearance',
      'SettingsDestinationId.profiles',
      'SettingsDestinationId.readingDisplay',
      'SettingsDestinationId.readingControls',
      'SettingsDestinationId.lookup',
      'SettingsDestinationId.cardCreation',
      'SettingsDestinationId.listening',
      'buildSyncBackupDestination',
      'SettingsDestinationId.system',
      'SettingsDestinationId.diagnostics',
    ],
    'lib/src/sync/sync_settings_schema.dart': <String>[
      'SettingsDestination buildSyncBackupDestination',
      'SettingsDestinationId.syncBackup',
    ],
    'lib/src/settings/material_settings_renderer.dart': <String>[
      'class MaterialSettingsRenderer',
      'SegmentedButton',
      'Switch',
      'Slider',
      'HibikiPageScaffold',
    ],
    'lib/src/settings/cupertino_settings_renderer.dart': <String>[
      'class CupertinoSettingsRenderer',
      'CupertinoPageScaffold',
      'CupertinoSliverNavigationBar',
      'CupertinoListSection',
      'CupertinoSwitch',
      'CupertinoSlidingSegmentedControl',
    ],
    'lib/src/settings/settings_home_page.dart': <String>[
      'class SettingsHomePage',
      'DesktopContentKind.settings',
      'master-detail',
    ],
    'lib/src/settings/settings_detail_page.dart': <String>[
      'class SettingsDetailPage',
      'SettingsDestination destination',
    ],
  };

  test('settings redesign files define schema-first platform renderers', () {
    for (final MapEntry<String, List<String>> entry in requiredFiles.entries) {
      final File file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: '${entry.key} must exist');

      final String source = readNormalizedSource(entry.key);
      for (final String token in entry.value) {
        expect(
          source,
          contains(token),
          reason: '${entry.key} must contain $token',
        );
      }
    }
  });

  test('settings home no longer uses the old linear adaptive page', () {
    final String source = readNormalizedSource(
        'lib/src/pages/implementations/hibiki_settings_page.dart');

    expect(source, contains('SettingsHomePage'));
    expect(source, contains('buildReaderQuickSettingsDestination'));
    expect(source, isNot(contains('class _ReaderBehaviorSettingsPage')));
    expect(source, isNot(contains('class _AudiobookSettingsPage')));
    expect(source, isNot(contains('class _UpdateSettingsPage')));
    expect(source, isNot(contains('_buildReaderOnlySwitches')));
  });

  test('reader settings dialog uses shared MD3 dialog chrome', () {
    final String source = readNormalizedSource(
        'lib/src/pages/implementations/hibiki_settings_page.dart');

    expect(source, contains('HibikiDialogFrame('));
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
  });

  test('settings shared actions use MD3 dialog chrome', () {
    final String actionsSource =
        readNormalizedSource('lib/src/settings/settings_actions.dart');
    final String schemaSource =
        readNormalizedSource('lib/src/settings/settings_schema.dart');
    final String syncSource =
        readNormalizedSource('lib/src/sync/sync_settings_schema.dart');
    final String combined = '$actionsSource\n$schemaSource\n$syncSource';

    expect(actionsSource, contains('HibikiDialogFrame('));
    expect(actionsSource, contains('HibikiModalSheetFrame('));

    expect(actionsSource, isNot(contains('adaptiveAlertDialog(')));
    expect(schemaSource, isNot(contains('adaptiveAlertDialog(')));
    expect(syncSource, isNot(contains('adaptiveAlertDialog(')));
    expect(combined, contains('showSettingsConfirmationDialog('));
    expect(combined, contains('showSettingsProgressDialog('));
  });

  test('legacy adaptive alert factory is removed', () {
    final String source =
        readNormalizedSource('lib/src/utils/adaptive/adaptive_widgets.dart');

    expect(source, isNot(contains('adaptiveAlertDialog(')));
    expect(source, isNot(contains('CupertinoAlertDialog(')));
    expect(source, isNot(contains('AlertDialog(')));
  });

  test('display settings contains reader layout only', () {
    final String source = readNormalizedSource(
        'lib/src/pages/implementations/display_settings_page.dart');

    expect(source, isNot(contains('design_system_label')));
    expect(source, isNot(contains('ProfileSelector')));
  });

  test('settings schema uses task-oriented destinations', () {
    final String destinationSource =
        readNormalizedSource('lib/src/settings/settings_destination.dart');
    final String schemaSource =
        readNormalizedSource('lib/src/settings/settings_schema.dart');
    final String syncSource =
        readNormalizedSource('lib/src/sync/sync_settings_schema.dart');
    final String combined = '$destinationSource\n$schemaSource\n$syncSource';

    for (final String token in <String>[
      'SettingsDestinationId.appearance',
      'SettingsDestinationId.profiles',
      'SettingsDestinationId.readingDisplay',
      'SettingsDestinationId.readingControls',
      'SettingsDestinationId.lookup',
      'SettingsDestinationId.cardCreation',
      'SettingsDestinationId.listening',
      'SettingsDestinationId.syncBackup',
      'SettingsDestinationId.system',
      'SettingsDestinationId.diagnostics',
    ]) {
      expect(combined, contains(token), reason: 'missing $token');
    }

    expect(
        combined, isNot(contains('SettingsDestinationId.dictionaryAndCards')));
    expect(combined, isNot(contains('SettingsDestinationId.audiobook')));
    expect(schemaSource, isNot(contains('DictionarySettingsDialogPage')));
  });

  test('sync backup settings use standard schema rows for options', () {
    final String source =
        readNormalizedSource('lib/src/sync/sync_settings_schema.dart');

    expect(
        source, contains("SettingsCustomItem(\n            id: 'sync.mode'"));
    expect(source,
        contains("SettingsSwitchItem(\n            id: 'sync.statistics'"));
    expect(source,
        contains("SettingsSwitchItem(\n            id: 'sync.audiobook'"));
    expect(source, isNot(contains("id: 'sync.options'")));
    expect(source, isNot(contains('class _SyncOptionsWidget')));
  });

  test('settings tab does not duplicate schema-level header actions', () {
    final String source =
        readNormalizedSource('lib/src/pages/implementations/home_page.dart');

    expect(source, isNot(contains('buildSettingsActions')));
    expect(source, isNot(contains('options_language')));
    expect(source, isNot(contains('options_github')));
  });

  test('profile destination uses one picker row for the active profile', () {
    final String schemaSource =
        readNormalizedSource('lib/src/settings/settings_schema.dart');
    final String actionsSource =
        readNormalizedSource('lib/src/settings/settings_actions.dart');

    expect(schemaSource, contains('buildProfilePickerRow'));
    expect(schemaSource, isNot(contains('buildProfileSelectorRow')));
    expect(actionsSource, contains('AdaptiveSettingsPickerRow<int>'));
  });

  test('Cupertino icon font is bundled when CupertinoIcons are used', () {
    final String pubspec = readNormalizedSource('pubspec.yaml');

    expect(pubspec, contains('cupertino_icons:'));
  });

  test('profile switching waits for reader settings refresh', () {
    final String source =
        readNormalizedSource('lib/src/profile/profile_view_model.dart');

    expect(
      source,
      contains('await ReaderHibikiSource.readerSettings?.refreshFromDb();'),
    );
  });
}
