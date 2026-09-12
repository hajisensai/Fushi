import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/src/reader/reader_control_layout_editor.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_listening.dart';
import 'package:fushi/utils.dart';

SettingsDestination buildReadingDestination() {
  bool isVertical(SettingsContext c) =>
      c.readerSource.readerWritingMode.startsWith('vertical');
  // 「每页列数」(pageColumns) 只在翻页(paginated)模式生效：CSS multicol 列模型只
  // 存在于 _paginatedLayoutCss，连续(continuous)滚动与 VN 模式的布局根本不含
  // column-count / 子列宽（reader_content_styles.dart 只把 columnsCss 传给
  // _paginatedLayoutCss）。故非翻页模式下把该项隐藏，避免用户改了没反应、误判「功能坏了」。
  bool isPaginated(SettingsContext c) =>
      c.readerSource.readerViewMode == 'paginated';
  bool isVisualNovel(SettingsContext c) =>
      c.readerSource.readerViewMode == 'vn';
  bool isVisualNovelSentenceMode(SettingsContext c) =>
      isVisualNovel(c) &&
      c.readerSource.readerVisualNovelScreenMode == 'sentences';
  return SettingsDestination(
    id: SettingsDestinationId.reading,
    title: t.settings_destination_reading,
    // 副标题带上「听书」：并入后本分类是听书设置的唯一入口，标题本身看不出这
    // 一点；且 summary 参与设置搜索的命中面（settings_search 的 haystack），
    // 用户搜「听书」才还能落到这里。复用原一级分类名，不新增 i18n key。
    summary: '${t.section_layout} · ${t.settings_destination_listening}',
    icon: Icons.auto_stories_outlined,
    sections: <SettingsSection>[
      // 「模式与排版方向」：阅读呈现的模式与方向选择（翻页/滚动、竖排、跨页展开、
      // 竖排取向、振假名）。原「布局与显示」组重命名并把翻页/滚动模式提到首位；纯
      // 展示重组：item id、持久化 key、ReaderPlacement 全部不变。
      SettingsSection(
        id: 'reading.section.mode',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.reading_section_mode,
        items: <SettingsItem>[
          SettingsSegmentedItem<String>(
            id: 'reading_display.view_mode',
            title: t.reader_view_mode_label,
            icon: Icons.chrome_reader_mode_outlined,
            controlBelow: true,
            // TODO-725：翻页/滚动从「外观」迁到「布局与显示」组（用户最直指的
            // 「滚动/翻页应放进布局与显示」）。仅改展示分类/排序，onChanged 不变。
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 0),
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'paginated',
                label: t.reader_paginated,
                tooltip: t.reader_paginated,
              ),
              SettingsSegmentOption<String>(
                value: 'continuous',
                label: t.reader_scroll,
                tooltip: t.reader_scroll,
              ),
              SettingsSegmentOption<String>(
                value: 'vn',
                label: t.reader_vn,
                tooltip: t.reader_vn,
              ),
            ],
            selected: (SettingsContext c) => c.readerSource.readerViewMode,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setReaderViewMode(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_display.writing_mode',
            title: t.reader_writing_direction,
            icon: Icons.text_rotate_vertical,
            controlBelow: true,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 5),
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'horizontal-tb',
                label: t.reader_horizontal,
                tooltip: t.reader_horizontal,
              ),
              SettingsSegmentOption<String>(
                value: 'vertical-rl',
                label: t.reader_vertical,
                tooltip: t.reader_vertical,
              ),
            ],
            selected: (SettingsContext c) => c.readerSource.readerWritingMode,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setReaderWritingMode(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_display.spread_mode',
            title: t.spread_mode,
            icon: Icons.menu_book_outlined,
            controlBelow: true,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 6),
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'off',
                label: t.spread_off,
                tooltip: t.spread_off,
              ),
              SettingsSegmentOption<String>(
                value: 'on',
                label: t.spread_on,
                tooltip: t.spread_on,
              ),
              SettingsSegmentOption<String>(
                value: 'auto',
                label: t.spread_auto,
                tooltip: t.spread_auto,
              ),
            ],
            selected: (SettingsContext c) => c.readerSource.readerSpreadMode,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setReaderSpreadMode(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_display.spread_direction',
            title: t.spread_direction,
            icon: Icons.swap_horiz_outlined,
            controlBelow: true,
            visible: (SettingsContext c) =>
                c.readerSource.readerSpreadMode != 'off',
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 7),
            // label 用本地化全称（从右到左/从左到右），不再用只有排版从业者
            // 认识的 RTL/LTR 缩写；分段条过宽时 _SegmentedStripHost 自带横向
            // 滚动兜底。
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'rtl',
                label: t.spread_direction_rtl,
                tooltip: t.spread_direction_rtl,
              ),
              SettingsSegmentOption<String>(
                value: 'ltr',
                label: t.spread_direction_ltr,
                tooltip: t.spread_direction_ltr,
              ),
            ],
            selected: (SettingsContext c) =>
                c.readerSource.readerSpreadDirection,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setReaderSpreadDirection(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_display.vert_text_orient',
            title: t.reader_vert_text_orient,
            icon: Icons.text_rotation_none,
            controlBelow: true,
            visible: isVertical,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 14),
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'mixed',
                label: t.reader_orient_mixed,
                tooltip: t.reader_orient_mixed,
              ),
              SettingsSegmentOption<String>(
                value: 'upright',
                label: t.reader_orient_upright,
                tooltip: t.reader_orient_upright,
              ),
            ],
            selected: (SettingsContext c) =>
                c.readerSource.readerVerticalTextOrientation,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setReaderVerticalTextOrientation(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_display.furigana_mode',
            title: t.reader_furigana_mode,
            icon: Icons.translate_outlined,
            controlBelow: true,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 13),
            // 四态：Off / Toggle / Hidden（对齐 Hoshi Reader iOS）+ Dimmed
            // （2026-09-12 用户追加的「显示但淡」）。
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'off',
                label: t.reader_furigana_off,
                tooltip: t.reader_furigana_off,
              ),
              SettingsSegmentOption<String>(
                value: 'toggle',
                label: t.reader_furigana_toggle,
                tooltip: t.reader_furigana_toggle,
              ),
              SettingsSegmentOption<String>(
                value: 'hidden',
                label: t.reader_furigana_hidden,
                tooltip: t.reader_furigana_hidden,
              ),
              SettingsSegmentOption<String>(
                value: 'dimmed',
                label: t.reader_furigana_dimmed,
                tooltip: t.reader_furigana_dimmed,
              ),
            ],
            selected: (SettingsContext c) => c.readerSource.readerFuriganaMode,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setReaderFuriganaMode(v);
              notifyReaderSettingsChanged(c);
            },
          ),
        ],
      ),
      SettingsSection(
        // #1351 新增的 VN 设置组；本轮重构要求每个 ordinary section 都有持久化 id
        // （守卫 settings_schema_information_architecture），按同文件命名补上。
        id: 'reading.section.visual_novel',
        title: t.reader_vn_settings,
        visible: isVisualNovel,
        items: <SettingsItem>[
          SettingsSliderItem(
            id: 'reading_vn.reveal_speed',
            title: t.reader_vn_reveal_speed,
            icon: Icons.animation_outlined,
            min: 0,
            max: 120,
            divisions: 24,
            step: 5,
            titleReadout: true,
            commitOnRelease: true,
            visible: isVisualNovel,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 22,
            ),
            value: (SettingsContext c) =>
                c.readerSource.readerVisualNovelRevealSpeed.toDouble(),
            label: (double v) =>
                v.round() == 0 ? t.reader_vn_reveal_instant : '${v.round()}/s',
            onChanged: (SettingsContext c, double v) async {
              await c.readerSource.setReaderVisualNovelRevealSpeed(v.round());
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_vn.screen_mode',
            title: t.reader_vn_screen_mode,
            icon: Icons.view_agenda_outlined,
            controlBelow: true,
            visible: isVisualNovel,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 23,
            ),
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'block',
                label: t.reader_vn_screen_block,
                tooltip: t.reader_vn_screen_block,
              ),
              SettingsSegmentOption<String>(
                value: 'sentences',
                label: t.reader_vn_screen_sentences,
                tooltip: t.reader_vn_screen_sentences,
              ),
            ],
            selected: (SettingsContext c) =>
                c.readerSource.readerVisualNovelScreenMode,
            onChanged: (SettingsContext c, String v) async {
              await c.readerSource.setReaderVisualNovelScreenMode(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_vn.sentences_per_screen',
            title: t.reader_vn_sentences_per_screen,
            icon: Icons.format_list_numbered,
            visible: isVisualNovelSentenceMode,
            min: 1,
            max: 12,
            step: 1,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 24,
            ),
            value: (SettingsContext c) =>
                c.readerSource.readerVisualNovelSentencesPerScreen.toDouble(),
            format: (double v) => '${v.round()}',
            onChanged: (SettingsContext c, double v) async {
              await c.readerSource
                  .setReaderVisualNovelSentencesPerScreen(v.round());
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_vn.preserve_dialogue',
            title: t.reader_vn_preserve_dialogue,
            icon: Icons.format_quote,
            visible: isVisualNovelSentenceMode,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 25,
            ),
            value: (SettingsContext c) =>
                c.readerSource.readerVisualNovelPreserveDialogue,
            onChanged: (SettingsContext c, bool v) async {
              await c.readerSource.setReaderVisualNovelPreserveDialogue(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_vn.click_advance',
            title: t.reader_vn_click_advance,
            icon: Icons.touch_app_outlined,
            visible: isVisualNovel,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 20,
            ),
            value: (SettingsContext c) =>
                c.readerSource.readerVisualNovelClickAdvance,
            onChanged: (SettingsContext c, bool v) async {
              await c.readerSource.setReaderVisualNovelClickAdvance(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_vn.merge_spoken_sentence',
            title: t.reader_vn_merge_spoken_sentence,
            icon: Icons.graphic_eq_outlined,
            visible: isVisualNovel,
            reader: const ReaderPlacement(
              group: ReaderGroup.audiobook,
              order: 0,
            ),
            value: (SettingsContext c) =>
                c.readerSource.readerVisualNovelMergeSpokenSentence,
            onChanged: (SettingsContext c, bool v) async {
              await c.readerSource.setReaderVisualNovelMergeSpokenSentence(v);
              notifyReaderLayoutChanged(c);
            },
          ),
        ],
      ),
      SettingsSection(
        id: 'reading.section.typography',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.section_typography,
        items: <SettingsItem>[
          SettingsStepperItem(
            id: 'reading_display.font_size',
            title: t.reader_font_size,
            icon: Icons.format_size,
            min: 8,
            // 64 was a conservative UI cap, not a technical one (TODO-299):
            // `font-size: ${settings.fontSize}px` 直接喂 CSS，ruby 用相对
            // `0.45em`、column-gap/padding-bottom 也只是按字号加几像素，
            // 字号再大 WebView/分页都按渲染高度重新换行，没有上限依赖。
            // 抬到 128 给低视力/大屏用户留足空间（128px 已是任何屏上的超大字）。
            max: 128,
            step: 1,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 1),
            value: (SettingsContext c) => c.readerSource.readerFontSize,
            format: (double v) => '${v.round()}',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setReaderFontSize(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          // 正文字重。纯 CSS 键（只改 body 的 `font-weight`，不动几何），故走
          // notifyReaderSettingsChanged 的活样式热替换，不需要重排章节。
          // 400 = CSS `normal` 是默认值，落到生成器是「不发声明」= 书自带样式原样。
          SettingsStepperItem(
            id: 'reading_display.font_weight',
            title: t.reader_font_weight,
            icon: Icons.format_bold,
            min: 100,
            max: 900,
            step: 100,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 2),
            value: (SettingsContext c) => c.readerSource.readerFontWeight,
            format: (double v) => '${v.round()}',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setReaderFontWeight(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.line_height',
            title: t.reader_line_height,
            icon: Icons.format_line_spacing,
            min: 1,
            max: 3,
            step: 0.1,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 3),
            value: (SettingsContext c) => c.readerSource.readerLineHeight,
            format: (double v) => v.toStringAsFixed(2),
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setReaderLineHeight(
                (v * 100).roundToDouble() / 100,
              );
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.text_indentation',
            title: t.reader_text_indentation,
            icon: Icons.format_indent_increase,
            min: 0,
            max: 10,
            step: 1,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 4),
            value: (SettingsContext c) => c.readerSource.readerTextIndentation,
            format: (double v) => '${v.round()}',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setReaderTextIndentation(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          // TODO-861①（移植 Hoshi `ebf5423`）：段落间距（em）。纯 CSS，走 live
          // re-inject（notifyReaderSettingsChanged）。范围 0..3 step 0.1，对齐 iOS。
          SettingsStepperItem(
            id: 'reading_display.paragraph_spacing',
            title: t.reader_paragraph_spacing,
            icon: Icons.format_line_spacing,
            min: 0,
            max: 3,
            step: 0.1,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 19),
            value: (SettingsContext c) => c.readerSource.readerParagraphSpacing,
            format: (double v) => '${v.toStringAsFixed(1)}em',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setReaderParagraphSpacing(
                (v * 10).roundToDouble() / 10,
              );
              notifyReaderSettingsChanged(c);
            },
          ),
          // 「每页列数」移到边距之前（先定列、再定边距）：仅翻页模式生效（isPaginated
          // 门控）。id / 持久化 key / ReaderPlacement 不变，只调组内相对位置。
          SettingsStepperItem(
            id: 'reading_display.page_columns',
            title: t.columns_per_page,
            icon: Icons.view_column_outlined,
            visible: isPaginated,
            min: 0,
            max: 4,
            step: 1,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 8),
            value: (SettingsContext c) =>
                c.readerSource.readerPageColumns.toDouble(),
            format: (double v) =>
                v.round() == 0 ? t.reader_page_columns_auto : '${v.round()}',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setReaderPageColumns(v.round());
              notifyReaderLayoutChanged(c);
            },
          ),
          // TODO-362（PR#3 响应式页边距）：四个边距都是百分比（左右 = vw / 上下 = vh），
          // 默认左右各 2%、上下 0%。范围 0~50%，禁止负值（负值与百分比语义冲突，且
          // CSS padding 不接受负值）。格式带 `%` 提示用户这是百分比。
          SettingsStepperItem(
            id: 'reading_display.margin_top',
            title: t.margin_top,
            icon: Icons.border_top,
            min: 0,
            max: 50,
            step: 1,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 9),
            value: (SettingsContext c) => c.readerSource.readerMarginTop,
            format: (double v) => '${v.round()}%',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setReaderMarginTop(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.margin_bottom',
            title: t.margin_bottom,
            icon: Icons.border_bottom,
            min: 0,
            max: 50,
            step: 1,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 10),
            value: (SettingsContext c) => c.readerSource.readerMarginBottom,
            format: (double v) => '${v.round()}%',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setReaderMarginBottom(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.margin_left',
            title: t.margin_left,
            icon: Icons.border_left,
            min: 0,
            max: 50,
            step: 1,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 11),
            value: (SettingsContext c) => c.readerSource.readerMarginLeft,
            format: (double v) => '${v.round()}%',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setReaderMarginLeft(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.margin_right',
            title: t.margin_right,
            icon: Icons.border_right,
            min: 0,
            max: 50,
            step: 1,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 12),
            value: (SettingsContext c) => c.readerSource.readerMarginRight,
            format: (double v) => '${v.round()}%',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setReaderMarginRight(v);
              notifyReaderSettingsChanged(c);
            },
          ),
        ],
      ),
      SettingsSection(
        id: 'reading.section.page_turn_input',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_section_page_turn_input,
        collapsedByDefault: true,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'reading_controls.highlight_on_tap',
            title: t.highlight_on_tap,
            icon: Icons.touch_app_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 0,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.highlightOnTap,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleHighlightOnTap();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_controls.volume_page_turning',
            title: t.volume_button_page_turning,
            // VolumeKeyChannel 仅 Android 实现，桌面隐藏此项（TODO-1155）。
            visible: (_) => Platform.isAndroid,
            icon: Icons.volume_up_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 1,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.volumePageTurningEnabled,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleVolumePageTurningEnabled();
              VolumeKeyChannel.instance.setInterceptEnabled(
                settingsContext.readerSource.volumePageTurningEnabled,
              );
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSliderItem(
            id: 'reading_controls.wheel_page_turn_interval',
            titleReadout: true,
            title: t.wheel_page_turn_interval,
            icon: Icons.mouse_outlined,
            min: 150,
            max: 1000,
            divisions: 17,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 8,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.wheelPageTurnInterval.toDouble(),
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.readerSource.setWheelPageTurnInterval(
                value.round(),
              );
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSliderItem(
            id: 'reading_controls.swipe_page_turn_sensitivity',
            title: t.swipe_page_turn_sensitivity,
            icon: Icons.swipe_outlined,
            min: 0.3,
            max: 2.0,
            divisions: 17,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 9,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.swipePageTurnSensitivity,
            label: (double value) => value.toStringAsFixed(1),
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.readerSource.setSwipePageTurnSensitivity(
                value,
              );
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
        ],
      ),
      // TODO-745 / TODO-830：「翻页方向」分组只收**真正反转翻页/句子方向**的
      // 开关（音量键 / 滑动 / 键盘方向键 + 反转底栏前进后退按钮）。原 TODO-745 误把
      // 「反转阅读器底栏」（纯左右镜像底栏控件位置、与翻页方向无关）塞进来，
      // 现移到上方「阅读界面」分组（id/持久化 key 不变，仅换 UI 分组）。
      // 纯展示重组：各开关的 id/title/value/onChanged 与持久化 key、默认值、
      // 消费点全不变；面板分组（ReaderGroup.behavior）也不动。
      SettingsSection(
        id: 'reading.section.page_turn_direction',
        presentation: SettingsSectionPresentation.collapsed,
        title: t.section_page_turn_direction,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'reading_controls.invert_volume_buttons',
            title: t.invert_volume_buttons,
            icon: Icons.swap_vert_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 2,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.volumePageTurningInverted,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleVolumePageTurningInverted();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_controls.invert_swipe_direction',
            title: t.invert_swipe_direction,
            icon: Icons.swipe_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 3,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.invertSwipeDirection,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleInvertSwipeDirection();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          // TODO-120: 反转键盘方向键翻页方向（仅键盘方向键，与滑动反转独立）。
          SettingsSwitchItem(
            id: 'reading_controls.reverse_arrow_page_turn',
            title: t.reverse_arrow_page_turn,
            icon: Icons.swap_horiz_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 4,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.reverseArrowPageTurn,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleReverseArrowPageTurn();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          // TODO-830: 反转有声书底栏 ⏮⏭ 前进/后退按钮的功能方向（per-reader）。
          SettingsSwitchItem(
            id: 'reading_controls.invert_audiobook_skip_direction',
            title: t.invert_audiobook_skip_direction,
            icon: Icons.swap_horizontal_circle_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 5,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.invertAudiobookSkipDirection,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleInvertAudiobookSkipDirection();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
        ],
      ),
      // 原「导航」13 项混杂平铺，拆两组：阅读界面（进度条/悬浮 chrome/底栏提示/
      // 常亮 + 从「底栏布局」并入的「反转阅读器底栏」）与翻页与交互（点击高亮/音量
      // 翻页/滚轮/滑动灵敏度）。纯展示重组：item id、持久化 key、ReaderPlacement
      // 全部不变（快捷面板分组不动）。
      SettingsSection(
        id: 'reading.section.chrome',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_section_reader_chrome,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'reading_controls.show_top_progress_bar',
            title: t.show_top_progress_bar,
            icon: Icons.data_usage_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 12,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.showTopProgressBar,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleShowTopProgressBar();
              // TODO-975 需求 A：开/关顶部进度改变了喂 WebView 的预留高（关进度回收
              // 18px），走重锚通道保住连续模式滚动位置。
              notifyReaderChromeReanchored(settingsContext);
            },
          ),
          // TODO-975 决策#2：顶部进度悬浮开关（点击唤出 + 自动收起 + 不占正文位置）。
          // 仅当进度本身开启时显示。切换改变预留高 → 走重锚通道。
          // TODO-1029：「悬浮控制栏」开关（原「点击空白处隐藏控制栏」）紧挨「悬浮阅读
          // 进度」分到一起——两个悬浮类开关相邻。持久化 key（tap_empty_hide_chrome）、
          // 运行时行为（TODO-975 决策#3：同时把底栏切到悬浮模式）不变，仅改显示名 +
          // 面板/设置页位置（order 11→18，紧随 top_progress_floating=17）。
          SettingsSwitchItem(
            id: 'reading_controls.tap_empty_hide_chrome',
            title: t.tap_empty_hide_chrome,
            icon: Icons.fullscreen_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 18,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.tapEmptyToHideChrome,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleTapEmptyToHideChrome();
              // TODO-975 决策#3：此开关现同时把底栏切到悬浮模式，改变底栏预留高 →
              // 走重锚通道（连续模式滚动保位）。
              notifyReaderChromeReanchored(settingsContext);
            },
          ),
          // TODO-975 决策#1：悬浮 chrome 唤出后自动收起的时长（秒，顶部/底栏共用）。
          // 仅当存在任一悬浮 chrome（顶部进度悬浮 或 点空白隐藏=底栏悬浮）时显示。
          // 纯时长不改预留高 → 走 settings 刷新即可，无需重锚。
          SettingsSliderItem(
            id: 'reading_controls.auto_hide_chrome_duration',
            titleReadout: true,
            title: t.reader_auto_hide_chrome_duration,
            icon: Icons.timer_outlined,
            min: 1,
            max: 10,
            divisions: 9,
            visible: (SettingsContext c) => c.readerSource.tapEmptyToHideChrome,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 19,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.autoHideChromeMillis / 1000.0,
            label: (double value) => '${value.round()}s',
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.readerSource.setAutoHideChromeMillis(
                (value * 1000).round(),
              );
              notifyReaderChromeChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_controls.keep_screen_awake',
            title: t.keep_screen_awake,
            icon: Icons.lightbulb_outline,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 7,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.keepScreenAwake,
            onChanged: setKeepScreenAwake,
          ),
          // TODO-830：「反转阅读器底栏」（纯位置镜像，仅左右调换底栏控件位置，左右手
          // 布局偏好，与翻页方向无关）。原独占一个「底栏布局」单项分组（欠填充结构），
          // 并入「阅读界面」尾部。id/持久化 key/ReaderPlacement 全不变，仅换 UI 分组。
          SettingsSwitchItem(
            id: 'reading_display.reverse_reader_bottom_bar',
            title: t.reverse_reader_bottom_bar,
            icon: Icons.swap_horiz_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              // order 13：behavior 组内已用 0-9/11/12（10 在 listening），取末位
              // 空号，避免与 volume_page_turning_speed(6)/keep_screen_awake(7) 撞号。
              order: 13,
            ),
            value: (SettingsContext c) => c.appModel.reverseReaderBottomBar,
            onChanged: (SettingsContext c, bool value) {
              c.appModel.toggleReverseReaderBottomBar();
              notifyReaderChromeChanged(c);
            },
          ),
          // 阅读器顶栏 / 底栏按钮拖拽编辑器（与视频页 video.player.controls_editor
          // 同一套泛型编辑器，用户 2026-09-13 要求「和视频一样支持可视化调整」）。
          // 写 appModel.setReaderControlLayout → prefsRepo 通知 → 阅读器页重建，
          // 开着的书立即换布局，不需要重锚（按钮增删不改预留高）。
          SettingsCustomItem(
            id: 'reading_controls.controls_editor',
            searchTitle: t.reader_control_editor_title,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 14,
            ),
            builder: buildReaderControlLayoutEditor,
          ),
          SettingsActionItem(
            id: 'reading_controls.reset_control_layout',
            title: t.reader_control_reset_layout,
            icon: Icons.restart_alt_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 15,
            ),
            onTap: (SettingsContext c) async {
              await c.appModel.setReaderControlLayout(
                ReaderControlLayout.defaults,
              );
              c.refresh();
            },
          ),
        ],
      ),
      // v92 统计域：阅读空闲门。只对阅读面生效（视频以播放态为准，用户拍板）；
      // 下次打开书生效（时钟在建书时读一次）。
      SettingsSection(
        id: 'reading.section.statistics',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_section_reading_stats,
        items: <SettingsItem>[
          SettingsStepperItem(
            id: 'reading.stats_idle_timeout_minutes',
            title: t.reading_stats_idle_timeout,
            subtitle: t.reading_stats_idle_timeout_hint,
            icon: Icons.timer_off_outlined,
            min: PreferencesRepository.readingIdleTimeoutMinutesMin.toDouble(),
            max: PreferencesRepository.readingIdleTimeoutMinutesMax.toDouble(),
            step: 1,
            value: (SettingsContext c) =>
                c.appModel.readingIdleTimeoutMinutes.toDouble(),
            format: (double value) => '${value.round()} min',
            onChanged: (SettingsContext c, double value) async {
              await c.appModel.setReadingIdleTimeoutMinutes(value.round());
              c.refresh();
            },
          ),
          // 「今日」重置时刻（整点）：写入时前移 dateKey，历史段不重分桶。
          SettingsStepperItem(
            id: 'reading.stats_day_reset_hour',
            title: t.reading_stats_day_reset_hour,
            subtitle: t.reading_stats_day_reset_hour_hint,
            icon: Icons.update_outlined,
            min: PreferencesRepository.statDayResetHourMin.toDouble(),
            max: PreferencesRepository.statDayResetHourMax.toDouble(),
            step: 1,
            value: (SettingsContext c) =>
                c.appModel.statDayResetHour.toDouble(),
            format: (double value) =>
                '${value.round().toString().padLeft(2, '0')}:00',
            onChanged: (SettingsContext c, double value) async {
              await c.appModel.setStatDayResetHour(value.round());
              c.refresh();
            },
          ),
        ],
      ),
      // 「高级选项」现移到最后（低频排版微调）：文字两端对齐、竖排字距/VPAL、
      // 优先阅读器样式、图片防剧透模糊、合并插图页。collapsedByDefault 与各项
      // id/持久化 key/ReaderPlacement 全不变，仅调 section 相对位置。
      SettingsSection(
        id: 'reading.section.advanced_typography',
        presentation: SettingsSectionPresentation.collapsed,
        title: t.section_advanced_typography,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'reading_display.text_justify',
            title: t.reader_text_justify,
            icon: Icons.format_align_justify,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 15),
            value: (SettingsContext c) =>
                c.readerSource.readerEnableTextJustification,
            onChanged: (SettingsContext c, bool value) {
              c.readerSource.setReaderEnableTextJustification(value);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_display.vert_kerning',
            title: t.reader_vert_kerning,
            icon: Icons.space_bar,
            visible: isVertical,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 16),
            value: (SettingsContext c) =>
                c.readerSource.readerEnableVerticalFontKerning,
            onChanged: (SettingsContext c, bool value) {
              c.readerSource.setReaderEnableVerticalFontKerning(value);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_display.font_vpal',
            title: t.reader_font_vpal,
            icon: Icons.format_shapes,
            visible: isVertical,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 17),
            value: (SettingsContext c) => c.readerSource.readerEnableFontVPAL,
            onChanged: (SettingsContext c, bool value) {
              c.readerSource.setReaderEnableFontVPAL(value);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_display.prioritize_reader_styles',
            title: t.reader_reader_styles,
            icon: Icons.style_outlined,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 18),
            value: (SettingsContext c) =>
                c.readerSource.readerPrioritizeReaderStyles,
            onChanged: (SettingsContext c, bool value) {
              c.readerSource.setReaderPrioritizeReaderStyles(value);
              notifyReaderLayoutChanged(c);
            },
          ),
          // TODO-861④（移植 Hoshi `f286108`）：图片防剧透模糊。加 `blurred` 类需重跑
          // 分页脚本（非纯 CSS），故走结构 reload（notifyReaderLayoutChanged）。
          SettingsSwitchItem(
            id: 'reading_display.blur_images',
            title: t.reader_blur_images,
            icon: Icons.blur_on_outlined,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 20),
            value: (SettingsContext c) => c.readerSource.readerBlurImages,
            onChanged: (SettingsContext c, bool value) {
              c.readerSource.setReaderBlurImages(value);
              notifyReaderLayoutChanged(c);
            },
          ),
          // TODO-1128（受限方案 A）：把 0 字符单图 spine 章并入相邻正文章连续显示，
          // 不再各占一页/一条目录。结构性布局键（改虚拟页映射 + 注入章 DOM），故走
          // notifyReaderLayoutChanged（重建 spread map + 重排）。**默认开**
          // （ReaderSettings.mergeImagePages 的 `_get` 真值就是 true）——旧注释写
          // 「默认关」已过期。
          SettingsSwitchItem(
            id: 'reading_display.merge_image_pages',
            title: t.reader_merge_image_pages,
            subtitle: t.reader_merge_image_pages_subtitle,
            icon: Icons.collections_bookmark_outlined,
            reader: const ReaderPlacement(group: ReaderGroup.layout, order: 21),
            value: (SettingsContext c) => c.readerSource.readerMergeImagePages,
            onChanged: (SettingsContext c, bool value) {
              c.readerSource.setReaderMergeImagePages(value);
              notifyReaderLayoutChanged(c);
            },
          ),
        ],
      ),
      // 听书（有声书 + 悬浮歌词）2026-08-24 并入本分类，见 buildListeningSections
      // 的合并说明。放在阅读各组之后：同一本 EPUB 的「读」与「听」从此在一个分类里。
      // 这两个分区自带听书模块门，关掉模块时它们不渲染、也不进搜索索引。
      ...buildListeningSections(),
    ],
  );
}

/// 阅读器按钮布局编辑器（设置页 / 书内设置抽屉共用）：读 appModel 当前布局，改动
/// 立刻写穿偏好；桌面按鼠标手感、其余按触屏。
Widget buildReaderControlLayoutEditor(SettingsContext context) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          t.reader_control_editor_hint,
          style: Theme.of(context.context).textTheme.bodySmall,
        ),
      ),
      ReaderControlLayoutEditor(
        layout: context.appModel.readerControlLayout,
        onLayoutChanged: (ReaderControlLayout layout) async {
          await context.appModel.setReaderControlLayout(layout);
          context.refresh();
        },
        isTouchControls: !isDesktopPlatform,
      ),
    ],
  );
}
