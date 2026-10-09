// M3E 设计体系静态守卫（原 md3_design_system_static_test；用户 2026-10-06：
// 「md3 静态检查其实现在是 m3e」）。本仓 Material 一律按 Material 3 Expressive
// 做：形状走 FushiM3eShape / SettingsKitRadii / FushiDesignTokens.radii，字号走
// context.fushiType 字阶，色调容器走 FushiDesignTokens.surfaces（或文件自己处理
// Apple 分支），组件走共享 Fushi* 原语。判据细节见文件末 [_m3eChromeHits]。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_history_source_corpus.dart';
import '../pages/reader_fushi_page_source_corpus.dart';
import '../sync/sync_settings_schema_source_corpus.dart';
import '../helpers/scan_scale.dart';

void main() {
  const Map<String, List<String>> requiredComponentTokens =
      <String, List<String>>{
        'lib/src/utils/components/fushi_design_tokens.dart': <String>[
          'class FushiDesignTokens',
          'class FushiRadii',
          'class FushiSurfaceColors',
          'class FushiTypeRoles',
          'class FushiDensityTokens',
          'final FushiDensityTokens density',
          'static FushiDesignTokens of',
        ],
        'lib/src/utils/components/fushi_material_components.dart': <String>[
          'class FushiCard',
          'class FushiListItem',
          'enum FushiListDensity',
          'FushiListDensity.compact',
          'class FushiSearchField',
          'class FushiTextField',
          'class FushiSelectableChip',
          'class FushiActionChip',
          'class FushiTagChip',
          'class FushiBadge',
          'class FushiColorSwatch',
          'class FushiPreviewSwitch',
          'class FushiPageHeader',
          'class FushiPageScaffold',
          'class FushiToolScaffold',
          'class FushiTransientScaffold',
          'class FushiOverlayScaffold',
          'class FushiModalSheetFrame',
          'class FushiDialogFrame',
          'class FushiOverflowMenu',
          'class FushiPopupMenuItem',
          'class FushiFilePickerRow',
          'class FushiLogPanel',
          'class FushiPopupSurface',
          'class FushiCompactSearchRow',
          'class FushiEditorPanel',
          'onLongPress',
        ],
        'lib/src/utils/components/settings_shared.dart': <String>[
          'class AdaptiveSettingsTextField',
          'FushiCard(',
          'FushiBadge(',
        ],
      };

  const Map<String, List<String>> migratedSurfaces = <String, List<String>>{
    'lib/src/settings/material_settings_renderer.dart': <String>[
      'FushiListItem',
      // schema 行的自适应组件已收口到 settings_schema_widgets（见下条）；渲染器只
      // 复用共享 SettingsSchemaSection。
      'SettingsSchemaSection',
      'FushiPageScaffold',
    ],
    'lib/src/settings/settings_section_container.dart': <String>[
      'AdaptiveSettingsSection',
      'SettingsSectionTitlePlacement.inside',
    ],
    'lib/src/settings/settings_schema_widgets.dart': <String>[
      'SettingsSectionContainer',
      'AdaptiveSettingsSwitchRow',
      'AdaptiveSettingsSegmentedRow',
      'AdaptiveSettingsSliderRow',
    ],
    'lib/src/settings/settings_home_page.dart': <String>['FushiPageHeader'],
    'lib/src/utils/components/fushi_list_tile.dart': <String>['FushiListItem'],
    'lib/src/utils/components/fushi_text_selection_controls.dart': <String>[
      // 选区工具条是浮层（MD3 浮层面 / Apple 玻璃胶囊），不是内容卡片。
      'FushiPopupSurface',
      'FushiOverflowMenu',
    ],
    'lib/src/pages/implementations/home_dictionary_page.dart': <String>[
      'FushiPageHeader',
      'FushiSearchField',
      'FushiCard',
      'FushiListItem',
    ],
    'lib/src/pages/implementations/home_page.dart': <String>[
      'FushiDialogFrame',
    ],
    'lib/src/pages/implementations/media_source_picker_dialog_page.dart':
        <String>['FushiListItem'],
    'lib/src/pages/base_source_page.dart': <String>['FushiPopupSurface'],
    // 2026-10 统计中心重设计：区块卡收敛成共享 StatSectionCard（stat_shared.dart，
    // 内部就是一张 FushiCard），页面不再直接写 FushiCard——共享壳在下一条钉住。
    'lib/src/pages/implementations/reading_statistics_page.dart': <String>[
      'FushiPageScaffold',
      'StatSectionCard',
      'FushiDesignTokens',
    ],
    'lib/src/pages/implementations/stat_shared.dart': <String>[
      'class StatSectionCard',
      'FushiCard(',
    ],
    'lib/src/pages/implementations/collections_page.dart': <String>[
      'FushiPageScaffold',
      'FushiListItem',
    ],
    'lib/src/pages/implementations/tag_management_page.dart': <String>[
      'FushiPageScaffold',
      'FushiListItem',
      'FushiTextField',
      'FushiColorSwatch',
    ],
    // TODO-293 长按媒体对话框重设计：旧版用 FushiListItem 行 + FushiActionChip 列举动作；
    // 重设计后封面即「阅读」点击目标，动作改为叠在封面上的半透明胶囊（_TranslucentActionChip）
    // + 危险动作藏进溢出菜单（内容性视觉，不再是 list 行 / 通用 chip）。共享 MD3 锚点收敛到
    // 仍真实使用的 FushiDialogFrame（外框 chrome）+ FushiDesignTokens（spacing/type/surface 令牌）。
    'lib/src/pages/implementations/media_item_dialog_page.dart': <String>[
      'FushiDialogFrame',
      'FushiDesignTokens',
    ],
    'lib/src/utils/misc/update_checker_ui.dart': <String>['FushiCard'],
    'lib/src/sync/sync_compare_dialog.dart': <String>[
      'FushiOverflowMenu',
      'FushiCard',
      'FushiDialogFrame',
    ],
    'lib/src/media/audiobook/book_import_dialog.dart': <String>[
      'AdaptiveSettingsSection',
      'AdaptiveSettingsSwitchRow',
      'FushiFilePickerRow',
      'FushiTextField',
    ],
    'lib/src/media/audiobook/audiobook_import_dialog.dart': <String>[
      'AdaptiveSettingsSection',
      'FushiFilePickerRow',
    ],
    'lib/src/pages/implementations/reader_fushi_history_page.dart': <String>[
      'FushiPageHeader',
      'FushiCard',
      'FushiTagChip',
      'FushiBadge',
      '_bookCardShell',
    ],
    'lib/src/pages/implementations/dictionary_dialog_page.dart': <String>[
      'FushiCard',
      'FushiListItem',
      '_buildCategoryTile',
      '_buildDictCheckbox',
    ],
    // 整页标签选择器收口成 sheet 同一个 TagPickerPanel（深链兼容壳）：页面只剩
    // FushiPageScaffold；面板本体的共享 M3E 原语在下一条钉住。
    'lib/src/pages/implementations/tag_picker_page.dart': <String>[
      'FushiPageScaffold',
      'TagPickerPanel(',
    ],
    'lib/src/media/tags/tag_picker_sheet.dart': <String>[
      'class TagPickerPanel',
      'FushiModalSheetFrame(',
      'FushiSearchField(',
      'FushiTagInputChip(',
      'FushiTagToggleChip(',
    ],
    // BUG-2589：书架端「查看插图」只剩装载壳，画廊本体是阅读器内的
    // ReaderGalleryPage（自带顶栏，不走 FushiToolScaffold / FushiCard）。
    'lib/src/pages/implementations/illustrations_viewer_page.dart': <String>[
      'FushiPageScaffold',
      'ReaderGalleryPage',
    ],
    'lib/src/pages/base_history_page.dart': <String>['FushiCard'],
    'lib/src/pages/implementations/history_reader_page.dart': <String>[
      'FushiDesignTokens',
    ],
    'lib/src/pages/implementations/debug_log_page.dart': <String>[
      'SettingsKitScaffold',
      'FushiLogPanel',
    ],
    'lib/src/pages/implementations/error_log_page.dart': <String>[
      'SettingsKitScaffold',
      'FushiLogPanel',
    ],
    'lib/src/pages/implementations/popup_dictionary_page.dart': <String>[
      'FushiPopupSurface',
      'FushiCompactSearchRow',
      'FushiOverlayScaffold',
    ],
    'lib/src/pages/implementations/dictionary_popup_layer.dart': <String>[
      'FushiPopupSurface',
    ],
    'lib/src/pages/implementations/floating_dict_page.dart': <String>[
      'FushiPopupSurface',
      'FushiCompactSearchRow',
      'FushiOverlayScaffold',
    ],
    'lib/src/pages/implementations/book_css_editor_page.dart': <String>[
      'FushiToolScaffold',
      'FushiEditorPanel',
      'FushiSelectableChip',
      'FushiPlaceholderMessage',
    ],
    'lib/src/pages/implementations/anki_settings_page.dart': <String>[
      'AdaptiveSettingsTextField',
    ],
    'lib/src/pages/implementations/dictionary_settings_dialog_page.dart':
        <String>['AdaptiveSettingsTextField', 'FushiEditorPanel'],
    // TODO-586：FushiTextField 随 SettingsNumberField 搬到共享 fields 文件。
    'lib/src/settings/settings_schema_fields.dart': <String>['FushiTextField'],
    'lib/src/sync/sync_settings_schema.dart': <String>['FushiTextField'],
    'lib/src/pages/implementations/custom_theme_page.dart': <String>[
      'FushiTextField',
      'FushiDesignTokens',
      'FushiColorSwatch',
      'FushiPreviewSwitch',
    ],
    'lib/src/pages/implementations/custom_fonts_page.dart': <String>[
      'FushiTextField',
    ],
    'lib/src/pages/implementations/lyrics_dialog_page.dart': <String>[
      'FushiTextField',
    ],
    'lib/src/pages/implementations/profile_management_page.dart': <String>[
      'FushiTextField',
    ],
    'lib/src/pages/implementations/miscellaneous_settings_page.dart': <String>[
      'FushiCard',
      'FushiBadge',
    ],
    'lib/src/media/audiobook/reader_quick_settings_sheet.dart': <String>[
      'FushiTextField',
    ],
    // BUG-244 / TODO-297：阅读器有声书播放条的播放/暂停键从扁平 FushiIconButton
    // 还原成原生 MD3 [IconButton.filledTonal]（标准圆形 filled-tonal 容器 +
    // state-layer + ripple），上一句/下一句/follow/设置改无框原生 IconButton。
    // 共享 MD3 锚点收敛到原生 filled-tonal 框 + FushiDesignTokens（spacing 令牌）；
    // 「圆框 md3 观感」由专用守卫 audiobook_play_bar_md3_frame_test.dart 锁定。
    'lib/src/media/audiobook/audiobook_play_bar.dart': <String>[
      'IconButton.filledTonal',
      'FushiDesignTokens',
    ],
    // 2026-10 M3E 标签管理：筛选 chip 改为带标签色的共享 FushiTagToggleChip。
    'lib/src/pages/implementations/tag_filter_sheet.dart': <String>[
      'FushiTagToggleChip',
      'FushiModalSheetFrame',
    ],
    'lib/src/media/audiobook/subtitle_rematch.dart': <String>[
      'FushiModalSheetFrame',
      'FushiDialogFrame',
    ],
    'lib/src/pages/implementations/dictionary_popup_native.dart': <String>[
      'FushiTagChip',
      'FushiDesignTokens',
    ],
    'lib/src/utils/misc/fushi_toast.dart': <String>['FushiDesignTokens'],
    // Merged from app_model_popup_dictionary_md3_static_test.dart: the desktop
    // popup dictionary lookup (AppModel.openPopupDictionaryLookup) uses the shared
    // MD3 dialog frame + PopupDictionaryPage instead of a bespoke Dialog shell.
    'lib/src/models/app_model.dart': <String>[
      'FushiDialogFrame(',
      'PopupDictionaryPage(',
    ],
    // galgame 弹窗 MD3 收口：统一走 showAppDialog 入口（MD3 弹窗动画 + Cupertino
    // 分支）+ 共享对话框骨架（FushiDialogFrame + FushiModalSheetFrame）+
    // adaptiveDialogAction（肯定动作 FilledButton 强调），与同子系统
    // galgame_helper_installer 的确认/进度框同一套样板；波形选区框文案改走 i18n，
    // 游戏库筛选面板改走 adaptiveModalSheet + FushiModalSheetFrame。
    'lib/src/mining/galgame_waveform_select_dialog.dart': <String>[
      'showAppDialog<GalWaveformRange>(',
      'FushiDialogFrame',
      'FushiModalSheetFrame',
      'adaptiveDialogAction',
      't.game_waveform_select_title',
      't.game_waveform_range_label',
    ],
    // 刮削二跳收口后，详情页的刮削 UI 全部委托统一弹窗（galgame_scrape_dialog）。
    'lib/src/pages/implementations/galgame_detail_page.dart': <String>[
      'showGalgameScrapeDialog(',
    ],
    // 统一刮削弹窗本体（库页卡菜单与详情页编辑 tab 共用）走共享对话框骨架。
    'lib/src/mining/galgame_scrape_dialog.dart': <String>[
      'showAppDialog<bool>(',
      'FushiDialogFrame',
      'FushiModalSheetFrame',
      'adaptiveDialogAction',
    ],
    'lib/src/pages/implementations/games_library_page.dart': <String>[
      'showAppDialog<GalgamePlayStatus>(',
      'showAppDialog<String>(',
      'adaptiveModalSheet<void>(',
      'FushiDialogFrame',
      'FushiModalSheetFrame',
      'FushiTextField',
      'adaptiveDialogAction',
      'AdaptiveSettingsSwitchRow',
      // 卡菜单「刮削元数据」直开统一弹窗；「移除」先过统一销毁确认框；
      // 合集横排行长按/右键有统一合集上下文菜单。
      'showGalgameScrapeDialog(',
      'FushiDestructiveConfirmDialog(',
      'showCollectionContextDialog(',
    ],
    'lib/src/pages/implementations/texthooker_page.dart': <String>[
      'showAppDialog<int>(',
      'showAppDialog<ExternalWindowInfo>(',
    ],
  };

  test('M3E design token and shared component files exist', () {
    for (final MapEntry<String, List<String>> entry
        in requiredComponentTokens.entries) {
      final File file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: '${entry.key} must exist');
      final String source = entry.key.endsWith('reader_fushi_history_page.dart')
          ? readReaderHistorySource()
          : entry.key.endsWith('sync_settings_schema.dart')
          ? readSyncSettingsSchemaSource()
          : file.readAsStringSync();
      for (final String token in entry.value) {
        expect(source, contains(token), reason: '${entry.key} lacks $token');
      }
    }
  });

  test('high exposure surfaces use shared M3E components', () {
    for (final MapEntry<String, List<String>> entry
        in migratedSurfaces.entries) {
      final File file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: '${entry.key} must exist');
      final String source = entry.key.endsWith('reader_fushi_history_page.dart')
          ? readReaderHistorySource()
          : entry.key.endsWith('sync_settings_schema.dart')
          ? readSyncSettingsSchemaSource()
          : file.readAsStringSync();
      for (final String token in entry.value) {
        expect(source, contains(token), reason: '${entry.key} lacks $token');
      }
    }
  });

  test('migrated surfaces do not instantiate old visual primitives directly', () {
    const Map<String, List<String>> bannedByFile = <String, List<String>>{
      'lib/src/settings/material_settings_renderer.dart': <String>[
        'ListTile(',
        'Card(',
        'surfaceContainerLowest',
      ],
      'lib/src/utils/components/fushi_list_tile.dart': <String>[
        'ListTile(',
        'dense: true',
        'fontSize:',
      ],
      'lib/src/utils/components/fushi_text_selection_controls.dart': <String>[
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
      'lib/src/pages/implementations/home_page.dart': <String>['AlertDialog('],
      'lib/src/pages/implementations/media_source_picker_dialog_page.dart':
          <String>['ListTile(', 'fontSize:'],
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
      'lib/src/utils/misc/update_checker_ui.dart': <String>['child: Card('],
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
      'lib/src/pages/implementations/reader_fushi_history_page.dart': <String>[
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
        'FushiFocusable(',
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
          <String>['fontSize: 13', 'OutlineInputBorder'],
      'lib/src/pages/implementations/media_item_edit_dialog_page.dart':
          <String>['TextField('],
      'lib/src/pages/implementations/websocket_dialog_page.dart': <String>[
        'TextField(',
      ],
      // TODO-586：SettingsSecretField/SettingsNumberField（含 AdaptiveSettingsTextField
      // / FushiTextField，子串带 'TextField('）搬到共享 fields 文件。
      'lib/src/settings/settings_schema_fields.dart': <String>['TextField('],
      'lib/src/sync/sync_settings_schema.dart': <String>[
        'TextField(',
        'OutlineInputBorder',
      ],
      'lib/src/pages/implementations/custom_theme_page.dart': <String>[
        'TextField(',
        // M3E：形状 token（SettingsKitRadii / FushiM3eShape）喂给
        // BorderRadius.circular 是规范用法，禁的是页面手写数字圆角。
        r're:BorderRadius\.circular\(\s*[0-9.]',
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
        'FushiDivider()',
      ],
      'lib/src/media/audiobook/subtitle_rematch.dart': <String>[
        '=> Dialog(',
        'SafeArea(',
      ],
      'lib/src/utils/misc/fushi_toast.dart': <String>[
        'BorderRadius.circular(24)',
        'fontSize: 14',
      ],
      // Merged from app_model_popup_dictionary_md3_static_test.dart: the popup
      // dictionary lookup must not fall back to a bespoke Dialog + ConstrainedBox
      // shell (it flows through FushiDialogFrame instead).
      'lib/src/models/app_model.dart': <String>[
        '=> Dialog(',
        'child: ConstrainedBox(',
      ],
      // galgame 弹窗 MD3 收口的反向锁：不再裸 showDialog / AlertDialog /
      // 手搓 showModalBottomSheet；波形选区框不再硬编码中文文案。
      'lib/src/mining/galgame_waveform_select_dialog.dart': <String>[
        'showDialog<',
        'AlertDialog(',
        '选择音频范围',
      ],
      'lib/src/pages/implementations/galgame_detail_page.dart': <String>[
        'showDialog<',
        'AlertDialog(',
        'SimpleDialog(',
      ],
      'lib/src/mining/galgame_scrape_dialog.dart': <String>[
        'showDialog<',
        'AlertDialog(',
        'SimpleDialog(',
      ],
      'lib/src/pages/implementations/games_library_page.dart': <String>[
        'showDialog<',
        'AlertDialog(',
        // 游玩状态选择框已收口设计系统骨架（FushiListItem 行），不再裸 SimpleDialog。
        'SimpleDialog(',
        'showModalBottomSheet<',
        'SwitchListTile(',
      ],
      'lib/src/pages/implementations/texthooker_page.dart': <String>[
        'showDialog<',
      ],
    };

    for (final MapEntry<String, List<String>> entry in bannedByFile.entries) {
      final String fileSource =
          entry.key.endsWith('reader_fushi_history_page.dart')
          ? readReaderHistorySource()
          : entry.key.endsWith('sync_settings_schema.dart')
          ? readSyncSettingsSchemaSource()
          : File(entry.key).readAsStringSync();
      final String source = entry.key.endsWith('reader_fushi_history_page.dart')
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
        // scrolled-under 是专用状态装饰；仅豁免该类唯一一处 BoxDecoration，
        // 其它类与其它裸原语仍受同一门约束（对应 popup_header_divider 守卫）。
        final String checkedSource =
            entry.key.endsWith('dictionary_popup_layer.dart') &&
                banned == 'BoxDecoration('
            ? _withoutPopupScrolledUnderDecoration(source)
            : source;
        expect(
          _containsMigratedBan(checkedSource, banned),
          isFalse,
          reason: '${entry.key} still contains $banned',
        );
      }
    }
  });

  test('migrated primitive bans respect identifiers and generic calls', () {
    expect(_containsMigratedBan('Container(child: x)', 'Container('), isTrue);
    expect(
      _containsMigratedBan('AnimatedContainer(child: x)', 'Container('),
      isFalse,
    );
    expect(
      _containsMigratedBan(
        "// Container()\nfinal label = 'Container()';",
        'Container(',
      ),
      isFalse,
    );
    expect(
      _containsMigratedBan('showDialog<void>(context: c)', 'showDialog<'),
      isTrue,
    );
    expect(
      _containsMigratedBan('showDialog(context: c)', 'showDialog<'),
      isTrue,
    );
    expect(
      _containsMigratedBan('myshowDialog<void>(context: c)', 'showDialog<'),
      isFalse,
    );
  });

  test(
    'popup scrolled-under decoration exemption cannot cover other classes',
    () {
      const String source = '''
class _PopupScrolledUnderBar {
  Widget build() => AnimatedContainer(decoration: BoxDecoration());
}
class AnotherPopupPart {
  Widget build() => Container(decoration: BoxDecoration());
}
''';
      final String checked = _withoutPopupScrolledUnderDecoration(source);
      expect(identifierCall('BoxDecoration').allMatches(checked), hasLength(1));
      expect(_containsMigratedBan(checked, 'Container('), isTrue);
    },
  );

  test('ordinary page chrome does not reopen local M3E decisions', () {
    const List<String> forbidden = <String>[
      'BorderRadius.circular(',
      'VisualDensity.compact',
      'surfaceContainerLow',
      'surfaceContainerLowest',
      'surfaceContainerHigh',
      'surfaceContainerHighest',
      'fontSize:',
      // BUG-1425：`TextStyle.apply` 的两个字号旋钮。少了它们，「读一个排版令牌
      // 再用 fontSizeFactor 把它整除掉」就能锁死任意字号而整个文件一个
      // `fontSize:` 都不剩——判据天然扫不到，等于给绕过留了正门。
      'fontSizeFactor',
      'fontSizeDelta',
      'Card(',
      'ListTile(',
      'SwitchListTile(',
      'CheckboxListTile(',
      'PopupMenuButton(',
    ];
    const String kGlassDesignSystemImplementation =
        'Apple glass design-system implementation (PR glass-material): the '
        'Fushi* glass components ARE the shared primitives pages route '
        'through; they translate Apple 26 HIG metrics (capsule radii, inset '
        'grouped radii, SF point sizes) and the Apple palette into widgets — '
        'same reviewed exception class as fushi_material_components.';
    const String kSharedComponentImplementation =
        'Shared Fushi* component implementation (PR glass-material redesign): '
        'pages consume this component instead of making the decision; the '
        'MD3 / Apple dual rendering of the component owns its radii, surface '
        'roles and label sizes — same reviewed exception class as '
        'fushi_material_components / settings_shared.';
    const Map<String, String> allowedFiles = <String, String>{
      'lib/src/utils/components/fushi_design_tokens.dart':
          'Token source owns app radii and semantic surface roles.',
      'lib/src/utils/components/fushi_material_components.dart': 'Shared MD3 component implementation may map tokens to framework widgets.',
      'lib/src/utils/components/settings_shared.dart':
          'Shared adaptive settings primitives own compact settings controls '
          '(including the Apple pop-up button capsule radius).',
      'lib/src/models/theme_notifier.dart':
          'Theme preview content intentionally displays generated surface '
          'roles. buildFushiThemeData is also the ThemeData source for both '
          'design systems: the component themes it builds (input decoration '
          'radius MD3 12 / Apple 10, Apple HIG text sizes for buttons, tabs, '
          'list tiles, app bars) ARE the shared tokens pages read through '
          'Theme.of — same reviewed exception class as fushi_design_tokens.',
      'lib/src/models/fushi_m3e_misc_themes.dart':
          'M3E component-theme source split out of buildFushiThemeData '
          '(snackbar / tooltip / badge / scrollbar / date-time picker): the '
          'surface roles and the badge label size (M3E label-small 11) it '
          'writes ARE the component themes pages consume through Theme.of — '
          'same reviewed exception class as theme_notifier.',
      'lib/src/utils/fushi_color_roles.dart':
          'M3E color-role helper (ColorScheme extension): containerOf maps '
          'FushiTone.neutral to surfaceContainerHighest — it is the shared '
          'role mapping pages call instead of picking a surface tone '
          'themselves, same reviewed exception class as fushi_design_tokens.',
      'lib/src/pages/implementations/custom_theme_page.dart':
          'Theme preview studio intentionally displays user-selected colors.',
      'lib/src/pages/implementations/font_preview/font_library_widgets.dart':
          'Font library specimens: every fontSize: sizes the font sample being '
          'previewed (grid / list / glyph cells, the adjustable detail '
          'specimen and its ruby, the reserved specimen height), i.e. content '
          'size, not UI type — UI labels in the file use fushiType / the '
          'shared sectionLabel token. Same class as font_target_preview.',
      'lib/src/pages/implementations/font_preview/font_target_preview.dart':
          'Font preview specimens size sample content (ruby, subtitle, game '
          'dialogue) relative to the rendered sample, not UI type.',
      'lib/src/floating_ball/desktop_system_ball_assets.dart':
          'Rasterizes Material icon glyphs into PNGs for the native desktop '
          'ball window; the font size is the bitmap edge, not UI type.',
      'lib/src/pages/implementations/dictionary_popup_native.dart':
          'Dictionary popup chip/content typography is dense lookup content.',
      'lib/src/pages/implementations/popup_settings_injection.dart':
          'TODO-895 single-source-of-truth popup settings injection builds the '
          'shared WebView CSS custom properties (--md-surface-container-high '
          'etc.) from the MD3 ColorScheme; surface roles are injected into '
          'popup CSS, not ordinary Flutter page chrome — same reviewed '
          'exception class as popup_theme_css / global_lookup_render.',
      'lib/src/utils/popup_theme_css.dart':
          'Popup theme CSS single source of truth maps MD3 ColorScheme surface '
          'roles (surfaceContainerHigh etc.) to WebView CSS custom '
          'properties for the three popup injectors — same reviewed '
          'exception class as popup_settings_injection / '
          'global_lookup_render.',
      'lib/src/pages/implementations/history_reader_page.dart':
          'History preview uses content-derived surface and text metrics.',
      // 作品详情页共享布局（本地系列 + Jellyfin/Emby 详情页同一套）：hero 上的
      // 徽标/标签/人物胶囊（BorderRadius.circular + 压在封面上的 12px 小字）、
      // 集卡（surfaceContainerLow 卡底 + 集简介小字）与每集封面缩略图（ClipRRect
      // 圆角 + 无封面 letterbox 占位 surfaceContainerHighest）——封面美术 / 媒体书架
      // 内容，非普通页面 chrome。原先挂在 media_collection_detail_page 上的同一条
      // 豁免随视觉代码整体搬到这里（页面本体已零命中）。
      'lib/src/media/collections/collection_detail_layout.dart':
          'Shared work-detail layout (local series + media-server detail): hero '
          'badge/tag/credit pills over cover art, hayase-style episode cards '
          '(surfaceContainerLow card surface + 12px synopsis) and per-episode '
          'cover thumbnails (ClipRRect radius + no-cover letterbox placeholder '
          'using surfaceContainerHighest); cover art / media-shelf content, not '
          'ordinary page chrome — the media_collection_detail_page exemption '
          'moved here with the visuals. Glass/MD3 redesign: under the Apple '
          'design system the continue-watching episode card is lifted one '
          'step to surfaceContainerHigh (iOS selected-row raised fill), '
          'because primaryContainer is a gray fill under the monochrome '
          'accent and becomes invisible on the card.',
      // TODO-587: 书架页拆成主壳 + reader_history/*.part.dart 五个 part 文件，
      // 同一份「书架内容 chrome」豁免理由随之延伸到各 part 文件（仅拆分搬运，零行为变化）。
      'lib/src/pages/implementations/reader_history/remote.part.dart':
          'Remote book download control density is reader-shelf content.',
      'lib/src/pages/implementations/reader_fushi_page.dart': 'Hoshi reader content and reader chrome have separate migration rules.',
      // TODO-589 batch1: reader_fushi_page.dart 拆成主壳 + reader_fushi/*.part.dart；
      // 同一份「reader content / 悬浮歌词数据」豁免随搬运延伸到 part 文件（零行为变化）。
      'lib/src/pages/implementations/reader_fushi/lyrics.part.dart':
          'Lyrics-mode HTML font size and FloatingLyricStyle font size are '
          'user content passed to LyricsModeHtml / the platform overlay '
          'channel, not page chrome — same rationale as the parent '
          'reader_fushi_page.dart allowlist (extracted verbatim).',
      // 2026-10-04 歌词覆盖层 Apple 外观：按用户要求逐值复刻 Niratan 的 Apple Music
      // 播放面板（封面圆角 12、进度条 / 元数据 / 读数的固定字号），画在恒深色的
      // 模糊封面媒体面上，是播放器内容而非普通页面 chrome；MD3 外观仍走设计令牌。
      'lib/src/media/audiobook/lyrics_player/lyrics_player_apple.dart':
          'Apple Music-style lyrics player reproduces Niratan player metrics '
          '(artwork radius, scrubber and metadata type sizes) on a fixed-dark '
          'blurred-cover media surface; player content, not page chrome.',
      // TODO-589 batch7: reader chrome 域(底栏/设置 sheet/进度条/主题/收藏句/图片查看)
      // 拆到 reader_fushi/chrome.part.dart；同一份「reader content / 阅读器 chrome」
      // 豁免随搬运延伸到该 part（零行为变化，逐字符搬运自父文件）。
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart':
          'Top reading-progress text size (_infoFontSize) is reader content / '
          'chrome, same rationale as the parent reader_fushi_page.dart '
          'allowlist (extracted verbatim).',
      // BUG-2589：Windows 图片右键菜单从 chrome.part.dart 抽成共享模块（阅读器
      // 正文 / 插图册 / 书架端插图册三处共用）。菜单尺寸写常量是 BUG-1438 的
      // 结论（菜单在缩放画布内，再乘 scale 得 scale²），豁免随搬运延伸。
      'lib/src/reader/illustration_zoom_viewer.dart':
          'Windows image context-menu font size is a fixed constant by '
          'design (BUG-1438: the menu already lives inside the ui-scale '
          'canvas), extracted verbatim from reader_fushi/chrome.part.dart.',
      // BUG-2434：书内查词弹窗的覆盖主题决策从 chrome.part.dart 抽成纯函数
      // （抽出来才能对「墨水屏下不叠纸色」「必须挂 FushiEinkTheme」直接写断言，
      // 而不是只能扫源码）。那段 ColorScheme.copyWith 是逐字搬运的，豁免随之
      // 延伸，理由与父条目 reader_fushi/chrome.part.dart 同一类。
      'lib/src/pages/implementations/dictionary_popup_theme.dart':
          'The dictionary popup override theme derives its neutral container '
          'ladder from the reader paper color (deriveSurfaceRolesFrom) — it is '
          'reader content chrome, same rationale as the parent '
          'reader_fushi/chrome.part.dart allowlist (extracted verbatim).',
      // BUG-1425：reader_fushi/webview.part.dart 的豁免已删除。它的理由写的是
      // 「shellScript 收到 fontSize: s.fontSize.round()」，但该文件如今一个禁用
      // token 都不剩（`shellScript` 这个符号在整个 lib/src 里也已不存在），豁免早与
      // 代码脱节。下面的「no dead allowlist entries」断言会让同类过期豁免立刻红。
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
          'hero), driven off the active ColorScheme. M3E redesign: the '
          'Material branch is a floating capsule sharing the floating '
          'toolbar pill decoration (surfaceContainer, full radius); only the '
          'e-ink strip (surfaceContainerHighest) and the cover radius remain.',
      'lib/src/models/app_model.dart':
          'AppModel builds the FloatingLyricStyle data object (overlay font '
          'size is user content passed to the platform overlay), not an '
          'ordinary page-chrome TextStyle. Its surfaceContainerHigh / '
          'surfaceContainerLowest hits feed the popup / browser-extension CSS '
          'variable map (the full ColorScheme mirrored to WebView), a token '
          'bridge like popup_theme_css, not page chrome.',
      'lib/src/media/audiobook/lyrics_player/lyrics_typography_panel.dart':
          'The fontSize: hit is the LyricsTypographyPanel constructor '
          'argument (the user-chosen lyric size the panel edits), not a '
          'TextStyle — the panel itself renders through fushiType. Same '
          'reviewed exception class as gal_hook_text_overlay_controller.',
      'lib/src/lookup/gal_hook_text_overlay_controller.dart':
          'BUG-1095: the fontSize: hits are named arguments of the '
          'GalHookTextOverlayChannel MethodChannel wrapper (the caption '
          'size handed to the native Win32 overlay window), not a Flutter '
          'TextStyle — this controller renders no widgets at all. Same '
          'reviewed exception class as the allowlisted AppModel '
          'FloatingLyricStyle payload.',
      'lib/src/media/video/video_subtitle_overlay.dart':
          'Video subtitle overlay renders caption content (fixed '
          'white-on-black caption radius/size), not ordinary page chrome.',
      'lib/src/media/video/subtitle_style_preview.dart':
          'Subtitle style preview renders caption content at the real '
          'subtitle font size inside a simulated video frame (frame radius '
          'and surfaceContainerLow backdrop are the preview specimen shell), '
          'same reviewed exception class as the subtitle overlay and the '
          'font target preview.',
      'lib/src/media/audiobook/audiobook_clip_text_render.dart':
          'TODO-945 audiobook clip share renders the selected sentence into '
          'a shareable video frame (offscreen RepaintBoundary → PNG); the '
          'fontSize: is rendered media content (auto-scaled to fit the clip '
          'image), not ordinary page chrome — same reviewed exception class '
          'as the video subtitle overlay caption.',
      // BUG-2202：与上面 audiobook_clip_text_render 逐字同型——片段导出把字幕画成
      // 一张离屏位图烧进画面（内封 tx3g 轨会让整个片段在 QQ 这类 IM 里判为不可播）。
      // 这里的 fontSize: 是**导出画面的像素尺寸**（由用户字幕外观设置按
      // 画面高/屏幕视频区高换算而来），从不渲染进 app 的任何界面。下面
      // 「clip subtitle image layer stays off-screen media rendering」把
      // 「不是页面 chrome」这句话钉成可证伪的断言，防止豁免退化成整文件免检。
      'lib/src/media/video/video_clip_subtitle_image.dart':
          'BUG-2202 clip export renders each subtitle cue into an off-screen '
          'full-frame PNG that ffmpeg burns into the picture; the '
          'fontSize: is rendered media content sized in video pixels, '
          'never app UI — same reviewed exception class as '
          'audiobook_clip_text_render.',
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
          'Episode list panel renders episode index + title cards as '
          'video-subsystem content in a bottom overlay rail; row font size scales '
          'with appUiScale, not ordinary page chrome.',
      'lib/src/media/video/video_episode_rail.dart':
          'Shared episode rail renders 16:9 media cover frames, episode titles '
          'and playback state as video-subsystem content in the player overlay '
          'and collection hero; card typography scales with appUiScale in the '
          'player, the same reviewed content exception as video_episode_panel.',
      'lib/src/media/video/video_subtitle_style.dart':
          'Subtitle appearance model holds user-configurable caption font '
          'size (content), defaults mirror the allowlisted overlay caption.',
      'lib/src/media/video/subtitle_transcript_text.dart':
          'Shared sentence/transcript renderer extracted out of the subtitle '
          'jump panel: fontSize: is the cue text itself scaled with '
          'appUiScale, never page chrome -- it carries over the reviewed '
          'content exception already granted to video_subtitle_jump_panel, '
          'which now delegates to this file.',
      'lib/src/pages/implementations/game_stream_page.dart':
          'Game-stream receiver: fontSize: sizes the streamed Hook line text '
          'in the collapsible transcript rail -- the same subtitle-content '
          'class as the allowlisted subtitle overlay, not ordinary chrome. '
          'The page chrome itself (device rows, key-binding rows) goes '
          'through FushiListItem.',
      'lib/src/media/video/subtitle_waveform_align_panel.dart':
          'TODO-1051/1207 subtitle-sync waveform panel: the audio-energy '
          'waveform is a CustomPaint chart, so the chart-canvas frame '
          '(surfaceContainerHighest tonal surface + rounded clip) and the '
          'legend color swatches (1-2px markers) are visualization content, '
          'not ordinary page chrome — same content rationale as the '
          'allowlisted reading/video statistics pages. Interactive chrome '
          '(entry button surface, delay/view controls) routes through '
          'FushiDesignTokens + shared MD3 components (FushiIconButton / '
          'adaptiveSlider / AdaptiveSettingsTextField).',
      'lib/src/media/video/video_danmaku_text_metrics.dart':
          'BUG-1297/PR#627 danmaku font-size single source of truth, shared '
          'by rendering (video_danmaku_overlay) and geometry measurement '
          '(VideoDanmakuTextMetrics.widthOf -> video_danmaku_layout). The '
          'file is headless: no Widget/build/BuildContext/Theme.of at all, '
          'and its only fontSize: is kVideoDanmakuBaseFontSize * the user '
          'fontScale preference inside the videoDanmakuTextStyle factory - '
          'timed video content typography, the same reviewed exception '
          'class as the video_danmaku_overlay entry it was extracted from '
          'and the user-configurable subtitle caption font size in '
          'video_fushi/layout.part.dart. Routing it through a shared MD3 '
          'type role would break the contract the file documents '
          '(inherit: false, so the host DefaultTextStyle cannot desync '
          'measurement from render) and reintroduce the measure-18px / '
          'render-20px drift that made danmaku vanish mid-screen.',
      'lib/src/media/video/video_thumbnail_preview_overlay.dart':
          'TODO-669 hover/seek thumbnail preview overlay: thumbnail frame corner '
          'radius (BorderRadius.circular(6*uiScale)) and timestamp bubble '
          'font size (12*uiScale) scale with appUiScale, colors from the '
          'active ColorScheme; a video-subsystem transient overlay shown on '
          'progress-bar scrub, not ordinary page chrome — same reviewed '
          'exception class as the sibling video_volume_overlays HUD and '
          'video_danmaku_overlay.',
      'lib/src/media/video/video_m3e_chrome.dart':
          '2026-10-05 M3 Expressive video chrome: the player controls are a '
          'media-page overlay drawn on the video picture (fixed dark chrome '
          'scheme, not the page ColorScheme). Morphing play button radii, the '
          'seek-track time bubble, the double-tap ripple and the tabular time '
          'text sizes scale with appUiScale x controls density; '
          'surfaceContainerHigh is the translucent dark-scheme container of '
          'the centre transport. Same reviewed media-page overlay class as '
          'video_apple_chrome / video_volume_overlays.',
      'lib/src/media/video/video_quick_settings_sheet.dart':
          'Video settings sheet category bar (2026-10-05 M3E connected button '
          'group): the segment corner radii (10 idle / pill selected), the '
          'surfaceContainerHigh idle segment fill and the Apple footnote / '
          'section-title font sizes are the reviewed segment geometry of that '
          'one control; the rows below are rendered by the shared settings '
          'renderer.',
      'lib/src/media/video/video_long_press_speed_badge.dart':
          'TODO-1154 long-press temporary-speed badge: a video-subsystem '
          'transient overlay bubble (BorderRadius.circular(8) pill + speed '
          'fontSize label) that follows the pointer during a long-press '
          'speed gesture, styled to match the sibling OSD/HUD; not ordinary '
          'page chrome — same reviewed media-page exception class as the '
          'sibling video_thumbnail_preview_overlay / video_volume_overlays '
          'HUD entries and the volume_osd.part.dart OSD.',
      'lib/src/media/video/video_volume_overlays.dart':
          'TODO-517 split out the compact video volume popover and '
          'volume/brightness HUD to keep visible slider/HUD layers from '
          'occupying the full screen; the barrier may be full-screen, '
          'but these visible layers are video-subsystem transient overlays, '
          'not ordinary page chrome. Their size, color, and type are '
          'measured against appUiScale and video overlay contrast needs, '
          'same reviewed exception class as video subtitle/jump/chapter/'
          'quick-settings overlays.',
      // 阶段B：video_quick_settings_sheet.dart 重写为纯 schema 投影外壳后已无
      // 违禁 token，其原豁免（字幕字号 content / 播放中专属 ListTile 行 /
      // monospace 逃生口）随行声明与内嵌 builder 迁移到下面的新文件
      // （video_settings_actions.dart 的 monospace 字号 2026-10-06 已改走排版
      // 令牌，不再命中违禁 token，豁免随之删除）。
      'lib/src/settings/settings_schema_video.dart':
          'Home video settings expose the same user-configurable subtitle '
          'caption font size (VideoSubtitleStyle.copyWith(fontSize:)) for '
          'parity with the in-player sheet (TODO-286); it is caption content, '
          'not page chrome — same rationale as video_quick_settings_sheet. '
          'TODO-586：随 video destination 拆到 settings_schema_video.dart。',
      'lib/src/pages/implementations/video_fushi_page.dart':
          'Video player page chrome (track-switch menu, media controls) '
          'follows media-page rules like reader/audiobook.',
      // TODO-590: video_fushi_page.dart 拆成主壳 + video_fushi/*.part.dart；
      // 同一份 video player page chrome 豁免随搬运延伸到含 chrome token 的 part 文件
      // （零行为变化，逐字符抽出）。
      'lib/src/pages/implementations/video_fushi/episode.part.dart':
          'Episode push-aside sidebar + auto-advance countdown overlay '
          'chrome extracted verbatim from video_fushi_page.dart '
          '(TODO-590 batch4); same media-page rationale as the parent '
          'video player page allowlist entry.',
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart':
          'Subtitle source menu / import / loading-overlay / subtitle jump-list '
          'side panel chrome extracted verbatim from video_fushi_page.dart '
          '(TODO-590 batch5); the fontSize:/ListTile chrome (jump panel + '
          'source side panel rows, caption font scales with appUiScale) is '
          'the same reviewed media-page exception class as the parent '
          'video player page allowlist entry.',
      'lib/src/pages/implementations/video_fushi/flicker_notice.part.dart':
          'Black-flicker warning banner chrome (errorContainer '
          'BorderRadius.circular(12) frame + fontSize title/body '
          'labels) added by TODO-1119/BUG-545 as an errorContainer-'
          'semantic notice bar over the video controls; same reviewed '
          'media-page exception class as the parent video player page '
          'allowlist entry.',
      'lib/src/pages/implementations/video_fushi/controls_popover.part.dart':
          'Volume / playback-speed compact control popover chrome '
          '(BorderRadius/surfaceContainerHighest frame, fontSize speed '
          'label, VideoVolumePopoverCard) extracted verbatim from '
          'video_fushi_page.dart (TODO-590 batch6); the popover frame + '
          'speed-label typography scales with appUiScale and is the same '
          'reviewed media-page exception class as the parent video player '
          'page allowlist entry.',
      'lib/src/pages/implementations/video_fushi/controls_theme.part.dart':
          'Mobile/desktop media-controls theme + horizontal-seek absolute-time '
          'HUD indicator chrome (BorderRadius.circular frame, fontSize '
          'target/delta time labels in _buildSeekIndicator) extracted from '
          'video_fushi_page.dart (TODO-590) and extended by TODO-916; the '
          'seek HUD typography scales with appUiScale and is the same '
          'reviewed media-page exception class as the parent video player '
          'page allowlist entry and the sibling control popover/OSD entries.',
      'lib/src/pages/implementations/video_fushi/volume_osd.part.dart':
          'Volume + OSD / level-HUD / brightness overlay chrome '
          '(left-top OSD notification card with BorderRadius/fontSize, '
          'volume & brightness level HUD indicators) extracted verbatim '
          'from video_fushi_page.dart (TODO-590 batch7); these are '
          'video-subsystem transient overlays whose size/color/typography '
          'scale with appUiScale, the same reviewed media-page exception '
          'class as the parent video player page allowlist entry and the '
          'sibling video_volume_overlays.dart HUD entry.',
      'lib/src/pages/implementations/video_fushi/layout.part.dart':
          'Subtitle caption render tree (fontSize: _subtitleStyle.fontSize) '
          'extracted verbatim from video_fushi_page.dart (TODO-590 '
          'batch16); the user-configurable subtitle caption font size is '
          'content, not page chrome — the same reviewed media-page '
          'exception class as the parent video player page allowlist entry '
          'and the sibling video_quick_settings_sheet caption font size.',
      // 2026-08 字幕工作台：两个 Jimaku 对话框的状态机整体搬进面板文件（对话框只剩
      // 壳，不再含被禁模式），豁免随代码一起搬，理由不变。
      'lib/src/pages/implementations/subtitle_search_panel.dart':
          'Online subtitle search panel lists downloadable subtitle files as '
          'transient video-subsystem content rows.',
      'lib/src/pages/implementations/anime_download_dialog.dart':
          'Anime download dialog lists Nyaa torrent candidates (release group / '
          'resolution / seeders / subtitle-coverage badges) and per-episode '
          'Jimaku subtitle rows plus a download-task list as transient '
          'video-subsystem content — the same reviewed content exception '
          'class as the sibling jimaku_subtitle_dialog / jimaku_batch_dialog.',
      // texthooker_page（Hook 控制台）的豁免已于 2026-10-06 M3E 重做时收口：未读
      // 计数胶囊改用共享 FushiFilledButton.tonal（xs），文件里不再有裸圆角 / 裸字号。
      // 批量刮削对话框（PR#387）已随「刮削自动化」删除——刮削不再由用户点按钮
      // 触发整库任务，故此处不再需要它的豁免条目。
      // PR#253 / BUG-922：制卡「选择句子上下文」原生对话框（Niratan 式）的 ±上下文
      // 调整按钮，在横屏矮窗里刻意收紧到 compact 视觉密度（VisualDensity.compact +
      // 收敛 padding/minSize），给句子预览让出竖向空间——挖矿子系统的内容对话框，
      // 非普通页面 chrome，同 anki_mined_card_action_sheet 的内容对话框豁免类。
      'lib/src/pages/implementations/sentence_context_dialog.dart':
          'Sentence-context mining dialog deliberately uses compact visual '
          'density on its context-adjust buttons to free vertical space for '
          'the sentence preview in short landscape windows (BUG-922); '
          'mining-subsystem content dialog, not ordinary page chrome — same '
          'reviewed exception class as anki_mined_card_action_sheet.',
      // PR#474 的 Google Lens 引擎是 manga.json 的**新生产者**：它写的
      // `MokuroBlock.fontSize` 与 mokuro_payload / manga_ocr_folder_job 里被
      // 豁免的是同一个数据字段（气泡文字尺寸，落盘给 overlay 用），文件本身
      // 零 UI。属既有 reviewed 豁免类跟随新生产者，不是放宽判据。
      'lib/src/media/manga/ocr/google_lens_ocr_service.dart':
          'Writes the MokuroBlock.fontSize data field for Lens-produced '
          'manga.json blocks; pure data layer, no UI typography.',
      // 设备自带 OCR 引擎是 manga.json 的又一个新生产者，与 Lens 完全同类：
      // 写的是同一个 MokuroBlock.fontSize 数据字段（落盘给 overlay 折算 cqi
      // 命中框字号），文件零 UI。既有 reviewed 豁免类跟随新生产者，不是放宽判据；
      // 「无 UI 代码」由下面的纯数据层断言钉成可证伪的。
      'lib/src/media/manga/ocr/system_ocr_manga_service.dart':
          'Writes the MokuroBlock.fontSize data field for device-OCR-produced '
          'manga.json blocks; pure data layer, no UI typography.',
      'lib/src/creator/fields/image_field.dart':
          'Anki image-field renderer uses OCR/image coordinate typography.',
      // BUG-1425：查词源文本条的字号是**跨边界对齐常量**，不是本地 MD3 排版决定：
      // BUG-175 / TODO-222 要求它与查词弹窗 headword 同级，而那个 headword 是
      // WebView 里 assets/popup/popup.css 的 `.expression { font-size: 26px }`。
      // 与 dictionary_popup_native / popup_theme_css 同一 reviewed 豁免类（弹窗查词
      // 排版是内容，不是页面 chrome）。这条散文由下面
      // 「source lookup strip headword size stays pinned to the popup CSS」钉成
      // 可证伪断言：常量必须等于 popup.css 里的真实值，且不得退回 fontSizeFactor。
      'lib/src/utils/components/clipboard_lookup_text_panel.dart':
          'The source-text strip must render at the popup dictionary headword '
          'size (BUG-175/TODO-222). That headword lives in the WebView, not '
          'in a Flutter type role: assets/popup/popup.css sets '
          '.expression { font-size: 26px }. kPopupHeadwordFontSize is that '
          'cross-boundary parity constant (scaled by the user dictionary '
          'font ratio), the same reviewed exception class as '
          'dictionary_popup_native / popup_theme_css.',
      // BUG-2166 批：桌面端阅读器 chrome 改 ッツ 形态时，原本长在
      // reader_fushi/chrome.part.dart 里的那几块（工具栏 / 状态行 / 画廊 /
      // 统计浮层 / 有声书面板）被拆成 lib/src/reader/ 下的独立文件。豁免随搬运
      // 延伸过去，与父条目 chrome.part.dart 同一个「reader content / 阅读器
      // chrome」类：这些面活在阅读面自己的尺度上（字号与顶部进度胶囊
      // kTopProgressFontSize 成一族），不跟随 app 全局 MD3 排版。
      'lib/src/reader/reader_desktop_chrome.dart':
          'Reader toolbar typography lives on the reading surface scale '
          '(kReaderDesktopHeaderTitleFontSize, a named sibling of '
          'kTopProgressFontSize), not the app type roles — same reviewed '
          'exception class as reader_fushi/chrome.part.dart. The reader '
          'settings side sheet background is the MD3 Expressive side-panel '
          'tone (surfaceContainerLow, one step under the setting group cards; '
          'Apple uses groupedBackground) — same class as video_side_panel.',
      'lib/src/reader/reader_status_footer.dart':
          'Status strip font size is kReaderStatusFooterFontSize == '
          'kTopProgressFontSize: the footer must match the top progress '
          'pill exactly — same reviewed exception class as '
          'reader_fushi/chrome.part.dart. The 3px progress track / 2px edge '
          'line round their own height (chart content, not page chrome).',
      'lib/src/reader/reader_settings_preview.dart':
          'Reading-settings live preview renders sample BOOK TEXT at the '
          "reader's own (scaled) font size — reader content, not page chrome; "
          'same reviewed exception class as reader_fushi/chrome.part.dart.',
      // 2026-10 阅读器侧板整合（M3 Expressive）：共享侧板件与导航侧板专用件。
      // 本身就是侧板的共享原语（与 fushi_material_components 同类），页面经它们
      // 拿到分级圆角（大容器 28 / 内卡 20 / 小件 12，Apple 14 / 10）与内卡面色。
      // 原先 reader_quick_settings_sheet.dart 唯一的豁免 token（目录行折叠钮的
      // VisualDensity.compact）随目录行迁到 ReaderTocRow 后已不再命中，按「不留
      // 死豁免」纪律删除。
      'lib/src/reader/reader_panel_kit.dart':
          'Reader side-panel shared primitives (tabs / progress / quote card / '
          'empty state / panel card): they ARE the graded M3 Expressive corner '
          'radii and the one-step-up inner card surface the four reader panels '
          'route through — same reviewed exception class as '
          'fushi_material_components.',
      'lib/src/reader/reader_navigation_widgets.dart':
          'Navigation panel parts (progress hero, TOC row, cover thumb) draw '
          'the M3 Expressive shape contrast (28 hero / 20 current-row pill / '
          '10 cover) on the reading surface — same reviewed exception class as '
          'reader_audiobook_panel.',
      // Apple 玻璃设计系统 + MD3 Expressive 重设计（PR glass-material）。
      // 1) 设计系统实现层：glass/ 下的 Fushi* 组件与新增 / 改写的共享组件——
      //    与 fushi_design_tokens / fushi_material_components 同一「共享原语本身」类，
      //    页面经它们拿到圆角 / 面色 / 字号，所以它们自己必然写出这些值。
      'lib/src/utils/components/glass/fushi_glass_bars.dart':
          kGlassDesignSystemImplementation,
      'lib/src/utils/components/glass/fushi_glass_buttons.dart':
          kGlassDesignSystemImplementation,
      'lib/src/utils/components/glass/fushi_glass_chips.dart':
          kGlassDesignSystemImplementation,
      'lib/src/utils/components/glass/fushi_glass_feedback.dart':
          kGlassDesignSystemImplementation,
      'lib/src/utils/components/glass/fushi_glass_lists.dart':
          kGlassDesignSystemImplementation,
      'lib/src/utils/components/glass/fushi_glass_overlays.dart':
          kGlassDesignSystemImplementation,
      'lib/src/utils/components/glass/fushi_glass_toggles.dart':
          kGlassDesignSystemImplementation,
      'lib/src/settings/glass_settings_renderer.dart':
          kSharedComponentImplementation,
      // settings kit（2026-10）：设置模块的共享设计积木（M3E 形状色块 / 胶囊
      // 搜索栏 / 浮动页头 + Apple 分支的 iOS 字号），同「共享原语本身」类。
      'lib/src/settings/settings_kit.dart': kSharedComponentImplementation,
      'lib/src/utils/adaptive/adaptive_navigation.dart':
          kSharedComponentImplementation,
      'lib/src/utils/components/fushi_bottom_action_bar.dart':
          kSharedComponentImplementation,
      'lib/src/utils/components/fushi_download_progress.dart':
          kSharedComponentImplementation,
      'lib/src/utils/components/fushi_dropdown.dart':
          kSharedComponentImplementation,
      'lib/src/utils/components/fushi_icon_button.dart':
          kSharedComponentImplementation,
      'lib/src/utils/components/fushi_loading_view.dart':
          kSharedComponentImplementation,
      'lib/src/utils/components/fushi_placeholder_message.dart':
          kSharedComponentImplementation,
      'lib/src/utils/components/fushi_tag.dart': kSharedComponentImplementation,
      'lib/src/utils/components/library_section_tabs.dart':
          kSharedComponentImplementation,
      'lib/src/utils/misc/fushi_toast.dart': kSharedComponentImplementation,
      // 2) 页面 / 功能模块里逐条审过的内容类例外（封面美术、预览、播放器浮层、
      //    Apple 分支的 HIG 尺寸——FushiTypeRoles 暂无 Apple 字阶）。
      'lib/src/lookup/lookup_popup_size_preview.dart':
          'Popup size preview draws a scaled mock screen (frame fill, fake text '
          'lines, popup rectangle) so the user can see where the lookup popup '
          'lands; the radii and surface are preview content, not page chrome — '
          'same reviewed exception class as the theme preview cards.',
      'lib/src/media/manga/interconnect/interconnect_manga_browse_page.dart':
          'Remote manga cover placeholder / decode-failure letterbox '
          '(surfaceContainerHighest) is cover art, replacing black12 — same '
          'reviewed exception class as series_shelf_card.',
      'lib/src/media/manga/library/manga_series_page.dart':
          'Chapter cover placeholder letterbox (surfaceContainerHighest) is cover '
          'art, replacing a hard-coded #303030 block — same reviewed exception '
          'class as series_shelf_card.',
      'lib/src/media/manga/manga_cover_failure.dart':
          'Cover decode-failure tile background (surfaceContainerHighest, caller '
          'may override) is cover art — same reviewed exception class as '
          'series_shelf_card.',
      'lib/src/media/video/video_side_panel.dart':
          'Shared floating side panel of the video player (subtitle / audio / '
          'chapter panels): the e-ink side-panel surface (surfaceContainerLow '
          '+ panel radius; M3E uses the neutral player chrome surface) and the '
          'Apple sheet title (17 / 15 semibold) are the player overlay chrome, '
          'drawn over video, not ordinary page chrome.',
      'lib/src/onboarding/recommended_pack_download_mini_bar.dart':
          'Recommended-pack download mini-bar mirrors the now-listening mini-bar '
          'tone-for-tone (MD3 floating surfaceContainerHigh card, Apple 28 clear '
          'bar glass capsule) — same reviewed media mini-bar family.',
      'lib/src/pages/implementations/ai_video_acquisition_page.dart':
          'AI video acquisition chat: message bubbles (user primaryContainer / AI '
          'surfaceContainerHigh) and the 28 capsule composer are conversation '
          'content, not ordinary page chrome.',
      'lib/src/pages/implementations/discovery/discovery_layout.dart':
          'Discovery layout helpers own the cover-art geometry of the discovery '
          'pages: cover radius (MD3 FushiRadii.posterValue / Apple TV 12 / 10), '
          'hero banner radius and skeleton text-line bars — cover art and loading '
          'skeleton content, same class as series_shelf_card.',
      'lib/src/pages/implementations/media_discovery_page.dart':
          'Torrent / file result thumbnail (36x54 cover) clips with a small cover '
          'radius — cover art, same class as series_shelf_card.',
      'lib/src/pages/implementations/shortcut_settings/action_tile.part.dart':
          'Apple branch of the shortcut key-cap chip pins its label to 12 w500 '
          '(macOS key-cap label); the MD3 branch stays on the shared tag chip '
          'type. FushiTypeRoles has no Apple key-cap role yet.',
      'lib/src/settings/settings_home_page.dart':
          'Settings shell under the Apple design system: the iOS large title '
          '(34 bold) and the CupertinoSearchTextField metrics (radius, 13 / 17 '
          'text) reproduce the iOS / macOS Settings app header; the MD3 branch '
          'stays on the shared settings primitives.',
    };

    // TODO-2715 ①：豁免的**粒度**从「整份文件」收到「这份文件里被审过的那几个 token」。
    //
    // 旧机制的问题不是名单太长，而是**名单项的语义**：文件一旦进 allowedFiles，它里面
    // 新写的**任何**违规都不会被抓——理由写的是「图表内容的小字号」，实际连 `Card(` /
    // `ListTile(` / 圆角一起整份免检。BUG-1425 已经用几条手写的可证伪断言堵了其中 5 个
    // 文件（video_chapter_panel / texthooker_page / video_shader_dialog /
    // anime_download_dialog / manga_json_writeback），但那是逐文件手写的，覆盖不了另外
    // 69 个，而且每加一个豁免就要再手写一条。
    //
    // 新机制：每条豁免同时登记它**当前实际命中**的 token 集合。
    // - 命中了名单外的 token ⇒ 违规。旧理由不再捎带免检未来的新违规；
    // - 名单里的 token 不再命中 ⇒ 过期登记，必须删。这就是 BUG-1425 那条 dead-entry
    //   断言，粒度从「文件」下沉到「token」。
    //
    // 为什么是**两张表**而不是把 token 塞进 allowedFiles 的值：理由是给人读的散文、
    // token 是给判据用的数据，两者的评审方式和修改节奏不同（改理由不该动判据，反之
    // 亦然）。下面有一条断言强制两张表键集合完全一致，所以拆表不会漂。
    //
    // 这张表是**实测生成**的，不是人拍脑袋写的：写下时逐文件跑 _forbiddenChromeHits
    // 得到，因此本轮零红。它不是「以后再收窄」的占位——名单里的每个 token 从现在起
    // 都必须真实存在，删一个就红。
    const Map<String, Set<String>> allowedTokens = <String, Set<String>>{
      'lib/src/creator/fields/image_field.dart': <String>{'fontSize:'},
      'lib/src/floating_ball/desktop_system_ball_assets.dart': <String>{
        'fontSize:',
      },
      'lib/src/lookup/gal_hook_text_overlay_controller.dart': <String>{
        'fontSize:',
      },
      'lib/src/media/audiobook/lyrics_player/lyrics_typography_panel.dart':
          <String>{'fontSize:'},
      'lib/src/media/audiobook/audiobook_bridge.dart': <String>{'fontSize:'},
      'lib/src/media/audiobook/audiobook_clip_text_render.dart': <String>{
        'fontSize:',
      },
      'lib/src/media/audiobook/audiobook_session.dart': <String>{'fontSize:'},
      'lib/src/media/audiobook/now_listening_mini_bar.dart': <String>{
        'BorderRadius.circular(',
      },
      'lib/src/media/video/video_clip_subtitle_image.dart': <String>{
        'fontSize:',
      },
      'lib/src/media/manga/ocr/google_lens_ocr_service.dart': <String>{
        'fontSize:',
      },
      'lib/src/media/manga/ocr/system_ocr_manga_service.dart': <String>{
        'fontSize:',
      },
      'lib/src/media/video/subtitle_waveform_align_panel.dart': <String>{
        'BorderRadius.circular(',
        'surfaceContainerHighest',
      },
      'lib/src/media/video/video_chapter_panel.dart': <String>{'fontSize:'},
      'lib/src/media/video/video_danmaku_text_metrics.dart': <String>{
        'fontSize:',
      },
      'lib/src/media/video/video_episode_panel.dart': <String>{'fontSize:'},
      'lib/src/media/video/video_episode_rail.dart': <String>{'fontSize:'},
      'lib/src/media/video/video_m3e_chrome.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/media/video/video_quick_settings_sheet.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/media/video/video_long_press_speed_badge.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/media/video/video_subtitle_jump_panel.dart': <String>{
        'VisualDensity.compact',
        'fontSize:',
      },
      'lib/src/media/video/video_subtitle_overlay.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/media/video/video_subtitle_style.dart': <String>{'fontSize:'},
      'lib/src/media/video/subtitle_style_preview.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/media/video/subtitle_transcript_text.dart': <String>{
        'fontSize:',
      },
      'lib/src/pages/implementations/game_stream_page.dart': <String>{
        'fontSize:',
      },
      'lib/src/media/video/video_thumbnail_preview_overlay.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/media/video/video_volume_overlays.dart': <String>{
        'BorderRadius.circular(',
        'surfaceContainerHighest',
        'fontSize:',
      },
      'lib/src/models/app_model.dart': <String>{
        'surfaceContainerHigh',
        'surfaceContainerLowest',
        'fontSize:',
      },
      'lib/src/models/fushi_m3e_misc_themes.dart': <String>{
        'surfaceContainerHigh',
        'surfaceContainerHighest',
      },
      'lib/src/utils/fushi_color_roles.dart': <String>{
        'surfaceContainerHighest',
      },
      'lib/src/models/theme_notifier.dart': <String>{
        'fontSize:',
        'surfaceContainerLow',
        'surfaceContainerLowest',
        'surfaceContainerHigh',
        'surfaceContainerHighest',
      },
      'lib/src/pages/implementations/anime_download_dialog.dart': <String>{
        'VisualDensity.compact',
        'fontSize:',
      },
      // BUG-2187 重设计后预览区改用的 token：SegmentedButton 的紧凑密度与
      // 预览进度条的 tonal 轨道底色，都是「预览studio 展示的样例控件」而非页面
      // chrome（原先的 surfaceContainerLow 已不复存在，留着会变死豁免）。
      'lib/src/pages/implementations/custom_theme_page.dart': <String>{
        'VisualDensity.compact',
      },
      // 字体样张：振假名、视频字幕、游戏台词的字号按样张内容等比推导（字幕照播放器
      // 1080p 基准缩放），是内容尺寸而非界面字号。
      'lib/src/pages/implementations/font_preview/font_target_preview.dart':
          <String>{'fontSize:'},
      'lib/src/pages/implementations/font_preview/font_library_widgets.dart':
          <String>{'fontSize:'},
      'lib/src/pages/implementations/dictionary_popup_native.dart': <String>{
        'surfaceContainerHighest',
      },
      'lib/src/pages/implementations/history_reader_page.dart': <String>{
        'surfaceContainerHighest',
      },
      'lib/src/pages/implementations/subtitle_search_panel.dart': <String>{
        'VisualDensity.compact',
      },
      'lib/src/media/collections/collection_detail_layout.dart': <String>{
        'BorderRadius.circular(',
      },
      'lib/src/pages/implementations/dictionary_popup_theme.dart': <String>{
        'surfaceContainerHigh',
        'surfaceContainerHighest',
        'surfaceContainerLow',
        'surfaceContainerLowest',
      },
      'lib/src/pages/implementations/popup_settings_injection.dart': <String>{
        'surfaceContainerHigh',
      },
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/reader/illustration_zoom_viewer.dart': <String>{'fontSize:'},
      'lib/src/reader/reader_desktop_chrome.dart': <String>{'fontSize:'},
      'lib/src/reader/reader_status_footer.dart': <String>{'fontSize:'},
      'lib/src/reader/reader_panel_kit.dart': <String>{
        'BorderRadius.circular(',
      },
      'lib/src/reader/reader_navigation_widgets.dart': <String>{
        'BorderRadius.circular(',
      },
      'lib/src/reader/reader_settings_preview.dart': <String>{'fontSize:'},
      'lib/src/pages/implementations/reader_fushi/lyrics.part.dart': <String>{
        'fontSize:',
      },
      'lib/src/media/audiobook/lyrics_player/lyrics_player_apple.dart':
          <String>{'BorderRadius.circular(', 'fontSize:'},
      'lib/src/pages/implementations/reader_fushi_page.dart': <String>{
        'BorderRadius.circular(',
      },
      'lib/src/pages/implementations/reader_history/remote.part.dart': <String>{
        'VisualDensity.compact',
        'surfaceContainerHighest',
      },
      'lib/src/pages/implementations/sentence_context_dialog.dart': <String>{
        'VisualDensity.compact',
      },
      'lib/src/pages/implementations/video_fushi/controls_popover.part.dart':
          <String>{'surfaceContainerHighest', 'fontSize:'},
      'lib/src/pages/implementations/video_fushi/controls_theme.part.dart':
          <String>{'BorderRadius.circular(', 'fontSize:'},
      'lib/src/pages/implementations/video_fushi/episode.part.dart': <String>{
        'BorderRadius.circular(',
        'VisualDensity.compact',
        'fontSize:',
      },
      'lib/src/pages/implementations/video_fushi/flicker_notice.part.dart':
          <String>{'BorderRadius.circular(', 'VisualDensity.compact'},
      'lib/src/pages/implementations/video_fushi/layout.part.dart': <String>{
        'fontSize:',
      },
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/pages/implementations/video_fushi/volume_osd.part.dart':
          <String>{'fontSize:'},
      'lib/src/pages/implementations/video_fushi_page.dart': <String>{
        'fontSize:',
      },
      'lib/src/settings/settings_schema_video.dart': <String>{'fontSize:'},
      'lib/src/utils/components/clipboard_lookup_text_panel.dart': <String>{
        'fontSize:',
      },
      'lib/src/utils/components/fushi_design_tokens.dart': <String>{
        'fontSize:',
      },
      'lib/src/utils/components/fushi_material_components.dart': <String>{
        'VisualDensity.compact',
        'fontSize:',
      },
      'lib/src/utils/components/settings_shared.dart': <String>{
        'VisualDensity.compact',
        'fontSize:',
      },
      'lib/src/utils/popup_theme_css.dart': <String>{
        'surfaceContainerLow',
        'surfaceContainerHigh',
        'surfaceContainerHighest',
      },
      // Apple 玻璃设计系统 + MD3 Expressive 重设计（PR glass-material），见 allowedFiles。
      'lib/src/lookup/lookup_popup_size_preview.dart': <String>{
        'BorderRadius.circular(',
      },
      'lib/src/media/manga/interconnect/interconnect_manga_browse_page.dart':
          <String>{'surfaceContainerHighest'},
      'lib/src/media/manga/library/manga_series_page.dart': <String>{
        'surfaceContainerHighest',
      },
      'lib/src/media/manga/manga_cover_failure.dart': <String>{
        'surfaceContainerHighest',
      },
      'lib/src/media/video/video_side_panel.dart': <String>{'fontSize:'},
      'lib/src/onboarding/recommended_pack_download_mini_bar.dart': <String>{
        'BorderRadius.circular(',
      },
      'lib/src/pages/implementations/ai_video_acquisition_page.dart': <String>{
        'BorderRadius.circular(',
      },
      'lib/src/pages/implementations/discovery/discovery_layout.dart': <String>{
        'BorderRadius.circular(',
      },
      'lib/src/pages/implementations/media_discovery_page.dart': <String>{
        'BorderRadius.circular(',
      },
      'lib/src/pages/implementations/shortcut_settings/action_tile.part.dart':
          <String>{'fontSize:'},
      'lib/src/settings/glass_settings_renderer.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/settings/settings_kit.dart': <String>{'fontSize:'},
      'lib/src/settings/settings_home_page.dart': <String>{'fontSize:'},
      'lib/src/utils/adaptive/adaptive_navigation.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/utils/components/fushi_bottom_action_bar.dart': <String>{
        'fontSize:',
      },
      'lib/src/utils/components/fushi_download_progress.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/utils/components/fushi_dropdown.dart': <String>{'fontSize:'},
      'lib/src/utils/components/fushi_icon_button.dart': <String>{'fontSize:'},
      'lib/src/utils/components/fushi_loading_view.dart': <String>{'fontSize:'},
      'lib/src/utils/components/fushi_placeholder_message.dart': <String>{
        'fontSize:',
      },
      'lib/src/utils/components/fushi_tag.dart': <String>{'fontSize:'},
      'lib/src/utils/components/glass/fushi_glass_bars.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/utils/components/glass/fushi_glass_buttons.dart': <String>{
        'VisualDensity.compact',
        'fontSize:',
      },
      'lib/src/utils/components/glass/fushi_glass_chips.dart': <String>{
        'VisualDensity.compact',
        'fontSize:',
      },
      'lib/src/utils/components/glass/fushi_glass_feedback.dart': <String>{
        'fontSize:',
      },
      'lib/src/utils/components/glass/fushi_glass_lists.dart': <String>{
        'fontSize:',
        'Card(',
        'ListTile(',
      },
      'lib/src/utils/components/glass/fushi_glass_overlays.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
      },
      'lib/src/utils/components/glass/fushi_glass_toggles.dart': <String>{
        'BorderRadius.circular(',
        'fontSize:',
        'SwitchListTile(',
        'CheckboxListTile(',
      },
      'lib/src/utils/components/library_section_tabs.dart': <String>{
        'fontSize:',
      },
      'lib/src/utils/misc/fushi_toast.dart': <String>{'fontSize:'},
    };

    expect(
      allowedTokens.keys.toSet(),
      allowedFiles.keys.toSet(),
      reason:
          '两张豁免表的键必须一一对应：allowedFiles 是给人读的理由，'
          'allowedTokens 是判据真正用的范围。少一边 = 要么有文件整份免检'
          '（token 表缺项按空集处理会当场红，这条只是把原因说清），'
          '要么有条理由挂在名单上却不再有对应范围。',
    );

    final List<String> violations = <String>[];
    // BUG-1425：真正被用上的豁免键。一条豁免没被用上只有两种情况——文件没了，或者
    // 文件里早就一个禁用 token 都不剩；两种都是**过期豁免**：理由与代码脱节，却仍
    // 挂在名单上给该文件整份免检，等于给未来的违规预留了一张不会被审的通行证。
    final Set<String> liveAllowlistKeys = <String>{};
    // TODO-2715：逐 token 的实际命中，用来抓「登记了却不再命中」的过期 token。
    final Map<String, Set<String>> liveTokens = <String, Set<String>>{};
    final List<File> dartFiles =
        Directory('lib/src')
            .listSync(recursive: true)
            .whereType<File>()
            .where((File file) => file.path.endsWith('.dart'))
            .toList(growable: false)
          ..sort((File a, File b) => a.path.compareTo(b.path));
    expectScanScale(
      dartFiles.length,
      what: 'lib/src 下的 .dart',
      atLeast: 750,
      measured: 930,
    );
    for (final File file in dartFiles) {
      final String path = file.path.replaceAll(r'\', '/');
      final String? reason = allowedFiles[path];
      // TODO-2715：先剥注释。判据是禁止型（isNot），注释里写着 `fontSize:` 的说明
      // 文字会被当成命中——既制造假红，又会把一条注释登记进豁免范围。
      final String source = _withoutSharedComponentNames(
        maskComments(file.readAsStringSync()),
      );
      final List<String> hits = _m3eChromeHits(source, forbidden);
      if (hits.isEmpty) continue;
      if (reason != null && reason.isNotEmpty) {
        liveAllowlistKeys.add(path);
        liveTokens[path] = hits.toSet();
        final Set<String> covered =
            allowedTokens[path] ?? const <String>{}; // 缺项 = 零豁免范围。
        final List<String> uncovered = hits
            .where((String token) => !covered.contains(token))
            .toList(growable: false);
        if (uncovered.isEmpty) continue;
        violations.add(
          '$path: ${uncovered.join(', ')}'
          '（豁免只覆盖 ${covered.join(', ')}；新 token 不在被审范围内）',
        );
        continue;
      }
      violations.add('$path: ${hits.join(', ')}');
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Route ordinary visual chrome through shared M3E components and '
          'tokens (FushiM3eShape / FushiDesignTokens / context.fushiType), or '
          'add a reviewed allowlist reason for true content exceptions:\n'
          '${violations.join('\n')}',
    );

    final List<String> deadAllowlistEntries = allowedFiles.keys
        .where((String path) => !liveAllowlistKeys.contains(path))
        .toList(growable: false);
    expect(
      deadAllowlistEntries,
      isEmpty,
      reason:
          'BUG-1425: these allowlist entries no longer match anything — '
          'the file is gone, or it has zero forbidden-chrome hits. A reason '
          'that has drifted away from the code is not a reviewed exception, '
          'it is a standing blanket waiver. Delete the entry.',
    );

    // TODO-2715：同一条纪律下沉到 token 粒度。登记了却不再命中的 token 会悄悄
    // 变成「预留通行证」：那一项收口之后，同名 token 再长回来不会红。
    final List<String> deadTokens = <String>[];
    allowedTokens.forEach((String path, Set<String> tokens) {
      final Set<String>? live = liveTokens[path];
      if (live == null) return; // 整条已由 deadAllowlistEntries 报出。
      final Iterable<String> gone = tokens.where(
        (String token) => !live.contains(token),
      );
      if (gone.isNotEmpty) deadTokens.add('$path: ${gone.join(', ')}');
    });
    expect(
      deadTokens,
      isEmpty,
      reason:
          'TODO-2715: these exempted tokens no longer occur in the file. '
          'A token that has been routed through the shared M3E components must '
          'be removed from allowedTokens, otherwise the exemption silently '
          'holds the door open for it to come back:\n${deadTokens.join('\n')}',
    );
  });

  // BUG-1425：上面四个文件的豁免理由写得比实际命中宽——理由只谈行字号 / 状态胶囊 /
  // 勾选行 / 内容行，却顺带把行骨架和设置开关一起放了行。整份文件免检时，「理由没
  // 覆盖到的那部分」是静默通过的，光看 allowlist 根本看不出来。裸 chrome 已收口到
  // 共享 MD3 组件，这条把「收口后不许长回来」钉成可证伪断言：判据复用主守卫同一个
  // 标识符边界原语（[_containsForbiddenChrome]），不是另写一套宽松子串。
  test('reviewed content exemptions do not silently cover bare chrome', () {
    // 章节面板：行骨架是共享组件，不是裸 ListTile（其豁免只覆盖行字号）。
    final String chapterPanel = File(
      'lib/src/media/video/video_chapter_panel.dart',
    ).readAsStringSync();
    expect(chapterPanel, contains('FushiListItem('));
    expect(
      _containsForbiddenChrome(chapterPanel, 'ListTile('),
      isFalse,
      reason:
          'video_chapter_panel is allowlisted for row font size only; '
          'its row skeleton must stay a shared MD3 component',
    );

    // Hook 控制台：两个选择对话框的行骨架同上（其豁免只覆盖状态胶囊）。
    final String texthooker = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();
    expect(texthooker, contains('FushiListItem('));
    expect(
      _containsForbiddenChrome(texthooker, 'ListTile('),
      isFalse,
      reason:
          'texthooker_page is allowlisted for hook status pills only; '
          'its dialog rows must stay shared MD3 components',
    );

    // 着色器对话框：豁免只写了「导入的 shader 文件以勾选行列出」，所以
    // CheckboxListTile 留着，Anime4K 预设列表的裸 ListTile 不许回来。
    final String shaderDialog = File(
      'lib/src/pages/implementations/video_shader_dialog.dart',
    ).readAsStringSync();
    expect(shaderDialog, contains('FushiListItem('));
    expect(
      shaderDialog,
      contains('CheckboxListTile('),
      reason:
          'the reviewed reason is about the shader-file checkbox rows; '
          'if they are gone the reason must be rewritten, not inherited',
    );
    expect(
      _containsForbiddenChrome(shaderDialog, 'ListTile('),
      isFalse,
      reason: 'the Anime4K preset picker must stay a shared MD3 row',
    );

    // 番剧下载对话框：豁免通篇讲内容行，开关不在其中。
    final String animeDownload = File(
      'lib/src/pages/implementations/anime_download_dialog.dart',
    ).readAsStringSync();
    expect(animeDownload, contains('AdaptiveSettingsSwitchRow('));
    expect(
      _containsForbiddenChrome(animeDownload, 'SwitchListTile('),
      isFalse,
      reason:
          'anime_download_dialog is allowlisted for content rows; a '
          'settings toggle must go through the shared MD3 switch row',
    );
  });

  // BUG-1425：查词源文本条的豁免理由说它的字号对齐弹窗 headword，而那个 headword
  // 是 WebView 里 popup.css 的 `.expression`。散文会漂，这条把两侧钉在一起：常量
  // 变了、popup.css 变了、或有人把字号重新藏回 TextStyle.apply，都会红。
  test('source lookup strip headword size stays pinned to the popup CSS', () {
    final String panel = File(
      'lib/src/utils/components/clipboard_lookup_text_panel.dart',
    ).readAsStringSync();
    final String code = maskComments(panel);

    final RegExp declaration = RegExp(
      r'const double kPopupHeadwordFontSize = ([0-9.]+);',
    );
    final RegExpMatch? declared = declaration.firstMatch(code);
    expect(
      declared,
      isNotNull,
      reason:
          'the strip must name its headword size as a documented '
          'cross-boundary constant, not an inline literal',
    );
    final double dartSize = double.parse(declared!.group(1)!);

    // popup.css 的 `.expression` 就是弹窗 headword 那一行。
    final String popupCss = File('assets/popup/popup.css').readAsStringSync();
    final RegExpMatch? cssRule = RegExp(
      r'\.expression\s*\{[^}]*?font-size:\s*([0-9.]+)px',
      dotAll: true,
    ).firstMatch(popupCss);
    expect(
      cssRule,
      isNotNull,
      reason:
          'popup.css must still size the .expression headword; if that '
          'rule moved, the Flutter-side parity reason is stale',
    );
    expect(
      dartSize,
      double.parse(cssRule!.group(1)!),
      reason:
          'the source-text strip must render at the popup headword size '
          '(BUG-175/TODO-222); the two sides have drifted apart',
    );

    // 不许把字号重新藏进 TextStyle.apply（BUG-1425 的原始绕过写法）。
    expect(code, isNot(contains('fontSizeFactor')));
    expect(code, isNot(contains('fontSizeDelta')));
    // 唯一的字号写入就是那条对齐常量。
    final List<String> fontSizeLines = code
        .split('\n')
        .where((String line) => line.contains('fontSize:'))
        .map((String line) => line.trim())
        .toList(growable: false);
    expect(fontSizeLines, <String>[
      'return base.copyWith(fontSize: kPopupHeadwordFontSize * safeScale);',
    ], reason: 'the allowlisted hit must stay the single popup-parity size');
  });

  // BUG-1414：上面 allowlist 里 manga_json_writeback.dart 的豁免理由是「纯数据层、
  // 无 Flutter import」。理由只是一句散文，会随代码漂移；这条把它钉成可证伪的
  // 断言——一旦有人往回写层塞 UI，豁免立刻失效，而不是继续静默免检。
  test('device OCR service stays a pure data layer', () {
    // 与 manga_json_writeback 那条同款纪律：豁免的是一个数据字段，不是这份文件。
    final String source = File(
      'lib/src/media/manga/ocr/system_ocr_manga_service.dart',
    ).readAsStringSync();
    final String code = maskComments(source);

    expect(
      code,
      isNot(contains('package:flutter/')),
      reason:
          'system_ocr_manga_service.dart is allowlisted as a pure data '
          'layer; a Flutter import invalidates that reason',
    );

    final List<String> dataFieldLines = code
        .split('\n')
        .where((String line) => line.contains('fontSize:'))
        .map((String line) => line.trim())
        .toList(growable: false);
    expect(
      dataFieldLines,
      <String>['fontSize: estimateMangaBlockFontSize('],
      reason:
          'the allowlisted hit must stay the MokuroBlock data-field '
          'write, not page typography',
    );

    for (final String chrome in const <String>[
      'TextStyle(',
      'Card(',
      'ListTile(',
      'BorderRadius.circular(',
    ]) {
      expect(
        code,
        isNot(contains(chrome)),
        reason: 'the reviewed exemption must not start covering page chrome',
      );
    }
  });

  test('clip subtitle image layer stays off-screen media rendering', () {
    // 与 manga_json_writeback / system_ocr_manga_service 同款纪律：豁免的是
    // 「烧进导出画面的位图字号」，不是这份文件。BUG-2202。
    final String source = File(
      'lib/src/media/video/video_clip_subtitle_image.dart',
    ).readAsStringSync();
    final String code = maskComments(source);

    // 它渲染到 PictureRecorder，不进 widget 树。出现任何 Widget/build 就说明它
    // 变成了界面代码，豁免理由随之作废。
    for (final String ui in const <String>[
      'extends StatelessWidget',
      'extends StatefulWidget',
      'Widget build(',
      'package:flutter/material.dart',
      'package:material_ui/material_ui.dart',
    ]) {
      expect(
        code,
        isNot(contains(ui)),
        reason:
            'video_clip_subtitle_image.dart is allowlisted as off-screen '
            'media rendering; "$ui" invalidates that reason',
      );
    }
    expect(
      code,
      contains('PictureRecorder'),
      reason: 'the allowlisted hit must stay an off-screen raster path',
    );

    // 命中的 fontSize: 恰好两处，都是**按画面尺寸换算出来的像素值**：一处算出来
    // （屏幕逻辑字号 × 画面高/屏幕视频区高），一处喂给 TextStyle。写死数值、或多出
    // 第三处，就不再是「导出画面像素」，豁免理由随之作废。
    final List<String> hits = code
        .split('\n')
        .where((String line) => line.contains('fontSize:'))
        .map((String line) => line.trim())
        .toList(growable: false);
    expect(hits, <String>[
      'fontSize: style.fontSize * scale,',
      'fontSize: layout.fontSize,',
    ], reason: 'the allowlisted hits must stay computed video-pixel sizes');
  });

  test('manga.json writeback stays a pure data layer', () {
    final String source = File('lib/src/media/manga/manga_json_writeback.dart')
        .readAsStringSync();
    final String code = maskComments(source);

    // 无 Flutter import ⇒ 这个文件里不可能存在页面 chrome。
    expect(
      code,
      isNot(contains('package:flutter/')),
      reason:
          'manga_json_writeback.dart is allowlisted as a pure data '
          'layer; a Flutter import invalidates that reason',
    );

    // 写侧不自己构造块（块由引擎链产出），这里一个 fontSize: 都不该有；有了就是
    // 有人把排版或块构造塞回了写侧。
    final List<String> dataFieldLines = code
        .split('\n')
        .where((String line) => line.contains('fontSize:'))
        .map((String line) => line.trim())
        .toList(growable: false);
    expect(
      dataFieldLines,
      isEmpty,
      reason:
          'manga_json_writeback.dart no longer writes MokuroBlock '
          'fields itself; a fontSize: here means block construction or '
          'typography leaked back into the write side',
    );

    for (final String chrome in const <String>[
      'TextStyle(',
      'Card(',
      'ListTile(',
      'BorderRadius.circular(',
      'surfaceContainer',
      'VisualDensity',
      'PopupMenuButton(',
      'Widget build(',
    ]) {
      expect(
        code,
        isNot(contains(chrome)),
        reason: 'manga.json writeback must stay UI-free, found $chrome',
      );
    }
  });

  test('scrape failure detail uses the shared M3E card and design tokens', () {
    final String source = File(
      'lib/src/media/metadata/scrape_failure_view.dart',
    ).readAsStringSync();

    // M3E（2026-10-06）：失败态走全应用共享的 FushiPlaceholderMessage（error
    // tone），详情块是 error tone 的 FushiCard + M3E 小形状档；面色 / 圆角来自
    // 卡片 tone 与 FushiM3eShape，不再是 MD3 时代的 overlay 面 + cardRadius。
    expect(source, contains('FushiPlaceholderMessage('));
    expect(source, contains('FushiCard('));
    expect(source, contains('FushiCardTone.error'));
    expect(source, contains('FushiM3eShape.'));
    expect(source, contains('FushiDesignTokens.of(context)'));
    expect(source, contains('tokens.spacing.gap'));
    expect(source, isNot(contains('surfaceContainerHighest')));
    expect(source, isNot(contains('BorderRadius.circular(')));
    expect(source, isNot(contains('const SizedBox(height: 8)')));
    expect(source, isNot(contains('const SizedBox(height: 12)')));
    expect(source, isNot(contains('spacing: 8,')));
  });

  test('reader history hover overlays use design tokens', () {
    // BookDragTarget 已从 reader_fushi_history_page.dart 提取为独立文件
    // book_drag_target.dart（history 页只剩调用点），守卫跟随到新文件。
    final String source = File(
      'lib/src/pages/implementations/book_drag_target.dart',
    ).readAsStringSync();
    final String tagDropTarget = _sectionSource(
      source,
      'class BookDragTarget extends StatefulWidget',
      source.length,
    );

    expect(tagDropTarget, contains('FushiDesignTokens.of(context)'));
    expect(tagDropTarget, isNot(contains('BorderRadius.circular(12)')));
  });

  test('shared tag filter bar uses shared M3E tag chips', () {
    // 标签筛选栏已从书架页内联类 _TagBarContent 提取为共享组件
    // FushiTagFilterBar（书架 + 视频 tab 共用），此处对整份共享组件文件做约束。
    final String tagBar = File(
      'lib/src/pages/implementations/tag_filter_bar.dart',
    ).readAsStringSync();

    expect(tagBar, contains('class FushiTagFilterBar'));
    expect(tagBar, contains('FushiTagChip('));
    // 首尾「管理」「清除」动作 chip 走共享标签 chip 套件（tag_chips.dart），
    // 不在标签栏里私拼一枚。
    expect(tagBar, contains('FushiTagActionChip('));
    expect(tagBar, isNot(contains('class _TagBarActionChip')));
    final String tagChips = File('lib/src/media/tags/tag_chips.dart')
        .readAsStringSync();
    final String actionChip = _sectionSource(
      tagChips,
      'class FushiTagActionChip',
      tagChips.length,
    );
    expect(actionChip, contains('FushiDesignTokens.of(context)'));
    expect(actionChip, contains('FushiM3eShape.smallRadius'));
    expect(actionChip, isNot(contains('Radius.circular(')));
    expect(actionChip, isNot(contains('const SizedBox(width: 6)')));
    expect(tagBar, contains('FushiIconButton('));
    expect(tagBar, contains('tokens.spacing'));
    expect(tagBar, contains('tokens.surfaces.outline'));
    expect(tagBar, isNot(contains('class _TagChip')));
    expect(tagBar, isNot(contains('child: IconButton(')));
    expect(tagBar, isNot(contains('width: 32')));
    expect(tagBar, isNot(contains('height: 32')));
    expect(tagBar, isNot(contains('size: 18')));
    expect(tagBar, isNot(contains('BorderRadius.circular(16)')));
    expect(tagBar, isNot(contains('height: 44')));
    expect(
      tagBar,
      isNot(contains('EdgeInsets.symmetric(horizontal: 12, vertical: 6)')),
    );
    expect(tagBar, isNot(contains('const SizedBox(width: 6)')));
  });

  test('shared icon button uses M3E design tokens', () {
    final String source = File(
      'lib/src/utils/components/fushi_icon_button.dart',
    ).readAsStringSync();
    // 文件末尾新增了 Apple 按压态私有类 _AppleIconPressable（自己的 build），
    // 「最后一个 build」不再是 FushiIconButton 的 build。先切出
    // _FushiIconButtonState 整个类（到下一个顶层 class 为止），再取其中的 build
    // 及其后的 _buildMaterialIcon / _buildAppleIcon 分支。
    final String stateSource = _functionSource(
      source,
      'class _FushiIconButtonState extends State<FushiIconButton>',
      '\nclass ',
    );
    final String buildSource = _sectionSource(
      stateSource,
      '  Widget build(BuildContext context) {',
      stateSource.length,
    );

    expect(buildSource, contains('FushiDesignTokens.of(context)'));
    expect(buildSource, contains('tokens.spacing'));
    expect(buildSource, isNot(contains('Spacing.of(context)')));
    expect(buildSource, isNot(contains('const EdgeInsets.all(8)')));
  });

  test('reader history card layout uses shared M3E spacing tokens', () {
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

    expect(cardLayout, contains('FushiDesignTokens.of(context)'));
    expect(cardLayout, contains('tokens.spacing'));
    // 巡检 PR-3：footer 提取到共享 ShelfCardFooter（与 SeriesShelfCard 共用）。
    expect(cardLayout, contains('ShelfCardFooter(title: title)'));
    // BUG-1184：footer 高度改为随文字缩放算出（ShelfCardFooter.heightFor），不再是
    // 死的 kShelfTitleFooterHeight——40px 装两行 12sp，textScale≥1.25 时书名第二行
    // 的下半截被 SizedBox 切掉。封面区是 Expanded，footer 长高只是等量压缩封面。
    expect(
      cardLayout,
      contains('height: ShelfCardFooter.heightFor(context)'),
      reason: 'footer 高度必须随文字缩放走，不得退回固定像素（BUG-1184）',
    );
    expect(cardLayout, isNot(contains('height: kShelfTitleFooterHeight')));
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

  test(
    'book long-press frame uses visible cover block and M3E action layout',
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

      // 共享 MD3 对话框框 + 可见封面卡（2026-10-04 hero 重设计：封面按自身宽高比
      // 定尺寸，不再整宽 contain 出 letterbox；限高仍在）。
      expect(frame, contains('FushiDialogFrame('));
      expect(frame, contains('ConstrainedBox('));
      expect(frame, contains('ColoredBox('));
      expect(frame, contains('tokens.surfaces.overlay'));
      expect(frame, contains('AspectRatio('));
      expect(frame, contains('class _CoverAspectResolver'));
      expect(frame, contains('screenHeight * _coverHeightFactor'));
      // 宽框列表动作双列、窄框单列。
      expect(frame, contains('columns = wide ? 2 : 1'));
      // MD3 action layout（Material 3 Expressive）：快捷动作是等宽 tonal 图标文字
      // 按钮网格，列表动作是分段分组卡，危险动作是文字按钮。
      // BUG-2603：网格是按真实内在宽度决定列数的 _QuickActionGrid，不再是
      // 「常量猜最小宽 + Wrap」（那套在手机宽度把标签截成「查…/导…/从…」）。
      expect(frame, contains('_QuickActionGrid('));
      expect(frame, isNot(contains('_quickActionMinChipWidth')));
      expect(frame, contains('FushiFilledButton.tonalIcon('));
      expect(frame, contains('_Md3SegmentRow('));
      // 2026-10-04：列表 / 多余快捷 / 危险动作都是同一张分段分组网格（行列缝
      // kSettingsSegmentGap、外角 24 内角 4），危险组 error 色、另起一组。
      expect(frame, contains('_buildMd3SegmentGrid('));
      expect(frame, contains('kSettingsSegmentOuterRadius'));
      expect(frame, contains('SizedBox(height: kSettingsSegmentGap)'));
      expect(
        frame,
        contains('DialogDangerAction(muted: false) => colors.error'),
      );
      expect(frame, contains('final bool showLaunchAction;'));
      expect(frame, contains('showLaunchAction &&'));
      expect(frame, contains('launchLabel != null'));
      expect(frame, contains('onLaunch != null'));
      expect(frame, isNot(contains('SingleChildScrollView(')));
      expect(frame, isNot(contains('ListTile(')));
      expect(frame, isNot(contains('OutlinedButton.icon(')));
      // 旧 scrim 背景结构（TODO-455：**前景封面**铺底 + 渐变遮罩、封面几乎不可见）
      // 不得回归。hero 头部（MD3）/ 整块面板（Apple）的模糊垫底与渐变只装
      // coverBackdrop 图源（降采样后的另一份图），传入的封面 widget 只能出现在
      // 前景封面卡里、清晰不透明。
      expect(frame, isNot(contains('Positioned.fill(child: cover')));
      expect(frame, contains('final ImageProvider? coverBackdrop;'));
      expect(frame, contains('ui.ImageFilter.blur('));
      expect(
        RegExp(r'cover!').allMatches(frame).length,
        1,
        reason: '封面 widget 只画一次：在前景封面卡里',
      );
      expect(
        frame,
        matches(RegExp(r'ClipRRect\([^;]*?child: cover!,')),
        reason: '前景封面必须在圆角封面卡（ClipRRect）里画，不是背景层',
      );
    },
  );

  test('settings renderer rows use shared M3E row primitives', () {
    // schema 行渲染已从两个渲染器收口到共享 settings_schema_widgets.SettingsSchemaItem。
    final String source = File('lib/src/settings/settings_schema_widgets.dart')
        .readAsStringSync();
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

  test('reader history selection chrome uses shared M3E tokens', () {
    final String source = readReaderHistorySource();
    final String cardShell = _functionSource(
      source,
      'Widget _bookCardShell({',
      'Widget _bookCardLayout({',
    );

    expect(cardShell, contains('FushiDesignTokens.of(context)'));
    expect(cardShell, contains('tokens.spacing'));
    // 巡检 PR-3：勾选圈 / 选中罩视觉提取到共享 ShelfSelectionCheck /
    // ShelfSelectedOverlay（eink 实底统一处理），token 守卫跟随到共享文件。
    // 2026-10-04 封面即卡片：shell 只广播多选态（ShelfCoverSelection），由卡内
    // 共享封面框 ShelfCoverFrame 把两件共享组件画在封面上。
    expect(cardShell, contains('ShelfCoverSelection('));
    expect(cardShell, contains('selected: selected,'));
    expect(cardShell, isNot(contains('Spacing.of(context)')));
    expect(cardShell, isNot(contains('top: 4,')));
    expect(cardShell, isNot(contains('left: 4,')));
    expect(cardShell, isNot(contains('EdgeInsets.all(2)')));
    expect(cardShell, isNot(contains('size: 14')));
    expect(cardShell, isNot(contains('theme.colorScheme.surface.withValues')));
    expect(cardShell, isNot(contains('theme.colorScheme.outline')));
    expect(cardShell, isNot(contains('theme.colorScheme.primary.withValues')));

    final String sharedSelection = File(
      'lib/src/utils/components/shelf_card_widgets.dart',
    ).readAsStringSync();
    expect(sharedSelection, contains('FushiDesignTokens.of(context)'));
    expect(sharedSelection, contains('tokens.surfaces'));
    expect(
      sharedSelection,
      contains('ShelfSelectionCheck(selected: selection.selected)'),
    );
    expect(
      sharedSelection,
      contains('const Positioned.fill(child: ShelfSelectedOverlay())'),
    );
    expect(sharedSelection, isNot(contains('theme.colorScheme.outline')));
  });

  test('reader history batch actions use shared M3E spacing tokens', () {
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
    // 批量打标签已收敛到共享标签选择器（tag_picker_sheet.dart），间距令牌在那里断言。
    final String batchTagIntentRow = File(
      'lib/src/media/tags/tag_picker_sheet.dart',
    ).readAsStringSync();

    // 批量操作栏的 chrome（含全部间距）已收敛到共享 [BatchActionBar]，所以令牌
    // 用法要到那份实现里断言；调用点只剩动作按钮，仍不得出现硬编码间距。
    // 钉的是「批量操作栏不许硬编码间距」这个不变式，不是它写在哪个函数里。
    final String sharedBar = File(
      'lib/src/utils/components/batch_action_bar.dart',
    ).readAsStringSync();
    expect(sharedBar, contains('FushiDesignTokens'));
    expect(sharedBar, contains('tokens.spacing'));
    expect(sharedBar, isNot(contains('const SizedBox(height: 12)')));
    expect(sharedBar, isNot(contains('const SizedBox(width: 12)')));
    expect(sharedBar, isNot(contains('const SizedBox(width: 8)')));

    for (final String section in <String>[placeholder, batchTagIntentRow]) {
      expect(section, contains('FushiDesignTokens'));
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
    expect(source, isNot(contains('padding: const EdgeInsets.all(24)')));
  });

  test('reader history title footer and drag target use shared M3E tokens', () {
    final String source = readReaderHistorySource();
    // 巡检 PR-3：footer 实现提取到共享 ShelfCardFooter（书卡 / SeriesShelfCard
    // 共用），MD3 token 守卫跟随到共享文件。
    final String sharedShelfCard = File(
      'lib/src/utils/components/shelf_card_widgets.dart',
    ).readAsStringSync();
    final String titleFooter = _sectionSource(
      sharedShelfCard,
      'class ShelfCardFooter extends StatelessWidget',
      sharedShelfCard.indexOf('class ShelfSelectionCheck'),
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
    expect(titleFooter, contains('FushiDesignTokens.of(context)'));
    expect(titleFooter, contains('tokens.spacing'));
    expect(titleFooter, contains('tokens.surfaces'));
    expect(titleFooter, contains('tokens.surfaces.onSurface'));
    expect(titleFooter, contains('maxLines: 2'));
    expect(titleFooter, contains('overflow: TextOverflow.ellipsis'));
    expect(titleFooter, isNot(contains('LinearGradient(')));
    expect(titleFooter, isNot(contains('EdgeInsets.fromLTRB(6, 4, 6, 6)')));
    expect(titleFooter, isNot(contains('theme.colorScheme.surface')));
    expect(titleFooter, isNot(contains('theme.colorScheme.onSurface')));

    expect(dragTarget, contains('FushiDesignTokens.of(context)'));
    expect(dragTarget, contains('tokens.spacing'));
    expect(dragTarget, contains('tokens.surfaces'));
    expect(dragTarget, isNot(contains('final ThemeData theme')));
    expect(dragTarget, isNot(contains('theme.colorScheme.primary')));
    expect(dragTarget, isNot(contains('width: 2')));
    expect(dragTarget, isNot(contains('size: 32')));
  });

  test('reader history action dialogs use shared M3E dialog chrome', () {
    final String source = readReaderHistorySource();
    final String deleteDialog = _sectionSource(
      source,
      'class ReaderHistoryDeleteDialog',
      'class _BookProfileDialog',
    );
    // 批量 / 单条打标签统一走共享标签选择器 [TagPickerPanel]：窄屏 sheet、宽屏
    // FushiDialogFrame 弹层，主体是 FushiModalSheetFrame（MD3 chrome 闭环）。
    final String batchTagDialog = File(
      'lib/src/media/tags/tag_picker_sheet.dart',
    ).readAsStringSync();

    expect(deleteDialog, contains('FushiDialogFrame('));
    expect(deleteDialog, contains('FushiModalSheetFrame('));
    expect(batchTagDialog, contains('FushiDialogFrame('));
    expect(batchTagDialog, contains('FushiModalSheetFrame('));
    expect(source, isNot(contains('class _BatchTagPickerDialog')));
    for (final String dialogSource in <String>[deleteDialog, batchTagDialog]) {
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('reader page prompt dialogs use shared M3E dialog chrome', () {
    final String source = readReaderPageSource();
    final String readerAudiobookPart = File(
      'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
    ).readAsStringSync();
    final String sentenceActionBar = _functionSource(
      source,
      'Widget buildRow(ThemeData theme)',
      '    if (!hasAudio) {',
    );
    final String lyricsHint = _sectionSource(
      source,
      'class ReaderLyricsModeHintDialog',
      source.length,
    );
    final String lyricsFlow = _functionSource(
      source,
      'void _showLyricsModeHintIfNeeded()',
      '  Future<void> _exitLyricsMode() async',
    );
    // 字幕书「重新导入」入口现在弹的是共享的 [SrtBookReimportDialog]（音频 +
    // 字幕两半），不再是本文件里那个只有音频一半的旧 picker（已删）；这里守的是
    // 「入口仍走共享对话框、没有人在流程里手搓 adaptiveAlertDialog」。
    final String pickerFlow = _functionSource(
      readerAudiobookPart,
      'Future<void> _openSrtBookReimport() async',
      '/// TODO-1115：有声书片段视频',
    );
    final String settingsBar = _functionSource(
      source,
      'Widget _buildSettingsBar()',
      '  int _tocHrefToChapterIndex(String? href)',
    );

    expect(lyricsFlow, contains('ReaderLyricsModeHintDialog('));
    expect(pickerFlow, contains('SrtBookReimportDialog('));
    expect(settingsBar, contains('FushiDesignTokens.of(context)'));
    expect(settingsBar, contains('tokens.spacing'));
    expect(
      settingsBar,
      isNot(contains('padding: const EdgeInsets.symmetric(horizontal: 8)')),
    );
    for (final String dialogSource in <String>[
      lyricsHint,
      lyricsFlow,
      pickerFlow,
    ]) {
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
    expect(lyricsHint, contains('FushiDialogFrame('));
    expect(lyricsHint, contains('FushiModalSheetFrame('));
    expect(sentenceActionBar, contains('FushiDesignTokens.of(context)'));
    expect(sentenceActionBar, contains('tokens.spacing'));
    expect(sentenceActionBar, isNot(contains('const SizedBox(width: 8)')));
  });

  test('audiobook import dialogs use shared M3E dialog chrome', () {
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
    expect(removeDialog, contains('showDeleteScopeConfirm('));
    expect(audiobookBuild, isNot(contains('adaptiveAlertDialog(')));
    expect(removeDialog, isNot(contains('adaptiveAlertDialog(')));

    // 导入对话框外框 chrome 已收敛到共享 ImportDialogFrame（清理 wave2；审计
    // §1-K 后迁到 media/import/ 共享目录）：两侧 Frame 断言走委托，共享件内再
    // 断言真实 chrome，MD3 保证传递闭环（参照 BatchTagPickerDialogFrame 先例）。
    // RemoveConfirmation 仍直持 chrome。
    final String sharedImportFrame = File(
      'lib/src/media/import/import_dialog_frame.dart',
    ).readAsStringSync();
    expect(bookImportFrame, contains('return ImportDialogFrame('));
    expect(audiobookFrame, contains('return ImportDialogFrame('));
    // 字幕书「重新导入」对话框（音频 + 字幕两半）与上面两个导入对话框同一 chrome。
    final String srtReimportSource = File(
      'lib/src/media/audiobook/srt_book_reimport_dialog.dart',
    ).readAsStringSync();
    // HBK-AUDIT-037：外框包在 buildImportPopGuard(child: ...) 里（导入中禁关），
    // 仍是同一个共享 ImportDialogFrame。
    expect(
      srtReimportSource,
      matches(RegExp(r'(return|child:)\s+ImportDialogFrame\(')),
    );
    expect(srtReimportSource, isNot(contains('adaptiveAlertDialog(')));
    expect(sharedImportFrame, contains('FushiDialogFrame('));
    expect(sharedImportFrame, contains('FushiModalSheetFrame('));
    expect(removeFrame, contains('FushiDialogFrame('));
    expect(removeFrame, contains('FushiModalSheetFrame('));
    for (final String dialogSource in <String>[
      bookImportFrame,
      audiobookFrame,
      removeFrame,
      sharedImportFrame,
    ]) {
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('audiobook import file rows use shared M3E icon buttons', () {
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

        expect(section, contains('FushiFilePickerRow('));
        expect(section, contains('FushiIconButton('));
        // 原写法先把 FushiIconButton 换名再做裸子串匹配 —— 那是白名单，白名单
        // 永远漏：仓内还有 `_RepeatIconButton(` / `_InBookIconButton(` /
        // `_CompactSearchIconButton(` 没登记，用上任何一个就假红；反向也漏，裸子串
        // 匹配不到本仓真实在用的 `IconButton.filledTonal(`。带标识符边界的匹配
        // 一次堵住两个方向，且不需要维护白名单。
        expect(
          containsIdentifierCall(section, 'IconButton'),
          isFalse,
          reason: '${entry.key} 不得用裸 IconButton（含 IconButton.filledTonal）',
        );
        expect(section, isNot(contains('Theme.of(context).colorScheme')));
        expect(section, isNot(contains('size: 18')));
        expect(section, isNot(contains('size: 20')));
      }
    }
  });

  test('audiobook import progress chrome uses shared M3E tokens', () {
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

    // 导入中 spinner 按钮（含 tokens.surfaces.primary 的进度指示）已收敛到
    // import_flow_mixin.buildImportAction：两侧 flow 断言委托，
    // mixin 体内再断言真实 token，保证传递闭环。
    final String progressMixinSource = File(
      'lib/src/media/import/import_flow_mixin.dart',
    ).readAsStringSync();
    final String importActionBody = _functionSource(
      progressMixinSource,
      'Widget buildImportAction(',
      '  List<Widget> buildProgressSection(',
    );
    expect(importActionBody, contains('FushiDesignTokens.of(context)'));
    expect(importActionBody, contains('tokens.surfaces.primary'));
    expect(
      importActionBody,
      isNot(contains('Theme.of(context).colorScheme.primary')),
    );

    for (final String section in <String>[
      bookImportFlow,
      audiobookImportFlow,
    ]) {
      expect(section, contains('FushiDesignTokens.of(context)'));
      expect(section, contains('tokens.spacing'));
      // M3E：导入中进度收敛成共享 ImportProgressCard（下方钉住它的排版走
      // context.fushiType），flow 不再自己拼 metadata 文本行。
      expect(section, contains('ImportProgressCard('));
      expect(section, contains('buildImportAction('));
      expect(section, isNot(contains('Theme.of(context).textTheme.bodySmall')));
      expect(section, isNot(contains('Theme.of(context).colorScheme.primary')));
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

    final String progressCard = _sectionSource(
      bookImportSource,
      'class ImportProgressCard',
      bookImportSource.length,
    );
    expect(progressCard, contains('FushiCard('));
    expect(progressCard, contains('context.fushiType'));
    expect(progressCard, isNot(contains('Theme.of(context).textTheme')));
    expect(progressCard, isNot(contains('fontSize:')));
  });

  test('sentenceAudioHighlight rematch controls use shared M3E tokens', () {
    final String source = File('lib/src/media/audiobook/subtitle_rematch.dart')
        .readAsStringSync();
    final String rematchSheet = _functionSource(
      source,
      'Widget buildSheetBody(BuildContext sheetCtx, StateSetter setSheet)',
      '  static Future<int?> runAutoProbe({',
    );
    final String windowSlider = _sectionSource(
      source,
      'class SubtitleRematchWindowSlider extends StatelessWidget',
      'class SubtitleRematchThresholdSlider extends StatelessWidget',
    );
    final String thresholdSlider = _sectionSource(
      source,
      'class SubtitleRematchThresholdSlider extends StatelessWidget',
      source.length,
    );

    for (final String section in <String>[
      rematchSheet,
      windowSlider,
      thresholdSlider,
    ]) {
      expect(section, contains('FushiDesignTokens.of('));
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

  test('audiobook play bar uses shared M3E spacing tokens', () {
    final String source = File(
      'lib/src/media/audiobook/audiobook_play_bar.dart',
    ).readAsStringSync();
    final String playBarBuild = _functionSource(
      source,
      'Widget build(BuildContext context) {',
      '/// Follow audio',
    );

    expect(playBarBuild, contains('FushiDesignTokens.of(context)'));
    expect(playBarBuild, contains('tokens.spacing'));
    expect(
      playBarBuild,
      isNot(contains('padding: const EdgeInsets.symmetric(horizontal: 8)')),
    );
    expect(playBarBuild, isNot(contains('const SizedBox(width: 4)')));
  });

  test('anki integration dialogs use shared M3E dialog chrome', () {
    final String source = File('lib/src/models/anki_integration.dart')
        .readAsStringSync();
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
    expect(apiDialog, contains('FushiDialogFrame('));
    expect(apiDialog, contains('FushiModalSheetFrame('));
    expect(apiDialog, isNot(contains('adaptiveAlertDialog(')));
  });

  test('update checker dialogs use shared M3E dialog chrome', () {
    // TODO-584 拆分后: _showUpdateDialog/_showFallbackDialog 随 UpdateChecker
    // 门面进 release part; UpdateAvailableDialog/_DownloadOverlay 进 ui part。
    final String releaseSource = File(
      'lib/src/utils/misc/update_checker_release.dart',
    ).readAsStringSync();
    final String uiSource = File('lib/src/utils/misc/update_checker_ui.dart')
        .readAsStringSync();
    final String updateFlow = _functionSource(
      releaseSource,
      'static Future<void> _showUpdateDialog(',
      // 终止锚点用**方法签名**而不是下一个方法的文档注释首行：注释是会被重写的
      // （iOS 更新落地入口分流那次就把这行英文注释换成了中文），锚点跟着失效，
      // 守卫拿 -1 当窗口末尾直接红，而被守的 chrome 其实一点没变。签名不会因为
      // 改注释而漂。
      '  static Future<void> _showFallbackDialog(',
    );
    final String fallbackFlow = _functionSource(
      releaseSource,
      'static Future<void> _showFallbackDialog(',
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
    expect(dialogSource, contains('FushiDialogFrame('));
    expect(dialogSource, contains('FushiModalSheetFrame('));
    expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
  });

  test('sync feedback dialogs use shared M3E dialog chrome', () {
    final String messageSource = File('lib/src/sync/sync_message_dialog.dart')
        .readAsStringSync();
    final String compareSource = File('lib/src/sync/sync_compare_dialog.dart')
        .readAsStringSync();
    // TODO-585: schema 拆成主库 + 5 个 part；读合并语料，正向 showSyncMessage(
    // 与负向 alert 禁令都覆盖全部 part。
    final String settingsSource = readSyncSettingsSchemaSource();
    final String combined = '$messageSource\n$compareSource\n$settingsSource';

    expect(messageSource, contains('class SyncMessageDialog'));
    expect(messageSource, contains('FushiDialogFrame('));
    expect(messageSource, contains('FushiModalSheetFrame('));
    expect(compareSource, contains('showSyncMessage('));
    expect(settingsSource, contains('showSyncMessage('));
    expect(combined, isNot(contains('CupertinoAlertDialog(')));
    expect(combined, isNot(contains('adaptiveAlertDialog(')));
  });

  test('settings action dialogs use shared M3E inset tokens', () {
    final String source = File('lib/src/settings/settings_actions.dart')
        .readAsStringSync();
    final String confirmationDialog = _functionSource(
      source,
      'Future<bool> showSettingsConfirmationDialog(',
      'void notifyReaderSettingsChanged(',
    );

    expect(confirmationDialog, contains('FushiDialogFrame('));
    expect(confirmationDialog, contains('FushiModalSheetFrame('));
    expect(confirmationDialog, contains('FushiDesignTokens.of(ctx)'));
    expect(confirmationDialog, contains('insetPadding: EdgeInsets.symmetric('));
    expect(confirmationDialog, contains('horizontal: tokens.spacing.card'));
    expect(confirmationDialog, contains('vertical: tokens.spacing.card'));
    expect(
      confirmationDialog,
      isNot(
        contains('const EdgeInsets.symmetric(horizontal: 16, vertical: 16)'),
      ),
    );
  });

  test('sync settings custom controls use shared M3E rows', () {
    // TODO-585: schema 拆成主库 + 5 个 part；读合并语料，AdaptiveSettingsSwitchRow/
    // PickerRow/FushiListItem 正向断言与 Dropdown/SwitchListTile/ListTile 负向断言
    // 都覆盖全部 part。
    final String source = readSyncSettingsSchemaSource();

    expect(source, contains('AdaptiveSettingsSwitchRow('));
    expect(source, contains('AdaptiveSettingsPickerRow<SyncBackendType>('));
    expect(source, contains('FushiListItem('));
    expect(source, isNot(contains('DropdownButton<SyncBackendType>(')));
    expect(source, isNot(contains('SwitchListTile')));
    expect(source, isNot(contains('ListTile(')));
  });

  test('popup menus use the shared M3E menu item primitive', () {
    final List<String> menuFiles = <String>[
      'lib/src/pages/implementations/dictionary_dialog_page.dart',
      // Gamepad add menu lives in the binding-edit-dialog part of the
      // shortcut settings library (shortcut settings refactor).
      'lib/src/pages/implementations/shortcut_settings/'
          'binding_edit_dialog.part.dart',
      'lib/src/sync/sync_compare_dialog.dart',
      'lib/src/utils/components/fushi_text_selection_controls.dart',
    ];

    final String sharedMenu = File(
      'lib/src/utils/components/fushi_material_components.dart',
    ).readAsStringSync();
    expect(sharedMenu, contains('class FushiPopupMenuItem<T>'));
    expect(sharedMenu, contains('minHeight: 48'));
    expect(sharedMenu, contains('tokens.radii.menuRadius'));
    expect(sharedMenu, contains('PopupMenuPosition.under'));

    final String dropdown = File('lib/src/utils/components/fushi_dropdown.dart')
        .readAsStringSync();
    expect(dropdown, contains('MenuAnchor('));
    expect(dropdown, contains('tokens.radii.menuRadius'));
    expect(dropdown, contains('tokens.surfaces.overlay'));
    expect(dropdown, contains('tokens.surfaces.selected'));
    expect(dropdown, isNot(contains('BorderRadius.circular(8)')));
    expect(dropdown, isNot(contains('colors.secondaryContainer')));

    for (final String path in menuFiles) {
      final String source = File(path).readAsStringSync();
      final String withoutSharedMenuItems = source.replaceAll(
        'FushiPopupMenuItem',
        'SharedMenuItem',
      );

      expect(
        source,
        contains('FushiPopupMenuItem'),
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

  test('transient routes use shared M3E motion tokens', () {
    final File motionFile = File(
      'lib/src/utils/components/fushi_motion_tokens.dart',
    );
    expect(motionFile.existsSync(), isTrue);

    final String motion = motionFile.readAsStringSync();
    expect(motion, contains('const AnimationStyle'));
    expect(motion, contains('fushiMd3DialogAnimationStyle'));
    expect(motion, contains('fushiMd3SheetAnimationStyle'));
    expect(motion, contains('fushiMd3MenuAnimationStyle'));
    expect(motion, contains('Easing.emphasizedDecelerate'));
    expect(motion, contains('Easing.emphasizedAccelerate'));

    final String dialog = File('lib/src/utils/misc/show_app_dialog.dart')
        .readAsStringSync();
    final String sheet = File('lib/src/utils/adaptive/adaptive_widgets.dart')
        .readAsStringSync();
    final String menu = File(
      'lib/src/utils/components/fushi_material_components.dart',
    ).readAsStringSync();
    final String home = File('lib/src/pages/implementations/home_page.dart')
        .readAsStringSync();
    final String sync = File('lib/src/sync/sync_compare_dialog.dart')
        .readAsStringSync();

    // 2026-10-05 浮层统一成 M3E：三个浮层动效换成弹簧 token（定义在
    // fushi_m3e_overlays.dart），旧 fushiMd3*AnimationStyle 仍留在 motion 文件里。
    expect(dialog, contains('animationStyle: fushiM3eDialogAnimationStyle'));
    // adaptiveModalSheet 先按系统「减少动态效果」把共享 sheet 动效收成一个局部
    // sheetMotion（关动效 = AnimationStyle.noAnimation，否则恒为
    // fushiMd3SheetAnimationStyle），三条 showModalBottomSheet 分支（Apple 液态
    // 玻璃 / 毛玻璃 / 标准 MD3）都只吃这一个值。钉住：sheetMotion 的唯一非零来源
    // 是共享 token，且每条底部弹层分支都用它——任何一条换回本地动效都会红。
    final String modalSheet = _functionSource(
      sheet,
      'Future<T?> adaptiveModalSheet<T>({',
      '\n}\n',
    );
    expect(
      modalSheet,
      contains(
        RegExp(
          r'AnimationStyle sheetMotion = noMotion\s*\?\s*'
          r'AnimationStyle\.noAnimation\s*:\s*fushiM3eSheetAnimationStyle;',
        ),
      ),
    );
    final int bottomSheetCalls = 'showModalBottomSheet<T>('
        .allMatches(modalSheet)
        .length;
    expect(bottomSheetCalls, greaterThanOrEqualTo(1));
    expect(
      'sheetAnimationStyle: sheetMotion'.allMatches(modalSheet).length,
      bottomSheetCalls,
      reason: 'every bottom-sheet branch must use the shared sheet motion',
    );
    expect(
      RegExp(r'sheetAnimationStyle:\s*AnimationStyle\(').hasMatch(modalSheet),
      isFalse,
    );
    expect(menu, contains('popUpAnimationStyle: fushiM3eMenuAnimationStyle'));
    expect(home, contains('showAppDialog<bool>('));
    expect(sync, contains('showAppDialog<int>('));
    expect(home, isNot(contains('showDialog<bool>(')));
    expect(sync, isNot(contains('showDialog<int>(')));
  });

  test('shared M3E primitives animate state changes', () {
    final String motion = File(
      'lib/src/utils/components/fushi_motion_tokens.dart',
    ).readAsStringSync();
    expect(motion, contains('fushiMd3StateDuration'));
    expect(motion, contains('fushiMd3StateCurve'));
    expect(motion, contains('Durations.short4'));
    expect(motion, contains('Easing.standard'));

    final String components = File(
      'lib/src/utils/components/fushi_material_components.dart',
    ).readAsStringSync();
    for (final (String start, String end) in <(String, String)>[
      ('class FushiCard', 'enum FushiListDensity'),
      ('class FushiListItem', 'class FushiSearchField'),
      ('class FushiTagChip', 'class FushiBadge'),
      ('class FushiColorSwatch', 'Color _swatchForegroundFor'),
    ]) {
      final String section = _sectionSource(components, start, end);
      expect(section, contains('AnimatedContainer('));
      // 状态动画时长 / 曲线必须来自共享动效 token：MD3 时代的
      // fushiMd3StateDuration / fushiMd3StateCurve，或 M3E 弹簧推导的
      // FushiMotion.short（effects default）/ FushiMotion.standard（2026-10 M3E
      // 列表与卡片共享层把 FushiListItem 迁到了后者）。经 einkSafeDuration 包装
      // （eink 下归零）也算合规——守卫的意图是「用共享 token」，不是「禁止 eink
      // 例外」；禁止的是页面 / 组件自写 Duration 字面量。
      const List<String> durationTokens = <String>[
        'fushiMd3StateDuration',
        'FushiMotion.short',
      ];
      expect(
        durationTokens.any(
          (String token) =>
              section.contains('duration: $token') ||
              section.contains('duration: einkSafeDuration(context, $token)'),
        ),
        isTrue,
        reason:
            '$start section must animate with a shared state-motion token '
            '(fushiMd3StateDuration or M3E FushiMotion.short, optionally '
            'eink-gated via einkSafeDuration)',
      );
      expect(
        section.contains('curve: fushiMd3StateCurve') ||
            section.contains('curve: FushiMotion.standard'),
        isTrue,
        reason:
            '$start section must use fushiMd3StateCurve or the M3E '
            'FushiMotion.standard spring curve',
      );
    }
  });

  test(
    'selected list items use primary foreground without stacking an outline',
    () {
      final String components = File(
        'lib/src/utils/components/fushi_material_components.dart',
      ).readAsStringSync();
      final String listItem = _sectionSource(
        components,
        'class FushiListItem',
        'class FushiSearchField',
      );

      expect(listItem, contains('selectedForeground'));
      expect(listItem, contains('tokens.surfaces.primary'));
      expect(listItem, contains('FontWeight.w700'));
      // pill 的边框两态都画、非 eink 下两态都透明：几何恒定（1px 占位）以免选中后
      // 行高跳变，而填充已经是选中信号，再叠一圈 primary 细边就是填充之上的第二
      // 条线。eink 下填充塌缩，那里才换成实描边色。
      expect(listItem, contains('Border.all('));
      expect(listItem, contains('Colors.transparent'));
      expect(listItem, isNot(contains('withValues(alpha: 0.20)')));
    },
  );

  test('dictionary and popup surfaces use shared M3E primitives', () {
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
    // FushiOverflowMenu 在移动端页头的溢出菜单 _buildMobilePageActions 里，
    // 仍守卫它用共享 MD3 原语（FushiOverflowMenu，而非裸 PopupMenuButton）。
    final String managerMenu = _functionSource(
      dictionaryManager,
      'List<Widget> _buildMobilePageActions() {',
      'Future<void> showDictionaryClearDialog()',
    );
    final String managerPopupItem = _functionSource(
      dictionaryManager,
      'FushiPopupMenuItem<VoidCallback> buildPopupItem({',
      '  // TODO-422：',
    );

    // 空分类行与全空状态统一成居中的 FushiPlaceholderMessage（共享 MD3 原语），
    // 不再是左对齐灰卡 FushiCard（BUG-058 空状态样式一致化）。
    expect(managerEmptyState, contains('FushiPlaceholderMessage('));
    expect(managerEmptyState, isNot(contains('DecoratedBox(')));
    expect(managerEmptyState, isNot(contains('surfaceContainerLowest')));
    // 词典行改成「整张列表读作一个设置分组」：每行外壳是共享分组行
    // FushiGroupedListItem（MD3 分段卡 / Apple inset grouped），它内部就是按组内
    // 位置定圆角的 FushiCard。守卫钉住外壳必须是这个共享原语、且共享原语本身仍
    // 落到 FushiCard——不许页面退回自己画卡片底 / 圆角。
    expect(managerTile, contains('FushiGroupedListItem('));
    expect(containsIdentifierCall(managerTile, 'Card'), isFalse);
    final String groupedListItem = _functionSource(
      File('lib/src/utils/components/glass/fushi_glass_lists.dart')
          .readAsStringSync(),
      'class FushiGroupedListItem extends StatelessWidget {',
      'class FushiGroupedList extends StatelessWidget {',
    );
    expect(groupedListItem, contains('FushiCard('));
    expect(managerTile, contains('FushiListItem('));
    expect(managerTile, contains('FushiDesignTokens.of(context)'));
    expect(managerTile, contains('tokens.spacing'));
    expect(managerTile, isNot(contains('DecoratedBox(')));
    expect(managerTile, isNot(contains('surfaceContainerLowest')));
    expect(
      managerTile,
      isNot(
        contains('const EdgeInsets.symmetric(horizontal: 12, vertical: 8)'),
      ),
    );
    expect(managerTile, isNot(contains('const SizedBox(width: 8)')));
    expect(managerTile, isNot(contains('const SizedBox(height: 8)')));
    expect(managerMenu, contains('FushiOverflowMenu<VoidCallback>('));
    expect(managerMenu, isNot(contains('PopupMenuButton')));
    expect(managerMenu, isNot(contains('Material(')));
    expect(managerMenu, isNot(contains('BorderRadius.circular(24)')));
    expect(managerPopupItem, contains('FushiPopupMenuItem<VoidCallback>('));
    // 裸子串 `Row(` 会被仓内几十个 `*Row(` 组件（`AdaptiveSettingsSwitchRow(` /
    // `AudioCueRow(` / `AnkiMappingRow(` …）命中，菜单项引用任何一个就假红。
    expect(containsIdentifierCall(managerPopupItem, 'Row'), isFalse);
    expect(managerPopupItem, isNot(contains('const SizedBox(width: 8)')));
    expect(managerMenu, isNot(contains('const SizedBox(width: 8)')));

    final String sourcePage = File('lib/src/pages/base_source_page.dart')
        .readAsStringSync();
    final String dictionaryLoading = _functionSource(
      sourcePage,
      'Widget buildDictionaryLoading()',
      // TODO-270-D 把 onMineFromPopup/onUpdateFromPopup 的返回类型由 Future<bool>
      // 改成 Future<MinePopupResult>，守卫的区段结束锚点跟随新签名。
      'Future<MinePopupResult> onMineFromPopup',
    );
    // 查词在途指示改走共享延迟加载层 FushiDeferredLoading（150ms 后才露出、
    // 至少停 300ms、撤场后是不拦指针的空盒；指示器是共享 FushiLoadingView），
    // 取代原先「透明 FushiCard 里手搭一条 LinearProgressIndicator」。钉住共享
    // 原语，且页面不许再自己搭进度条 / 卡片底。
    expect(dictionaryLoading, contains('FushiDeferredLoading('));
    expect(
      containsIdentifierCall(dictionaryLoading, 'LinearProgressIndicator'),
      isFalse,
    );
    // 免白名单：`FushiCard(` 本身含子串 `Card(`，旧写法靠换名绕开；但仓内还有
    // `_EndpointCard(` / `_EpisodeRailCard(` / `SeriesShelfCard(` 等一堆以 Card
    // 结尾的组件没登记。标识符边界匹配只认裸 `Card` 构造。
    expect(containsIdentifierCall(dictionaryLoading, 'Card'), isFalse);

    final String progressContent = File(
      'lib/src/pages/implementations/dictionary_progress_dialog_content.dart',
    ).readAsStringSync();
    expect(progressContent, contains('tokens.type.metadata'));
    expect(progressContent, isNot(contains('headerStyle')));

    final String popupNativeSource = File(
      'lib/src/pages/implementations/dictionary_popup_native.dart',
    ).readAsStringSync();
    final String mineButton = _functionSource(
      popupNativeSource,
      'Widget _buildMineButton(',
      '  Widget _buildDeinflection(',
    );
    expect(mineButton, contains('FushiIconButton('));
    expect(mineButton, contains('Icons.add_circle_outline'));
    expect(mineButton, contains('tokens.spacing'));
    expect(mineButton, contains('creator_export_card'));
    expect(
      containsIdentifierCall(mineButton, 'IconButton'),
      isFalse,
      reason: '制卡按钮不得用裸 IconButton（含 IconButton.filledTonal）',
    );
    expect(mineButton, isNot(contains("Text('+")));
    expect(mineButton, isNot(contains('FushiFocusable(')));

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
      expect(section, contains('FushiDesignTokens.of(context)'));
      expect(section, contains('tokens.spacing'));
      expect(section, isNot(contains('const EdgeInsets.symmetric(')));
    }
  });

  test('media search shell no longer depends on legacy floating search', () {
    for (final String path in <String>[
      'lib/src/pages/base_tab_page.dart',
      'lib/src/media/media_type.dart',
      'lib/src/media/sources/reader_fushi_source.dart',
    ]) {
      final String source = File(path).readAsStringSync();
      expect(
        source,
        isNot(contains('material_floating_search_bar')),
        reason: '$path still imports legacy floating search',
      );
      expect(
        source,
        isNot(contains('FloatingSearchBar')),
        reason: '$path still depends on legacy floating search widgets',
      );
    }
  });

  test('custom theme preview uses shared M3E card shell', () {
    final String source = File(
      'lib/src/pages/implementations/custom_theme_page.dart',
    ).readAsStringSync();
    // 锚点随 2026-10 M3E 自定义主题编辑器重设计更新：预览卡多了 compact 参数
    // （吸顶紧凑预览），后继函数是 _buildAppPreview。
    // 判据随设计更新：预览壳画的是**用户正在编辑的配色**（_scheme 的 surface /
    // outlineVariant，随编辑动画过渡），而 FushiCard 只认 app 当前主题的面色，
    // 套它就预览不出用户选的颜色——所以壳是一个 AnimatedContainer。守的不变式：
    // 不自开裸 Card；形状取共享设置套件的容器圆角 token；间距走 FushiDesignTokens。
    final String previewCard = _functionSource(
      source,
      'Widget _buildPreviewCard({bool compact = false})',
      'Widget _buildAppPreview(',
    );
    final String normalized = _withoutSharedComponentNames(previewCard);
    // 标识符左边界：函数签名 `_buildPreviewCard({` 自己就含 `Card(`，不是裸 Card。
    expect(_containsForbiddenChrome(normalized, 'Card('), isFalse);
    expect(previewCard, contains('SettingsKitRadii.container('));
    expect(previewCard, contains('tokens.spacing'));
    expect(
      RegExp(r'BorderRadius\.circular\(\d').hasMatch(previewCard),
      isFalse,
      reason: 'preview shell radius must come from SettingsKitRadii',
    );
  });

  test('custom theme page uses shared M3E spacing tokens', () {
    final String source = File(
      'lib/src/pages/implementations/custom_theme_page.dart',
    ).readAsStringSync();

    expect(source, contains('FushiDesignTokens.of(context)'));
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

  test('theme selector uses shared M3E swatches', () {
    final String source = File('lib/src/settings/settings_actions.dart')
        .readAsStringSync();
    final String themeSelector = _functionSource(
      source,
      'Widget buildThemeSelector(SettingsContext settingsContext)',
      'Widget buildBrightnessSelector(SettingsContext settingsContext)',
    );

    // 2026-10 M3E：主题是色板网格卡（种子色块 + primary/secondary/tertiary
    // 三色条 + 名称），三色条取自按当前明暗生成的真实 scheme，不是单一种子色。
    expect(themeSelector, contains('FushiThemePresetCard('));
    expect(themeSelector, contains('scheme: AppModel.buildPresetColorScheme('));
    expect(themeSelector, isNot(contains('entry.value.brightness')));
    expect(source, isNot(contains('class _ColorSwatch')));
    expect(themeSelector, isNot(contains('_ColorSwatch(')));
    expect(themeSelector, isNot(contains('Container(')));
    expect(themeSelector, isNot(contains('BoxDecoration(')));
  });

  test('custom theme import dialog uses shared M3E dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/custom_theme_page.dart',
    ).readAsStringSync();
    // 结束锚点随 BUG-2187 重设计更新：_importTheme 之后紧接的已不是
    // _buildPreviewCard 而是 build()。守的不变式没变：导入弹窗走共享
    // FushiDialogFrame + FushiModalSheetFrame，不得回退到 adaptiveAlertDialog。
    final String importDialog = _functionSource(
      source,
      'Future<void> _importTheme()',
      '  Widget build(BuildContext context)',
    );

    expect(importDialog, contains('FushiDialogFrame('));
    expect(importDialog, contains('FushiModalSheetFrame('));
    expect(importDialog, isNot(contains('adaptiveAlertDialog(')));
  });

  test('tag filter sheet uses shared M3E spacing tokens', () {
    final String source = File(
      'lib/src/pages/implementations/tag_filter_sheet.dart',
    ).readAsStringSync();

    expect(source, contains('FushiDesignTokens.of(context)'));
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

  test('app icon custom confirmation uses shared M3E dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/miscellaneous_settings_page.dart',
    ).readAsStringSync();
    final String confirmDialog = _functionSource(
      source,
      'Future<void> _pickCustomIcon()',
      '  @override',
    );

    expect(confirmDialog, contains('FushiDialogFrame('));
    expect(confirmDialog, contains('FushiModalSheetFrame('));
    expect(confirmDialog, isNot(contains('adaptiveAlertDialog(')));
  });

  test('shortcut reset confirmation uses shared M3E dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ).readAsStringSync();
    final String confirmDialog = _functionSource(
      source,
      'Future<void> _confirmResetScope(ShortcutScope scope)',
      '  Future<void> _editBinding(',
    );

    expect(confirmDialog, contains('FushiDialogFrame('));
    expect(confirmDialog, contains('FushiModalSheetFrame('));
    expect(confirmDialog, isNot(contains('adaptiveAlertDialog(')));
  });

  test('shortcut binding editor uses shared M3E dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/shortcut_settings/'
      'binding_edit_dialog.part.dart',
    ).readAsStringSync();
    final String editDialog = _sectionSource(
      source,
      'class _ShortcutBindingEditDialogState',
      source.length,
    );

    expect(editDialog, contains('FushiDialogFrame('));
    expect(editDialog, contains('FushiModalSheetFrame('));
    expect(editDialog, isNot(contains('adaptiveAlertDialog(')));
  });

  test('shortcut action rows use shared M3E list and tag chips', () {
    // _ActionTile + _MouseChip are the whole action_tile part (shortcut
    // settings refactor), so the section spans from the tile class to EOF.
    final String source = File(
      'lib/src/pages/implementations/shortcut_settings/action_tile.part.dart',
    ).readAsStringSync();
    final String tileSource = _sectionSource(
      source,
      'class _ActionTile',
      source.length,
    );

    expect(tileSource, contains('FushiListItem('));
    // 2026-10 重设计：绑定渲染成键帽胶囊（_BindingKeycap，键盘拆成单枚键帽、
    // 手柄用品牌按钮图标、鼠标 / 滚轮复用 _InputIconChip），不再是文字 tag chip。
    expect(tileSource, contains('_BindingKeycap('));
    expect(tileSource, isNot(contains('ListTile(')));
    expect(tileSource, isNot(contains('=> Chip(')));
    expect(tileSource, isNot(contains('child: Chip(')));
  });

  test('shortcut scopes render as unified settings sections', () {
    // TODO-317: each scope is now an AdaptiveSettingsSection card (shared
    // SettingsSectionHeader title via AdaptiveSettingsSection.title) projected
    // through the unified settings detail shell — the bespoke primary-coloured
    // _ScopeSectionHeader and the standalone FushiPageScaffold/ListView are
    // gone. Reset is an in-card AdaptiveSettingsRow action.
    // 2026-10 单页重设计：分组卡仍是 AdaptiveSettingsSection，分组标题改成吸顶的
    // _GroupHeader（scope.label + 计数 + 恢复默认），由浏览器 part 渲染。
    final String source = File(
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ).readAsStringSync();
    final String browser = File(
      'lib/src/pages/implementations/shortcut_settings/'
      'shortcut_browser.part.dart',
    ).readAsStringSync();
    final String scopeSections = _sectionSource(
      browser,
      'Widget _buildResults(',
      'Widget _buildRow(',
    );

    expect(scopeSections, contains('AdaptiveSettingsSection('));
    expect(scopeSections, contains('PinnedHeaderSliver('));
    expect(scopeSections, contains('_GroupHeader('));
    expect(scopeSections, contains('_buildRow('));
    expect(browser, contains('scope.label'));
    expect(browser, contains('t.shortcut_reset_defaults'));
    expect(browser, contains('_ActionTile('));
    expect(source, contains('AdaptiveSettingsRow('));
    expect(source, contains('bodyFillsViewport: true'));

    // Converged: no bespoke section-header class, no standalone scaffold/list.
    expect(source, isNot(contains('class _ScopeSectionHeader')));
    expect(source, contains('buildSettingsDetailShell('));
    expect(source, isNot(contains('const EdgeInsets.fromLTRB(16, 16, 8, 4)')));
  });

  test('shortcut binding editor uses shared M3E tag chips', () {
    final String source = File(
      'lib/src/pages/implementations/shortcut_settings/'
      'binding_edit_dialog.part.dart',
    ).readAsStringSync();
    final String editDialog = _sectionSource(
      source,
      'class _ShortcutBindingEditDialogState',
      source.length,
    );

    expect(editDialog, contains('FushiTagChip('));
    expect(editDialog, contains('onDeleted:'));
    expect(editDialog, contains('FushiOverflowMenu<GamepadButton>('));
    // 捕获块圆角：MD3 时代是 tokens.radii.controlRadius，M3E 改用形状档
    // FushiM3eShape（激活态 listActive）；两者都是共享 token，禁的是字面量。
    expect(
      editDialog.contains('tokens.radii.controlRadius') ||
          editDialog.contains('FushiM3eShape.'),
      isTrue,
      reason: 'capture block radius must come from a shared shape token',
    );
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

  test('custom font dialogs use shared M3E dialog chrome', () {
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
      expect(dialogSource, contains('FushiDialogFrame('));
      expect(dialogSource, contains('FushiModalSheetFrame('));
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

    // 自实现的 FushiReorderableColumn，**不是** SDK ReorderableListView：整棵树
    // 活在 FushiAppUiScale 的 Transform.scale 下，SDK 的 _DragItemProxy 用
    // 「全局坐标 − overlay 原点」纯平移、不认祖先缩放，「界面大小」非 100% 时
    // 拖拽浮层会漂移、缩小时一拖即飞出屏幕（BUG-778 同根因）。此前这条断言正向
    // 钉死了 `ReorderableListView.builder(`，等于把缺陷焊在原地。
    expect(pageSource, contains('FushiReorderableColumn('));
    expect(
      pageSource,
      isNot(contains('ReorderableListView.builder(')),
      reason: 'SDK Reorderable 在全局 UI 缩放下拖拽坐标漂移（BUG-778 同根因）',
    );
    // 每行仍有上/下移动按钮（onMoveUp / onMoveDown 调 _onReorder），适配焦点/
    // 手柄导航，也是拖拽之外的无障碍路径。
    expect(pageSource, contains('onMoveUp:'));
    expect(pageSource, contains('onMoveDown:'));
    expect(source, isNot(contains('ReorderableDelayedDragStartListener(')));
    expect(source, isNot(contains('ReorderableDragStartListener(')));
  });

  test('system font picker search uses shared M3E spacing tokens', () {
    // 系统字体选择页已换成独立文件里的浏览页（每款字体用自己渲染日文样张）。
    final String source = File(
      'lib/src/pages/implementations/font_preview/system_font_browser_page.dart',
    ).readAsStringSync();
    final String pickerSource = _sectionSource(
      source,
      'class _SystemFontBrowserPageState',
      source.length,
    );

    expect(pickerSource, contains('FushiDesignTokens.of(context)'));
    expect(pickerSource, contains('tokens.spacing'));
    expect(
      pickerSource,
      isNot(contains('contentPadding: const EdgeInsets.symmetric(')),
    );
  });

  test('book CSS confirmation dialog uses shared M3E dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/book_css_editor_page.dart',
    ).readAsStringSync();
    final String dialogSource = _sectionSource(
      source,
      'class BookCssConfirmationDialog<T>',
      source.length,
    );

    expect(dialogSource, contains('FushiDialogFrame('));
    expect(dialogSource, contains('FushiModalSheetFrame('));
    expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
  });

  test('book CSS editor shell uses shared M3E spacing tokens', () {
    final String source = File(
      'lib/src/pages/implementations/book_css_editor_page.dart',
    ).readAsStringSync();
    final String editorBuild = _functionSource(
      source,
      'Widget build(BuildContext context)',
      '@visibleForTesting',
    );

    expect(editorBuild, contains('FushiDesignTokens.of(context)'));
    expect(editorBuild, contains('tokens.spacing'));
    expect(editorBuild, contains('FushiSelectableChip('));
    expect(editorBuild, contains('FushiEditorPanel('));
    expect(editorBuild, isNot(contains('height: 40')));
    expect(editorBuild, isNot(contains('const EdgeInsets.only(right: 6)')));
    expect(
      editorBuild,
      isNot(
        contains('const EdgeInsets.symmetric(horizontal: 12, vertical: 6)'),
      ),
    );
    expect(editorBuild, isNot(contains('spacing: 8')));
    expect(editorBuild, isNot(contains('runSpacing: 4')));
  });

  test('collection dialogs use shared M3E dialog chrome', () {
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
      expect(dialogSource, contains('FushiDialogFrame('));
      expect(dialogSource, contains('FushiModalSheetFrame('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('collection list rows use shared M3E primitives', () {
    final String source = File(
      'lib/src/pages/implementations/collections_page.dart',
    ).readAsStringSync();
    final String itemSource = _functionSource(
      source,
      'Widget _buildItem(_CollectionItem item)',
      'class CollectionItemDialogFrame',
    );
    expect(itemSource, contains('FushiListItem('));
    expect(itemSource, contains('FushiIconButton('));
    expect(itemSource, contains('tokens.spacing'));
    expect(itemSource, contains('_hasAudio(item)'));
    expect(itemSource, contains('_playItemAudio(item)'));
    expect(itemSource, contains('onLongPress: () => _showItemDialog(item)'));
    // 三条判据都换成标识符边界匹配，_withoutSharedComponentNames 白名单在此不再需要：
    // 共享组件（FushiIconButton / FushiListTile / FushiCard）天然不匹配，
    // 未登记的 `_RepeatIconButton(` / `_EndpointCard(` 也不再假红，
    // 而 `IconButton.filledTonal(` 这类命名构造器回归反而能被抓到。
    expect(containsIdentifierCall(itemSource, 'IconButton'), isFalse);
    expect(itemSource, isNot(contains('VisualDensity.compact')));
    expect(containsIdentifierCall(itemSource, 'ListTile'), isFalse);
    expect(containsIdentifierCall(itemSource, 'Card'), isFalse);
  });

  test('media item edit dialog uses shared M3E dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/media_item_edit_dialog_page.dart',
    ).readAsStringSync();
    final String dialogSource = _sectionSource(
      source,
      'class MediaItemEditDialogFrame',
      'class MediaItemCoverOverrideField',
    );

    expect(dialogSource, contains('FushiDialogFrame('));
    expect(dialogSource, contains('FushiModalSheetFrame('));
    expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
  });

  test(
    'media item cover override uses M3E card chrome instead of fake input',
    () {
      final String source = File(
        'lib/src/pages/implementations/media_item_edit_dialog_page.dart',
      ).readAsStringSync();
      final String coverField = _sectionSource(
        source,
        'class MediaItemCoverOverrideField',
        source.length,
      );

      expect(coverField, contains('FushiCard('));
      expect(coverField, contains('FushiDesignTokens.of(context)'));
      expect(coverField, contains('tokens.spacing'));
      expect(coverField, isNot(contains('FushiTextField(')));
      expect(
        coverField,
        isNot(contains('TextStyle(color: Colors.transparent)')),
      );
      expect(coverField, isNot(contains('contentPadding: EdgeInsets.zero')));
      expect(coverField, isNot(contains('const BoxConstraints(')));
      expect(coverField, isNot(contains('Spacing.of(context)')));
    },
  );

  test('page chrome surfaces use shared M3E spacing tokens', () {
    final String homeSource = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    // 品牌位（rail 的 leading）已从 home_page 的私有方法抽成
    // [NavRailBrandButton]——它同时是官网入口，需要独立可测（点击/焦点确认真的
    // 打开官网，见 test/widgets/nav_rail_brand_button_test.dart）。MD3 判据跟着
    // 实现搬到该组件的 build 里，home_page 这边只剩「rail 确实挂了品牌位」。
    final String brandSource = File(
      'lib/src/utils/components/nav_rail_brand_button.dart',
    ).readAsStringSync();
    final String railLeading = _sectionSource(
      brandSource,
      'Widget build(BuildContext context)',
      // 品牌位的 build 是该文件最后一个成员，没有下一个可锚的符号。
      brandSource.length,
    );
    expect(homeSource, contains('leading: const NavRailBrandButton()'));
    expect(railLeading, contains('FushiDesignTokens.of(context)'));
    expect(railLeading, contains('tokens.spacing'));
    expect(railLeading, contains('tokens.radii.controlRadius'));
    expect(railLeading, contains('CurrentAppIcon'));
    expect(railLeading, isNot(contains('DecoratedBox')));
    expect(railLeading, isNot(contains('tokens.surfaces.card')));
    expect(railLeading, isNot(contains('Border.all')));

    final String collectionsSource = File(
      'lib/src/pages/implementations/collections_page.dart',
    ).readAsStringSync();
    final String collectionItem = _functionSource(
      collectionsSource,
      'Widget _buildItem(_CollectionItem item)',
      '@visibleForTesting',
    );
    expect(collectionItem, contains('FushiDesignTokens.of(context)'));
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
    expect(tagList, contains('FushiDesignTokens.of(context)'));
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
    expect(historyGrid, contains('FushiDesignTokens.of(context)'));
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
    expect(historyTile, contains('FushiDesignTokens.of(context)'));
    expect(historyTile, contains('tokens.spacing'));
    expect(
      historyTile,
      isNot(contains('const EdgeInsets.fromLTRB(2, 2, 2, 4)')),
    );

    final String illustrationsSource = File(
      'lib/src/pages/implementations/illustrations_viewer_page.dart',
    ).readAsStringSync();
    final String illustrationsBody = _sectionSource(
      illustrationsSource,
      'Widget _buildPending(BuildContext context)',
      illustrationsSource.length,
    );
    // 装载 / 出错态改由共享 FushiLoadingView / FushiPlaceholderMessage 承担
    // 间距（它们内部取 tokens.spacing），页面不再自排。
    expect(illustrationsBody, contains('FushiLoadingView'));
    expect(illustrationsBody, contains('FushiPlaceholderMessage'));
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
    expect(profileState, contains('FushiDesignTokens.of(context)'));
    expect(profileState, contains('tokens.spacing'));
    expect(
      profileState,
      isNot(contains('padding: const EdgeInsets.symmetric(vertical: 48)')),
    );
  });

  test('open stash dialogs use shared M3E dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/open_stash_dialog_page.dart',
    ).readAsStringSync();

    expect(source, contains('class OpenStashDialogFrame'));
    expect(source, contains('class OpenStashClearDialog'));
    expect(source, contains('FushiDialogFrame('));
    expect(source, contains('FushiModalSheetFrame('));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
  });

  test('home dictionary clear dialog uses shared M3E dialog chrome', () {
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
    expect(dialogSource, contains('FushiDialogFrame('));
    expect(dialogSource, contains('FushiModalSheetFrame('));
    expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
  });

  test('home dictionary list chrome uses shared M3E spacing tokens', () {
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
      expect(section, contains('FushiDesignTokens.of(context)'));
      expect(section, contains('tokens.spacing'));
    }
    expect(
      searchHeader,
      isNot(contains('isCupertinoPlatform(context) ? 8 : 16')),
    );
    expect(
      historyList,
      isNot(contains('padding: const EdgeInsets.only(top: 4, bottom: 16)')),
    );
    expect(
      historyList,
      isNot(
        contains(
          'margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2)',
        ),
      ),
    );
    expect(historyList, isNot(contains('const SizedBox(width: 4)')));
  });

  test('dictionary confirmation dialogs use shared M3E dialog chrome', () {
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
      '  /// 「清空全部词典 / 删除单本词典」共用的确认对话框流程',
    );
    // 清空/删除两个确认流程已收敛到共用 helper（原为两份逐字复制的构造样板），
    // MD3 对话框铬件断言随之锚到 helper 本体；两个入口只需保证仍委托给它。
    final String confirmHelper = _functionSource(
      source,
      'Future<void> _showDictionaryActionConfirmDialog({',
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
      expect(dialogSource, contains('_showDictionaryActionConfirmDialog('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
    expect(confirmHelper, contains('DictionaryConfirmationDialog('));
    expect(confirmHelper, isNot(contains('adaptiveAlertDialog(')));

    for (final String dialogSource in <String>[
      confirmationFrame,
      lowMemoryDialog,
    ]) {
      expect(dialogSource, contains('FushiDialogFrame('));
      expect(dialogSource, contains('FushiModalSheetFrame('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('dictionary download dialogs use shared M3E dialog chrome', () {
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
      '  static const _safChannel = FushiChannels.saf;',
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

    expect(selectionFlow, contains('DictionaryDownloadSelectionDialogFrame('));
    expect(selectionFlow, isNot(contains('adaptiveAlertDialog(')));
    expect(progressFlow, contains('DictionaryDownloadProgressDialog('));
    expect(progressFlow, isNot(contains('adaptiveAlertDialog(')));

    for (final String dialogSource in <String>[selectionFrame, progressFrame]) {
      expect(dialogSource, contains('FushiDialogFrame('));
      expect(dialogSource, contains('FushiModalSheetFrame('));
      expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    }
  });

  test('reader popup audio controls use shared M3E micro spacing tokens', () {
    final String source = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final String popupAudio = _functionSource(
      source,
      'Widget? buildPopupAudioControls()',
      '  // ── Helpers ',
    );

    expect(popupAudio, contains('FushiDesignTokens.of(context)'));
    expect(popupAudio, contains('tokens.spacing'));
    expect(
      popupAudio,
      isNot(contains('padding: const EdgeInsets.symmetric(vertical: 2)')),
    );
  });

  test('M3E review report does not reopen completed app chrome scope', () {
    final String report = File('../docs/reviews/2026-05-26-project-review.md')
        .readAsStringSync();
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

/// Constructor bans are identifier calls, not suffix text: AnimatedContainer
/// must not count as Container. Generic prefixes retain their whole-call scope.
bool _containsMigratedBan(String source, String banned) {
  if (banned.startsWith('re:')) {
    return RegExp(banned.substring(3)).hasMatch(source);
  }
  final RegExpMatch? call = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)[<(]$')
      .firstMatch(banned);
  if (call != null) {
    return containsIdentifierCall(
      maskCommentsAndStrings(source),
      call.group(1)!,
    );
  }
  return source.contains(banned);
}

String _withoutPopupScrolledUnderDecoration(String source) {
  final String code = maskCommentsAndStrings(source);
  final String owner = methodBody(code, 'class _PopupScrolledUnderBar');
  final List<RegExpMatch> decorations = identifierCall('BoxDecoration')
      .allMatches(owner)
      .toList();
  expect(
    decorations,
    hasLength(1),
    reason: 'scrolled-under owns exactly one state decoration',
  );
  final RegExpMatch decoration = decorations.single;
  final int ownerStart = code.indexOf(owner);
  return source.replaceRange(
    ownerStart + decoration.start,
    ownerStart + decoration.end,
    'PopupScrolledUnderDecoration(',
  );
}

String _withoutSharedComponentNames(String source) {
  return source
      .replaceAll('FushiCard(', 'FushiSharedPanel(')
      // 统计中心共享区块卡（stat_shared.dart，内部是 FushiCard）：名字里的
      // `Card(` 不是裸 Card。
      .replaceAll('StatSectionCard(', 'StatSharedSection(')
      .replaceAll('FushiListItem(', 'FushiSharedRow(')
      .replaceAll('FushiListTile(', 'FushiSharedTile(')
      .replaceAll('FushiIconButton(', 'FushiSharedIconControl(')
      .replaceAll('FushiSearchField(', 'FushiSharedSearch(')
      .replaceAll('FushiTextField(', 'FushiSharedField(')
      .replaceAll('AdaptiveSettingsTextField(', 'AdaptiveSettingsSharedField(')
      .replaceAll('FushiOverflowMenu(', 'FushiSharedOverflow(')
      .replaceAll('FushiTransientScaffold(', 'FushiSharedTransient(')
      .replaceAll('FushiOverlayScaffold(', 'FushiSharedOverlay(');
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

/// 全树「普通页面 chrome」扫描的 M3E 判据（2026-10-06 守卫由 MD3 改为 M3E）。
///
/// 在 [_forbiddenChromeHits] 的基础上按 M3E 设计体系收窄两类 token：
/// - **形状**：M3E 的形状档本身就是共享 token（[FushiM3eShape] / `tokens.radii` /
///   `SettingsKitRadii`），`BorderRadius.circular(<token>)` 是在用形状系统；只有
///   数字字面量 `BorderRadius.circular(12)` 才是页面本地重开的形状决策。
/// - **色调容器**：`surfaceContainerLow … Highest` 是 M3E tonal 色彩角色本身，
///   M3E 组件直接读它们是规范用法。但 Apple 设计系统不认这套色调——读它们的文件
///   必须同时处理 Apple 分支（`isGlassDesign(` / `appleColorsOf(` /
///   `FushiAppleColors`），否则 Apple 下会漏出 Material 色调，这类仍判违规。
///
/// 其余 token（`fontSize:`、`VisualDensity.compact`、裸 `Card(` / `ListTile(` …）
/// 判据不变：M3E 字阶走 `context.fushiType`，组件走共享 Fushi* 原语。
List<String> _m3eChromeHits(String source, List<String> forbidden) {
  final bool appleAware = RegExp(
    r'isGlassDesign\(|appleColorsOf\(|FushiAppleColors',
  ).hasMatch(source);
  return _forbiddenChromeHits(source, forbidden)
      .where((String token) {
        if (token == 'BorderRadius.circular(') {
          return RegExp(r'BorderRadius\.circular\(\s*[0-9.]').hasMatch(source);
        }
        if (_wholeIdentifierTokens.contains(token)) return !appleAware;
        return true;
      })
      .toList(growable: false);
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
  if (_identifierCallTokens.contains(token)) {
    // 左边界：`FushiCard(` / `CheckboxListTile(` 不是裸 `Card(` / `ListTile(`。
    // 共享组件正是本守卫要求你改用的东西，裸子串会在「改对那一刻」把它判成违规。
    return RegExp(r'(?<![A-Za-z0-9_])' + RegExp.escape(token)).hasMatch(source);
  }
  if (_wholeIdentifierTokens.contains(token)) {
    // 右边界：`surfaceContainerHigh` 不该被 `surfaceContainerHighest` 命中，
    // 否则失败报告里会列出源码里根本不存在的 token，把维护者引去找不存在的行。
    return RegExp(RegExp.escape(token) + r'(?![A-Za-z0-9_])').hasMatch(source);
  }
  return source.contains(token);
}

const Set<String> _identifierCallTokens = <String>{
  'Card(',
  'ListTile(',
  'SwitchListTile(',
  'CheckboxListTile(',
  'PopupMenuButton(',
};

/// 互为前缀的 MD3 容器面色角色：必须整标识符匹配，且四个变体都得在 forbidden
/// 列表里（右边界收窄只去掉重复命中，不放过任何一个角色）。
const Set<String> _wholeIdentifierTokens = <String>{
  'surfaceContainerLow',
  'surfaceContainerLowest',
  'surfaceContainerHigh',
  'surfaceContainerHighest',
};

String _functionSource(String source, String startToken, String endToken) {
  final int start = source.indexOf(startToken);
  final int end = source.indexOf(endToken, start + startToken.length);
  expect(start, isNonNegative, reason: 'missing $startToken');
  expect(
    end,
    greaterThan(start),
    reason: 'missing $endToken after $startToken',
  );
  return source.substring(start, end);
}

String _sectionSource(String source, String startToken, Object endToken) {
  final int start = source.lastIndexOf(startToken);
  expect(start, isNonNegative, reason: 'missing final $startToken');
  final int end = switch (endToken) {
    final int endIndex => endIndex,
    final String token => source.indexOf(token, start + startToken.length),
    _ => throw ArgumentError.value(endToken, 'endToken'),
  };
  expect(
    end,
    greaterThan(start),
    reason: 'missing $endToken after $startToken',
  );
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
  return source.substring(
    start + startToken.length + match!.start + 1,
    start + startToken.length + match.start + match.group(0)!.length,
  );
}
