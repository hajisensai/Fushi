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
          // searchTitle 复用各自绘制行的既有标题（无新 key），让这些自定义选择器
          // 进入设置搜索（主题/语言/明暗等此前搜不到）。
          SettingsCustomItem(
            id: 'appearance.design_system',
            icon: Icons.devices_outlined,
            searchTitle: t.design_system_label,
            builder: buildDesignSystemSelector,
          ),
          SettingsCustomItem(
            id: 'appearance.theme',
            icon: Icons.color_lens_outlined,
            searchTitle: t.ttu_theme,
            builder: buildThemeSelector,
          ),
          SettingsCustomItem(
            id: 'appearance.brightness',
            icon: Icons.contrast_outlined,
            searchTitle: t.dark_mode,
            builder: buildBrightnessSelector,
          ),
          // 墨水屏模式：全局单开关（设备属性，不随 Profile 快照），叠加在主题/
          // 明暗机制之上——开=纯黑白+无动画+线式高亮，关=还原原主题。
          SettingsSwitchItem(
            id: 'appearance.eink_mode',
            title: t.eink_mode,
            subtitle: t.eink_mode_hint,
            icon: Icons.filter_b_and_w_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.einkMode,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setEinkMode(value);
              settingsContext.refresh();
            },
          ),
          // 「界面大小」滑条用自定义有状态行：拖动中只更新局部值跟手，松手才提交
          // 真实缩放（见 buildAppUiScaleSelector）。这样拖动期间不触发全局
          // HibikiAppUiScale 的 Transform 重排，滑条不会在手指下被缩放位移、可连续拖。
          SettingsCustomItem(
            id: 'appearance.app_ui_scale',
            icon: Icons.format_size_outlined,
            searchTitle: t.app_ui_scale,
            builder: buildAppUiScaleSelector,
          ),
          // 「界面语言」从系统分类归位到这里：它改的是界面呈现语言，与主题/明暗/
          // 缩放同属界面外观；id/持久化 key 不变（本就带 appearance 前缀）。
          SettingsCustomItem(
            id: 'appearance.language',
            icon: Icons.translate_outlined,
            searchTitle: t.options_language,
            builder: buildLanguageSelector,
          ),
        ],
      ),
      SettingsSection(
        title: t.section_typography,
        collapsedByDefault: true,
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
        collapsedByDefault: true,
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
          // 「启动时打开查词」(id 'appearance.startup_default_dictionary_tab') 已归位到
          // 「系统 · 通用」分区（它管的是启动落地页/导航行为，与主题/明暗等外观无关）；
          // id / 持久化 key 保持不变（历史命名 appearance 前缀，仅换展示分类）。
        ],
      ),
    ],
  );
}
