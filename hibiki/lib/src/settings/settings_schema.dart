import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';
import 'package:hibiki/utils.dart';
import 'package:url_launcher/url_launcher.dart';

List<SettingsDestination> buildSettingsSchema(SettingsContext context) {
  return <SettingsDestination>[
    _appearanceDestination(),
    _profilesDestination(),
    _readingDestination(),
    _lookupDestination(),
    _cardCreationDestination(),
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
          SettingsSliderItem(
            id: 'appearance.app_ui_scale',
            title: t.app_ui_scale,
            subtitle: t.app_ui_scale_hint,
            icon: Icons.format_size_outlined,
            min: HibikiAppUiScale.minScale,
            max: HibikiAppUiScale.maxScale,
            divisions: 27,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.appUiScale,
            label: (double value) => '${(value * 100).round()}%',
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel.setAppUiScale(value);
              settingsContext.refresh();
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.section_typography,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.fonts',
            title: customFontsTitlePlaceholder,
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
          SettingsNavigationItem(
            id: 'profiles.management',
            title: t.profile_management,
            icon: Icons.manage_accounts_outlined,
            builder: (_) => const ProfileManagementPage(),
          ),
        ],
      ),
    ],
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
            max: 64,
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
          SettingsStepperItem(
            id: 'reading_display.margin_top',
            title: t.margin_top,
            icon: Icons.border_top,
            min: -5,
            max: 30,
            step: 1,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 0,
            ),
            value: (SettingsContext c) => c.readerSource.ttuMarginTop,
            format: (double v) => '${v.round()}',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuMarginTop(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.margin_bottom',
            title: t.margin_bottom,
            icon: Icons.border_bottom,
            min: -5,
            max: 30,
            step: 1,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 1,
            ),
            value: (SettingsContext c) => c.readerSource.ttuMarginBottom,
            format: (double v) => '${v.round()}',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuMarginBottom(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.margin_left',
            title: t.margin_left,
            icon: Icons.border_left,
            min: -5,
            max: 30,
            step: 1,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 2,
            ),
            value: (SettingsContext c) => c.readerSource.ttuMarginLeft,
            format: (double v) => '${v.round()}',
            onChanged: (SettingsContext c, double v) {
              c.readerSource.setTtuMarginLeft(v);
              notifyReaderSettingsChanged(c);
            },
          ),
          SettingsStepperItem(
            id: 'reading_display.margin_right',
            title: t.margin_right,
            icon: Icons.border_right,
            min: -5,
            max: 30,
            step: 1,
            reader: const ReaderPlacement(
              group: ReaderGroup.layout,
              order: 3,
            ),
            value: (SettingsContext c) => c.readerSource.ttuMarginRight,
            format: (double v) => '${v.round()}',
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
            options: const <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'rtl',
                label: 'RTL',
                tooltip: 'Right to Left',
              ),
              SettingsSegmentOption<String>(
                value: 'ltr',
                label: 'LTR',
                tooltip: 'Left to Right',
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
          // 快捷键设置入口暂时隐藏，后面再更新（功能保留，仅不在设置中展示）。
          // SettingsNavigationItem(
          //   id: 'reading_controls.keyboard_shortcuts',
          //   title: t.shortcut_settings_title,
          //   icon: Icons.keyboard_outlined,
          //   builder: (BuildContext context) => const ShortcutSettingsPage(),
          // ),
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
                  localAudioEnabled: appModel.localAudioEnabled,
                  onToggleLocalAudio: appModel.setLocalAudioEnabled,
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
          SettingsSwitchItem(
            id: 'lookup.pause_on_lookup',
            title: t.pause_on_lookup,
            icon: Icons.pause_circle_outline,
            reader: const ReaderPlacement(
              group: ReaderGroup.lookup,
              order: 1,
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
    sections: <SettingsSection>[
      SettingsSection(
        title: t.anki_settings_label,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'card_creation.anki',
            title: t.anki_settings_label,
            icon: Icons.style_outlined,
            builder: (_) => const AnkiSettingsPage(),
          ),
          SettingsSwitchItem(
            id: 'card_creation.auto_add_book_name_to_tags',
            title: t.auto_add_book_name_to_tags,
            icon: Icons.label_outline,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.autoAddBookNameToTags,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleAutoAddBookNameToTags();
              settingsContext.refresh();
            },
          ),
        ],
      ),
    ],
  );
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
            visible: (_) => Platform.isAndroid,
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
            visible: (_) => Platform.isAndroid,
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

String get customFontsTitlePlaceholder => t.custom_fonts;
