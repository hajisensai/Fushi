import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const Map<String, List<String>> requiredComponentTokens =
      <String, List<String>>{
    'lib/src/utils/components/hibiki_design_tokens.dart': <String>[
      'class HibikiDesignTokens',
      'class HibikiRadii',
      'class HibikiSurfaceColors',
      'class HibikiTypeRoles',
      'static HibikiDesignTokens of',
    ],
    'lib/src/utils/components/hibiki_material_components.dart': <String>[
      'class HibikiCard',
      'class HibikiListItem',
      'class HibikiSearchField',
      'class HibikiTextField',
      'class HibikiSelectableChip',
      'class HibikiTagChip',
      'class HibikiBadge',
      'class HibikiPageHeader',
      'class HibikiPageScaffold',
      'class HibikiToolScaffold',
      'class HibikiTransientScaffold',
      'class HibikiOverlayScaffold',
      'class HibikiOverflowMenu',
      'class HibikiFilePickerRow',
      'class HibikiLogPanel',
      'class HibikiPopupSurface',
      'class HibikiCompactSearchRow',
      'class HibikiEditorPanel',
      'onLongPress',
    ],
    'lib/src/utils/components/settings_shared.dart': <String>[
      'class AdaptiveSettingsTextField',
      'HibikiCard(',
      'HibikiBadge(',
    ],
  };

  const Map<String, List<String>> migratedSurfaces = <String, List<String>>{
    'lib/src/settings/material_settings_renderer.dart': <String>[
      'HibikiListItem',
      'HibikiCard',
      'HibikiPageScaffold',
    ],
    'lib/src/settings/settings_home_page.dart': <String>[
      'HibikiPageHeader',
    ],
    'lib/src/utils/components/hibiki_list_tile.dart': <String>[
      'HibikiListItem',
    ],
    'lib/src/utils/components/hibiki_bottom_sheet.dart': <String>[
      'HibikiListItem',
    ],
    'lib/src/utils/components/hibiki_text_selection_controls.dart': <String>[
      'HibikiCard',
      'HibikiOverflowMenu',
    ],
    'lib/src/pages/implementations/home_dictionary_page.dart': <String>[
      'HibikiPageHeader',
      'HibikiSearchField',
      'HibikiCard',
      'HibikiListItem',
    ],
    'lib/src/pages/implementations/media_source_picker_dialog_page.dart':
        <String>[
      'HibikiListItem',
    ],
    'lib/src/pages/base_media_search_bar.dart': <String>[
      'HibikiSearchField',
      'TextEditingController',
      'FocusNode',
    ],
    'lib/src/pages/base_source_page.dart': <String>[
      'HibikiPopupSurface',
    ],
    'lib/src/pages/implementations/reading_statistics_page.dart': <String>[
      'HibikiPageScaffold',
      'HibikiCard',
      'HibikiDesignTokens',
    ],
    'lib/src/utils/components/hibiki_search_history.dart': <String>[
      'HibikiListItem',
      'HibikiDesignTokens',
    ],
    'lib/src/pages/implementations/collections_page.dart': <String>[
      'HibikiPageScaffold',
      'HibikiListItem',
    ],
    'lib/src/pages/implementations/tag_management_page.dart': <String>[
      'HibikiPageScaffold',
      'HibikiListItem',
      'HibikiTextField',
    ],
    'lib/src/pages/implementations/media_item_dialog_page.dart': <String>[
      'HibikiListItem',
    ],
    'lib/src/utils/misc/update_checker.dart': <String>[
      'HibikiCard',
    ],
    'lib/src/sync/sync_compare_dialog.dart': <String>[
      'HibikiOverflowMenu',
      'HibikiCard',
    ],
    'lib/src/media/audiobook/book_import_dialog.dart': <String>[
      'AdaptiveSettingsSection',
      'AdaptiveSettingsSwitchRow',
      'HibikiFilePickerRow',
      'HibikiTextField',
    ],
    'lib/src/media/audiobook/audiobook_import_dialog.dart': <String>[
      'AdaptiveSettingsSection',
      'HibikiFilePickerRow',
    ],
    'lib/src/pages/implementations/reader_hibiki_history_page.dart': <String>[
      'HibikiPageHeader',
      'HibikiCard',
      'HibikiTagChip',
      'HibikiBadge',
      '_bookCardShell',
    ],
    'lib/src/pages/implementations/dictionary_dialog_page.dart': <String>[
      'HibikiCard',
      'HibikiListItem',
      '_buildCategoryTile',
      '_buildDictCheckbox',
    ],
    'lib/src/pages/implementations/tag_picker_page.dart': <String>[
      'HibikiPageScaffold',
      'HibikiCard',
      'HibikiListItem',
    ],
    'lib/src/pages/implementations/illustrations_viewer_page.dart': <String>[
      'HibikiPageScaffold',
      'HibikiToolScaffold',
      'HibikiCard',
    ],
    'lib/src/pages/base_history_page.dart': <String>[
      'HibikiCard',
    ],
    'lib/src/pages/implementations/history_reader_page.dart': <String>[
      'HibikiDesignTokens',
    ],
    'lib/src/pages/implementations/debug_log_page.dart': <String>[
      'HibikiPageScaffold',
      'HibikiLogPanel',
    ],
    'lib/src/pages/implementations/error_log_page.dart': <String>[
      'HibikiPageScaffold',
      'HibikiLogPanel',
    ],
    'lib/src/pages/implementations/popup_dictionary_page.dart': <String>[
      'HibikiPopupSurface',
      'HibikiCompactSearchRow',
      'HibikiOverlayScaffold',
    ],
    'lib/src/pages/implementations/dictionary_popup_layer.dart': <String>[
      'HibikiPopupSurface',
    ],
    'lib/src/pages/implementations/floating_dict_page.dart': <String>[
      'HibikiPopupSurface',
      'HibikiCompactSearchRow',
    ],
    'lib/src/pages/implementations/book_css_editor_page.dart': <String>[
      'HibikiToolScaffold',
      'HibikiEditorPanel',
      'HibikiSelectableChip',
      'HibikiPlaceholderMessage',
    ],
    'lib/src/pages/implementations/anki_settings_page.dart': <String>[
      'AdaptiveSettingsTextField',
    ],
    'lib/src/pages/implementations/dictionary_settings_dialog_page.dart':
        <String>[
      'AdaptiveSettingsTextField',
      'HibikiEditorPanel',
    ],
    'lib/src/settings/settings_schema.dart': <String>[
      'HibikiTextField',
    ],
    'lib/src/sync/sync_settings_schema.dart': <String>[
      'HibikiTextField',
    ],
    'lib/src/pages/implementations/custom_theme_page.dart': <String>[
      'HibikiTextField',
      'HibikiDesignTokens',
    ],
    'lib/src/pages/implementations/custom_fonts_page.dart': <String>[
      'HibikiTextField',
    ],
    'lib/src/pages/implementations/lyrics_dialog_page.dart': <String>[
      'HibikiTextField',
    ],
    'lib/src/pages/implementations/profile_management_page.dart': <String>[
      'HibikiTextField',
    ],
    'lib/src/pages/implementations/miscellaneous_settings_page.dart': <String>[
      'HibikiCard',
      'HibikiBadge',
    ],
    'lib/src/media/audiobook/reader_quick_settings_sheet.dart': <String>[
      'HibikiTextField',
    ],
    'lib/src/pages/implementations/language_dialog_page.dart': <String>[
      'HibikiDesignTokens',
    ],
    'lib/src/media/audiobook/audiobook_play_bar.dart': <String>[
      'HibikiSelectableChip',
    ],
    'lib/src/pages/implementations/tag_filter_sheet.dart': <String>[
      'HibikiSelectableChip',
    ],
    'lib/src/pages/implementations/dictionary_popup_native.dart': <String>[
      'HibikiTagChip',
      'HibikiDesignTokens',
    ],
    'lib/src/pages/implementations/loading_page.dart': <String>[
      'HibikiTransientScaffold',
    ],
    'lib/src/pages/implementations/placeholder_source_page.dart': <String>[
      'HibikiTransientScaffold',
    ],
  };

  test('MD3 design token and shared component files exist', () {
    for (final MapEntry<String, List<String>> entry
        in requiredComponentTokens.entries) {
      final File file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: '${entry.key} must exist');
      final String source = file.readAsStringSync();
      for (final String token in entry.value) {
        expect(source, contains(token), reason: '${entry.key} lacks $token');
      }
    }
  });

  test('high exposure surfaces use shared MD3 components', () {
    for (final MapEntry<String, List<String>> entry
        in migratedSurfaces.entries) {
      final File file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: '${entry.key} must exist');
      final String source = file.readAsStringSync();
      for (final String token in entry.value) {
        expect(source, contains(token), reason: '${entry.key} lacks $token');
      }
    }
  });

  test('migrated surfaces do not instantiate old visual primitives directly',
      () {
    const Map<String, List<String>> bannedByFile = <String, List<String>>{
      'lib/src/settings/material_settings_renderer.dart': <String>[
        'ListTile(',
        'Card(',
        'surfaceContainerLowest',
      ],
      'lib/src/utils/components/hibiki_list_tile.dart': <String>[
        'ListTile(',
        'dense: true',
        'fontSize:',
      ],
      'lib/src/utils/components/hibiki_bottom_sheet.dart': <String>[
        'ListTile(',
        'dense: true',
      ],
      'lib/src/utils/components/hibiki_text_selection_controls.dart': <String>[
        'toolbarBuilder: (context, child) => Card(',
        'PopupMenuButton',
      ],
      'lib/src/pages/implementations/home_dictionary_page.dart': <String>[
        'TextField(',
        'Card(',
        'fontSize: 18',
        'fontSize: 13',
        'fontSize: 12',
        'surfaceContainerHigh',
      ],
      'lib/src/pages/implementations/media_source_picker_dialog_page.dart':
          <String>[
        'ListTile(',
        'fontSize:',
      ],
      'lib/src/pages/base_media_search_bar.dart': <String>[
        'material_floating_search_bar',
        'FloatingSearchBar',
        'FloatingSearchBarAction',
        'surfaceContainerHigh',
      ],
      'lib/src/pages/base_source_page.dart': <String>[
        'DecoratedBox(',
        'BorderRadius.circular(8)',
      ],
      'lib/src/pages/implementations/reading_statistics_page.dart': <String>[
        'Card(',
        'surfaceContainerHighest.withValues',
        'BorderRadius.circular(4)',
        'Radius.circular(2)',
        'fontSize: 9',
      ],
      'lib/src/utils/components/hibiki_search_history.dart': <String>[
        'fontSize:',
        'TextStyle(',
      ],
      'lib/src/utils/components/settings_shared.dart': <String>[
        'surfaceContainerLowest',
      ],
      'lib/src/pages/implementations/collections_page.dart': <String>[
        'ListTile(',
        'fontSize: 10',
      ],
      'lib/src/pages/implementations/tag_management_page.dart': <String>[
        'ListTile(',
        'OutlineInputBorder',
      ],
      'lib/src/pages/implementations/language_dialog_page.dart': <String>[
        'fontSize: 10',
      ],
      'lib/src/pages/implementations/media_item_dialog_page.dart': <String>[
        'ListTile(',
        'dense: true',
      ],
      'lib/src/utils/misc/update_checker.dart': <String>[
        'child: Card(',
      ],
      'lib/src/sync/sync_compare_dialog.dart': <String>[
        'PopupMenuButton',
        'BorderRadius.circular(8)',
      ],
      'lib/src/media/audiobook/book_import_dialog.dart': <String>[
        'SwitchListTile',
        'fontSize: 13',
        'fontSize: 11',
        'OutlineInputBorder',
      ],
      'lib/src/media/audiobook/audiobook_import_dialog.dart': <String>[
        'fontSize: 13',
        'fontSize: 11',
      ],
      'lib/src/pages/implementations/reader_hibiki_history_page.dart': <String>[
        'Material(',
        'surfaceContainerLow',
        'BorderRadius.circular(12)',
        'BorderRadius.circular(4)',
        'BorderRadius.circular(6)',
        'fontSize: 9',
      ],
      'lib/src/pages/implementations/dictionary_popup_native.dart': <String>[
        'TextStyle(',
        'BorderRadius.circular(4)',
        'fontSize: 10',
        'fontSize: 11',
      ],
      'lib/src/pages/implementations/dictionary_dialog_page.dart': <String>[
        'ExpansionTile',
        'CheckboxListTile',
        'fontSize: textTheme',
      ],
      'lib/src/pages/implementations/tag_picker_page.dart': <String>[
        'CheckboxListTile',
        'ListTile(',
      ],
      'lib/src/pages/implementations/illustrations_viewer_page.dart': <String>[
        'adaptiveAppBar',
        'surfaceContainerLow',
        'BorderRadius.circular(8)',
      ],
      'lib/src/pages/base_history_page.dart': <String>[
        'return Material(',
        'InkWell(',
      ],
      'lib/src/pages/implementations/history_reader_page.dart': <String>[
        'surfaceContainerLowest',
        'fontSize: textTheme',
      ],
      'lib/src/pages/implementations/debug_log_page.dart': <String>[
        'SingleChildScrollView(',
        'SelectableText(',
        'fontSize: 11',
      ],
      'lib/src/pages/implementations/error_log_page.dart': <String>[
        'SingleChildScrollView(',
        'SelectableText(',
        'fontSize: 12',
      ],
      'lib/src/pages/implementations/popup_dictionary_page.dart': <String>[
        'Scaffold(',
        'TextField(',
        'BorderRadius.circular(8)',
        'fontSize:',
      ],
      'lib/src/pages/implementations/dictionary_popup_layer.dart': <String>[
        'Container(',
        'BoxDecoration(',
        'BorderRadius.circular(8)',
      ],
      'lib/src/pages/implementations/loading_page.dart': <String>[
        'Scaffold(',
      ],
      'lib/src/pages/implementations/placeholder_source_page.dart': <String>[
        'Scaffold(',
      ],
      'lib/src/pages/implementations/floating_dict_page.dart': <String>[
        'DecoratedBox(',
        'TextField(',
        'BorderRadius.circular(',
        'fontSize:',
      ],
      'lib/src/pages/implementations/book_css_editor_page.dart': <String>[
        'adaptiveAppBar',
        'ChoiceChip(',
        'fontSize: 13',
        'OutlineInputBorder',
        'Center(child: Text(',
      ],
      'lib/src/pages/implementations/anki_settings_page.dart': <String>[
        'OutlineInputBorder',
      ],
      'lib/src/pages/implementations/dictionary_settings_dialog_page.dart':
          <String>[
        'fontSize: 13',
        'OutlineInputBorder',
      ],
      'lib/src/pages/implementations/blur_options_dialog_page.dart': <String>[
        'TextField(',
        'OutlineInputBorder',
      ],
      'lib/src/pages/implementations/media_item_edit_dialog_page.dart':
          <String>[
        'TextField(',
      ],
      'lib/src/pages/implementations/websocket_dialog_page.dart': <String>[
        'TextField(',
      ],
      'lib/src/settings/settings_schema.dart': <String>[
        'TextField(',
      ],
      'lib/src/sync/sync_settings_schema.dart': <String>[
        'TextField(',
        'OutlineInputBorder',
      ],
      'lib/src/pages/implementations/custom_theme_page.dart': <String>[
        'TextField(',
        'BorderRadius.circular(',
        'fontSize:',
      ],
      'lib/src/pages/implementations/custom_fonts_page.dart': <String>[
        'TextField(',
        'OutlineInputBorder',
      ],
      'lib/src/pages/implementations/lyrics_dialog_page.dart': <String>[
        'TextField(',
      ],
      'lib/src/pages/implementations/profile_management_page.dart': <String>[
        'TextField(',
      ],
      'lib/src/pages/implementations/miscellaneous_settings_page.dart':
          <String>[
        'BorderRadius.circular(16)',
        'BorderRadius.circular(13)',
        'shape: BoxShape.circle',
      ],
      'lib/src/media/audiobook/reader_quick_settings_sheet.dart': <String>[
        'TextField(',
        'OutlineInputBorder',
        'BorderRadius.circular(8)',
      ],
      'lib/src/media/audiobook/audiobook_play_bar.dart': <String>[
        'ChoiceChip(',
      ],
      'lib/src/pages/implementations/tag_filter_sheet.dart': <String>[
        'FilterChip(',
        'ChoiceChip(',
      ],
    };

    for (final MapEntry<String, List<String>> entry in bannedByFile.entries) {
      final String fileSource = File(entry.key).readAsStringSync();
      final String source =
          entry.key.endsWith('reader_hibiki_history_page.dart')
              ? _functionSource(
                  fileSource,
                  'Widget _bookCardShell({',
                  'Widget _titleOverlay(String title)',
                )
              : entry.key.endsWith('dictionary_dialog_page.dart')
                  ? _functionSource(
                      fileSource,
                      'Widget _buildCategoryTile({',
                      'Future<void> _downloadSelectedDictionaries(',
                    )
                  : _withoutSharedComponentNames(fileSource);
      for (final String banned in entry.value) {
        expect(source, isNot(contains(banned)),
            reason: '${entry.key} still contains $banned');
      }
    }
  });

  test('reader history hover overlays use design tokens', () {
    final String source = File(
      'lib/src/pages/implementations/reader_hibiki_history_page.dart',
    ).readAsStringSync();
    final String tagDropTarget = _functionSource(
      source,
      'class _BookDragTarget extends StatefulWidget',
      'class BookProfileDialogContent',
    );

    expect(tagDropTarget, contains('HibikiDesignTokens.of(context)'));
    expect(tagDropTarget, isNot(contains('BorderRadius.circular(12)')));
  });

  test('reader history tag bar uses shared MD3 tag chips', () {
    final String source = File(
      'lib/src/pages/implementations/reader_hibiki_history_page.dart',
    ).readAsStringSync();
    final String tagBar = _functionSource(
      source,
      'class _TagBarContent extends ConsumerStatefulWidget',
      'class _BookDragTarget extends StatefulWidget',
    );

    expect(tagBar, contains('HibikiTagChip('));
    expect(tagBar, isNot(contains('class _TagChip')));
    expect(tagBar, isNot(contains('BorderRadius.circular(16)')));
  });

  test('dictionary and popup surfaces use shared MD3 primitives', () {
    final String dictionaryManager = File(
      'lib/src/pages/implementations/dictionary_dialog_page.dart',
    ).readAsStringSync();
    final String managerEmptyState = _functionSource(
      dictionaryManager,
      'Widget _buildEmptyCategoryRow()',
      'Widget _buildDictionaryTile({',
    );
    final String managerTile = _functionSource(
      dictionaryManager,
      'Widget _buildDictionaryTile({',
      'Widget _buildDictionaryList(',
    );
    final String managerMenu = _functionSource(
      dictionaryManager,
      'Widget buildDictionaryTileTrailing(',
      'PopupMenuItem<VoidCallback> buildPopupItem({',
    );

    expect(managerEmptyState, contains('HibikiCard('));
    expect(managerEmptyState, isNot(contains('DecoratedBox(')));
    expect(managerEmptyState, isNot(contains('surfaceContainerLowest')));
    expect(managerTile, contains('HibikiCard('));
    expect(managerTile, contains('HibikiListItem('));
    expect(managerTile, isNot(contains('DecoratedBox(')));
    expect(managerTile, isNot(contains('surfaceContainerLowest')));
    expect(managerMenu, contains('HibikiOverflowMenu<VoidCallback>('));
    expect(managerMenu, isNot(contains('PopupMenuButton')));

    final String entrySource = File(
      'lib/src/pages/implementations/dictionary_entry_page.dart',
    ).readAsStringSync();
    expect(entrySource, contains('HibikiOverflowMenu<VoidCallback>('));
    expect(entrySource, isNot(contains('PopupMenuButton')));

    final String sourcePage =
        File('lib/src/pages/base_source_page.dart').readAsStringSync();
    final String dictionaryLoading = _functionSource(
      sourcePage,
      'Widget buildDictionaryLoading()',
      'Future<bool> onMineFromPopup',
    );
    expect(dictionaryLoading, contains('HibikiCard('));
    expect(
      _withoutSharedComponentNames(dictionaryLoading),
      isNot(contains('Card(')),
    );

    final String termSource = File(
      'lib/src/pages/implementations/dictionary_term_page.dart',
    ).readAsStringSync();
    expect(termSource, contains('HibikiCard('));
    expect(_withoutSharedComponentNames(termSource), isNot(contains('Card(')));
  });

  test('media search shell no longer depends on legacy floating search', () {
    for (final String path in <String>[
      'lib/src/pages/base_tab_page.dart',
      'lib/src/media/media_type.dart',
      'lib/src/media/sources/reader_hibiki_source.dart',
    ]) {
      final String source = File(path).readAsStringSync();
      expect(source, isNot(contains('material_floating_search_bar')),
          reason: '$path still imports legacy floating search');
      expect(source, isNot(contains('FloatingSearchBar')),
          reason: '$path still depends on legacy floating search widgets');
    }
  });

  test('custom theme preview uses shared MD3 card shell', () {
    final String source = File(
      'lib/src/pages/implementations/custom_theme_page.dart',
    ).readAsStringSync();
    final String previewCard = _functionSource(
      source,
      'Widget _buildPreviewCard(ColorScheme cs)',
      'Widget _swatch(',
    );
    expect(previewCard, contains('HibikiCard('));
    final String normalized = _withoutSharedComponentNames(previewCard);
    expect(normalized, isNot(contains('return Card(')));
    expect(normalized, isNot(contains('child: Card(')));
  });

  test('MD3 review report does not reopen completed app chrome scope', () {
    final String report = File(
      '../docs/reviews/2026-05-26-project-review.md',
    ).readAsStringSync();
    final String finalJudgment = _sectionSource(
      report,
      '### Overall Judgment',
      '### Verification',
    );
    final String finalNextScope = _sectionSource(
      report,
      '### Next Scope',
      report.length,
    );

    expect(finalJudgment, isNot(contains('仍有后续普通页面债务')));
    expect(finalJudgment, contains('内容渲染'));
    expect(finalNextScope, isNot(contains('collections/tag management')));
    expect(finalNextScope, isNot(contains('custom theme preview')));
    expect(finalNextScope, contains('native popup dictionary'));
    expect(finalNextScope, contains('reader history cards'));
  });
}

String _withoutSharedComponentNames(String source) {
  return source
      .replaceAll('HibikiCard(', 'HibikiSharedPanel(')
      .replaceAll('HibikiListItem(', 'HibikiSharedRow(')
      .replaceAll('HibikiListTile(', 'HibikiSharedTile(')
      .replaceAll('HibikiSearchField(', 'HibikiSharedSearch(')
      .replaceAll('HibikiTextField(', 'HibikiSharedField(')
      .replaceAll('HibikiOverflowMenu(', 'HibikiSharedOverflow(')
      .replaceAll('HibikiTransientScaffold(', 'HibikiSharedTransient(')
      .replaceAll('HibikiOverlayScaffold(', 'HibikiSharedOverlay(');
}

String _functionSource(
  String source,
  String startToken,
  String endToken,
) {
  final int start = source.indexOf(startToken);
  final int end = source.indexOf(endToken, start + startToken.length);
  expect(start, isNonNegative, reason: 'missing $startToken');
  expect(end, greaterThan(start),
      reason: 'missing $endToken after $startToken');
  return source.substring(start, end);
}

String _sectionSource(
  String source,
  String startToken,
  Object endToken,
) {
  final int start = source.lastIndexOf(startToken);
  expect(start, isNonNegative, reason: 'missing final $startToken');
  final int end = switch (endToken) {
    final int endIndex => endIndex,
    final String token => source.indexOf(token, start + startToken.length),
    _ => throw ArgumentError.value(endToken, 'endToken'),
  };
  expect(end, greaterThan(start),
      reason: 'missing $endToken after $startToken');
  return source.substring(start, end);
}
