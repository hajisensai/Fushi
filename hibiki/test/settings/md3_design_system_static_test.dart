import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_history_source_corpus.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';
import '../sync/sync_settings_schema_source_corpus.dart';

void main() {
  const Map<String, List<String>> requiredComponentTokens =
      <String, List<String>>{
    'lib/src/utils/components/hibiki_design_tokens.dart': <String>[
      'class HibikiDesignTokens',
      'class HibikiRadii',
      'class HibikiSurfaceColors',
      'class HibikiTypeRoles',
      'class HibikiDensityTokens',
      'final HibikiDensityTokens density',
      'static HibikiDesignTokens of',
    ],
    'lib/src/utils/components/hibiki_material_components.dart': <String>[
      'class HibikiCard',
      'class HibikiListItem',
      'enum HibikiListDensity',
      'HibikiListDensity.compact',
      'class HibikiSearchField',
      'class HibikiTextField',
      'class HibikiSelectableChip',
      'class HibikiActionChip',
      'class HibikiTagChip',
      'class HibikiBadge',
      'class HibikiColorSwatch',
      'class HibikiPreviewSwitch',
      'class HibikiPageHeader',
      'class HibikiPageScaffold',
      'class HibikiToolScaffold',
      'class HibikiTransientScaffold',
      'class HibikiOverlayScaffold',
      'class HibikiModalSheetFrame',
      'class HibikiDialogFrame',
      'class HibikiOverflowMenu',
      'class HibikiPopupMenuItem',
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
      // schema 行的自适应组件已收口到 settings_schema_widgets（见下条）；渲染器只
      // 复用共享 SettingsSchemaSection。
      'SettingsSchemaSection',
      'HibikiPageScaffold',
    ],
    'lib/src/settings/settings_schema_widgets.dart': <String>[
      'AdaptiveSettingsSection',
      'AdaptiveSettingsSwitchRow',
      'AdaptiveSettingsSegmentedRow',
      'AdaptiveSettingsSliderRow',
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
    'lib/src/pages/implementations/home_page.dart': <String>[
      'HibikiDialogFrame',
    ],
    'lib/src/pages/implementations/media_source_picker_dialog_page.dart':
        <String>[
      'HibikiListItem',
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
      'HibikiColorSwatch',
    ],
    // TODO-293 长按媒体对话框重设计：旧版用 HibikiListItem 行 + HibikiActionChip 列举动作；
    // 重设计后封面即「阅读」点击目标，动作改为叠在封面上的半透明胶囊（_TranslucentActionChip）
    // + 危险动作藏进溢出菜单（内容性视觉，不再是 list 行 / 通用 chip）。共享 MD3 锚点收敛到
    // 仍真实使用的 HibikiDialogFrame（外框 chrome）+ HibikiDesignTokens（spacing/type/surface 令牌）。
    'lib/src/pages/implementations/media_item_dialog_page.dart': <String>[
      'HibikiDialogFrame',
      'HibikiDesignTokens',
    ],
    'lib/src/utils/misc/update_checker_ui.dart': <String>[
      'HibikiCard',
    ],
    'lib/src/sync/sync_compare_dialog.dart': <String>[
      'HibikiOverflowMenu',
      'HibikiCard',
      'HibikiDialogFrame',
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
      'HibikiOverlayScaffold',
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
    // TODO-586：HibikiTextField 随 SettingsNumberField 搬到共享 fields 文件。
    'lib/src/settings/settings_schema_fields.dart': <String>[
      'HibikiTextField',
    ],
    'lib/src/sync/sync_settings_schema.dart': <String>[
      'HibikiTextField',
    ],
    'lib/src/pages/implementations/custom_theme_page.dart': <String>[
      'HibikiTextField',
      'HibikiDesignTokens',
      'HibikiColorSwatch',
      'HibikiPreviewSwitch',
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
    // BUG-244 / TODO-297：阅读器有声书播放条的播放/暂停键从扁平 HibikiIconButton
    // 还原成原生 MD3 [IconButton.filledTonal]（标准圆形 filled-tonal 容器 +
    // state-layer + ripple），上一句/下一句/follow/设置改无框原生 IconButton。
    // 共享 MD3 锚点收敛到原生 filled-tonal 框 + HibikiDesignTokens（spacing 令牌）；
    // 「圆框 md3 观感」由专用守卫 audiobook_play_bar_md3_frame_test.dart 锁定。
    'lib/src/media/audiobook/audiobook_play_bar.dart': <String>[
      'IconButton.filledTonal',
      'HibikiDesignTokens',
    ],
    'lib/src/pages/implementations/tag_filter_sheet.dart': <String>[
      'HibikiSelectableChip',
      'HibikiModalSheetFrame',
    ],
    'lib/src/media/audiobook/sasayaki_rematch.dart': <String>[
      'HibikiModalSheetFrame',
      'HibikiDialogFrame',
    ],
    'lib/src/pages/implementations/dictionary_popup_native.dart': <String>[
      'HibikiTagChip',
      'HibikiDesignTokens',
    ],
    'lib/src/pages/implementations/placeholder_source_page.dart': <String>[
      'HibikiTransientScaffold',
    ],
    'lib/src/utils/misc/hibiki_toast.dart': <String>[
      'HibikiDesignTokens',
    ],
  };

  test('MD3 design token and shared component files exist', () {
    for (final MapEntry<String, List<String>> entry
        in requiredComponentTokens.entries) {
      final File file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: '${entry.key} must exist');
      final String source =
          entry.key.endsWith('reader_hibiki_history_page.dart')
              ? readReaderHistorySource()
              : entry.key.endsWith('sync_settings_schema.dart')
                  ? readSyncSettingsSchemaSource()
                  : file.readAsStringSync();
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
      final String source =
          entry.key.endsWith('reader_hibiki_history_page.dart')
              ? readReaderHistorySource()
              : entry.key.endsWith('sync_settings_schema.dart')
                  ? readSyncSettingsSchemaSource()
                  : file.readAsStringSync();
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
        'const SizedBox(height: 12)',
      ],
      'lib/src/pages/implementations/home_page.dart': <String>[
        'AlertDialog(',
      ],
      'lib/src/pages/implementations/media_source_picker_dialog_page.dart':
          <String>[
        'ListTile(',
        'fontSize:',
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
        'const EdgeInsets.all(16)',
        'const EdgeInsets.symmetric(horizontal: 16)',
        'const EdgeInsets.symmetric(horizontal: 16, vertical: 4)',
        'const SizedBox(width: 12)',
        'const SizedBox(height: 8)',
        'const SizedBox(height: 12)',
        'const SizedBox(height: 24)',
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
        'shape: BoxShape.circle',
      ],
      'lib/src/pages/implementations/media_item_dialog_page.dart': <String>[
        'return Dialog(',
        '=> Dialog(',
        'SingleChildScrollView(',
        'ListTile(',
        'dense: true',
        '_QuickActionChip',
        'OutlinedButton.icon(',
      ],
      'lib/src/utils/misc/update_checker_ui.dart': <String>[
        'child: Card(',
      ],
      'lib/src/sync/sync_compare_dialog.dart': <String>[
        'return AlertDialog(',
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
        "Text('+",
        'HibikiFocusable(',
        'fontSize: 10',
        'fontSize: 11',
        'EdgeInsets.symmetric(horizontal: 10, vertical: 4)',
        'EdgeInsets.symmetric(vertical: 4)',
        'EdgeInsets.symmetric(horizontal: 4)',
        'EdgeInsets.only(top: 2)',
        'EdgeInsets.only(top: 3)',
        'EdgeInsets.only(left: 8, bottom: 2)',
        'spacing: 2',
      ],
      'lib/src/pages/implementations/dictionary_dialog_page.dart': <String>[
        'ExpansionTile',
        'CheckboxListTile',
        'Material(',
        'BorderRadius.circular(24)',
        'fontSize: textTheme',
      ],
      'lib/src/pages/implementations/tag_picker_page.dart': <String>[
        'CheckboxListTile',
        'ListTile(',
        'const EdgeInsets.all(16)',
        'const SizedBox(height: 8)',
      ],
      'lib/src/pages/implementations/illustrations_viewer_page.dart': <String>[
        'adaptiveAppBar',
        'surfaceContainerLow',
        'BorderRadius.circular(8)',
        'const SizedBox(height: 16)',
        'const EdgeInsets.all(8)',
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
        'Material(',
        'Container(',
        'BoxDecoration(',
        'BorderRadius.circular(8)',
        'padding: const EdgeInsets.all(8)',
      ],
      'lib/src/pages/implementations/placeholder_source_page.dart': <String>[
        'Scaffold(',
      ],
      'lib/src/pages/implementations/floating_dict_page.dart': <String>[
        'Scaffold(',
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
      // TODO-586：SettingsSecretField/SettingsNumberField（含 AdaptiveSettingsTextField
      // / HibikiTextField，子串带 'TextField('）搬到共享 fields 文件。
      'lib/src/settings/settings_schema_fields.dart': <String>[
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
        'Widget _colorDot(',
        'shape: BoxShape.circle',
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
        'SafeArea(',
        'HibikiDivider()',
      ],
      'lib/src/media/audiobook/sasayaki_rematch.dart': <String>[
        '=> Dialog(',
        'SafeArea(',
      ],
      'lib/src/utils/misc/hibiki_toast.dart': <String>[
        'BorderRadius.circular(24)',
        'fontSize: 14',
      ],
    };

    for (final MapEntry<String, List<String>> entry in bannedByFile.entries) {
      final String fileSource =
          entry.key.endsWith('reader_hibiki_history_page.dart')
              ? readReaderHistorySource()
              : entry.key.endsWith('sync_settings_schema.dart')
                  ? readSyncSettingsSchemaSource()
                  : File(entry.key).readAsStringSync();
      final String source =
          entry.key.endsWith('reader_hibiki_history_page.dart')
              ? _withoutTransparentInkHosts(
                  _functionSource(
                    fileSource,
                    'Widget _bookCardShell({',
                    'Widget _cardBadge({',
                  ),
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

  test('ordinary page chrome does not reopen local MD3 decisions', () {
    const List<String> forbidden = <String>[
      'BorderRadius.circular(',
      'VisualDensity.compact',
      'surfaceContainerLow',
      'surfaceContainerHigh',
      'surfaceContainerHighest',
      'fontSize:',
      'Card(',
      'ListTile(',
      'SwitchListTile(',
      'CheckboxListTile(',
      'PopupMenuButton(',
    ];
    const Map<String, String> allowedFiles = <String, String>{
      'lib/src/utils/components/hibiki_design_tokens.dart':
          'Token source owns app radii and semantic surface roles.',
      'lib/src/utils/components/hibiki_material_components.dart':
          'Shared MD3 component implementation may map tokens to framework widgets.',
      'lib/src/utils/components/settings_shared.dart':
          'Shared adaptive settings primitives own compact settings controls.',
      'lib/src/utils/components/hibiki_dropdown.dart':
          'Shared dropdown owns its menu anchor shape until it is tokenized.',
      'lib/src/utils/adaptive/adaptive_theme.dart':
          'Cupertino text-theme bridge defines platform typography roles.',
      'lib/src/models/theme_notifier.dart':
          'Theme preview content intentionally displays generated surface roles.',
      'lib/src/pages/implementations/custom_theme_page.dart':
          'Theme preview studio intentionally displays user-selected colors.',
      'lib/src/pages/implementations/reading_statistics_page.dart':
          'Chart and metric preview content keeps small chart typography.',
      'lib/src/pages/implementations/video_statistics_page.dart':
          'Video statistics charts/metric bars mirror reading_statistics_page: '
              'progress-bar track surface is chart content, not page chrome.',
      'lib/src/pages/implementations/dictionary_term_page.dart':
          'Dictionary article surface is content chrome, not ordinary page rows.',
      'lib/src/pages/implementations/dictionary_popup_native.dart':
          'Dictionary popup chip/content typography is dense lookup content.',
      'lib/src/pages/implementations/dictionary_popup_webview.dart':
          'WebView result theming injects MD3 ColorScheme surface roles into popup CSS.',
      'lib/src/pages/implementations/history_reader_page.dart':
          'History preview uses content-derived surface and text metrics.',
      'lib/src/pages/implementations/media_item_dialog_page.dart':
          'TODO-293 long-press media dialog redesign: the cover-hero placeholder '
              '(no-cover case) paints a surfaceContainerHighest->High tonal '
              'gradient as immersive cover content, not ordinary page chrome. '
              'Surfaces still flow through HibikiDialogFrame + HibikiDesignTokens.',
      'lib/src/pages/implementations/reader_hibiki_history_page.dart':
          'Book-cover overlays and drag affordances are reader-shelf content.',
      // TODO-587: 书架页拆成主壳 + reader_history/*.part.dart 五个 part 文件，
      // 同一份「书架内容 chrome」豁免理由随之延伸到各 part 文件（仅拆分搬运，零行为变化）。
      'lib/src/pages/implementations/reader_history/card_widgets.part.dart':
          'Book-cover badges/progress are reader-shelf card content.',
      'lib/src/pages/implementations/reader_history/remote.part.dart':
          'Remote book download control density is reader-shelf content.',
      'lib/src/pages/implementations/reader_history/dialogs.part.dart':
          'Reader-shelf dialog/segment typography is content chrome.',
      'lib/src/pages/implementations/reader_hibiki_page.dart':
          'Hoshi reader content and reader chrome have separate migration rules.',
      // TODO-589 batch1: reader_hibiki_page.dart 拆成主壳 + reader_hibiki/*.part.dart；
      // 同一份「reader content / 悬浮歌词数据」豁免随搬运延伸到 part 文件（零行为变化）。
      'lib/src/pages/implementations/reader_hibiki/lyrics.part.dart':
          'Lyrics-mode HTML font size and FloatingLyricStyle font size are '
              'user content passed to LyricsModeHtml / the platform overlay '
              'channel, not page chrome — same rationale as the parent '
              'reader_hibiki_page.dart allowlist (extracted verbatim).',
      'lib/src/media/audiobook/reader_quick_settings_sheet.dart':
          'Reader quick settings and audiobook chrome migrate under Task 8.',
      'lib/src/media/audiobook/audiobook_bridge.dart':
          'Serialized audiobook bridge data includes reader font size.',
      'lib/src/media/audiobook/audiobook_session.dart':
          'Audiobook session forwards the user-configurable floating-lyric font '
              'size to the platform overlay channel (content/data passed to '
              'FloatingLyricChannel.show/updateStyle), not page chrome — same '
              'rationale as audiobook_bridge.',
      'lib/src/media/audiobook/now_listening_mini_bar.dart':
          'Now-listening media mini-bar: surface role + book-cover thumbnail '
              'radius are media-subsystem content chrome (same category as the '
              'allowlisted reader-shelf book covers / media_item_dialog cover '
              'hero), driven off the active ColorScheme.',
      'lib/src/models/app_model.dart':
          'AppModel builds the FloatingLyricStyle data object (overlay font '
              'size is user content passed to the platform overlay), not an '
              'ordinary page-chrome TextStyle.',
      'lib/src/media/video/video_subtitle_overlay.dart':
          'Video subtitle overlay renders caption content (fixed '
              'white-on-black caption radius/size), not ordinary page chrome.',
      'lib/src/media/video/video_subtitle_jump_panel.dart':
          'Subtitle jump list (asbplayer-style transcript panel) renders cue '
              'text + timestamp rows as video-subsystem content; row/timestamp '
              'font size scales with appUiScale, not ordinary page chrome '
              '(same content rationale as the allowlisted subtitle overlay).',
      'lib/src/media/video/video_chapter_panel.dart':
          'Chapter list panel (TODO-424) renders chapter index + title + start '
              'timestamp rows as video-subsystem content; row font size scales '
              'with appUiScale, not ordinary page chrome (same content rationale '
              'as the allowlisted sibling subtitle jump panel).',
      'lib/src/media/video/video_episode_panel.dart':
          'Episode list panel (TODO-638) renders episode index + title rows '
              'as video-subsystem content in a push-aside sidebar mirroring '
              'the allowlisted sibling chapter panel; row font size scales '
              'with appUiScale, not ordinary page chrome.',
      'lib/src/media/video/video_side_panel.dart':
          'Video translucent side-panel scaffold (favorite sentences list etc.) '
              'renders video-subsystem overlay chrome; lock toggle (TODO-611) '
              'uses a dense compact icon button consistent with the sibling '
              'subtitle jump panel, not ordinary page chrome.',
      'lib/src/media/video/video_subtitle_style.dart':
          'Subtitle appearance model holds user-configurable caption font '
              'size (content), defaults mirror the allowlisted overlay caption.',
      'lib/src/media/video/video_danmaku_overlay.dart':
          'Danmaku overlay renders timed video content text, not app chrome.',
      'lib/src/media/video/video_volume_overlays.dart':
          'TODO-517 split out the compact video volume popover and '
              'volume/brightness HUD to keep visible slider/HUD layers from '
              'occupying the full screen; the barrier may be full-screen, '
              'but these visible layers are video-subsystem transient overlays, '
              'not ordinary page chrome. Their size, color, and type are '
              'measured against appUiScale and video overlay contrast needs, '
              'same reviewed exception class as video subtitle/jump/chapter/'
              'quick-settings overlays.',
      'lib/src/media/video/video_quick_settings_sheet.dart':
          'Video quick settings sheet (media-page chrome like reader/audiobook) '
              'drives the user-configurable subtitle caption font size '
              '(_style.copyWith(fontSize:)), which is content, not page chrome.',
      'lib/src/settings/settings_schema_video.dart':
          'Home video settings expose the same user-configurable subtitle '
              'caption font size (VideoSubtitleStyle.copyWith(fontSize:)) for '
              'parity with the in-player sheet (TODO-286); it is caption content, '
              'not page chrome — same rationale as video_quick_settings_sheet. '
              'TODO-586：随 video destination 拆到 settings_schema_video.dart。',
      'lib/src/pages/implementations/video_hibiki_page.dart':
          'Video player page chrome (track-switch menu, media controls) '
              'follows media-page rules like reader/audiobook.',
      // TODO-590: video_hibiki_page.dart 拆成主壳 + video_hibiki/*.part.dart；
      // 同一份 video player page chrome 豁免随搬运延伸到含 chrome token 的 part 文件
      // （零行为变化，逐字符抽出）。
      'lib/src/pages/implementations/video_hibiki/episode.part.dart':
          'Episode push-aside sidebar + auto-advance countdown overlay '
              'chrome extracted verbatim from video_hibiki_page.dart '
              '(TODO-590 batch4); same media-page rationale as the parent '
              'video player page allowlist entry.',
      'lib/src/pages/implementations/home_video_page.dart':
          'Home video grid renders media content badges/download progress; '
              'long-press management actions use the shared media dialog frame, '
              'not bespoke bottom-sheet chrome.',
      'lib/src/pages/implementations/video_shader_dialog.dart':
          'Experimental mpv shader dialog lists imported shader files as '
              'checkbox rows (transient video-subsystem content).',
      'lib/src/pages/implementations/jimaku_subtitle_dialog.dart':
          'Experimental Jimaku subtitle dialog lists downloadable subtitle '
              'files as transient video-subsystem content rows.',
      'lib/src/creator/fields/image_field.dart':
          'Anki image-field renderer uses OCR/image coordinate typography.',
      'lib/src/pages/implementations/dictionary_dialog_import_page.dart':
          'Dictionary import content mirrors text-theme metrics.',
      'lib/src/pages/implementations/dictionary_dialog_delete_page.dart':
          'Dictionary delete content mirrors text-theme metrics.',
      'lib/src/settings/cupertino_settings_renderer.dart':
          'Cupertino destination list still wraps platform navigation rows.',
      'lib/src/utils/components/hibiki_list_tile.dart':
          'Legacy compatibility adapter wraps framework ListTile.',
      'lib/src/utils/components/hibiki_text_selection_controls.dart':
          'Shared text-selection toolbar owns its transient surface.',
      'lib/src/utils/misc/update_checker_ui.dart':
          'Update checker migrated card shell is already covered by local guard.',
      'lib/src/utils/misc/mokuro_payload.dart':
          'Debug payload string logs parsed reader font size.',
      'lib/src/reader/reader_pagination_scripts.dart':
          'Injected reader JavaScript receives content font size.',
    };

    final List<String> violations = <String>[];
    final List<File> dartFiles = Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File file) => file.path.endsWith('.dart'))
        .toList(growable: false)
      ..sort((File a, File b) => a.path.compareTo(b.path));
    for (final File file in dartFiles) {
      final String path = file.path.replaceAll(r'\', '/');
      final String? reason = allowedFiles[path];
      final String source = _withoutSharedComponentNames(
        file.readAsStringSync(),
      );
      final List<String> hits = _forbiddenChromeHits(source, forbidden);
      if (hits.isEmpty) continue;
      if (reason != null && reason.isNotEmpty) continue;
      violations.add('$path: ${hits.join(', ')}');
    }

    expect(
      violations,
      isEmpty,
      reason: 'Route ordinary visual chrome through shared MD3 components, or '
          'add a reviewed allowlist reason for true content exceptions.',
    );
  });

  test('reader history hover overlays use design tokens', () {
    // BookDragTarget 已从 reader_hibiki_history_page.dart 提取为独立文件
    // book_drag_target.dart（history 页只剩调用点），守卫跟随到新文件。
    final String source = File(
      'lib/src/pages/implementations/book_drag_target.dart',
    ).readAsStringSync();
    final String tagDropTarget = _sectionSource(
      source,
      'class BookDragTarget extends StatefulWidget',
      source.length,
    );

    expect(tagDropTarget, contains('HibikiDesignTokens.of(context)'));
    expect(tagDropTarget, isNot(contains('BorderRadius.circular(12)')));
  });

  test('shared tag filter bar uses shared MD3 tag chips', () {
    // 标签筛选栏已从书架页内联类 _TagBarContent 提取为共享组件
    // HibikiTagFilterBar（书架 + 视频 tab 共用），此处对整份共享组件文件做约束。
    final String tagBar = File(
      'lib/src/pages/implementations/tag_filter_bar.dart',
    ).readAsStringSync();

    expect(tagBar, contains('class HibikiTagFilterBar'));
    expect(tagBar, contains('HibikiTagChip('));
    expect(tagBar, contains('HibikiIconButton('));
    expect(tagBar, contains('tokens.spacing'));
    expect(tagBar, contains('tokens.surfaces.outline'));
    expect(tagBar, isNot(contains('class _TagChip')));
    expect(tagBar, isNot(contains('child: IconButton(')));
    expect(tagBar, isNot(contains('width: 32')));
    expect(tagBar, isNot(contains('height: 32')));
    expect(tagBar, isNot(contains('size: 18')));
    expect(tagBar, isNot(contains('BorderRadius.circular(16)')));
    expect(tagBar, isNot(contains('height: 44')));
    expect(tagBar,
        isNot(contains('EdgeInsets.symmetric(horizontal: 12, vertical: 6)')));
    expect(tagBar, isNot(contains('const SizedBox(width: 6)')));
  });

  test('shared icon button uses MD3 design tokens', () {
    final String source = File(
      'lib/src/utils/components/hibiki_icon_button.dart',
    ).readAsStringSync();
    final String buildSource = _sectionSource(
      source,
      '  Widget build(BuildContext context) {',
      source.length,
    );

    expect(buildSource, contains('HibikiDesignTokens.of(context)'));
    expect(buildSource, contains('tokens.spacing'));
    expect(buildSource, isNot(contains('Spacing.of(context)')));
    expect(buildSource, isNot(contains('const EdgeInsets.all(8)')));
  });

  test('reader history card layout uses shared MD3 spacing tokens', () {
    final String source = readReaderHistorySource();
    final String cardLayout = _functionSource(
      source,
      'Widget _bookCardLayout({',
      'Widget _bookCardTagArea(',
    );
    final String epubCardChrome = _functionSource(
      source,
      'Widget buildMediaItemContent(MediaItem item)',
      'Widget buildMediaItem(MediaItem item)',
    );

    expect(cardLayout, contains('HibikiDesignTokens.of(context)'));
    expect(cardLayout, contains('tokens.spacing'));
    expect(cardLayout, contains('_bookCardFooter(title)'));
    expect(cardLayout, contains('height: kShelfTitleFooterHeight'));
    expect(cardLayout, contains('PositionedDirectional('));
    expect(cardLayout, contains('tokens.spacing.gap * 0.75'));
    expect(cardLayout, isNot(contains('_titleOverlay(title)')));
    expect(epubCardChrome, contains('_bookCardLayout('));
    expect(cardLayout, isNot(contains('EdgeInsets.only(right: 3, bottom: 2)')));
    expect(cardLayout, isNot(contains('EdgeInsets.fromLTRB(12, 8, 12, 2)')));
    expect(cardLayout, isNot(contains('top: 6,')));
    expect(cardLayout, isNot(contains('right: 6,')));
    expect(cardLayout, isNot(contains('left: 6,')));
  });

  test('book long-press frame uses visible cover block and MD3 action layout',
      () {
    // TODO-557 把长按对话框封面从「Stack/Positioned.fill + LinearGradient scrim
    // 背景」（TODO-455 引入、让封面几乎不可见）改回「Column 顶部可见封面块」：
    // ConstrainedBox 限高 + ColoredBox letterbox + 传入的封面 widget（其内部
    // BoxFit.contain，整幅可见不裁切）。本守卫断言这一可见封面结构，并反向锁定
    // 旧 scrim 背景结构不回归。
    final String source = File(
      'lib/src/pages/implementations/media_item_dialog_page.dart',
    ).readAsStringSync();
    final String frame = _sectionSource(
      source,
      'class MediaItemDialogFrame extends StatelessWidget',
      source.length,
    );

    // 共享 MD3 对话框框 + 顶部可见封面块（限高 + letterbox 背景）。
    expect(frame, contains('HibikiDialogFrame('));
    expect(frame, contains('ConstrainedBox('));
    expect(frame, contains('ColoredBox('));
    expect(frame, contains('tokens.surfaces.overlay'));
    // MD3 action layout：快捷动作 chip 网格 + 列表动作 + 危险文字按钮。
    expect(frame, contains('Wrap('));
    expect(frame, contains('HibikiActionChip('));
    expect(frame, contains('HibikiListItem('));
    expect(frame, contains('TextButton('));
    expect(frame, contains('final bool showLaunchAction;'));
    expect(frame, contains('showLaunchAction &&'));
    expect(frame, contains('launchLabel != null'));
    expect(frame, contains('onLaunch != null'));
    expect(frame, isNot(contains('SingleChildScrollView(')));
    expect(frame, isNot(contains('ListTile(')));
    expect(frame, isNot(contains('OutlinedButton.icon(')));
    // 旧 scrim 背景结构（封面铺底 + 渐变遮罩）不得回归。
    expect(frame, isNot(contains('Positioned.fill')));
    expect(frame, isNot(contains('LinearGradient(')));
  });

  test('settings renderer rows use shared MD3 row primitives', () {
    // schema 行渲染已从两个渲染器收口到共享 settings_schema_widgets.SettingsSchemaItem。
    final String source = File(
      'lib/src/settings/settings_schema_widgets.dart',
    ).readAsStringSync();
    final String itemSource = _sectionSource(
      source,
      'class SettingsSchemaItem',
      source.length,
    );

    expect(itemSource, contains('AdaptiveSettingsRow('));
    expect(itemSource, contains('AdaptiveSettingsSwitchRow('));
    expect(itemSource, contains('AdaptiveSettingsSegmentedRow<'));
    expect(itemSource, contains('AdaptiveSettingsSliderRow('));
    expect(itemSource, contains('AdaptiveSettingsStepperRow('));
    expect(
      itemSource,
      isNot(contains('padding: const EdgeInsets.only(top: 2)')),
    );
  });

  test('reader history selection chrome uses shared MD3 tokens', () {
    final String source = readReaderHistorySource();
    final String cardShell = _functionSource(
      source,
      'Widget _bookCardShell({',
      'Widget _bookCardLayout({',
    );

    expect(cardShell, contains('HibikiDesignTokens.of(context)'));
    expect(cardShell, contains('tokens.spacing'));
    expect(cardShell, contains('tokens.surfaces'));
    expect(cardShell, isNot(contains('Spacing.of(context)')));
    expect(cardShell, isNot(contains('top: 4,')));
    expect(cardShell, isNot(contains('left: 4,')));
    expect(cardShell, isNot(contains('EdgeInsets.all(2)')));
    expect(cardShell, isNot(contains('size: 14')));
    expect(cardShell, isNot(contains('theme.colorScheme.surface.withValues')));
    expect(cardShell, isNot(contains('theme.colorScheme.outline')));
    expect(cardShell, isNot(contains('theme.colorScheme.primary.withValues')));
  });

  test('reader history batch actions use shared MD3 spacing tokens', () {
    final String source = readReaderHistorySource();
    final String batchActionBar = _functionSource(
      source,
      'Widget _buildBatchActionBar()',
      '  Future<void> _batchDeleteConfirm()',
    );
    final String placeholder = _functionSource(
      source,
      'Widget buildPlaceholder()',
      'Widget buildMediaItemContent(MediaItem item)',
    );
    final String batchTagIntentRow = _sectionSource(
      source,
      'class _BatchTagIntentRow',
      source.length,
    );

    for (final String section in <String>[
      batchActionBar,
      placeholder,
      batchTagIntentRow,
    ]) {
      expect(section, contains('HibikiDesignTokens'));
      expect(section, contains('tokens.spacing'));
      expect(section, isNot(contains('const SizedBox(height: 12)')));
      expect(section, isNot(contains('const SizedBox(width: 12)')));
      expect(section, isNot(contains('const SizedBox(width: 8)')));
      expect(
        section,
        isNot(
          contains('const EdgeInsets.symmetric(horizontal: 12, vertical: 8)'),
        ),
      );
    }
    expect(batchActionBar, isNot(contains('const SizedBox(width: 4)')));
    expect(
      source,
      isNot(contains('padding: const EdgeInsets.all(24)')),
    );
  });

  test('reader history title footer and drag target use shared MD3 tokens', () {
    final String source = readReaderHistorySource();
    final String titleFooter = _functionSource(
      source,
      'Widget _bookCardFooter(String title)',
      'Widget _bookCardTagArea(',
    );
    // BookDragTarget 已提取到独立文件 book_drag_target.dart，守卫跟随。
    final String dragSource = File(
      'lib/src/pages/implementations/book_drag_target.dart',
    ).readAsStringSync();
    final String dragTarget = _sectionSource(
      dragSource,
      'class BookDragTarget extends StatefulWidget',
      dragSource.length,
    );

    // 书名 footer 用共享 token，不允许退回封面内暗角覆盖层或硬编码颜色/像素。
    expect(source, isNot(contains('Widget _titleOverlay(String title)')));
    expect(titleFooter, contains('HibikiDesignTokens.of(context)'));
    expect(titleFooter, contains('tokens.spacing'));
    expect(titleFooter, contains('tokens.surfaces'));
    expect(titleFooter, contains('tokens.surfaces.onSurface'));
    expect(titleFooter, contains('maxLines: 2'));
    expect(titleFooter, contains('overflow: TextOverflow.ellipsis'));
    expect(titleFooter, isNot(contains('LinearGradient(')));
    expect(titleFooter, isNot(contains('EdgeInsets.fromLTRB(6, 4, 6, 6)')));
    expect(titleFooter, isNot(contains('theme.colorScheme.surface')));
    expect(titleFooter, isNot(contains('theme.colorScheme.onSurface')));

    expect(dragTarget, contains('HibikiDesignTokens.of(context)'));
    expect(dragTarget, contains('tokens.spacing'));
    expect(dragTarget, contains('tokens.surfaces'));
    expect(dragTarget, isNot(contains('final ThemeData theme')));
    expect(dragTarget, isNot(contains('theme.colorScheme.primary')));
    expect(dragTarget, isNot(contains('width: 2')));
    expect(dragTarget, isNot(contains('size: 32')));
  });

  test('reader history action dialogs use shared MD3 dialog chrome', () {
    final String source = readReaderHistorySource();
    final String deleteDialog = _sectionSource(
      source,
      'class ReaderHistoryDeleteDialog',
      'class _BookProfileDialog',
    );
    final String batchTagDialog = _sectionSource(
      source,
      'class _BatchTagPickerDialog',
      'enum _BatchTagIntent',
    );

    for (final String dialogSource in <String>[
      deleteDialog,
      batchTagDialog,
    ]) {
      expect(dialogSource, contains('HibikiDialogFrame('));
      expect(dialogSource, contains('HibikiModalSheetFrame('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('reader page prompt dialogs use shared MD3 dialog chrome', () {
    final String source = readReaderPageSource();
    final String sentenceActionBar = _functionSource(
      source,
      'Widget buildRow(ThemeData theme)',
      '    if (!hasAudio) {',
    );
    final String lyricsHint = _sectionSource(
      source,
      'class ReaderLyricsModeHintDialog',
      'class ReaderSrtAudioPickerDialog',
    );
    final String srtAudioPicker = _sectionSource(
      source,
      'class ReaderSrtAudioPickerDialog',
      source.length,
    );
    final String lyricsFlow = _functionSource(
      source,
      'void _showLyricsModeHintIfNeeded()',
      '  Future<void> _exitLyricsMode() async',
    );
    final String pickerFlow = _functionSource(
      source,
      'Future<void> _openSrtBookAudioPicker() async',
      '  Future<void> _pickSrtAudioFiles(BuildContext dialogContext) async',
    );
    final String settingsBar = _functionSource(
      source,
      'Widget _buildSettingsBar()',
      '  int _tocHrefToChapterIndex(String? href)',
    );

    expect(lyricsFlow, contains('ReaderLyricsModeHintDialog('));
    expect(pickerFlow, contains('ReaderSrtAudioPickerDialog('));
    expect(settingsBar, contains('HibikiDesignTokens.of(context)'));
    expect(settingsBar, contains('tokens.spacing'));
    expect(
      settingsBar,
      isNot(contains('padding: const EdgeInsets.symmetric(horizontal: 8)')),
    );
    for (final String dialogSource in <String>[
      lyricsHint,
      srtAudioPicker,
      lyricsFlow,
      pickerFlow,
    ]) {
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
    for (final String dialogSource in <String>[
      lyricsHint,
      srtAudioPicker,
    ]) {
      expect(dialogSource, contains('HibikiDialogFrame('));
      expect(dialogSource, contains('HibikiModalSheetFrame('));
    }
    expect(sentenceActionBar, contains('HibikiDesignTokens.of(context)'));
    expect(sentenceActionBar, contains('tokens.spacing'));
    expect(sentenceActionBar, isNot(contains('const SizedBox(width: 8)')));
  });

  test('audiobook import dialogs use shared MD3 dialog chrome', () {
    final String bookImportSource = File(
      'lib/src/media/audiobook/book_import_dialog.dart',
    ).readAsStringSync();
    final String audiobookImportSource = File(
      'lib/src/media/audiobook/audiobook_import_dialog.dart',
    ).readAsStringSync();
    final String bookImportFrame = _sectionSource(
      bookImportSource,
      'class BookImportDialogFrame',
      bookImportSource.length,
    );
    final String audiobookBuild = _functionSource(
      audiobookImportSource,
      'Widget build(BuildContext context)',
      '  Widget _buildAttachedView(Audiobook ab)',
    );
    final String removeDialog = _functionSource(
      audiobookImportSource,
      'Future<void> _removeAudiobook(Audiobook ab) async',
      '  Future<Directory> _ensurePersistDir()',
    );
    final String audiobookFrame = _sectionSource(
      audiobookImportSource,
      'class AudiobookImportDialogFrame',
      'class AudiobookRemoveConfirmationDialog',
    );
    final String removeFrame = _sectionSource(
      audiobookImportSource,
      'class AudiobookRemoveConfirmationDialog',
      audiobookImportSource.length,
    );

    expect(audiobookBuild, contains('AudiobookImportDialogFrame('));
    expect(removeDialog, contains('AudiobookRemoveConfirmationDialog('));
    expect(audiobookBuild, isNot(contains('adaptiveAlertDialog(')));
    expect(removeDialog, isNot(contains('adaptiveAlertDialog(')));

    for (final String dialogSource in <String>[
      bookImportFrame,
      audiobookFrame,
      removeFrame,
    ]) {
      expect(dialogSource, contains('HibikiDialogFrame('));
      expect(dialogSource, contains('HibikiModalSheetFrame('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('audiobook import file rows use shared MD3 icon buttons', () {
    final Map<String, List<String>> rowSections = <String, List<String>>{
      'lib/src/media/audiobook/book_import_dialog.dart': <String>[
        'Widget _epubRow()',
        'Widget _subtitleRow()',
        'Widget _audioRow()',
        'Widget _coverRow()',
      ],
      'lib/src/media/audiobook/audiobook_import_dialog.dart': <String>[
        'Widget _audioSourceRow()',
        'Widget _alignmentRow()',
      ],
    };

    for (final MapEntry<String, List<String>> entry in rowSections.entries) {
      final String source = File(entry.key).readAsStringSync();
      for (final String startToken in entry.value) {
        final String section = _functionSource(
          source,
          startToken,
          _nextWidgetAfter(source, startToken),
        );

        expect(section, contains('HibikiFilePickerRow('));
        expect(section, contains('HibikiIconButton('));
        expect(
          section.replaceAll('HibikiIconButton(', 'HibikiSharedAction('),
          isNot(contains('IconButton(')),
        );
        expect(section, isNot(contains('Theme.of(context).colorScheme')));
        expect(section, isNot(contains('size: 18')));
        expect(section, isNot(contains('size: 20')));
      }
    }
  });

  test('audiobook import progress chrome uses shared MD3 tokens', () {
    final String bookImportSource = File(
      'lib/src/media/audiobook/book_import_dialog.dart',
    ).readAsStringSync();
    final String audiobookImportSource = File(
      'lib/src/media/audiobook/audiobook_import_dialog.dart',
    ).readAsStringSync();
    final String bookImportFlow = _functionSource(
      bookImportSource,
      'Widget build(BuildContext context)',
      '  Widget _epubRow()',
    );
    final String audiobookImportFlow = _functionSource(
      audiobookImportSource,
      'Widget build(BuildContext context)',
      '  Widget _audioSourceRow()',
    );

    for (final String section in <String>[
      bookImportFlow,
      audiobookImportFlow,
    ]) {
      expect(section, contains('HibikiDesignTokens.of(context)'));
      expect(section, contains('tokens.spacing'));
      expect(section, contains('tokens.type.metadata'));
      expect(section, contains('tokens.surfaces.primary'));
      expect(section, isNot(contains('Theme.of(context).textTheme.bodySmall')));
      expect(
        section,
        isNot(contains('Theme.of(context).colorScheme.primary')),
      );
      expect(
        section,
        isNot(contains('Theme.of(context).colorScheme.onSurfaceVariant')),
      );
      expect(section, isNot(contains('const SizedBox(width: 8)')));
      expect(section, isNot(contains('const SizedBox(height: 4)')));
      expect(section, isNot(contains('const SizedBox(height: 8)')));
      expect(section, isNot(contains('const SizedBox(height: 12)')));
      expect(section, isNot(contains('const SizedBox(height: 16)')));
      expect(section, isNot(contains('height: 64')));
    }
  });

  test('sasayaki rematch controls use shared MD3 tokens', () {
    final String source = File('lib/src/media/audiobook/sasayaki_rematch.dart')
        .readAsStringSync();
    final String rematchSheet = _functionSource(
      source,
      'Widget buildSheetBody(BuildContext sheetCtx, StateSetter setSheet)',
      '  static Future<int?> runAutoProbe({',
    );
    final String windowSlider = _sectionSource(
      source,
      'class SasayakiWindowSlider extends StatelessWidget',
      'class SasayakiThresholdSlider extends StatelessWidget',
    );
    final String thresholdSlider = _sectionSource(
      source,
      'class SasayakiThresholdSlider extends StatelessWidget',
      source.length,
    );

    for (final String section in <String>[
      rematchSheet,
      windowSlider,
      thresholdSlider,
    ]) {
      expect(section, contains('HibikiDesignTokens.of('));
      expect(section, contains('tokens.spacing'));
      expect(section, isNot(contains('const SizedBox(height: 4)')));
      expect(section, isNot(contains('const SizedBox(height: 8)')));
      expect(section, isNot(contains('const SizedBox(height: 12)')));
      expect(section, isNot(contains('const SizedBox(width: 8)')));
      expect(
        section,
        isNot(contains('const EdgeInsets.symmetric(horizontal: 20)')),
      );
    }
    for (final String slider in <String>[windowSlider, thresholdSlider]) {
      expect(slider, contains('tokens.type.listTitle'));
      expect(slider, contains('tokens.type.metadata'));
      expect(slider, isNot(contains('final ThemeData theme')));
      expect(slider, isNot(contains('theme.textTheme.titleMedium')));
      expect(slider, isNot(contains('theme.textTheme.bodySmall')));
      expect(slider, isNot(contains('theme.colorScheme.onSurfaceVariant')));
    }
  });

  test('audiobook play bar uses shared MD3 spacing tokens', () {
    final String source = File(
      'lib/src/media/audiobook/audiobook_play_bar.dart',
    ).readAsStringSync();
    final String playBarBuild = _functionSource(
      source,
      'Widget build(BuildContext context) {',
      '/// Follow audio',
    );

    expect(playBarBuild, contains('HibikiDesignTokens.of(context)'));
    expect(playBarBuild, contains('tokens.spacing'));
    expect(
      playBarBuild,
      isNot(contains('padding: const EdgeInsets.symmetric(horizontal: 8)')),
    );
    expect(playBarBuild, isNot(contains('const SizedBox(width: 4)')));
  });

  test('anki integration dialogs use shared MD3 dialog chrome', () {
    final String source =
        File('lib/src/models/anki_integration.dart').readAsStringSync();
    final String apiFlow = _functionSource(
      source,
      'Future<void> showApiMessage(BuildContext? ctx) async',
      '  Future<List<String>> getDecks(BuildContext? ctx) async',
    );
    final String apiDialog = _sectionSource(
      source,
      'class AnkiApiMessageDialog',
      source.length,
    );

    expect(apiFlow, contains('AnkiApiMessageDialog('));
    expect(apiFlow, isNot(contains('adaptiveAlertDialog(')));
    expect(apiDialog, contains('HibikiDialogFrame('));
    expect(apiDialog, contains('HibikiModalSheetFrame('));
    expect(apiDialog, isNot(contains('adaptiveAlertDialog(')));
  });

  test('update checker dialogs use shared MD3 dialog chrome', () {
    // TODO-584 拆分后: _showUpdateDialog/_showFallbackDialog 随 UpdateChecker
    // 门面进 release part; UpdateAvailableDialog/_DownloadOverlay 进 ui part。
    final String releaseSource =
        File('lib/src/utils/misc/update_checker_release.dart')
            .readAsStringSync();
    final String uiSource =
        File('lib/src/utils/misc/update_checker_ui.dart').readAsStringSync();
    final String updateFlow = _functionSource(
      releaseSource,
      'static void _showUpdateDialog(',
      '  /// Fallback dialog for when no APK asset exists',
    );
    final String fallbackFlow = _functionSource(
      releaseSource,
      'static void _showFallbackDialog(',
      '  static Future<void> _downloadAndInstall(',
    );
    final String dialogSource = _sectionSource(
      uiSource,
      'class UpdateAvailableDialog',
      'class _DownloadOverlay',
    );

    expect(updateFlow, contains('UpdateAvailableDialog('));
    expect(fallbackFlow, contains('UpdateAvailableDialog('));
    expect(updateFlow, isNot(contains('adaptiveAlertDialog(')));
    expect(fallbackFlow, isNot(contains('adaptiveAlertDialog(')));
    expect(dialogSource, contains('HibikiDialogFrame('));
    expect(dialogSource, contains('HibikiModalSheetFrame('));
    expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
  });

  test('sync feedback dialogs use shared MD3 dialog chrome', () {
    final String messageSource =
        File('lib/src/sync/sync_message_dialog.dart').readAsStringSync();
    final String compareSource =
        File('lib/src/sync/sync_compare_dialog.dart').readAsStringSync();
    // TODO-585: schema 拆成主库 + 5 个 part；读合并语料，正向 showSyncMessage(
    // 与负向 alert 禁令都覆盖全部 part。
    final String settingsSource = readSyncSettingsSchemaSource();
    final String combined = '$messageSource\n$compareSource\n$settingsSource';

    expect(messageSource, contains('class SyncMessageDialog'));
    expect(messageSource, contains('HibikiDialogFrame('));
    expect(messageSource, contains('HibikiModalSheetFrame('));
    expect(compareSource, contains('showSyncMessage('));
    expect(settingsSource, contains('showSyncMessage('));
    expect(combined, isNot(contains('CupertinoAlertDialog(')));
    expect(combined, isNot(contains('adaptiveAlertDialog(')));
  });

  test('settings action dialogs use shared MD3 inset tokens', () {
    final String source =
        File('lib/src/settings/settings_actions.dart').readAsStringSync();
    final String confirmationDialog = _functionSource(
      source,
      'Future<bool> showSettingsConfirmationDialog(',
      'Future<void> showSettingsProgressDialog(',
    );
    final String progressDialog = _functionSource(
      source,
      'Future<void> showSettingsProgressDialog(',
      'void notifyReaderSettingsChanged(',
    );

    for (final String dialogSource in <String>[
      confirmationDialog,
      progressDialog,
    ]) {
      expect(dialogSource, contains('HibikiDialogFrame('));
      expect(dialogSource, contains('HibikiModalSheetFrame('));
      expect(dialogSource, contains('HibikiDesignTokens.of(ctx)'));
      expect(dialogSource, contains('insetPadding: EdgeInsets.symmetric('));
      expect(dialogSource, contains('horizontal: tokens.spacing.card'));
      expect(dialogSource, contains('vertical: tokens.spacing.card'));
      expect(
        dialogSource,
        isNot(
          contains('const EdgeInsets.symmetric(horizontal: 16, vertical: 16)'),
        ),
      );
    }
  });

  test('sync settings custom controls use shared MD3 rows', () {
    // TODO-585: schema 拆成主库 + 5 个 part；读合并语料，AdaptiveSettingsSwitchRow/
    // PickerRow/HibikiListItem 正向断言与 Dropdown/SwitchListTile/ListTile 负向断言
    // 都覆盖全部 part。
    final String source = readSyncSettingsSchemaSource();

    expect(source, contains('AdaptiveSettingsSwitchRow('));
    expect(source, contains('AdaptiveSettingsPickerRow<SyncBackendType>('));
    expect(source, contains('HibikiListItem('));
    expect(source, isNot(contains('DropdownButton<SyncBackendType>(')));
    expect(source, isNot(contains('SwitchListTile')));
    expect(source, isNot(contains('ListTile(')));
  });

  test('popup menus use the shared MD3 menu item primitive', () {
    final List<String> menuFiles = <String>[
      'lib/src/pages/implementations/dictionary_dialog_page.dart',
      'lib/src/pages/implementations/dictionary_entry_page.dart',
      'lib/src/pages/implementations/shortcut_settings_page.dart',
      'lib/src/sync/sync_compare_dialog.dart',
      'lib/src/utils/components/hibiki_text_selection_controls.dart',
    ];

    final String sharedMenu = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    expect(sharedMenu, contains('class HibikiPopupMenuItem<T>'));
    expect(sharedMenu, contains('minHeight: 48'));
    expect(sharedMenu, contains('tokens.radii.menuRadius'));
    expect(sharedMenu, contains('PopupMenuPosition.under'));

    final String dropdown =
        File('lib/src/utils/components/hibiki_dropdown.dart')
            .readAsStringSync();
    expect(dropdown, contains('MenuAnchor('));
    expect(dropdown, contains('tokens.radii.menuRadius'));
    expect(dropdown, contains('tokens.surfaces.overlay'));
    expect(dropdown, contains('tokens.surfaces.selected'));
    expect(dropdown, isNot(contains('BorderRadius.circular(8)')));
    expect(dropdown, isNot(contains('colors.secondaryContainer')));

    for (final String path in menuFiles) {
      final String source = File(path).readAsStringSync();
      final String withoutSharedMenuItems =
          source.replaceAll('HibikiPopupMenuItem', 'SharedMenuItem');

      expect(
        source,
        contains('HibikiPopupMenuItem'),
        reason: '$path should route menu rows through the shared MD3 item.',
      );
      expect(
        withoutSharedMenuItems,
        isNot(contains('PopupMenuItem(')),
        reason: '$path should not create bespoke popup menu rows.',
      );
      expect(
        withoutSharedMenuItems,
        isNot(contains('PopupMenuItem<')),
        reason: '$path should not type local helpers as raw popup items.',
      );
    }
  });

  test('transient routes use shared MD3 motion tokens', () {
    final File motionFile =
        File('lib/src/utils/components/hibiki_motion_tokens.dart');
    expect(motionFile.existsSync(), isTrue);

    final String motion = motionFile.readAsStringSync();
    expect(motion, contains('const AnimationStyle'));
    expect(motion, contains('hibikiMd3DialogAnimationStyle'));
    expect(motion, contains('hibikiMd3SheetAnimationStyle'));
    expect(motion, contains('hibikiMd3MenuAnimationStyle'));
    expect(motion, contains('Easing.emphasizedDecelerate'));
    expect(motion, contains('Easing.emphasizedAccelerate'));

    final String dialog =
        File('lib/src/utils/misc/show_app_dialog.dart').readAsStringSync();
    final String sheet =
        File('lib/src/utils/adaptive/adaptive_widgets.dart').readAsStringSync();
    final String menu = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    final String home =
        File('lib/src/pages/implementations/home_page.dart').readAsStringSync();
    final String sync =
        File('lib/src/sync/sync_compare_dialog.dart').readAsStringSync();

    expect(dialog, contains('animationStyle: hibikiMd3DialogAnimationStyle'));
    expect(
        sheet, contains('sheetAnimationStyle: hibikiMd3SheetAnimationStyle'));
    expect(menu, contains('popUpAnimationStyle: hibikiMd3MenuAnimationStyle'));
    expect(home, contains('showAppDialog<bool>('));
    expect(sync, contains('showAppDialog<int>('));
    expect(home, isNot(contains('showDialog<bool>(')));
    expect(sync, isNot(contains('showDialog<int>(')));
  });

  test('shared MD3 primitives animate state changes', () {
    final String motion =
        File('lib/src/utils/components/hibiki_motion_tokens.dart')
            .readAsStringSync();
    expect(motion, contains('hibikiMd3StateDuration'));
    expect(motion, contains('hibikiMd3StateCurve'));
    expect(motion, contains('Durations.short4'));
    expect(motion, contains('Easing.standard'));

    final String components = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    for (final (String start, String end) in <(String, String)>[
      ('class HibikiCard', 'enum HibikiListDensity'),
      ('class HibikiListItem', 'class HibikiSearchField'),
      ('class HibikiTagChip', 'class HibikiBadge'),
      ('class HibikiColorSwatch', 'Color _swatchForegroundFor'),
    ]) {
      final String section = _sectionSource(components, start, end);
      expect(section, contains('AnimatedContainer('));
      expect(section, contains('duration: hibikiMd3StateDuration'));
      expect(section, contains('curve: hibikiMd3StateCurve'));
    }
  });

  test('selected list items use primary foreground and a subtle outline', () {
    final String components = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    final String listItem = _sectionSource(
      components,
      'class HibikiListItem',
      'class HibikiSearchField',
    );

    expect(listItem, contains('selectedForeground'));
    expect(listItem, contains('tokens.surfaces.primary'));
    expect(listItem, contains('FontWeight.w700'));
    expect(listItem, contains('Border.all('));
    expect(listItem, contains('withValues(alpha: 0.20)'));
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
    // TODO-422：词典行尾的三点菜单已改为独立删除按钮，词典管理界面剩下的
    // HibikiOverflowMenu 在移动端页头的溢出菜单 _buildMobilePageActions 里，
    // 仍守卫它用共享 MD3 原语（HibikiOverflowMenu，而非裸 PopupMenuButton）。
    final String managerMenu = _functionSource(
      dictionaryManager,
      'List<Widget> _buildMobilePageActions() {',
      'Future<void> showDictionaryClearDialog()',
    );
    final String managerPopupItem = _functionSource(
      dictionaryManager,
      'HibikiPopupMenuItem<VoidCallback> buildPopupItem({',
      '  // TODO-422：',
    );

    // 空分类行与全空状态统一成居中的 HibikiPlaceholderMessage（共享 MD3 原语），
    // 不再是左对齐灰卡 HibikiCard（BUG-058 空状态样式一致化）。
    expect(managerEmptyState, contains('HibikiPlaceholderMessage('));
    expect(managerEmptyState, isNot(contains('DecoratedBox(')));
    expect(managerEmptyState, isNot(contains('surfaceContainerLowest')));
    expect(managerTile, contains('HibikiCard('));
    expect(managerTile, contains('HibikiListItem('));
    expect(managerTile, contains('HibikiDesignTokens.of(context)'));
    expect(managerTile, contains('tokens.spacing'));
    expect(managerTile, isNot(contains('DecoratedBox(')));
    expect(managerTile, isNot(contains('surfaceContainerLowest')));
    expect(
      managerTile,
      isNot(
          contains('const EdgeInsets.symmetric(horizontal: 12, vertical: 8)')),
    );
    expect(managerTile, isNot(contains('const SizedBox(width: 8)')));
    expect(managerTile, isNot(contains('const SizedBox(height: 8)')));
    expect(managerMenu, contains('HibikiOverflowMenu<VoidCallback>('));
    expect(managerMenu, isNot(contains('PopupMenuButton')));
    expect(managerMenu, isNot(contains('Material(')));
    expect(managerMenu, isNot(contains('BorderRadius.circular(24)')));
    expect(managerPopupItem, contains('HibikiPopupMenuItem<VoidCallback>('));
    expect(managerPopupItem, isNot(contains('Row(')));
    expect(managerPopupItem, isNot(contains('const SizedBox(width: 8)')));
    expect(managerMenu, isNot(contains('const SizedBox(width: 8)')));

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
      // TODO-270-D 把 onMineFromPopup/onUpdateFromPopup 的返回类型由 Future<bool>
      // 改成 Future<MinePopupResult>，守卫的区段结束锚点跟随新签名。
      'Future<MinePopupResult> onMineFromPopup',
    );
    expect(dictionaryLoading, contains('HibikiCard('));
    expect(
      _withoutSharedComponentNames(dictionaryLoading),
      isNot(contains('Card(')),
    );

    final String progressContent = File(
      'lib/src/pages/implementations/dictionary_progress_dialog_content.dart',
    ).readAsStringSync();
    expect(progressContent, contains('tokens.type.metadata'));
    expect(progressContent, isNot(contains('headerStyle')));

    final String termSource = File(
      'lib/src/pages/implementations/dictionary_term_page.dart',
    ).readAsStringSync();
    expect(termSource, contains('HibikiCard('));
    expect(_withoutSharedComponentNames(termSource), isNot(contains('Card(')));

    final String popupNativeSource = File(
      'lib/src/pages/implementations/dictionary_popup_native.dart',
    ).readAsStringSync();
    final String mineButton = _functionSource(
      popupNativeSource,
      'Widget _buildMineButton(',
      '  Widget _buildDeinflection(',
    );
    expect(mineButton, contains('HibikiIconButton('));
    expect(mineButton, contains('Icons.add_circle_outline'));
    expect(mineButton, contains('tokens.spacing'));
    expect(mineButton, contains('creator_export_card'));
    expect(_withoutSharedComponentNames(mineButton),
        isNot(contains('IconButton(')));
    expect(mineButton, isNot(contains("Text('+")));
    expect(mineButton, isNot(contains('HibikiFocusable(')));

    final String floatingSource = File(
      'lib/src/pages/implementations/floating_dict_page.dart',
    ).readAsStringSync();
    final String floatingTitle = _functionSource(
      floatingSource,
      'Widget _buildTitleBar()',
      'Widget _buildSearchBar()',
    );
    final String floatingSearch = _functionSource(
      floatingSource,
      'Widget _buildSearchBar()',
      'Widget _buildResults()',
    );
    for (final String section in <String>[floatingTitle, floatingSearch]) {
      expect(section, contains('HibikiDesignTokens.of(context)'));
      expect(section, contains('tokens.spacing'));
      expect(section, isNot(contains('const EdgeInsets.symmetric(')));
    }
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

  test('custom theme page uses shared MD3 spacing tokens', () {
    final String source = File(
      'lib/src/pages/implementations/custom_theme_page.dart',
    ).readAsStringSync();

    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, isNot(contains('const SizedBox(height: 16)')));
    expect(source, isNot(contains('const SizedBox(height: 12)')));
    expect(source, isNot(contains('const SizedBox(height: 8)')));
    expect(source, isNot(contains('const SizedBox(width: 16)')));
    expect(source, isNot(contains('const SizedBox(width: 8)')));
    expect(source, isNot(contains('padding: const EdgeInsets.all(16)')));
    expect(source, isNot(contains('padding: const EdgeInsets.all(12)')));
    expect(source, isNot(contains('const EdgeInsets.symmetric(horizontal: 8')));
    expect(source, isNot(contains('const EdgeInsets.symmetric(horizontal: 6')));
  });

  test('theme selector uses shared MD3 swatches', () {
    final String source =
        File('lib/src/settings/settings_actions.dart').readAsStringSync();
    final String themeSelector = _functionSource(
      source,
      'Widget buildThemeSelector(SettingsContext settingsContext)',
      'Widget buildBrightnessSelector(SettingsContext settingsContext)',
    );

    // Theme circles preview the generated scheme (primary/secondary/tertiary/
    // surface) via the four-quadrant HibikiSchemeSwatch, not a single seed
    // colour — see hibikiSchemeSwatchColors.
    expect(themeSelector, contains('HibikiSchemeSwatch('));
    expect(themeSelector, contains('hibikiSchemeSwatchColors('));
    expect(source, isNot(contains('class _ColorSwatch')));
    expect(themeSelector, isNot(contains('_ColorSwatch(')));
    expect(themeSelector, isNot(contains('Container(')));
    expect(themeSelector, isNot(contains('BoxDecoration(')));
  });

  test('custom theme import dialog uses shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/custom_theme_page.dart',
    ).readAsStringSync();
    final String importDialog = _functionSource(
      source,
      'Future<void> _importTheme()',
      '  Widget _buildPreviewCard(ColorScheme cs)',
    );

    expect(importDialog, contains('HibikiDialogFrame('));
    expect(importDialog, contains('HibikiModalSheetFrame('));
    expect(importDialog, isNot(contains('adaptiveAlertDialog(')));
  });

  test('tag filter sheet uses shared MD3 spacing tokens', () {
    final String source = File(
      'lib/src/pages/implementations/tag_filter_sheet.dart',
    ).readAsStringSync();

    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, contains('tokens.spacing'));
    expect(
      source,
      isNot(contains('const EdgeInsets.symmetric(horizontal: 16)')),
    );
    expect(source, isNot(contains('padding: const EdgeInsets.all(32)')));
    expect(source, isNot(contains('padding: const EdgeInsets.all(24)')));
    expect(source, isNot(contains('spacing: 8')));
    expect(source, isNot(contains('runSpacing: 4')));
  });

  test('app icon custom confirmation uses shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/miscellaneous_settings_page.dart',
    ).readAsStringSync();
    final String confirmDialog = _functionSource(
      source,
      'Future<void> _pickCustomIcon()',
      '  @override',
    );

    expect(confirmDialog, contains('HibikiDialogFrame('));
    expect(confirmDialog, contains('HibikiModalSheetFrame('));
    expect(confirmDialog, isNot(contains('adaptiveAlertDialog(')));
  });

  test('shortcut reset confirmation uses shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ).readAsStringSync();
    final String confirmDialog = _functionSource(
      source,
      'Future<void> _confirmResetScope(ShortcutScope scope)',
      '  Future<void> _editBinding(ShortcutAction action)',
    );

    expect(confirmDialog, contains('HibikiDialogFrame('));
    expect(confirmDialog, contains('HibikiModalSheetFrame('));
    expect(confirmDialog, isNot(contains('adaptiveAlertDialog(')));
  });

  test('shortcut binding editor uses shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ).readAsStringSync();
    final String editDialog = _sectionSource(
      source,
      'class _ShortcutBindingEditDialogState',
      source.length,
    );

    expect(editDialog, contains('HibikiDialogFrame('));
    expect(editDialog, contains('HibikiModalSheetFrame('));
    expect(editDialog, isNot(contains('adaptiveAlertDialog(')));
  });

  test('shortcut action rows use shared MD3 list and tag chips', () {
    final String source = File(
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ).readAsStringSync();
    final String tileSource = _sectionSource(
      source,
      'class _ActionTile',
      'class ShortcutBindingEditDialog',
    );

    expect(tileSource, contains('HibikiListItem('));
    expect(tileSource, contains('HibikiTagChip('));
    expect(tileSource, isNot(contains('ListTile(')));
    expect(tileSource, isNot(contains('=> Chip(')));
    expect(tileSource, isNot(contains('child: Chip(')));
  });

  test('shortcut scopes render as unified settings sections', () {
    // TODO-317: each scope is now an AdaptiveSettingsSection card (shared
    // SettingsSectionHeader title via AdaptiveSettingsSection.title) projected
    // through the unified settings detail shell — the bespoke primary-coloured
    // _ScopeSectionHeader and the standalone HibikiPageScaffold/ListView are
    // gone. Reset is an in-card AdaptiveSettingsRow action.
    final String source = File(
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ).readAsStringSync();
    final String scopeSections = _functionSource(
      source,
      'Widget _buildScopeSections(BuildContext context)',
      '  @override',
    );

    expect(scopeSections, contains('AdaptiveSettingsSection('));
    expect(scopeSections, contains('title: _scopeLabel(scope)'));
    expect(scopeSections, contains('AdaptiveSettingsRow('));
    expect(scopeSections, contains('t.shortcut_reset_defaults'));
    expect(scopeSections, contains('_ActionTile('));

    // Converged: no bespoke section-header class, no standalone scaffold/list.
    expect(source, isNot(contains('class _ScopeSectionHeader')));
    expect(source, contains('buildSettingsDetailShell('));
    expect(
      source,
      isNot(contains('const EdgeInsets.fromLTRB(16, 16, 8, 4)')),
    );
  });

  test('shortcut binding editor uses shared MD3 tag chips', () {
    final String source = File(
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ).readAsStringSync();
    final String editDialog = _sectionSource(
      source,
      'class _ShortcutBindingEditDialogState',
      source.length,
    );

    expect(editDialog, contains('HibikiTagChip('));
    expect(editDialog, contains('onDeleted:'));
    expect(editDialog, contains('HibikiOverflowMenu<GamepadButton>('));
    expect(editDialog, contains('tokens.radii.controlRadius'));
    expect(editDialog, contains('tokens.spacing'));
    expect(editDialog, isNot(contains('PopupMenuButton')));
    expect(editDialog, isNot(contains('=> Chip(')));
    expect(editDialog, isNot(contains('BorderRadius.circular(8)')));
    expect(editDialog, isNot(contains('const SizedBox(height: 8)')));
    expect(editDialog, isNot(contains('const SizedBox(width: 4)')));
    expect(
      editDialog,
      isNot(contains('const EdgeInsets.symmetric(vertical: 4)')),
    );
  });

  test('custom font dialogs use shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/custom_fonts_page.dart',
    ).readAsStringSync();
    final String progressDialog = _sectionSource(
      source,
      'class CustomFontDownloadProgressDialog',
      'class CustomFontUrlImportDialog',
    );
    final String urlDialog = _sectionSource(
      source,
      'class _CustomFontUrlImportDialogState',
      'class _RecommendedFontsPage',
    );

    for (final String dialogSource in <String>[progressDialog, urlDialog]) {
      expect(dialogSource, contains('HibikiDialogFrame('));
      expect(dialogSource, contains('HibikiModalSheetFrame('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('custom font manager disables default reorder handles', () {
    final String source = File(
      'lib/src/pages/implementations/custom_fonts_page.dart',
    ).readAsStringSync();
    final String pageSource = _sectionSource(
      source,
      'class _CustomFontsPageState',
      'class CustomFontDownloadProgressDialog',
    );

    expect(pageSource, contains('ReorderableListView.builder('));
    expect(pageSource, contains('buildDefaultDragHandles: false'));
    // 不再显示 ☰ 拖拽手柄，也不用长按拖拽，改用每行的上/下移动按钮
    // （onMoveUp / onMoveDown 调 _onReorder），更适配焦点/手柄导航。
    expect(pageSource, contains('onMoveUp:'));
    expect(pageSource, contains('onMoveDown:'));
    expect(source, isNot(contains('ReorderableDelayedDragStartListener(')));
    expect(source, isNot(contains('ReorderableDragStartListener(')));
  });

  test('system font picker search uses shared MD3 spacing tokens', () {
    final String source = File(
      'lib/src/pages/implementations/custom_fonts_page.dart',
    ).readAsStringSync();
    final String pickerSource = _sectionSource(
      source,
      'class _SystemFontPickerPageState',
      'class CustomFontsPage',
    );

    expect(pickerSource, contains('HibikiDesignTokens.of(context)'));
    expect(pickerSource, contains('tokens.spacing'));
    expect(
      pickerSource,
      isNot(contains('contentPadding: const EdgeInsets.symmetric(')),
    );
  });

  test('book CSS confirmation dialog uses shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/book_css_editor_page.dart',
    ).readAsStringSync();
    final String dialogSource = _sectionSource(
      source,
      'class BookCssConfirmationDialog<T>',
      source.length,
    );

    expect(dialogSource, contains('HibikiDialogFrame('));
    expect(dialogSource, contains('HibikiModalSheetFrame('));
    expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
  });

  test('book CSS editor shell uses shared MD3 spacing tokens', () {
    final String source = File(
      'lib/src/pages/implementations/book_css_editor_page.dart',
    ).readAsStringSync();
    final String editorBuild = _functionSource(
      source,
      'Widget build(BuildContext context)',
      '@visibleForTesting',
    );

    expect(editorBuild, contains('HibikiDesignTokens.of(context)'));
    expect(editorBuild, contains('tokens.spacing'));
    expect(editorBuild, contains('HibikiSelectableChip('));
    expect(editorBuild, contains('HibikiEditorPanel('));
    expect(editorBuild, isNot(contains('height: 40')));
    expect(
      editorBuild,
      isNot(contains('const EdgeInsets.only(right: 6)')),
    );
    expect(
      editorBuild,
      isNot(
        contains('const EdgeInsets.symmetric(horizontal: 12, vertical: 6)'),
      ),
    );
    expect(editorBuild, isNot(contains('spacing: 8')));
    expect(editorBuild, isNot(contains('runSpacing: 4')));
  });

  test('collection dialogs use shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/collections_page.dart',
    ).readAsStringSync();
    final String itemDialog = _sectionSource(
      source,
      'class CollectionItemDialogFrame',
      'class CollectionDeleteDialog',
    );
    final String deleteDialog = _sectionSource(
      source,
      'class CollectionDeleteDialog',
      source.length,
    );

    for (final String dialogSource in <String>[itemDialog, deleteDialog]) {
      expect(dialogSource, contains('HibikiDialogFrame('));
      expect(dialogSource, contains('HibikiModalSheetFrame('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('collection list rows use shared MD3 primitives', () {
    final String source = File(
      'lib/src/pages/implementations/collections_page.dart',
    ).readAsStringSync();
    final String itemSource = _functionSource(
      source,
      'Widget _buildItem(_CollectionItem item)',
      'class CollectionItemDialogFrame',
    );
    final String normalized = _withoutSharedComponentNames(itemSource);

    expect(itemSource, contains('HibikiListItem('));
    expect(itemSource, contains('HibikiIconButton('));
    expect(itemSource, contains('tokens.spacing'));
    expect(itemSource, contains('_hasAudio(item)'));
    expect(itemSource, contains('_playItemAudio(item)'));
    expect(itemSource, contains('onLongPress: () => _showItemDialog(item)'));
    expect(normalized, isNot(contains('IconButton(')));
    expect(itemSource, isNot(contains('VisualDensity.compact')));
    expect(normalized, isNot(contains('ListTile(')));
    expect(normalized, isNot(contains('Card(')));
  });

  test('media item edit dialog uses shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/media_item_edit_dialog_page.dart',
    ).readAsStringSync();
    final String dialogSource = _sectionSource(
      source,
      'class MediaItemEditDialogFrame',
      'class MediaItemCoverOverrideField',
    );

    expect(dialogSource, contains('HibikiDialogFrame('));
    expect(dialogSource, contains('HibikiModalSheetFrame('));
    expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
  });

  test('media item cover override uses MD3 card chrome instead of fake input',
      () {
    final String source = File(
      'lib/src/pages/implementations/media_item_edit_dialog_page.dart',
    ).readAsStringSync();
    final String coverField = _sectionSource(
      source,
      'class MediaItemCoverOverrideField',
      source.length,
    );

    expect(coverField, contains('HibikiCard('));
    expect(coverField, contains('HibikiDesignTokens.of(context)'));
    expect(coverField, contains('tokens.spacing'));
    expect(coverField, isNot(contains('HibikiTextField(')));
    expect(coverField, isNot(contains('TextStyle(color: Colors.transparent)')));
    expect(coverField, isNot(contains('contentPadding: EdgeInsets.zero')));
    expect(coverField, isNot(contains('const BoxConstraints(')));
    expect(coverField, isNot(contains('Spacing.of(context)')));
  });

  test('page chrome surfaces use shared MD3 spacing tokens', () {
    // 注：宽屏 rail 的 leading logo 表面在 8fd0fc1fe（drop rail logo）已整体删除，
    // 其 `_buildRailLeading()` 函数不复存在；对它的 MD3 token 守卫随之移除（BUG-012）。
    // 下方 collections + tag-management 页面 chrome 的守卫保持不变。
    final String collectionsSource = File(
      'lib/src/pages/implementations/collections_page.dart',
    ).readAsStringSync();
    final String collectionItem = _functionSource(
      collectionsSource,
      'Widget _buildItem(_CollectionItem item)',
      '@visibleForTesting',
    );
    expect(collectionItem, contains('HibikiDesignTokens.of(context)'));
    expect(collectionItem, contains('tokens.spacing'));
    expect(
      collectionItem,
      isNot(contains('padding: const EdgeInsets.only(right: 20)')),
    );

    final String tagSource = File(
      'lib/src/pages/implementations/tag_management_page.dart',
    ).readAsStringSync();
    final String tagList = _functionSource(
      tagSource,
      'Widget build(BuildContext context)',
      'class TagDeleteConfirmationDialog',
    );
    expect(tagList, contains('HibikiDesignTokens.of(context)'));
    expect(tagList, contains('tokens.spacing'));
    expect(
      tagList,
      isNot(contains('padding: const EdgeInsets.only(right: 16)')),
    );

    final String historySource = File(
      'lib/src/pages/implementations/history_reader_page.dart',
    ).readAsStringSync();
    final String historyGrid = _functionSource(
      historySource,
      'Widget buildHistory(List<MediaItem> items)',
      '/// Build the widget visually',
    );
    expect(historyGrid, contains('HibikiDesignTokens.of(context)'));
    expect(historyGrid, contains('tokens.spacing'));
    expect(
      historyGrid,
      isNot(contains('const EdgeInsets.fromLTRB(16, 48, 16, 16)')),
    );
    expect(historyGrid, isNot(contains('mainAxisSpacing: 12')));
    expect(historyGrid, isNot(contains('crossAxisSpacing: 12')));
    final String historyTile = _sectionSource(
      historySource,
      'Widget buildMediaItemContent(MediaItem item)',
      historySource.length,
    );
    expect(historyTile, contains('HibikiDesignTokens.of(context)'));
    expect(historyTile, contains('tokens.spacing'));
    expect(
      historyTile,
      isNot(contains('const EdgeInsets.fromLTRB(2, 2, 2, 4)')),
    );

    final String illustrationsSource = File(
      'lib/src/pages/implementations/illustrations_viewer_page.dart',
    ).readAsStringSync();
    final String illustrationsBody = _functionSource(
      illustrationsSource,
      'Widget _buildBody(ThemeData theme, HibikiDesignTokens tokens)',
      'class _FullScreenGallery',
    );
    expect(illustrationsBody, contains('tokens.spacing'));
    expect(
      illustrationsBody,
      isNot(contains('padding: const EdgeInsets.all(32)')),
    );

    final String profileSource = File(
      'lib/src/pages/implementations/profile_management_page.dart',
    ).readAsStringSync();
    // Profile 管理正文已抽到 ProfileManagementBody（无脚手架，可平铺进「配置方案」
    // 设置页）；tokens.spacing 等设计令牌的用法随之移到该 body state。
    final String profileState = _sectionSource(
      profileSource,
      'class _ProfileManagementBodyState',
      'class _ProfileActionButton',
    );
    expect(profileState, contains('HibikiDesignTokens.of(context)'));
    expect(profileState, contains('tokens.spacing'));
    expect(
      profileState,
      isNot(contains('padding: const EdgeInsets.symmetric(vertical: 48)')),
    );
  });

  test('open stash dialogs use shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/open_stash_dialog_page.dart',
    ).readAsStringSync();

    expect(source, contains('class OpenStashDialogFrame'));
    expect(source, contains('class OpenStashClearDialog'));
    expect(source, contains('HibikiDialogFrame('));
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
  });

  test('home dictionary clear dialog uses shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync();
    final String flow = _functionSource(
      source,
      'void _showDeleteDictionaryHistoryPrompt() async',
      'class HomeDictionaryClearHistoryDialog',
    );
    final String dialogSource = _sectionSource(
      source,
      'class HomeDictionaryClearHistoryDialog',
      source.length,
    );

    expect(flow, contains('HomeDictionaryClearHistoryDialog('));
    expect(flow, isNot(contains('adaptiveAlertDialog(')));
    expect(dialogSource, contains('HibikiDialogFrame('));
    expect(dialogSource, contains('HibikiModalSheetFrame('));
    expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
  });

  test('home dictionary list chrome uses shared MD3 spacing tokens', () {
    final String source = File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync();
    final String searchHeader = _functionSource(
      source,
      'Widget _buildSearchHeader()',
      'Widget _buildBody()',
    );
    final String historyList = _functionSource(
      source,
      'Widget _buildDictionaryHistory()',
      'void _onQueryChanged(String query)',
    );

    for (final String section in <String>[searchHeader, historyList]) {
      expect(section, contains('HibikiDesignTokens.of(context)'));
      expect(section, contains('tokens.spacing'));
    }
    expect(
      searchHeader,
      isNot(
        contains('isCupertinoPlatform(context) ? 8 : 16'),
      ),
    );
    expect(
      historyList,
      isNot(contains('padding: const EdgeInsets.only(top: 4, bottom: 16)')),
    );
    expect(
      historyList,
      isNot(
        contains(
            'margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2)'),
      ),
    );
    expect(historyList, isNot(contains('const SizedBox(width: 4)')));
  });

  test('dictionary confirmation dialogs use shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/dictionary_dialog_page.dart',
    ).readAsStringSync();
    final String clearDialog = _functionSource(
      source,
      'Future<void> showDictionaryClearDialog()',
      '  Future<void> showDictionaryDeleteDialog(Dictionary dictionary)',
    );
    final String deleteDialog = _functionSource(
      source,
      'Future<void> showDictionaryDeleteDialog(Dictionary dictionary)',
      '  Future<void> _importDictionaryFiles()',
    );
    final String confirmationFrame = _sectionSource(
      source,
      'class DictionaryConfirmationDialog',
      'class DictionaryLowMemoryDialog',
    );
    final String lowMemoryDialog = _sectionSource(
      source,
      'class DictionaryLowMemoryDialog',
      source.length,
    );

    for (final String dialogSource in <String>[clearDialog, deleteDialog]) {
      expect(dialogSource, contains('DictionaryConfirmationDialog('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }

    for (final String dialogSource in <String>[
      confirmationFrame,
      lowMemoryDialog,
    ]) {
      expect(dialogSource, contains('HibikiDialogFrame('));
      expect(dialogSource, contains('HibikiModalSheetFrame('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('dictionary download dialogs use shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/dictionary_dialog_page.dart',
    ).readAsStringSync();
    final String selectionFlow = _functionSource(
      source,
      'Future<void> _showDownloadSelectionDialog()',
      '  Widget _buildLanguageSelector({',
    );
    final String progressFlow = _functionSource(
      source,
      'Future<void> _downloadSelectedDictionaries(',
      '  static const _safChannel = HibikiChannels.saf;',
    );
    final String selectionFrame = _sectionSource(
      source,
      'class DictionaryDownloadSelectionDialogFrame',
      'class DictionaryDownloadProgressDialog',
    );
    final String progressFrame = _sectionSource(
      source,
      'class DictionaryDownloadProgressDialog',
      source.length,
    );

    expect(
      selectionFlow,
      contains('DictionaryDownloadSelectionDialogFrame('),
    );
    expect(selectionFlow, isNot(contains('adaptiveAlertDialog(')));
    expect(progressFlow, contains('DictionaryDownloadProgressDialog('));
    expect(progressFlow, isNot(contains('adaptiveAlertDialog(')));

    for (final String dialogSource in <String>[
      selectionFrame,
      progressFrame,
    ]) {
      expect(dialogSource, contains('HibikiDialogFrame('));
      expect(dialogSource, contains('HibikiModalSheetFrame('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('reader popup audio controls use shared MD3 micro spacing tokens', () {
    final String source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
    final String popupAudio = _functionSource(
      source,
      'Widget? buildPopupAudioControls()',
      '  // ── Helpers ',
    );

    expect(popupAudio, contains('HibikiDesignTokens.of(context)'));
    expect(popupAudio, contains('tokens.spacing'));
    expect(
      popupAudio,
      isNot(contains('padding: const EdgeInsets.symmetric(vertical: 2)')),
    );
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
      .replaceAll('HibikiIconButton(', 'HibikiSharedIconControl(')
      .replaceAll('HibikiSearchField(', 'HibikiSharedSearch(')
      .replaceAll('HibikiTextField(', 'HibikiSharedField(')
      .replaceAll('AdaptiveSettingsTextField(', 'AdaptiveSettingsSharedField(')
      .replaceAll('HibikiOverflowMenu(', 'HibikiSharedOverflow(')
      .replaceAll('HibikiTransientScaffold(', 'HibikiSharedTransient(')
      .replaceAll('HibikiOverlayScaffold(', 'HibikiSharedOverlay(');
}

String _withoutTransparentInkHosts(String source) {
  // A transparent Material directly hosting InkWell is an ink layer, not a
  // local visual primitive. Other Material usages remain visible to the guard.
  return source.replaceAll(
    RegExp(
      r'Material\(\s*type:\s*MaterialType\.transparency,\s*child:\s*InkWell\(',
    ),
    'TransparentInkHost(child: InkWell(',
  );
}

List<String> _forbiddenChromeHits(String source, List<String> forbidden) {
  final List<String> hits = <String>[];
  for (final String token in forbidden) {
    if (_containsForbiddenChrome(source, token)) {
      hits.add(token);
    }
  }
  return hits;
}

bool _containsForbiddenChrome(String source, String token) {
  if (!_identifierCallTokens.contains(token)) {
    return source.contains(token);
  }
  final RegExp rawCall = RegExp(
    r'(?<![A-Za-z0-9_])' + RegExp.escape(token),
  );
  return rawCall.hasMatch(source);
}

const Set<String> _identifierCallTokens = <String>{
  'Card(',
  'ListTile(',
  'SwitchListTile(',
  'CheckboxListTile(',
  'PopupMenuButton(',
};

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

String _nextWidgetAfter(String source, String startToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final RegExp widgetFunction = RegExp(r'\n  Widget [_A-Za-z0-9]+\(');
  final RegExpMatch? match = widgetFunction.firstMatch(
    source.substring(start + startToken.length),
  );
  expect(match, isNotNull, reason: 'missing next Widget after $startToken');
  return source.substring(start + startToken.length + match!.start + 1,
      start + startToken.length + match.start + match.group(0)!.length);
}
