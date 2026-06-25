import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';

SettingsDestination buildAppearanceDestination() {
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
            visible: (_) => Platform.isAndroid || Platform.isWindows,
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

// TODO-049: `customFontsTitlePlaceholder` removed — the single font entry was
// split into three per-target rows (see appearance.fonts_* above), each using
// its own `t.font_target_*` title.
