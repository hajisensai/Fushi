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
          // 「界面大小」滑条：commitOnRelease——本滑条位于受 HibikiAppUiScale 的
          // Transform.scale 缩放的子树内，拖动逐帧提交会让整树立刻按新比例重排、
          // 滑块在手指下位移、手势断裂（TODO-374 旧 _AppUiScaleSliderRow 注释）。
          // 渲染层 _CommitOnReleaseSlider 拖动只更新本地预览值（跟手 + 标题读数
          // 实时），松手才经 onChanged 一次性提交真实缩放；键盘/手柄步进每按即提交。
          // 一等 schema 项同时带来静止常驻读数（titleReadout）与搜索索引，替代原
          // 自定义 custom 行双实现。id/持久化路径不变。
          SettingsSliderItem(
            id: 'appearance.app_ui_scale',
            title: t.app_ui_scale,
            subtitle: t.app_ui_scale_hint,
            icon: Icons.format_size_outlined,
            min: HibikiAppUiScale.minScale,
            max: HibikiAppUiScale.maxScale,
            divisions: 27,
            label: (double value) => '${(value * 100).round()}%',
            titleReadout: true,
            commitOnRelease: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.appUiScale,
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel.setAppUiScale(value);
            },
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
        // 排版分区**不折叠**：改字体是外观页的高频操作（用户显式反馈），折叠让每次
        // 改字体都多一次展开点击，收益（省一行高度）远小于代价。
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
