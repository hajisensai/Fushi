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
      'SettingsDestinationId.reading',
      'SettingsDestinationId.lookup',
      'SettingsDestinationId.cardCreation',
      'SettingsDestinationId.listening',
      'buildSyncBackupDestination',
      'SettingsDestinationId.system',
    ],
    'lib/src/sync/sync_settings_schema.dart': <String>[
      'SettingsDestination buildSyncBackupDestination',
      'SettingsDestinationId.syncBackup',
      'sync.sync_now',
      'runManualFullSync',
    ],
    // schema 行的自适应组件收口在共享 settings_schema_widgets（见下条），两个渲染器
    // 只保留各自平台外壳并复用共享 SettingsSchemaSection。
    'lib/src/settings/material_settings_renderer.dart': <String>[
      'class MaterialSettingsRenderer',
      'SettingsSchemaSection',
      'HibikiPageScaffold',
    ],
    'lib/src/settings/cupertino_settings_renderer.dart': <String>[
      'class CupertinoSettingsRenderer',
      'CupertinoPageScaffold',
      'CupertinoSliverNavigationBar',
      'SettingsSchemaSection',
    ],
    'lib/src/settings/settings_schema_widgets.dart': <String>[
      'class SettingsSchemaSection',
      'class SettingsSchemaItem',
      'AdaptiveSettingsSection',
      'AdaptiveSettingsSwitchRow',
      'AdaptiveSettingsSegmentedRow',
      'AdaptiveSettingsSliderRow',
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

  test('settings renderers use shared MD3 spacing tokens', () {
    final String materialSource = readNormalizedSource(
        'lib/src/settings/material_settings_renderer.dart');
    final String cupertinoSource = readNormalizedSource(
        'lib/src/settings/cupertino_settings_renderer.dart');

    expect(materialSource, contains('HibikiDesignTokens.of(context)'));
    expect(cupertinoSource, contains('HibikiDesignTokens.of('));

    for (final String source in <String>[materialSource, cupertinoSource]) {
      expect(source, isNot(contains('EdgeInsets.fromLTRB(16, 8, 16, 16)')));
      expect(
          source, isNot(contains('const EdgeInsets.symmetric(horizontal: 16')));
      expect(
          source, isNot(contains('const EdgeInsets.symmetric(horizontal: 8')));
      expect(source, isNot(contains('const EdgeInsets.only(bottom: 12)')));
      expect(source, isNot(contains('const EdgeInsets.only(bottom: 6)')));
      expect(
          source, isNot(contains('const EdgeInsets.fromLTRB(12, 6, 12, 0)')));
      expect(source, isNot(contains('const EdgeInsets.only(right: 12)')));
      expect(source, isNot(contains('const EdgeInsets.only(top: 8)')));
      expect(source, isNot(contains('const SizedBox(height: 4)')));
    }
  });

  test('legacy adaptive alert factory is removed', () {
    final String source =
        readNormalizedSource('lib/src/utils/adaptive/adaptive_widgets.dart');

    expect(source, isNot(contains('adaptiveAlertDialog(')));
    expect(source, isNot(contains('CupertinoAlertDialog(')));
    expect(source, isNot(contains('AlertDialog(')));
  });

  test('legacy standalone display settings page is removed', () {
    // TODO-317: the residual DisplaySettingsPage (an AdaptiveSettingsScaffold
    // sub-page with zero live `lib/` references — its appearance row already
    // pointed elsewhere) was deleted. Reader display settings now live solely in
    // the schema `reading` destination rendered through the unified detail shell.
    expect(
      File('lib/src/pages/implementations/display_settings_page.dart')
          .existsSync(),
      isFalse,
      reason: 'DisplaySettingsPage should be deleted, not resurrected',
    );
    expect(
      readNormalizedSource('lib/pages.dart'),
      isNot(contains('display_settings_page.dart')),
      reason: 'pages barrel must not export the deleted display settings page',
    );
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
      'SettingsDestinationId.reading',
      'SettingsDestinationId.lookup',
      'SettingsDestinationId.cardCreation',
      'SettingsDestinationId.listening',
      'SettingsDestinationId.syncBackup',
      'SettingsDestinationId.system',
    ]) {
      expect(combined, contains(token), reason: 'missing $token');
    }

    expect(
        combined, isNot(contains('SettingsDestinationId.dictionaryAndCards')));
    expect(combined, isNot(contains('SettingsDestinationId.audiobook')));
    expect(schemaSource, isNot(contains('DictionarySettingsDialogPage')));
  });

  test('custom fonts are grouped with app appearance typography', () {
    final String schemaSource =
        readNormalizedSource('lib/src/settings/settings_schema.dart');
    final int appearanceStart =
        schemaSource.indexOf('SettingsDestination _appearanceDestination()');
    final int profilesStart =
        schemaSource.indexOf('SettingsDestination _profilesDestination()');
    final int readingStart =
        schemaSource.indexOf('SettingsDestination _readingDestination()');
    final int lookupStart =
        schemaSource.indexOf('SettingsDestination _lookupDestination()');

    expect(appearanceStart, isNonNegative);
    expect(profilesStart, isNonNegative);
    expect(readingStart, isNonNegative);
    expect(lookupStart, isNonNegative);

    final String appearanceSource =
        schemaSource.substring(appearanceStart, profilesStart);
    final String readingSource =
        schemaSource.substring(readingStart, lookupStart);

    expect(appearanceSource, contains('CustomFontsPage'));
    expect(appearanceSource, contains("id: 'appearance.font_catalog'"));
    expect(appearanceSource, contains('t.custom_fonts_catalog_title'));
    expect(appearanceSource, isNot(contains("id: 'appearance.fonts_app_ui'")));
    expect(appearanceSource, isNot(contains("id: 'appearance.fonts_body'")));
    expect(
      appearanceSource,
      isNot(contains("id: 'appearance.fonts_dictionary'")),
    );
    expect(readingSource, isNot(contains('CustomFontsPage')));
  });

  test('reader quick settings project from schema reader placements', () {
    final String schemaSource =
        readNormalizedSource('lib/src/settings/settings_schema.dart');
    final String destinationSource =
        readNormalizedSource('lib/src/settings/settings_destination.dart');
    final String sheetSource = readNormalizedSource(
        'lib/src/media/audiobook/reader_quick_settings_sheet.dart');
    expect(schemaSource,
        contains('Map<ReaderGroup, List<SettingsItem>> collectReaderItems'));
    expect(schemaSource, contains('item.reader'));
    expect(schemaSource,
        isNot(contains("item.id == 'lookup.auto_read_on_lookup' ||")));

    expect(destinationSource, contains('lookup'));
    expect(schemaSource, contains('sectionFor(ReaderGroup.lookup'));
    expect(sheetSource, contains("page: 'lookup'"));
    expect(sheetSource, contains('ReaderGroup.lookup'));

    final int autoReadStart =
        schemaSource.indexOf("id: 'lookup.auto_read_on_lookup'");
    final int pauseStart = schemaSource.indexOf("id: 'lookup.pause_on_lookup'");
    expect(autoReadStart, isNonNegative);
    expect(pauseStart, isNonNegative);

    final String autoReadSource =
        schemaSource.substring(autoReadStart, pauseStart);
    final String pauseSource =
        schemaSource.substring(pauseStart, pauseStart + 520);
    expect(autoReadSource, contains('group: ReaderGroup.lookup'));
    expect(pauseSource, contains('group: ReaderGroup.lookup'));
    expect(autoReadSource, isNot(contains('group: ReaderGroup.behavior')));
    expect(pauseSource, isNot(contains('group: ReaderGroup.behavior')));

    // TODO-436：「滑动关闭弹窗」是查词弹窗手势行为，归查词分组（ReaderGroup.lookup），
    // 不得回到阅读控制（ReaderGroup.behavior）。
    final int swipeCloseStart =
        schemaSource.indexOf("id: 'reading_controls.enable_swipe_to_close'");
    expect(swipeCloseStart, isNonNegative);
    final String swipeCloseSource =
        schemaSource.substring(swipeCloseStart, swipeCloseStart + 360);
    expect(swipeCloseSource, contains('group: ReaderGroup.lookup'));
    expect(swipeCloseSource, isNot(contains('group: ReaderGroup.behavior')));
  });

  test('popup instant scroll is a global lookup display setting', () {
    final String schemaSource =
        readNormalizedSource('lib/src/settings/settings_schema.dart');
    final int displayStart = schemaSource.indexOf(
      'title: t.settings_section_lookup_display',
    );
    final int cardStart =
        schemaSource.indexOf('SettingsDestination _cardCreationDestination()');
    expect(displayStart, isNonNegative);
    expect(cardStart, greaterThan(displayStart));

    final String displaySource =
        schemaSource.substring(displayStart, cardStart);
    expect(displaySource, contains("id: 'lookup.popup_instant_scroll'"));
    expect(displaySource, contains('t.popup_instant_scroll'));
    expect(displaySource, contains('popupInstantScroll'));
    expect(
      displaySource,
      isNot(contains('ReaderPlacement(')),
      reason:
          'This controls shared lookup popup behavior across reader, video, '
          'and dictionary surfaces, so it must not become reader-only.',
    );
  });

  test('reader quick settings reuse the shared theme selector', () {
    final String sheetSource = readNormalizedSource(
        'lib/src/media/audiobook/reader_quick_settings_sheet.dart');
    final String actionsSource =
        readNormalizedSource('lib/src/settings/settings_actions.dart');

    expect(actionsSource, contains('Widget buildThemeSelector'));
    expect(
        sheetSource, contains('buildThemeSelector(_themeSettingsContext())'));
    expect(sheetSource, isNot(contains('TtuReaderSettings.availableThemes')));
    expect(sheetSource, isNot(contains('buildReaderThemeChip(')));
  });

  test('sync backup settings use standard schema rows for options', () {
    final String source =
        readNormalizedSource('lib/src/sync/sync_settings_schema.dart');

    expect(
        source, contains("SettingsCustomItem(\n            id: 'sync.mode'"));
    expect(source,
        contains("SettingsSwitchItem(\n            id: 'sync.statistics'"));
    expect(
        source,
        isNot(
            contains("SettingsSwitchItem(\n            id: 'sync.audiobook'")));
    expect(source, isNot(contains("id: 'sync.audiobook'")));
    expect(source,
        contains("SettingsSwitchItem(\n            id: 'sync.dictionary'"));
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

  test(
      'wide settings nav pane gets a tonal container background (material only)',
      () {
    final String source =
        readNormalizedSource('lib/src/settings/settings_home_page.dart');
    // MD3 list-detail: nav pane on tonal token surface (surfaces.group =
    // surfaceContainerLow), gated to Material via the cupertino branch.
    expect(source, contains('tokens.surfaces.group'));
    expect(source, contains('cupertino ? null :'));
  });

  test('material destination list uses pill selection + gated chevron', () {
    final String source = readNormalizedSource(
        'lib/src/settings/material_settings_renderer.dart');
    expect(source, contains('HibikiListItemSelectedShape'));
    expect(source, contains('pushRoutes ? const Icon(Icons.chevron_right)'));
  });

  test('settings lists and schema sections opt into contained surfaces', () {
    final String shared =
        readNormalizedSource('lib/src/utils/components/settings_shared.dart');
    final String schema =
        readNormalizedSource('lib/src/settings/settings_schema_widgets.dart');
    final String material = readNormalizedSource(
        'lib/src/settings/material_settings_renderer.dart');

    expect(shared, contains('class AdaptiveSettingsSurface'),
        reason: 'destination lists and non-row groups need the same surface');
    expect(shared, contains('SettingsSectionTitlePlacement.inside'));
    expect(schema,
        contains('titlePlacement: SettingsSectionTitlePlacement.inside'),
        reason:
            'schema detail section titles such as System must live inside the section surface');
    expect(material, contains('AdaptiveSettingsSection('),
        reason: 'Material destination list should be one grouped section');
    expect(material, contains('surfaceColor: tokens.surfaces.card'),
        reason:
            'wide supporting-pane list needs a visible lightweight surface over its tonal pane');
    expect(material, isNot(contains('ListView.separated(')),
        reason: 'destination rows should not be a bare separated list');
  });

  test('settings Material polish keeps surfaces outlined and actions aligned',
      () {
    final String shared =
        readNormalizedSource('lib/src/utils/components/settings_shared.dart');

    expect(shared, contains('color ?? tokens.surfaces.card'),
        reason:
            'right-pane sections should read as card surfaces, not page fill');
    expect(shared, contains('borderColor: tokens.surfaces.outline'),
        reason: 'settings section surfaces need a lightweight MD3 outline');
    expect(shared, contains('endIndent:'));
    expect(shared, contains('tokens.spacing.rowHorizontal'),
        reason: 'row dividers should respect the section content density');
    expect(shared, contains('Alignment.centerRight'),
        reason: 'inline trailing actions must be visually right-aligned');
  });

  test('settings rows bound long text and inline controls for MD3 density', () {
    final String shared =
        readNormalizedSource('lib/src/utils/components/settings_shared.dart');
    final String destination =
        readNormalizedSource('lib/src/settings/settings_destination.dart');

    expect(shared, contains('kSettingsRowTitleMaxLines'));
    expect(shared, contains('kSettingsRowSubtitleMaxLines'));
    expect(shared, contains('maxLines: kSettingsRowTitleMaxLines'));
    expect(shared, contains('maxLines: kSettingsRowSubtitleMaxLines'));
    expect(shared, contains('kSettingsPickerDefaultWidth'));
    expect(shared, contains('kSettingsPickerMinInlineWidth'));
    expect(shared, contains('trailingFlexible: !cupertino && !controlBelow'));
    expect(shared, contains('LayoutBuilder('),
        reason:
            'inline picker controls must be bounded by the settings row width');
    expect(destination, contains('this.controlBelow = true'),
        reason:
            'schema segmented rows default to the readable below-label form');
    for (final String banned in <String>[
      'ListTile(',
      'SwitchListTile(',
      'ExpansionTile(',
    ]) {
      expect(shared, isNot(contains(banned)),
          reason: 'settings_shared.dart must keep the shared MD3 row system');
    }
    expect(shared, isNot(contains('return Card(')),
        reason: 'settings_shared.dart must not use a bare Material Card');
  });

  test('unified settings detail shell is the single page chrome (TODO-317)',
      () {
    // The shared shell delegates to the active platform renderer's
    // buildDetailPage, so every page built on it gets the SAME chrome
    // (HibikiPageScaffold + 24px + AdaptiveSettingsSection on Material).
    final String shell =
        readNormalizedSource('lib/src/settings/settings_detail_page.dart');
    expect(shell, contains('Widget buildSettingsDetailShell('));
    expect(shell, contains('renderer.buildDetailPage('));

    // Every settings sub-page that the unified detail panel can navigate into
    // must route through that one shell — NOT its own bespoke scaffold — so the
    // user never sees a style jump between the detail pane and what it opens.
    // (Anki / Profile are projected as destination bodies and so are covered by
    // the renderer directly; these two are pushed sub-pages.)
    for (final String path in <String>[
      'lib/src/pages/implementations/shortcut_settings_page.dart',
      'lib/src/pages/implementations/miscellaneous_settings_page.dart',
    ]) {
      final String source = readNormalizedSource(path);
      expect(source, contains('buildSettingsDetailShell('),
          reason:
              '$path must render through the unified settings detail shell');
      // No parallel page-shell vocabulary: the converged pages do not stand up
      // their own AdaptiveSettingsScaffold or hand-rolled HibikiPageScaffold.
      expect(source, isNot(contains('AdaptiveSettingsScaffold(')),
          reason: '$path must not reintroduce its own settings scaffold');
      expect(source, isNot(contains('return HibikiPageScaffold(')),
          reason: '$path must not hand-roll a page scaffold + bare list');
      // Body content is grouped into the shared section cards.
      expect(source, contains('AdaptiveSettingsSection('),
          reason: '$path body must use shared AdaptiveSettingsSection cards');
    }
  });
}
