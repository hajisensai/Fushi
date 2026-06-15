import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';
import 'package:hibiki/src/sync/texthooker_ws_client_host.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/utils.dart';
import 'package:url_launcher/url_launcher.dart';

List<SettingsDestination> buildSettingsSchema(SettingsContext context) {
  return <SettingsDestination>[
    _appearanceDestination(),
    _profilesDestination(),
    _readingDestination(),
    _lookupDestination(),
    _cardCreationDestination(),
    _videoDestination(),
    _listeningDestination(),
    buildSyncBackupDestination(),
    _systemDestination(),
  ];
}

/// 遍历完整 schema，收集所有带 [ReaderPlacement] 的 item，按 group + order 升序分组。
Map<ReaderGroup, List<SettingsItem>> collectReaderItems(
  SettingsContext context,
) {
  final Map<ReaderGroup, List<SettingsItem>> grouped =
      <ReaderGroup, List<SettingsItem>>{};
  for (final SettingsDestination destination in buildSettingsSchema(context)) {
    for (final SettingsSection section in destination.sections) {
      for (final SettingsItem item in section.items) {
        final ReaderPlacement? placement = item.reader;
        if (placement == null) continue;
        grouped.putIfAbsent(placement.group, () => <SettingsItem>[]).add(item);
      }
    }
  }
  for (final List<SettingsItem> items in grouped.values) {
    items.sort((SettingsItem a, SettingsItem b) =>
        a.reader!.order.compareTo(b.reader!.order));
  }
  return grouped;
}

/// 把某个 [ReaderGroup] 的 item 包装成一个可被 SettingsRenderer 渲染的 destination。
SettingsDestination buildReaderGroupDestination(
  SettingsContext context,
  ReaderGroup group,
  String title,
) {
  final List<SettingsItem> items =
      collectReaderItems(context)[group] ?? <SettingsItem>[];
  return SettingsDestination(
    id: SettingsDestinationId.readerQuickSettings,
    title: title,
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[SettingsSection(items: items)],
  );
}

SettingsDestination buildReaderQuickSettingsDestination(
  SettingsContext context,
) {
  final Map<ReaderGroup, List<SettingsItem>> grouped =
      collectReaderItems(context);
  SettingsSection sectionFor(ReaderGroup group, String title) {
    return SettingsSection(
      title: title,
      items: grouped[group] ?? <SettingsItem>[],
    );
  }

  return SettingsDestination(
    id: SettingsDestinationId.readerQuickSettings,
    title: t.reader_settings_section,
    summary: t.source_description_epub,
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[
      sectionFor(ReaderGroup.appearance, t.settings_destination_appearance),
      sectionFor(ReaderGroup.layout, t.section_layout),
      sectionFor(ReaderGroup.behavior, t.settings_destination_reading_controls),
      sectionFor(ReaderGroup.lookup, t.settings_destination_lookup),
      sectionFor(ReaderGroup.audiobook, t.section_audiobook),
    ].where((SettingsSection s) => s.items.isNotEmpty).toList(growable: false),
  );
}

SettingsDestination _appearanceDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: t.settings_destination_appearance,
    summary: t.design_system_hint,
    icon: Icons.palette_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_interface,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'appearance.design_system',
            icon: Icons.devices_outlined,
            builder: buildDesignSystemSelector,
          ),
          SettingsCustomItem(
            id: 'appearance.theme',
            icon: Icons.color_lens_outlined,
            builder: buildThemeSelector,
          ),
          SettingsCustomItem(
            id: 'appearance.brightness',
            icon: Icons.contrast_outlined,
            builder: buildBrightnessSelector,
          ),
          // 「界面大小」滑条用自定义有状态行：拖动中只更新局部值跟手，松手才提交
          // 真实缩放（见 buildAppUiScaleSelector）。这样拖动期间不触发全局
          // HibikiAppUiScale 的 Transform 重排，滑条不会在手指下被缩放位移、可连续拖。
          SettingsCustomItem(
            id: 'appearance.app_ui_scale',
            icon: Icons.format_size_outlined,
            builder: buildAppUiScaleSelector,
          ),
        ],
      ),
      SettingsSection(
        title: t.section_typography,
        items: <SettingsItem>[
          // TODO-231: one visible font library; each row manages app UI /
          // body / dictionary target membership via font_catalog/font_targets.
          SettingsNavigationItem(
            id: 'appearance.font_catalog',
            title: t.custom_fonts_catalog_title,
            icon: Icons.font_download_outlined,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const CustomFontsPage(),
              );
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_section_app_shell,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.app_icon',
            title: t.app_icon_label,
            icon: Icons.widgets_outlined,
            visible: (_) => Platform.isAndroid,
            builder: (_) => const MiscellaneousSettingsPage(),
          ),
          SettingsSwitchItem(
            id: 'appearance.reverse_navigation_bar',
            title: t.reverse_navigation_bar,
            icon: Icons.swap_horiz_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.reverseNavigationBar,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleReverseNavigationBar();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'appearance.startup_default_dictionary_tab',
            title: t.startup_default_dictionary_tab,
            subtitle: t.startup_default_dictionary_tab_hint,
            icon: Icons.manage_search_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.startupDefaultDictionaryTab,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setStartupDefaultDictionaryTab(value);
              settingsContext.refresh();
            },
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _profilesDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.profiles,
    title: t.settings_destination_profiles,
    summary: t.profile_management,
    icon: Icons.manage_accounts_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.profile_label,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'profiles.current',
            icon: Icons.person_outline,
            builder: buildProfilePickerRow,
          ),
        ],
      ),
    ],
    // 平铺：原本「配置管理」是一层独立路由子页，现在把其正文直接接在「配置」快速
    // 选择器下方，点一次设置就能管理 Profile，不再多跳一层。
    body: (_) => const ProfileManagementBody(),
  );
}

SettingsDestination _readingDestination() {
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
              order: 0,
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
              order: 1,
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
              order: 2,
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
              order: 3,
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
              order: 5,
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
              order: 6,
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
              order: 7,
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
            reader: const ReaderPlacement(
              group: ReaderGroup.appearance,
              order: 3,
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
              order: 8,
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
              order: 10,
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
              order: 11,
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
              order: 12,
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
              order: 13,
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
            id: 'reading_controls.tap_empty_hide_chrome',
            title: t.tap_empty_hide_chrome,
            icon: Icons.fullscreen_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 10,
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
              order: 3,
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
              order: 4,
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
            id: 'reading_controls.dismiss_swipe_sensitivity',
            title: t.dismiss_swipe_sensitivity,
            icon: Icons.swipe_down_outlined,
            min: 0.1,
            max: 1,
            divisions: 9,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 5,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.dismissSwipeSensitivity,
            label: (double value) => value.toStringAsFixed(1),
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.readerSource
                  .setDismissSwipeSensitivity(value);
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          // TODO-407②：是否允许"水平滑动关闭查词弹窗"。Windows/Linux 默认关闭
          // （鼠标框选正文与滑动手势同形易误触），其余平台默认开启；任何平台均可
          // 用弹窗顶栏的 X 关闭。
          SettingsSwitchItem(
            id: 'reading_controls.enable_swipe_to_close',
            title: t.enable_swipe_to_close,
            icon: Icons.swipe_left_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 6,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.enableSwipeToClose,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.readerSource.setEnableSwipeToClose(value);
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
              order: 7,
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
              order: 8,
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
              order: 6,
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

SettingsDestination _lookupDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.lookup,
    title: t.settings_destination_lookup,
    summary: t.dictionary_settings,
    icon: Icons.manage_search_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.manager,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'lookup.dictionaries',
            title: t.dictionaries,
            icon: Icons.auto_stories_outlined,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const DictionaryDialogPage(),
              );
              settingsContext.refresh();
            },
          ),
          SettingsActionItem(
            id: 'lookup.custom_css',
            title: t.custom_dict_css,
            icon: Icons.code_outlined,
            onTap: (SettingsContext settingsContext) {
              return showSettingsDialog(
                settingsContext,
                (_) => const DictCssEditorDialog(),
              );
            },
          ),
          SettingsActionItem(
            id: 'lookup.audio_sources',
            title: t.manage_audio_sources,
            icon: Icons.volume_up_outlined,
            onTap: (SettingsContext settingsContext) {
              final AppModel appModel = settingsContext.appModel;
              return showSettingsDialog(
                settingsContext,
                (_) => AudioSourcesDialog(
                  sources: List<AudioSourceConfig>.from(
                    appModel.audioSourceConfigs,
                  ),
                  onSave: appModel.setAudioSourceConfigs,
                  onPickLocalDb: () async {
                    final FilePickerResult? result =
                        await FilePicker.platform.pickFiles();
                    final String? pickedPath = result?.files.single.path;
                    if (pickedPath == null) return null;
                    final LocalAudioDbEntry entry =
                        await appModel.importLocalAudioDbFile(
                      pickedPath,
                      displayName: result!.files.single.name,
                    );
                    return AudioSourceConfig.localAudio(
                      label: entry.displayName,
                      path: entry.path,
                      enabled: true,
                    );
                  },
                  onEditLocalSources: (String path) async {
                    await showSettingsDialog(
                      settingsContext,
                      (_) => LocalAudioSourcesDialog(
                        dbPath: path,
                        savedPrefs: appModel.sourcePrefsForLocalDb(path),
                        listSources: () => appModel.listLocalAudioSources(path),
                        onApply: (List<LocalAudioSourcePref> prefs) =>
                            appModel.setLocalAudioDbSources(path, prefs),
                      ),
                    );
                    settingsContext.refresh();
                  },
                ),
              );
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_section_lookup_behavior,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'lookup.auto_search',
            title: t.auto_search,
            icon: Icons.manage_search_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.autoSearchEnabled,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleAutoSearchEnabled();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.remote_lookup',
            title: t.remote_dict_lookup,
            subtitle: t.remote_dict_lookup_hint,
            icon: Icons.hub_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.remoteLookupEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setRemoteLookupEnabled(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.yomitan_api_server',
            title: t.yomitan_api_server,
            subtitle:
                t.yomitan_api_server_hint + t.settings_experimental_suffix,
            icon: Icons.api_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.yomitanApiServerEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setYomitanApiServerEnabled(value);
              if (value) {
                try {
                  await settingsContext.appModel.startYomitanApiServer();
                } on SyncServerPortInUseException {
                  // startYomitanApiServer 已在抛出前把开关复位为 false。
                  final BuildContext ctx = settingsContext.context;
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text(
                          t.sync_server_port_in_use(
                            port: settingsContext.appModel.yomitanApiPort,
                          ),
                        ),
                      ),
                    );
                  }
                }
              } else {
                await settingsContext.appModel.stopYomitanApiServer();
              }
              settingsContext.refresh();
            },
          ),
          SettingsCustomItem(
            id: 'lookup.yomitan_api_key',
            icon: Icons.key_outlined,
            builder: _buildYomitanApiKeyField,
          ),
          SettingsSwitchItem(
            id: 'lookup.texthooker',
            title: t.texthooker_enabled,
            subtitle:
                t.texthooker_enabled_hint + t.settings_experimental_suffix,
            icon: Icons.sensors_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.texthookerEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setTexthookerEnabled(value);
              if (value) {
                TexthookerWsClientHost.instance
                    .start(settingsContext.appModel.texthookerUrls);
              } else {
                await TexthookerWsClientHost.instance.stop();
              }
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.desktop_clipboard',
            title: t.desktop_clipboard_enabled,
            subtitle: t.desktop_clipboard_enabled_hint +
                t.settings_experimental_suffix,
            icon: Icons.content_paste_search,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.desktopClipboardEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setDesktopClipboardEnabled(value);
              if (!value) {
                await DesktopLookupService.instance.stop();
              }
              settingsContext.refresh();
            },
          ),
          SettingsSegmentedItem<DesktopClipboardWindowMode>(
            id: 'lookup.desktop_clipboard_window_mode',
            title: t.desktop_clipboard_window_mode,
            subtitle: t.desktop_clipboard_window_mode_hint,
            icon: Icons.vertical_align_top_outlined,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop &&
                settingsContext.appModel.desktopClipboardEnabled,
            options: <SettingsSegmentOption<DesktopClipboardWindowMode>>[
              SettingsSegmentOption<DesktopClipboardWindowMode>(
                value: DesktopClipboardWindowMode.normal,
                label: t.desktop_clipboard_window_mode_normal,
                tooltip: t.desktop_clipboard_window_mode_normal,
              ),
              SettingsSegmentOption<DesktopClipboardWindowMode>(
                value: DesktopClipboardWindowMode.lookup,
                label: t.desktop_clipboard_window_mode_lookup,
                tooltip: t.desktop_clipboard_window_mode_lookup,
              ),
              SettingsSegmentOption<DesktopClipboardWindowMode>(
                value: DesktopClipboardWindowMode.always,
                label: t.desktop_clipboard_window_mode_always,
                tooltip: t.desktop_clipboard_window_mode_always,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.desktopClipboardWindowMode,
            onChanged: (
              SettingsContext settingsContext,
              DesktopClipboardWindowMode value,
            ) async {
              await settingsContext.appModel.setDesktopClipboardWindowMode(
                value,
              );
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.auto_read_on_lookup',
            title: t.auto_read_on_lookup,
            icon: Icons.record_voice_over_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.lookup,
              order: 0,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.autoReadOnLookup,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleAutoReadOnLookup();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSliderItem(
            id: 'lookup.audio_volume',
            title: t.lookup_audio_volume,
            icon: Icons.volume_up_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.lookup,
              order: 1,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.lookupAudioVolume.toDouble(),
            min: 0,
            max: 100,
            // 与有声书音量行（AudiobookVolumeRow）同款粒度契约：拖动 1% 一档
            // （0–100% 共 100 档），键盘 / 手柄左右键 5% 一步（step 与档位解
            // 耦——按键也走 1% 的话 0–100% 要按 100 下），标题带实时百分比读数。
            divisions: 100,
            step: 5,
            titleReadout: true,
            label: (double value) => '${value.round()}%',
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.readerSource.setLookupAudioVolume(value);
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.pause_on_lookup',
            title: t.pause_on_lookup,
            icon: Icons.pause_circle_outline,
            reader: const ReaderPlacement(
              group: ReaderGroup.lookup,
              order: 2,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.pauseOnLookup,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.readerSource.setPauseOnLookup(value: value);
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsCustomItem(
            id: 'lookup.auto_search_debounce_delay',
            icon: Icons.timer_outlined,
            builder: _buildSearchDebounceField,
          ),
          SettingsCustomItem(
            id: 'lookup.maximum_terms',
            icon: Icons.format_list_numbered_outlined,
            builder: _buildMaximumTermsField,
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_section_lookup_display,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'lookup.collapse_dictionaries',
            title: t.collapse_dictionaries,
            icon: Icons.unfold_less_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.collapseDictionaries,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleCollapseDictionaries();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.show_expression_tags',
            title: t.show_expression_tags,
            icon: Icons.sell_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.showExpressionTags,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleShowExpressionTags();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.deduplicate_pitch_accents',
            title: t.deduplicate_pitch_accents,
            icon: Icons.filter_alt_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.deduplicatePitchAccents,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleDeduplicatePitchAccents();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.harmonic_frequency',
            title: t.harmonic_frequency,
            icon: Icons.bar_chart_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.harmonicFrequency,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleHarmonicFrequency();
              settingsContext.refresh();
            },
          ),
          SettingsCustomItem(
            id: 'lookup.dictionary_font_size',
            icon: Icons.format_size,
            builder: _buildDictionaryFontSizeField,
          ),
          SettingsSliderItem(
            id: 'lookup.popup_max_width',
            title: t.popup_max_width,
            icon: Icons.open_in_full_outlined,
            min: 250,
            max: 1000,
            divisions: 75,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupMaxWidth,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setPopupMaxWidth(value);
              settingsContext.refresh();
            },
          ),
          SettingsSliderItem(
            id: 'lookup.popup_max_height',
            title: t.popup_max_height,
            icon: Icons.height_outlined,
            min: 200,
            max: 800,
            divisions: 60,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupMaxHeight,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setPopupMaxHeight(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.popup_instant_scroll',
            title: t.popup_instant_scroll,
            subtitle: t.popup_instant_scroll_hint,
            icon: Icons.animation_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupInstantScroll,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setPopupInstantScroll(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.popup_bottom_docked',
            title: t.popup_bottom_docked,
            subtitle: t.popup_bottom_docked_hint,
            icon: Icons.vertical_align_bottom_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupBottomDocked,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setPopupBottomDocked(value);
              settingsContext.refresh();
            },
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _cardCreationDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.cardCreation,
    title: t.settings_destination_card_creation,
    summary: t.anki_settings_label,
    icon: Icons.style_outlined,
    // 平铺：原本「Anki 设置」是一层独立路由子页、和「自动添加书名到标签」开关并列；
    // 现在整段 Anki 正文（含该开关，见 AnkiSettingsBody 页尾）直接平铺进本页，点一次
    // 就看到全部 Anki 配置，不再多跳一层。
    sections: const <SettingsSection>[],
    body: (_) => const AnkiSettingsBody(),
  );
}

SettingsDestination _videoDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.video,
    title: t.settings_destination_video,
    summary: t.video_settings_title,
    icon: Icons.movie_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_video_playback,
        items: <SettingsItem>[
          SettingsSegmentedItem<VideoImmersiveMode>(
            id: 'video.playback.immersive_mode',
            title: t.video_setting_immersive_mode,
            subtitle: t.video_setting_immersive_mode_hint,
            icon: Icons.lock_outline,
            options: <SettingsSegmentOption<VideoImmersiveMode>>[
              for (final VideoImmersiveMode mode in VideoImmersiveMode.values)
                SettingsSegmentOption<VideoImmersiveMode>(
                  value: mode,
                  label: _videoImmersiveModeLabel(mode),
                ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoImmersiveMode,
            onChanged: (
              SettingsContext settingsContext,
              VideoImmersiveMode mode,
            ) async {
              await settingsContext.appModel.setVideoImmersiveMode(mode);
            },
          ),
          SettingsSegmentedItem<VideoFitMode>(
            id: 'video.playback.picture_fit',
            title: t.video_setting_picture_fit,
            subtitle: t.video_setting_picture_fit_hint,
            icon: Icons.fit_screen_outlined,
            options: <SettingsSegmentOption<VideoFitMode>>[
              SettingsSegmentOption<VideoFitMode>(
                value: VideoFitMode.cover,
                label: t.video_setting_picture_fit_cover,
              ),
              SettingsSegmentOption<VideoFitMode>(
                value: VideoFitMode.contain,
                label: t.video_setting_picture_fit_contain,
              ),
              SettingsSegmentOption<VideoFitMode>(
                value: VideoFitMode.fill,
                label: t.video_setting_picture_fit_fill,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoFitMode,
            onChanged: (
              SettingsContext settingsContext,
              VideoFitMode mode,
            ) async {
              await settingsContext.appModel.setVideoFitMode(mode);
            },
          ),
          SettingsSegmentedItem<int>(
            id: 'video.playback.double_tap',
            title: t.video_setting_double_tap,
            subtitle: t.video_setting_double_tap_hint,
            icon: Icons.touch_app_outlined,
            options: <SettingsSegmentOption<int>>[
              SettingsSegmentOption<int>(
                value: 0,
                label: t.video_setting_double_tap_off,
              ),
              for (final int seconds in <int>[3, 5, 10])
                SettingsSegmentOption<int>(
                  value: seconds,
                  label: '${seconds}s',
                ),
              SettingsSegmentOption<int>(
                value: VideoAsbplayerConfig.kDoubleTapSubtitle,
                label: t.video_setting_double_tap_subtitle,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                VideoAsbplayerConfig.decode(
              settingsContext.appModel.videoAsbplayerConfig,
            ).doubleTapSeekSeconds,
            onChanged: (SettingsContext settingsContext, int value) async {
              final VideoAsbplayerConfig current = VideoAsbplayerConfig.decode(
                settingsContext.appModel.videoAsbplayerConfig,
              );
              await settingsContext.appModel.setVideoAsbplayerConfig(
                VideoAsbplayerConfig.encode(
                  current.copyWith(doubleTapSeekSeconds: value),
                ),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'video.playback.lock_window_aspect',
            title: t.video_setting_lock_window_aspect,
            icon: Icons.aspect_ratio_outlined,
            visible: (_) => isDesktopPlatform,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoLockWindowAspectRatio,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setVideoLockWindowAspectRatio(value);
            },
          ),
          // 长按倍速 / 跳转步长 / 句末暂停都落在 videoAsbplayerConfig（纯 pref，无需
          // 播放器 controller）；这里是它们的全局默认，下次播放即生效，与播放页内调一致。
          SettingsSliderItem(
            id: 'video.playback.long_press_speed',
            title: t.video_setting_long_press_speed,
            subtitle: t.video_setting_long_press_speed_hint,
            icon: Icons.touch_app_outlined,
            min: 1.0,
            max: 4.0,
            divisions: 30,
            step: 0.1,
            label: (double v) => '${v.toStringAsFixed(1)}x',
            value: (SettingsContext settingsContext) =>
                VideoAsbplayerConfig.decode(
              settingsContext.appModel.videoAsbplayerConfig,
            ).longPressSpeed,
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoAsbConfig(
                settingsContext,
                (VideoAsbplayerConfig c) => c.copyWith(
                  longPressSpeed: ((v * 10).roundToDouble() / 10)
                      .clamp(1.0, 4.0)
                      .toDouble(),
                ),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
          SettingsStepperItem(
            id: 'video.playback.seek_seconds',
            title: t.video_setting_seek_seconds,
            icon: Icons.keyboard_double_arrow_right_outlined,
            value: (SettingsContext settingsContext) =>
                VideoAsbplayerConfig.decode(
              settingsContext.appModel.videoAsbplayerConfig,
            ).seekSeconds.toDouble(),
            step: 1,
            min: 1,
            max: 30,
            format: (double v) => '${v.round()}s',
            onChanged: (SettingsContext settingsContext, double v) async {
              await _commitVideoAsbConfig(
                settingsContext,
                (VideoAsbplayerConfig c) =>
                    c.copyWith(seekSeconds: v.round().clamp(1, 30)),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'video.playback.pause_at_subtitle_end',
            title: t.playback_auto_pause,
            icon: Icons.pause_circle_outline,
            value: (SettingsContext settingsContext) =>
                VideoAsbplayerConfig.decode(
              settingsContext.appModel.videoAsbplayerConfig,
            ).pauseAtSubtitleEnd,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await _commitVideoAsbConfig(
                settingsContext,
                (VideoAsbplayerConfig c) =>
                    c.copyWith(pauseAtSubtitleEnd: value),
              );
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.video_setting_mpv_group_quality,
        items: <SettingsItem>[
          // 画质增强（mpv 内置高质量缩放开关）+ 解码 / 去色带 / 循环：这些 mpv 配置项
          // 都序列化进 videoMpvConfig（纯 pref），下次打开视频时 applyMpvConfigToPlayer
          // 应用；无需运行中的 controller，故可在首页全局设置改。着色器档位选择需下载 +
          // 文件系统，仍只在播放页内的「画质增强」管理视图里调。
          SettingsSwitchItem(
            id: 'video.quality.enhancement',
            title: t.video_shader_quality_tier,
            subtitle: t.video_quality_enhancement_hint,
            icon: Icons.auto_fix_high_outlined,
            value: (SettingsContext settingsContext) => VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).highQuality,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(highQuality: value),
              );
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'video.quality.hwdec',
            title: t.video_setting_mpv_hwdec,
            icon: Icons.memory_outlined,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'no',
                label: t.video_setting_mpv_hwdec_off,
              ),
              SettingsSegmentOption<String>(
                value: 'auto-safe',
                label: t.video_setting_mpv_hwdec_auto,
              ),
              SettingsSegmentOption<String>(
                value: 'auto-copy',
                label: t.video_setting_mpv_hwdec_copy,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).hwdec,
            onChanged: (SettingsContext settingsContext, String value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(hwdec: value),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'video.quality.deband',
            title: t.video_setting_mpv_deband,
            icon: Icons.gradient_outlined,
            value: (SettingsContext settingsContext) => VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).deband,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(deband: value),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'video.quality.loop',
            title: t.video_setting_mpv_loop,
            icon: Icons.repeat_outlined,
            value: (SettingsContext settingsContext) => VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).loopFile,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(loopFile: value),
              );
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.section_video_subtitles,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'video.subtitle.blur',
            title: t.video_setting_subtitle_blur,
            subtitle: t.video_setting_subtitle_blur_hint,
            icon: Icons.blur_on_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoSubtitleBlur,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setVideoSubtitleBlur(value);
            },
          ),
          // 字幕外观（字号/字重/阴影/背景不透明度/位置）全序列化进 videoSubtitleStyle
          // （纯 pref）。首页设置无实时预览（没有 overlay），落盘后下次播放生效；播放页内
          // 仍有拖动实时预览。字重/阴影粗细在 style 里以 null=「跟随界面缩放」存储，这里
          // 只在用户显式拖动时写显式值（与播放页一致），不主动把默认折成显式值。
          SettingsSliderItem(
            id: 'video.subtitle.font_size',
            title: t.video_setting_subtitle_font_size,
            icon: Icons.format_size_outlined,
            min: 12,
            max: 48,
            divisions: 36,
            label: (double v) => v.round().toString(),
            value: (SettingsContext settingsContext) =>
                VideoSubtitleStyle.decode(
              settingsContext.appModel.videoSubtitleStyle,
            ).fontSize.clamp(12, 48),
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(fontSize: v),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
          SettingsStepperItem(
            id: 'video.subtitle.font_weight',
            title: t.video_setting_subtitle_font_weight,
            icon: Icons.format_bold,
            value: (SettingsContext settingsContext) =>
                VideoSubtitleStyle.decode(
              settingsContext.appModel.videoSubtitleStyle,
            ).resolveFontWeight(settingsContext.appModel.appUiScale).toDouble(),
            step: 100,
            min: 100,
            max: 900,
            format: (double v) => v.round().toString(),
            onChanged: (SettingsContext settingsContext, double v) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(fontWeight: v.round()),
              );
            },
          ),
          SettingsSliderItem(
            id: 'video.subtitle.shadow',
            title: t.video_setting_subtitle_shadow,
            icon: Icons.format_color_text_outlined,
            min: 0,
            max: 12,
            divisions: 12,
            label: (double v) => '${v.round()}px',
            value: (SettingsContext settingsContext) =>
                VideoSubtitleStyle.decode(
              settingsContext.appModel.videoSubtitleStyle,
            )
                    .resolveShadowThickness(
                      settingsContext.appModel.appUiScale,
                    )
                    .clamp(0, 12),
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(shadowThickness: v),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
          SettingsSliderItem(
            id: 'video.subtitle.bg_opacity',
            title: t.video_setting_subtitle_bg_opacity,
            icon: Icons.opacity_outlined,
            divisions: 20,
            value: (SettingsContext settingsContext) =>
                VideoSubtitleStyle.decode(
              settingsContext.appModel.videoSubtitleStyle,
            ).backgroundOpacity.clamp(0, 1),
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(backgroundOpacity: v),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
          SettingsSliderItem(
            id: 'video.subtitle.position',
            title: t.video_setting_subtitle_position,
            icon: Icons.height_outlined,
            min: 0,
            max: 240,
            divisions: 24,
            value: (SettingsContext settingsContext) =>
                VideoSubtitleStyle.decode(
              settingsContext.appModel.videoSubtitleStyle,
            ).bottomPadding.clamp(0, 240),
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(bottomPadding: v),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
        ],
      ),
      SettingsSection(
        title: t.section_video_danmaku,
        items: <SettingsItem>[
          // 弹幕开关 / 在线匹配 / 同屏上限都是纯 pref（appModel 直接读写 prefsRepo），
          // 与播放页内弹幕设置语义一致，下次播放生效。
          SettingsSwitchItem(
            id: 'video.danmaku.enabled',
            title: t.video_setting_danmaku_enabled,
            subtitle: t.video_setting_danmaku_enabled_hint,
            icon: Icons.forum_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setVideoDanmakuEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'video.danmaku.online',
            title: t.video_setting_danmaku_online,
            subtitle: t.video_setting_danmaku_online_hint,
            icon: Icons.cloud_sync_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuOnlineEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setVideoDanmakuOnlineEnabled(value);
            },
          ),
          SettingsStepperItem(
            id: 'video.danmaku.max_active',
            title: t.video_setting_danmaku_max_active,
            subtitle: t.video_setting_danmaku_max_active_hint,
            icon: Icons.speed_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuMaxActive.toDouble(),
            step: 10,
            min: 10,
            max: kMaxVideoDanmakuActive.toDouble(),
            format: (double v) => v.round().toString(),
            onChanged: (SettingsContext settingsContext, double v) async {
              await settingsContext.appModel.setVideoDanmakuMaxActive(
                normalizeVideoDanmakuMaxActive(v.round()),
              );
            },
          ),
          // TODO-277：弹幕来源配置——自建/镜像 Dandanplay 服务器地址 + 可选 API 凭据。
          // 空地址=用官方 api.dandanplay.net；AppId/AppSecret 同时填写时按 v2 签名请求。
          // 写入 videoDanmakuConfig（纯 pref），同步推进程级 DandanplayConfig.current，
          // 下次匹配弹幕即生效（播放页里无参构造的 DandanplayClient 自动读取）。
          SettingsCustomItem(
            id: 'video.danmaku.server_url',
            builder: _buildDanmakuServerField,
          ),
          SettingsCustomItem(
            id: 'video.danmaku.app_id',
            builder: _buildDanmakuAppIdField,
          ),
          SettingsCustomItem(
            id: 'video.danmaku.app_secret',
            builder: _buildDanmakuAppSecretField,
          ),
        ],
      ),
    ],
  );
}

/// 读改写 videoDanmakuConfig（纯 pref）：decode 当前 → 应用 [mutate] → 落盘 → 刷新面板。
Future<void> _commitVideoDanmakuConfig(
  SettingsContext settingsContext,
  DandanplayConfig Function(DandanplayConfig config) mutate,
) async {
  final DandanplayConfig current = settingsContext.appModel.videoDanmakuConfig;
  await settingsContext.appModel.setVideoDanmakuConfig(mutate(current));
  settingsContext.refresh();
}

Widget _buildDanmakuServerField(SettingsContext settingsContext) {
  return _SettingsSecretField(
    title: t.video_setting_danmaku_server_url,
    icon: Icons.dns_outlined,
    initialValue: settingsContext.appModel.videoDanmakuConfig.baseUrl,
    keyboardType: TextInputType.url,
    onChanged: (String value) async {
      await _commitVideoDanmakuConfig(
        settingsContext,
        (DandanplayConfig c) => c.copyWith(baseUrl: value.trim()),
      );
    },
  );
}

Widget _buildDanmakuAppIdField(SettingsContext settingsContext) {
  return _SettingsSecretField(
    title: t.video_setting_danmaku_app_id,
    icon: Icons.badge_outlined,
    initialValue: settingsContext.appModel.videoDanmakuConfig.appId,
    onChanged: (String value) async {
      await _commitVideoDanmakuConfig(
        settingsContext,
        (DandanplayConfig c) => c.copyWith(appId: value.trim()),
      );
    },
  );
}

Widget _buildDanmakuAppSecretField(SettingsContext settingsContext) {
  return _SettingsSecretField(
    title: t.video_setting_danmaku_app_secret,
    icon: Icons.key_outlined,
    initialValue: settingsContext.appModel.videoDanmakuConfig.appSecret,
    obscureText: true,
    keyboardType: TextInputType.visiblePassword,
    onChanged: (String value) async {
      await _commitVideoDanmakuConfig(
        settingsContext,
        (DandanplayConfig c) => c.copyWith(appSecret: value.trim()),
      );
    },
  );
}

/// 读改写 videoAsbplayerConfig（纯 pref）：decode 当前 → 应用 [mutate] → encode 落盘 →
/// 刷新设置面板。所有视频播放手势 / 字幕 pref 都装在这一个 JSON 里，故统一一个 helper。
Future<void> _commitVideoAsbConfig(
  SettingsContext settingsContext,
  VideoAsbplayerConfig Function(VideoAsbplayerConfig config) mutate,
) async {
  final VideoAsbplayerConfig current = VideoAsbplayerConfig.decode(
    settingsContext.appModel.videoAsbplayerConfig,
  );
  await settingsContext.appModel.setVideoAsbplayerConfig(
    VideoAsbplayerConfig.encode(mutate(current)),
  );
  settingsContext.refresh();
}

/// 读改写 videoMpvConfig（纯 pref）：decode → [mutate] → encode 落盘 → 刷新面板。
Future<void> _commitVideoMpvConfig(
  SettingsContext settingsContext,
  VideoMpvConfig Function(VideoMpvConfig config) mutate,
) async {
  final VideoMpvConfig current = VideoMpvConfig.decode(
    settingsContext.appModel.videoMpvConfig,
  );
  await settingsContext.appModel.setVideoMpvConfig(
    VideoMpvConfig.encode(mutate(current)),
  );
  settingsContext.refresh();
}

/// 读改写 videoSubtitleStyle（纯 pref）：decode → [mutate] → encode 落盘 → 刷新面板。
Future<void> _commitVideoSubtitleStyle(
  SettingsContext settingsContext,
  VideoSubtitleStyle Function(VideoSubtitleStyle style) mutate,
) async {
  final VideoSubtitleStyle current = VideoSubtitleStyle.decode(
    settingsContext.appModel.videoSubtitleStyle,
  );
  await settingsContext.appModel.setVideoSubtitleStyle(
    VideoSubtitleStyle.encode(mutate(current)),
  );
  settingsContext.refresh();
}

String _videoImmersiveModeLabel(VideoImmersiveMode mode) {
  switch (mode) {
    case VideoImmersiveMode.full:
      return t.video_immersive_mode_full;
    case VideoImmersiveMode.seekAndLookup:
      return t.video_immersive_mode_seek_lookup;
    case VideoImmersiveMode.lookupOnly:
      return t.video_immersive_mode_lookup_only;
    case VideoImmersiveMode.unlockOnly:
      return t.video_immersive_mode_unlock_only;
  }
}

SettingsDestination _listeningDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.listening,
    title: t.settings_destination_listening,
    summary: t.floating_lyric_hint,
    icon: Icons.headphones_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_audiobook,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'listening.media_notification',
            title: t.show_media_notification,
            icon: Icons.notifications_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.showMediaNotification,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setShowMediaNotification(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'listening.floating_lyric',
            title: t.show_floating_lyric,
            subtitle: t.floating_lyric_hint,
            icon: Icons.subtitles_outlined,
            // The strip is the desktop counterpart of the Android overlay
            // (windows/runner/floating_lyric_window.cpp), so Windows must see
            // this switch too — gating it to Android hid it from desktop users
            // and was the "floating subtitle setting missing/permission"
            // complaint (TODO-038). The Dart channel's isSupported already
            // allows Android + Windows.
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.showFloatingLyric,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setShowFloatingLyric(value);
              settingsContext.refresh();
            },
          ),
          SettingsStepperItem(
            id: 'listening.floating_lyric_font_size',
            title: t.floating_lyric_font_size,
            icon: Icons.format_size,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            min: 8,
            max: 64,
            step: 1,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.floatingLyricFontSize,
            format: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel.setFloatingLyricFontSize(value);
              settingsContext.refresh();
            },
          ),
          // TODO-370: 悬浮字幕「文字透明度」+「按钮底色透明度」自定义（0..100%，
          // 100=保持现观感）。与字号一样仅 Android/Windows 可见（有原生悬浮窗后端）。
          SettingsStepperItem(
            id: 'listening.floating_lyric_text_opacity',
            title: t.floating_lyric_text_opacity,
            subtitle: t.floating_lyric_text_opacity_hint,
            icon: Icons.opacity_outlined,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            min: 0,
            max: 100,
            step: 5,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.floatingLyricTextOpacity.toDouble(),
            format: (double value) => '${value.round()}%',
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel
                  .setFloatingLyricTextOpacity(value.round());
              await settingsContext.appModel.audiobookSession
                  .applyFloatingLyricStyle();
              settingsContext.refresh();
            },
          ),
          SettingsStepperItem(
            id: 'listening.floating_lyric_button_bg_opacity',
            title: t.floating_lyric_button_bg_opacity,
            subtitle: t.floating_lyric_button_bg_opacity_hint,
            icon: Icons.smart_button_outlined,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            min: 0,
            max: 100,
            step: 5,
            value: (SettingsContext settingsContext) => settingsContext
                .appModel.floatingLyricButtonBgOpacity
                .toDouble(),
            format: (double value) => '${value.round()}%',
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel
                  .setFloatingLyricButtonBgOpacity(value.round());
              await settingsContext.appModel.audiobookSession
                  .applyFloatingLyricStyle();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'listening.floating_lyric_click_lookup',
            title: t.floating_lyric_click_lookup,
            subtitle: t.floating_lyric_click_lookup_hint,
            icon: Icons.touch_app_outlined,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.floatingLyricClickLookup,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setFloatingLyricClickLookup(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'listening.volume_key_sentence_nav',
            title: t.volume_key_sentence_nav,
            icon: Icons.skip_next_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 9,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.volumeKeySentenceNavEnabled,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleVolumeKeySentenceNavEnabled();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _systemDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.system,
    title: t.settings_destination_system,
    summary: t.section_update,
    icon: Icons.settings_suggest_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_update,
        // 更新分区在所有平台可见（至少能「检查→打开发布页」）；自动安装开关
        // 仅在支持应用内安装的平台显示（platformSupportsInAppInstall，见
        // platform_updater.dart 单一真相源）。
        visible: (_) => platformSupportsUpdateCheck(),
        items: <SettingsItem>[
          SettingsSegmentedItem<String>(
            id: 'system.update_channel',
            title: t.settings_section_update_channel,
            icon: Icons.system_update_alt_outlined,
            controlBelow: true,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'stable',
                label: t.update_channel_stable,
                icon: Icons.verified_outlined,
                tooltip: t.update_channel_stable,
              ),
              SettingsSegmentOption<String>(
                value: 'beta',
                label: t.update_channel_beta,
                icon: Icons.science_outlined,
                tooltip: t.update_channel_beta,
              ),
              SettingsSegmentOption<String>(
                value: 'debug',
                label: t.update_channel_debug,
                icon: Icons.bug_report_outlined,
                tooltip: t.update_channel_debug,
              ),
            ],
            selected: _selectedUpdateChannel,
            onChanged: setUpdateChannel,
          ),
          SettingsSwitchItem(
            id: 'system.update_never_remind',
            title: t.update_never_remind,
            icon: Icons.notifications_off_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateNeverRemind,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setUpdateNeverRemind(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'system.update_auto_install',
            title: t.update_auto_install,
            icon: Icons.download_done_outlined,
            visible: (_) => platformSupportsInAppInstall(),
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateAutoInstall,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setUpdateAutoInstall(value);
              settingsContext.refresh();
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_destination_system,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'appearance.language',
            icon: Icons.translate_outlined,
            builder: buildLanguageSelector,
          ),
          SettingsCustomItem(
            id: 'system.app_version',
            icon: Icons.info_outline,
            builder: _buildRuntimeAppVersionRow,
          ),
          SettingsSwitchItem(
            id: 'system.low_memory_mode',
            title: t.low_memory_mode,
            subtitle: t.low_memory_mode_hint,
            icon: Icons.memory_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.lowMemoryMode,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setLowMemoryMode(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'system.focus_navigation',
            title: t.focus_navigation_enabled,
            subtitle: t.focus_navigation_enabled_hint +
                t.settings_experimental_suffix,
            icon: Icons.gamepad_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.experimentalFocusNavigationEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setExperimentalFocusNavigationEnabled(value);
              settingsContext.refresh();
            },
          ),
          SettingsNavigationItem(
            id: 'system.keyboard_shortcuts',
            title: t.shortcut_settings_title,
            subtitle: t.settings_experimental_suffix,
            icon: Icons.keyboard_outlined,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const ShortcutSettingsPage(),
              );
            },
          ),
          SettingsActionItem(
            id: 'system.github',
            title: t.options_github,
            icon: Icons.public_outlined,
            onTap: (_) async {
              await launchUrl(
                Uri.parse('https://github.com/hdjsadgfwtg/hibiki'),
                mode: LaunchMode.externalApplication,
              );
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_destination_diagnostics,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'diagnostics.error_log',
            title:
                t.error_log_label(n: ErrorLogService.instance.entries.length),
            icon: Icons.report_problem_outlined,
            builder: (_) => const ErrorLogPage(),
          ),
          SettingsSwitchItem(
            id: 'diagnostics.debug_log_enabled',
            title: t.debug_log_toggle,
            icon: Icons.rule_outlined,
            value: (_) => DebugLogService.instance.enabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await DebugLogService.instance.setEnabled(value);
              settingsContext.refresh();
            },
          ),
          SettingsNavigationItem(
            id: 'diagnostics.debug_log',
            title: t.debug_log_title(
              count: DebugLogService.instance.entries.length,
            ),
            icon: Icons.terminal_outlined,
            visible: (_) =>
                DebugLogService.instance.enabled ||
                DebugLogService.instance.entries.isNotEmpty,
            builder: (_) => const DebugLogPage(),
          ),
        ],
      ),
    ],
  );
}

String _selectedUpdateChannel(SettingsContext settingsContext) {
  if (settingsContext.appModel.updateDebugChannel) return 'debug';
  if (settingsContext.appModel.updateBetaChannel) return 'beta';
  return 'stable';
}

Widget _buildRuntimeAppVersionRow(SettingsContext settingsContext) {
  final packageInfo = settingsContext.appModel.packageInfo;
  return AdaptiveSettingsRow(
    title: t.app_version,
    subtitle: '${packageInfo.version}+${packageInfo.buildNumber}',
    icon: Icons.info_outline,
    showIcon: true,
  );
}

Widget _buildYomitanApiKeyField(SettingsContext settingsContext) {
  return _SettingsSecretField(
    title: t.yomitan_api_key,
    icon: Icons.key_outlined,
    initialValue: settingsContext.appModel.yomitanApiKey,
    obscureText: true,
    keyboardType: TextInputType.visiblePassword,
    onChanged: (String value) async {
      await settingsContext.appModel.setYomitanApiKey(value);
      await _restartYomitanApiServerIfEnabled(settingsContext);
    },
  );
}

Future<void> _restartYomitanApiServerIfEnabled(
  SettingsContext settingsContext,
) async {
  if (!settingsContext.appModel.yomitanApiServerEnabled) return;
  await settingsContext.appModel.stopYomitanApiServer();
  try {
    await settingsContext.appModel.startYomitanApiServer();
  } on SyncServerPortInUseException {
    final BuildContext ctx = settingsContext.context;
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(
          t.sync_server_port_in_use(
            port: settingsContext.appModel.yomitanApiPort,
          ),
        ),
      ),
    );
  }
}

Widget _buildSearchDebounceField(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  return _SettingsNumberField(
    title: t.auto_search_debounce_delay,
    icon: Icons.timer_outlined,
    suffixText: t.unit_milliseconds,
    initialValue: appModel.searchDebounceDelay.toString(),
    resetValue: appModel.defaultSearchDebounceDelay.toString(),
    onChanged: (String value) {
      int newDelay = int.tryParse(value) ?? appModel.defaultSearchDebounceDelay;
      if (newDelay.isNegative) newDelay = appModel.defaultSearchDebounceDelay;
      appModel.setSearchDebounceDelay(newDelay);
      settingsContext.refresh();
    },
    onReset: () {
      appModel.setSearchDebounceDelay(appModel.defaultSearchDebounceDelay);
      settingsContext.refresh();
    },
  );
}

Widget _buildDictionaryFontSizeField(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  return _SettingsNumberField(
    title: t.dictionary_font_size,
    icon: Icons.format_size,
    suffixText: t.unit_pixels,
    initialValue: appModel.dictionaryFontSize.toString(),
    resetValue: appModel.defaultDictionaryFontSize.toString(),
    onChanged: (String value) {
      double newSize =
          double.tryParse(value) ?? appModel.defaultDictionaryFontSize;
      if (newSize.isNegative) newSize = appModel.defaultDictionaryFontSize;
      appModel.setDictionaryFontSize(newSize);
      settingsContext.refresh();
    },
    onReset: () {
      appModel.setDictionaryFontSize(appModel.defaultDictionaryFontSize);
      settingsContext.refresh();
    },
  );
}

Widget _buildMaximumTermsField(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  return _SettingsNumberField(
    title: t.maximum_terms,
    icon: Icons.format_list_numbered_outlined,
    initialValue: appModel.maximumTerms.toString(),
    resetValue: appModel.defaultMaximumDictionaryTermsInResult.toString(),
    onChanged: (String value) {
      int newAmount =
          int.tryParse(value) ?? appModel.defaultMaximumDictionaryTermsInResult;
      if (newAmount.isNegative) {
        newAmount = appModel.defaultMaximumDictionaryTermsInResult;
      }
      appModel.setMaximumTerms(newAmount);
      appModel.clearDictionaryResultsCache();
      settingsContext.refresh();
    },
    onReset: () {
      appModel.setMaximumTerms(appModel.defaultMaximumDictionaryTermsInResult);
      appModel.clearDictionaryResultsCache();
      settingsContext.refresh();
    },
  );
}

class _SettingsSecretField extends StatefulWidget {
  const _SettingsSecretField({
    required this.title,
    required this.icon,
    required this.initialValue,
    required this.onChanged,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
  });

  final String title;
  final IconData icon;
  final String initialValue;
  final bool obscureText;
  final TextInputType keyboardType;
  final Future<void> Function(String value) onChanged;

  @override
  State<_SettingsSecretField> createState() => _SettingsSecretFieldState();
}

class _SettingsSecretFieldState extends State<_SettingsSecretField> {
  late final TextEditingController _controller;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(widget.onChanged(value));
    });
  }

  void _submit(String value) {
    _debounce?.cancel();
    unawaited(widget.onChanged(value));
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: widget.title,
      icon: widget.icon,
      controlBelow: true,
      trailing: AdaptiveSettingsTextField(
        controller: _controller,
        obscureText: widget.obscureText,
        keyboardType: widget.keyboardType,
        textInputAction: TextInputAction.done,
        labelText: widget.title,
        onChanged: _scheduleChanged,
        onSubmitted: _submit,
      ),
    );
  }
}

class _SettingsNumberField extends StatefulWidget {
  const _SettingsNumberField({
    required this.title,
    required this.icon,
    required this.initialValue,
    required this.resetValue,
    required this.onChanged,
    required this.onReset,
    this.suffixText,
  });

  final String title;
  final IconData icon;
  final String initialValue;
  final String resetValue;
  final String? suffixText;
  final ValueChanged<String> onChanged;
  final VoidCallback onReset;

  @override
  State<_SettingsNumberField> createState() => _SettingsNumberFieldState();
}

class _SettingsNumberFieldState extends State<_SettingsNumberField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: widget.title,
      icon: widget.icon,
      controlBelow: true,
      trailing: HibikiTextField(
        controller: _controller,
        keyboardType: TextInputType.number,
        suffixText: widget.suffixText,
        suffixIcon: HibikiIconButton(
          tooltip: t.reset,
          size: 18,
          icon: Icons.undo_outlined,
          onTap: () {
            _controller.text = widget.resetValue;
            widget.onReset();
            FocusScope.of(context).unfocus();
          },
        ),
        labelText: widget.title,
        onChanged: widget.onChanged,
      ),
    );
  }
}

// TODO-049: `customFontsTitlePlaceholder` removed — the single font entry was
// split into three per-target rows (see appearance.fonts_* above), each using
// its own `t.font_target_*` title.
