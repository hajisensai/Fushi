/// 小说阅读器「阅读设置」侧板的信息架构（2026-10 侧板重设计）。
///
/// 旧面板按 [ReaderGroup] 三组（布局显示 / 阅读操作 / 查词）平铺 schema 项：
/// 每个标签页是二十多行同级的行，字号 / 行高这类每次开面板都会动的项与竖排字距、
/// 防剧透模糊这类一辈子改一次的项挤在同一列里，主题卡还压在「布局」页顶上。
///
/// 这里把同一批 schema 项按**用户要完成的任务**重新分到五个标签页、每页若干带标题
/// 的小节；常用小节展开置顶，高级小节默认折叠（[SettingsSectionPresentation.collapsed]，
/// 折叠只影响展示，偏好值与写路径都不变）。
///
/// 纯数据：只认 schema 项的 id，不改任何 schema 文件、偏好键或写路径。新加到
/// [ReaderGroup] 的项若没在下表登记，会落进它所属组默认标签页末尾的无题小节——
/// 不会凭空消失（守卫见 `reader_settings_ia_test.dart`）。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_destination.dart';

/// 设置侧板的标签页。[id] 是页面会话记忆（`ReaderChromeController.lastSettingsTab`）
/// 与测试使用的稳定标识；沿用旧三组的 id（layout / behavior / lookup），让
/// 记住的旧标签仍能对上。
enum ReaderSettingsTab {
  appearance('appearance'),
  layout('layout'),
  gestures('behavior'),
  listening('listening'),
  lookup('lookup'),
  lyrics('lyrics');

  const ReaderSettingsTab(this.id);

  final String id;

  String get label => switch (this) {
    ReaderSettingsTab.appearance => t.reader_panel_tab_appearance,
    ReaderSettingsTab.layout => t.reader_panel_tab_layout,
    ReaderSettingsTab.gestures => t.reader_panel_tab_gestures,
    ReaderSettingsTab.listening => t.section_audiobook,
    ReaderSettingsTab.lookup => t.settings_destination_lookup,
    ReaderSettingsTab.lyrics => t.lyrics_mode,
  };

  /// 按 id 找标签页；未知 id（旧版本记忆、已隐藏的页）返回 null。
  static ReaderSettingsTab? byId(String id) {
    for (final ReaderSettingsTab tab in ReaderSettingsTab.values) {
      if (tab.id == id) return tab;
    }
    return null;
  }
}

/// 某次打开时实际出现的标签页（顺序即标签栏顺序）。
///
/// * 歌词模式下「歌词模式」页置首（字号 / 颜色 / 边距 / 竖排 / 模糊都是歌词页专属
///   控件，集中在这一页），「排版」页没有对象（歌词页是独立文档，不读正文排版项），
///   隐藏；
/// * 书籍模式下「歌词模式」页排在最后，只在本书能进歌词模式（[lyricsAvailable]：
///   有声书已加载）时出现——可以提前调好歌词样式、顶部一行直接进入歌词模式；
/// * 「听书」模块关掉时「有声书」页隐藏，它的按键小节回落到「翻页与手势」页
///   （见 [buildReaderSettingsSections] 的 `listeningTab`）。
List<ReaderSettingsTab> readerSettingsTabs({
  required bool lyricsMode,
  required bool listeningEnabled,
  bool lyricsAvailable = false,
}) {
  return <ReaderSettingsTab>[
    if (lyricsMode) ReaderSettingsTab.lyrics,
    ReaderSettingsTab.appearance,
    if (!lyricsMode) ReaderSettingsTab.layout,
    ReaderSettingsTab.gestures,
    if (listeningEnabled) ReaderSettingsTab.listening,
    ReaderSettingsTab.lookup,
    if (!lyricsMode && lyricsAvailable) ReaderSettingsTab.lyrics,
  ];
}

/// 一个小节：落在哪个标签页、标题、是否默认折叠、按顺序列出的 schema 项 id。
class ReaderSettingsSectionSpec {
  const ReaderSettingsSectionSpec({
    required this.id,
    required this.tab,
    required this.title,
    required this.itemIds,
    this.collapsed = false,
    this.itemIdPrefixes = const <String>[],
  });

  /// 稳定 id（折叠状态按它记忆，`reader_panel.<id>`）。
  final String id;
  final ReaderSettingsTab tab;
  final String Function() title;
  final List<String> itemIds;

  /// 按前缀收编的一族 id（如按模块展开的 `lookup.popup_bottom_docked.<module>`）。
  final List<String> itemIdPrefixes;
  final bool collapsed;

  bool claims(String itemId) =>
      itemIds.contains(itemId) ||
      itemIdPrefixes.any((String prefix) => itemId.startsWith(prefix));

  /// 组内排序：显式 id 按表内顺序，前缀族排在显式项之后、族内保持 schema 顺序。
  int rankOf(String itemId) {
    final int index = itemIds.indexOf(itemId);
    return index >= 0 ? index : itemIds.length;
  }
}

/// 信息架构表。顺序 = 页内小节顺序。
final List<ReaderSettingsSectionSpec> kReaderSettingsSections =
    <ReaderSettingsSectionSpec>[
      // ── 主题与字体（主题卡 / 书籍样式是面板自绘，不在表里） ──
      ReaderSettingsSectionSpec(
        id: 'font',
        tab: ReaderSettingsTab.appearance,
        title: () => t.reader_panel_section_font,
        itemIds: const <String>[
          'reading_display.font_size',
          'reading_display.font_weight',
          'reading_display.furigana_mode',
        ],
      ),
      // ── 排版 ──
      ReaderSettingsSectionSpec(
        id: 'layout_common',
        tab: ReaderSettingsTab.layout,
        title: () => t.reader_panel_section_common,
        itemIds: const <String>[
          'reading_display.view_mode',
          'reading_display.writing_mode',
          'reading_display.line_height',
          'reading_display.page_columns',
        ],
      ),
      ReaderSettingsSectionSpec(
        id: 'layout_page',
        tab: ReaderSettingsTab.layout,
        title: () => t.reader_panel_section_page,
        itemIds: const <String>[
          'reading_display.spread_mode',
          'reading_display.spread_direction',
          'reading_display.margin_top',
          'reading_display.margin_bottom',
          'reading_display.margin_left',
          'reading_display.margin_right',
        ],
      ),
      ReaderSettingsSectionSpec(
        id: 'layout_vn',
        tab: ReaderSettingsTab.layout,
        title: () => t.reader_vn_settings,
        collapsed: true,
        itemIds: const <String>[
          'reading_vn.screen_mode',
          'reading_vn.reveal_speed',
          'reading_vn.sentences_per_screen',
          'reading_vn.preserve_dialogue',
          'reading_vn.click_advance',
        ],
      ),
      ReaderSettingsSectionSpec(
        id: 'layout_advanced',
        tab: ReaderSettingsTab.layout,
        title: () => t.section_advanced_typography,
        collapsed: true,
        itemIds: const <String>[
          'reading_display.text_indentation',
          'reading_display.paragraph_spacing',
          'reading_display.text_justify',
          'reading_display.vert_text_orient',
          'reading_display.vert_kerning',
          'reading_display.font_vpal',
          'reading_display.prioritize_reader_styles',
          'reading_display.blur_images',
          'reading_display.merge_image_pages',
        ],
      ),
      // ── 翻页与手势 ──
      ReaderSettingsSectionSpec(
        id: 'gestures_common',
        tab: ReaderSettingsTab.gestures,
        title: () => t.reader_panel_section_common,
        itemIds: const <String>[
          'reading_controls.volume_page_turning',
          'reading_controls.highlight_on_tap',
          'reading_controls.wheel_page_turn_interval',
          'reading_controls.swipe_page_turn_sensitivity',
          'reading_controls.keep_screen_awake',
        ],
      ),
      ReaderSettingsSectionSpec(
        id: 'gestures_chrome',
        tab: ReaderSettingsTab.gestures,
        title: () => t.settings_section_reader_chrome,
        itemIds: const <String>[
          'reading_controls.show_top_progress_bar',
          'reading_controls.tap_empty_hide_chrome',
          'reading_controls.auto_hide_chrome_duration',
          'reading_controls.hide_toolbars',
          'reading_display.reverse_reader_bottom_bar',
        ],
      ),
      ReaderSettingsSectionSpec(
        id: 'gestures_direction',
        tab: ReaderSettingsTab.gestures,
        title: () => t.section_page_turn_direction,
        collapsed: true,
        itemIds: const <String>[
          'reading_controls.invert_volume_buttons',
          'reading_controls.invert_swipe_direction',
          'reading_controls.reverse_arrow_page_turn',
        ],
      ),
      ReaderSettingsSectionSpec(
        id: 'gestures_buttons',
        tab: ReaderSettingsTab.gestures,
        title: () => t.reader_panel_section_button_layout,
        collapsed: true,
        itemIds: const <String>[
          'reading_controls.controls_editor',
          'reading_controls.reset_control_layout',
        ],
      ),
      // ── 有声书 ──
      ReaderSettingsSectionSpec(
        id: 'listening_controls',
        tab: ReaderSettingsTab.listening,
        title: () => t.reader_panel_section_listening_controls,
        itemIds: const <String>[
          'listening.volume_key_sentence_nav',
          'reading_controls.invert_audiobook_skip_direction',
          'reading_vn.merge_spoken_sentence',
        ],
      ),
      // ── 查词 ──
      ReaderSettingsSectionSpec(
        id: 'lookup_popup',
        tab: ReaderSettingsTab.lookup,
        title: () => t.settings_section_lookup_popup_window,
        itemIds: const <String>[
          'lookup.popup_max_width',
          'lookup.popup_max_height',
          'lookup.popup_size_preview',
          'lookup.dictionary_font_size',
          'lookup.popup_bottom_docked_books_only',
        ],
        itemIdPrefixes: const <String>['lookup.popup_bottom_docked.'],
      ),
      ReaderSettingsSectionSpec(
        id: 'lookup_trigger',
        tab: ReaderSettingsTab.lookup,
        title: () => t.settings_section_lookup_trigger,
        itemIds: const <String>[
          'lookup.hover_auto_lookup',
          'lookup.scan_non_japanese',
        ],
      ),
      ReaderSettingsSectionSpec(
        id: 'lookup_audio',
        tab: ReaderSettingsTab.lookup,
        title: () => t.settings_section_lookup_audio,
        itemIds: const <String>[
          'lookup.auto_read_on_lookup',
          'lookup.audio_volume',
          'lookup.pause_on_lookup',
        ],
      ),
      ReaderSettingsSectionSpec(
        id: 'lookup_dismiss',
        tab: ReaderSettingsTab.lookup,
        title: () => t.reader_panel_section_popup_dismiss,
        itemIds: const <String>[
          'reading_controls.enable_swipe_to_close',
          'reading_controls.dismiss_swipe_sensitivity',
          'reading_controls.popup_dismiss_animation',
          'reading_controls.dismiss_popup_on_scroll',
        ],
      ),
      ReaderSettingsSectionSpec(
        id: 'lookup_advanced',
        tab: ReaderSettingsTab.lookup,
        title: () => t.section_advanced_typography,
        collapsed: true,
        itemIds: const <String>[
          'lookup.popup_instant_scroll',
          'lookup.popup_instant_scroll_wheel_step',
          'lookup.popup_instant_scroll_touch_step',
          'lookup.collapse_dictionaries',
          'lookup.popup_auto_expand_dictionaries',
          'lookup.compact_glossaries',
        ],
      ),
    ];

/// 未登记项的落点：所属 [ReaderGroup] 的默认标签页。
ReaderSettingsTab readerSettingsTabForGroup(ReaderGroup group) =>
    switch (group) {
      ReaderGroup.layout => ReaderSettingsTab.layout,
      ReaderGroup.behavior => ReaderSettingsTab.gestures,
      ReaderGroup.lookup => ReaderSettingsTab.lookup,
      ReaderGroup.audiobook => ReaderSettingsTab.listening,
    };

/// 打开设置侧板时落在哪一页：记忆的页（[remembered]，旧版本的三组 id 照样认）
/// 本次存在就用它；歌词模式下记忆的页若是书籍模式才有的「排版」等，改落「歌词
/// 模式」页（歌词模式里最常调的就是它）；其余落第一页。纯函数，供测试。
ReaderSettingsTab readerSettingsInitialTab(
  List<ReaderSettingsTab> tabs, {
  required String remembered,
  required bool lyricsMode,
  String? requested,
}) {
  // 定向入口只影响本次初始选择，不覆盖普通设置入口的会话记忆。
  final ReaderSettingsTab? target =
      requested == null ? null : ReaderSettingsTab.byId(requested);
  if (target != null && tabs.contains(target)) return target;
  final ReaderSettingsTab? byId = ReaderSettingsTab.byId(remembered);
  if (byId != null && tabs.contains(byId)) return byId;
  if (lyricsMode && tabs.contains(ReaderSettingsTab.lyrics)) {
    return ReaderSettingsTab.lyrics;
  }
  return tabs.first;
}

/// 把按 [ReaderGroup] 收集好的 schema 项（`collectReaderItems`）投影成 [tab] 页的
/// 小节列表（纯函数，便于测试）。
///
/// * [listeningTab] 为 false（「有声书」页不出现）时，原属该页的小节改挂到
///   「翻页与手势」页末尾、默认折叠——按键映射这类全局偏好仍可达；
/// * 歌词模式下「排版」页不在 [readerSettingsTabs] 里，它的小节就不会被渲染
///   （歌词页不读这些排版项，旧面板在歌词模式下同样不展示它们）；「歌词模式」页
///   全是面板自绘的歌词专属控件，不收任何 schema 项；
/// * 未登记的项落在所属组默认页末尾一个无题小节里。
List<SettingsSection> buildReaderSettingsSections(
  Map<ReaderGroup, List<SettingsItem>> grouped,
  ReaderSettingsTab tab, {
  bool listeningTab = true,
}) {
  ReaderSettingsTab homeOf(ReaderSettingsTab declared) {
    if (!listeningTab && declared == ReaderSettingsTab.listening) {
      return ReaderSettingsTab.gestures;
    }
    return declared;
  }

  final List<SettingsItem> all = <SettingsItem>[
    for (final ReaderGroup group in ReaderGroup.values) ...?grouped[group],
  ];
  final Map<String, ReaderGroup> groupOf = <String, ReaderGroup>{
    for (final ReaderGroup group in ReaderGroup.values)
      for (final SettingsItem item in grouped[group] ?? const <SettingsItem>[])
        item.id: group,
  };

  final List<SettingsSection> sections = <SettingsSection>[];
  final Set<String> claimed = <String>{};
  for (final ReaderSettingsSectionSpec spec in kReaderSettingsSections) {
    final List<SettingsItem> items = <SettingsItem>[
      for (final SettingsItem item in all)
        if (spec.claims(item.id)) item,
    ];
    claimed.addAll(items.map((SettingsItem item) => item.id));
    if (homeOf(spec.tab) != tab || items.isEmpty) continue;
    // 稳定排序：显式 id 按表序，前缀族保持 schema 序。
    final List<(int, int, SettingsItem)> ranked =
        <(int, int, SettingsItem)>[
          for (final (int i, SettingsItem item) in items.indexed)
            (spec.rankOf(item.id), i, item),
        ]..sort(((int, int, SettingsItem) a, (int, int, SettingsItem) b) {
          final int byRank = a.$1.compareTo(b.$1);
          return byRank != 0 ? byRank : a.$2.compareTo(b.$2);
        });
    final bool demoted = spec.tab != homeOf(spec.tab);
    sections.add(
      SettingsSection(
        id: 'reader_panel.${spec.id}',
        title: spec.title(),
        presentation: spec.collapsed || demoted
            ? SettingsSectionPresentation.collapsed
            : SettingsSectionPresentation.alwaysExpanded,
        items: <SettingsItem>[
          for (final (int, int, SettingsItem) entry in ranked) entry.$3,
        ],
      ),
    );
  }

  final List<SettingsItem> orphans = <SettingsItem>[
    for (final SettingsItem item in all)
      if (!claimed.contains(item.id) &&
          homeOf(readerSettingsTabForGroup(groupOf[item.id]!)) == tab)
        item,
  ];
  if (orphans.isNotEmpty) {
    sections.add(
      SettingsSection(id: 'reader_panel.${tab.id}_more', items: orphans),
    );
  }
  return sections;
}
