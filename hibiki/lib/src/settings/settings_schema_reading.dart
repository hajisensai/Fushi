import 'package:flutter/material.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';

SettingsDestination buildReadingDestination() {
  bool isVertical(SettingsContext c) =>
      c.readerSource.ttuWritingMode.startsWith('vertical');
  return SettingsDestination(
    id: SettingsDestinationId.reading,
    title: t.settings_destination_reading,
    summary: t.section_layout,
    icon: Icons.auto_stories_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_typography,
        items: <SettingsItem>[
          SettingsStepperItem(
            id: 'reading_display.font_size',
            title: t.ttu_font_size,
            icon: Icons.format_size,
            min: 8,
            // 64 was a conservative UI cap, not a technical one (TODO-299):
            // `font-size: ${settings.fontSize}px` 直接喂 CSS，ruby 用相对
            // `0.45em`、column-gap/padding-bottom 也只是按字号加几像素，
            // 字号再大 WebView/分页都按渲染高度重新换行，没有上限依赖。
            // 抬到 128 给低视力/大屏用户留足空间（128px 已是任何屏上的超大字）。
            max: 128,
            step: 1,
            reader: const ReaderPlacement(
              group: ReaderGroup.appearance,
              order: 0,
            ),
            value: (SettingsContext c) => c.readerSource.ttuFontSize,
            format: (double v) => '${v.round()}',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuFontSize(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.line_height',
            title: t.ttu_line_height,
            icon: Icons.format_line_spacing,
            min: 1,
            max: 3,
            step: 0.1,
            reader: const ReaderPlacement(
              group: ReaderGroup.appearance,
              order: 1,
            ),
            value: (SettingsContext c) => c.readerSource.ttuLineHeight,
            format: (double v) => v.toStringAsFixed(2),
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuLineHeight((v * 100).roundToDouble() / 100);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.text_indentation',
            title: t.ttu_text_indentation,
            icon: Icons.format_indent_increase,
            min: 0,
            max: 10,
            step: 1,
            reader: const ReaderPlacement(
              group: ReaderGroup.appearance,
              order: 2,
            ),
            value: (SettingsContext c) => c.readerSource.ttuTextIndentation,
            format: (double v) => '${v.round()}',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuTextIndentation(v);
              notifyReaderSettingsChanged(c);
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
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 5,
            ),
            value: (SettingsContext c) => c.readerSource.ttuMarginTop,
            format: (double v) => '${v.round()}%',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuMarginTop(v);
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
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 6,
            ),
            value: (SettingsContext c) => c.readerSource.ttuMarginBottom,
            format: (double v) => '${v.round()}%',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuMarginBottom(v);
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
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 7,
            ),
            value: (SettingsContext c) => c.readerSource.ttuMarginLeft,
            format: (double v) => '${v.round()}%',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuMarginLeft(v);
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
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 8,
            ),
            value: (SettingsContext c) => c.readerSource.ttuMarginRight,
            format: (double v) => '${v.round()}%',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuMarginRight(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.page_columns',
            title: t.columns_per_page,
            icon: Icons.view_column_outlined,
            min: 0,
            max: 4,
            step: 1,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 4,
            ),
            value: (SettingsContext c) =>
                c.readerSource.ttuPageColumns.toDouble(),
            format: (double v) =>
                v.round() == 0 ? t.ttu_page_columns_auto : '${v.round()}',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuPageColumns(v.round());
              notifyReaderLayoutChanged(c);
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.section_layout,
        items: <SettingsItem>[
          SettingsSegmentedItem<String>(
            id: 'reading_display.spread_mode',
            title: t.spread_mode,
            icon: Icons.menu_book_outlined,
            controlBelow: true,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 2,
            ),
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
            selected: (SettingsContext c) => c.readerSource.ttuSpreadMode,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setTtuSpreadMode(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_display.spread_direction',
            title: t.spread_direction,
            icon: Icons.swap_horiz_outlined,
            controlBelow: true,
            visible: (SettingsContext c) =>
                c.readerSource.ttuSpreadMode != 'off',
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 3,
            ),
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'rtl',
                label: 'RTL',
                tooltip: t.spread_direction_rtl,
              ),
              SettingsSegmentOption<String>(
                value: 'ltr',
                label: 'LTR',
                tooltip: t.spread_direction_ltr,
              ),
            ],
            selected: (SettingsContext c) => c.readerSource.ttuSpreadDirection,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setTtuSpreadDirection(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_display.writing_mode',
            title: t.ttu_writing_direction,
            icon: Icons.text_rotate_vertical,
            controlBelow: true,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 1,
            ),
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'horizontal-tb',
                label: t.ttu_horizontal,
                tooltip: t.ttu_horizontal,
              ),
              SettingsSegmentOption<String>(
                value: 'vertical-rl',
                label: t.ttu_vertical,
                tooltip: t.ttu_vertical,
              ),
            ],
            selected: (SettingsContext c) => c.readerSource.ttuWritingMode,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setTtuWritingMode(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_display.view_mode',
            title: t.ttu_view_mode_label,
            icon: Icons.chrome_reader_mode_outlined,
            controlBelow: true,
            // TODO-725：翻页/滚动从「外观」迁到「布局与显示」组（用户最直指的
            // 「滚动/翻页应放进布局与显示」）。仅改展示分类/排序，onChanged 不变。
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 0,
            ),
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'paginated',
                label: t.ttu_paginated,
                tooltip: t.ttu_paginated,
              ),
              SettingsSegmentOption<String>(
                value: 'continuous',
                label: t.ttu_scroll,
                tooltip: t.ttu_scroll,
              ),
            ],
            selected: (SettingsContext c) => c.readerSource.ttuViewMode,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setTtuViewMode(v);
              notifyReaderLayoutChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_display.vert_text_orient',
            title: t.ttu_vert_text_orient,
            icon: Icons.text_rotation_none,
            controlBelow: true,
            visible: isVertical,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 10,
            ),
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'mixed',
                label: t.ttu_orient_mixed,
                tooltip: t.ttu_orient_mixed,
              ),
              SettingsSegmentOption<String>(
                value: 'upright',
                label: t.ttu_orient_upright,
                tooltip: t.ttu_orient_upright,
              ),
            ],
            selected: (SettingsContext c) =>
                c.readerSource.ttuVerticalTextOrientation,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setTtuVerticalTextOrientation(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'reading_display.furigana_mode',
            title: t.ttu_furigana_mode,
            icon: Icons.translate_outlined,
            controlBelow: true,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 9,
            ),
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'show',
                label: t.ttu_furigana_show,
                tooltip: t.ttu_furigana_show,
              ),
              SettingsSegmentOption<String>(
                value: 'hide',
                label: t.ttu_furigana_hide,
                tooltip: t.ttu_furigana_hide,
              ),
              SettingsSegmentOption<String>(
                value: 'partial',
                label: t.ttu_furigana_partial,
                tooltip: t.ttu_furigana_partial,
              ),
              SettingsSegmentOption<String>(
                value: 'toggle',
                label: t.ttu_furigana_toggle,
                tooltip: t.ttu_furigana_toggle,
              ),
            ],
            selected: (SettingsContext c) => c.readerSource.ttuFuriganaMode,
            onChanged: (SettingsContext c, String v) {
              c.readerSource.setTtuFuriganaMode(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_display.reverse_reader_bottom_bar',
            title: t.reverse_reader_bottom_bar,
            icon: Icons.swap_horiz_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 0,
            ),
            value: (SettingsContext c) => c.appModel.reverseReaderBottomBar,
            onChanged: (SettingsContext c, bool value) {
              c.appModel.toggleReverseReaderBottomBar();
              c.refresh();
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.section_advanced_typography,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'reading_display.text_justify',
            title: t.ttu_text_justify,
            icon: Icons.format_align_justify,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 11,
            ),
            value: (SettingsContext c) =>
                c.readerSource.ttuEnableTextJustification,
            onChanged: (SettingsContext c, bool value) {
              c.readerSource.setTtuEnableTextJustification(value);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_display.vert_kerning',
            title: t.ttu_vert_kerning,
            icon: Icons.space_bar,
            visible: isVertical,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 12,
            ),
            value: (SettingsContext c) =>
                c.readerSource.ttuEnableVerticalFontKerning,
            onChanged: (SettingsContext c, bool value) {
              c.readerSource.setTtuEnableVerticalFontKerning(value);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_display.font_vpal',
            title: t.ttu_font_vpal,
            icon: Icons.format_shapes,
            visible: isVertical,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 13,
            ),
            value: (SettingsContext c) => c.readerSource.ttuEnableFontVPAL,
            onChanged: (SettingsContext c, bool value) {
              c.readerSource.setTtuEnableFontVPAL(value);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_display.prioritize_reader_styles',
            title: t.ttu_reader_styles,
            icon: Icons.style_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 14,
            ),
            value: (SettingsContext c) =>
                c.readerSource.ttuPrioritizeReaderStyles,
            onChanged: (SettingsContext c, bool value) {
              c.readerSource.setTtuPrioritizeReaderStyles(value);
              notifyReaderLayoutChanged(c);
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.section_navigation,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'reading_controls.highlight_on_tap',
            title: t.highlight_on_tap,
            icon: Icons.touch_app_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 1,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.highlightOnTap,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleHighlightOnTap();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
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
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_controls.tap_empty_hide_chrome',
            title: t.tap_empty_hide_chrome,
            icon: Icons.fullscreen_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 11,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.tapEmptyToHideChrome,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleTapEmptyToHideChrome();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'reading_controls.volume_page_turning',
            title: t.volume_button_page_turning,
            icon: Icons.volume_up_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 2,
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
          SettingsSwitchItem(
            id: 'reading_controls.invert_volume_buttons',
            title: t.invert_volume_buttons,
            icon: Icons.swap_vert_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 3,
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
              order: 4,
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
              order: 5,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.reverseArrowPageTurn,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleReverseArrowPageTurn();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSliderItem(
            id: 'reading_controls.volume_page_turning_speed',
            title: t.volume_button_turning_speed,
            icon: Icons.speed_outlined,
            min: 10,
            max: 500,
            divisions: 49,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 6,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.volumePageTurningSpeed.toDouble(),
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.readerSource
                  .setVolumePageTurningSpeed(value.round());
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSliderItem(
            id: 'reading_controls.wheel_page_turn_interval',
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
              await settingsContext.readerSource
                  .setWheelPageTurnInterval(value.round());
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
              await settingsContext.readerSource
                  .setSwipePageTurnSensitivity(value);
              notifyReaderSettingsChanged(settingsContext);
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
        ],
      ),
    ],
  );
}
