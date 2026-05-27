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
      'class HibikiOverflowMenu',
      'class HibikiFilePickerRow',
      'onLongPress',
    ],
  };

  const Map<String, List<String>> migratedSurfaces = <String, List<String>>{
    'lib/src/settings/material_settings_renderer.dart': <String>[
      'HibikiListItem',
      'HibikiCard',
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
    'lib/src/pages/implementations/reading_statistics_page.dart': <String>[
      'HibikiCard',
    ],
    'lib/src/utils/components/hibiki_search_history.dart': <String>[
      'HibikiListItem',
      'HibikiDesignTokens',
    ],
    'lib/src/pages/implementations/collections_page.dart': <String>[
      'HibikiListItem',
    ],
    'lib/src/pages/implementations/tag_management_page.dart': <String>[
      'HibikiListItem',
    ],
    'lib/src/pages/implementations/media_item_dialog_page.dart': <String>[
      'HibikiListItem',
    ],
    'lib/src/utils/misc/update_checker.dart': <String>[
      'HibikiCard',
    ],
    'lib/src/sync/sync_compare_dialog.dart': <String>[
      'HibikiOverflowMenu',
    ],
    'lib/src/media/audiobook/book_import_dialog.dart': <String>[
      'AdaptiveSettingsSection',
      'AdaptiveSettingsSwitchRow',
      'HibikiFilePickerRow',
    ],
    'lib/src/media/audiobook/audiobook_import_dialog.dart': <String>[
      'AdaptiveSettingsSection',
      'HibikiFilePickerRow',
    ],
    'lib/src/pages/implementations/reader_hibiki_history_page.dart': <String>[
      'HibikiCard',
      '_bookCardShell',
    ],
    'lib/src/pages/implementations/dictionary_dialog_page.dart': <String>[
      'HibikiCard',
      'HibikiListItem',
      '_buildCategoryTile',
      '_buildDictCheckbox',
    ],
    'lib/src/pages/implementations/tag_picker_page.dart': <String>[
      'HibikiCard',
      'HibikiListItem',
    ],
    'lib/src/pages/implementations/illustrations_viewer_page.dart': <String>[
      'HibikiCard',
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
      'lib/src/pages/implementations/reading_statistics_page.dart': <String>[
        'Card(',
        'surfaceContainerHighest.withValues',
      ],
      'lib/src/utils/components/hibiki_search_history.dart': <String>[
        'fontSize:',
        'TextStyle(',
      ],
      'lib/src/pages/implementations/collections_page.dart': <String>[
        'ListTile(',
        'fontSize: 10',
      ],
      'lib/src/pages/implementations/tag_management_page.dart': <String>[
        'ListTile(',
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
      ],
      'lib/src/media/audiobook/book_import_dialog.dart': <String>[
        'SwitchListTile',
        'fontSize: 13',
        'fontSize: 11',
      ],
      'lib/src/media/audiobook/audiobook_import_dialog.dart': <String>[
        'fontSize: 13',
        'fontSize: 11',
      ],
      'lib/src/pages/implementations/reader_hibiki_history_page.dart': <String>[
        'Material(',
        'surfaceContainerLow',
        'BorderRadius.circular(12)',
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
        'surfaceContainerLow',
        'BorderRadius.circular(8)',
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
      .replaceAll('HibikiOverflowMenu(', 'HibikiSharedOverflow(');
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
