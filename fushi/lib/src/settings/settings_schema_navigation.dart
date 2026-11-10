/// 「导航与首页」一级分类：应用骨架怎么走——有哪些模块、底栏长什么样、打开
/// 落在哪一页、首页放什么、跨页跳转怎么记。
///
/// 这些项原本散在外观与系统两页，但都回答「怎么在应用里移动」，与配色、字体
/// 无关。各项仍留在原文件（依赖那里的私有 helper），以顶层 builder 导出，
/// 本文件只按分区装配。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

SettingsDestination buildNavigationDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.navigation,
    title: t.settings_navigation_title,
    summary: t.settings_navigation_summary,
    icon: FushiIcons.dashboardCustomize,
    sections: <SettingsSection>[
      buildModulesSection(),
      // 启动页与底栏三项放一组：启动页的选项就是底栏上的页面，底栏样式 / 文字 /
      // 方向决定这些页面怎么摆。
      SettingsSection(
        id: 'navigation.section.startup_bar',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_navigation_section_startup_bar,
        items: <SettingsItem>[
          buildStartupPageItem(),
          buildNavBarStyleItem(),
          buildNavBarLabelsItem(),
          buildReverseNavigationBarItem(),
        ],
      ),
      buildHomePanelsSection(),
      buildJumpHistorySection(),
    ],
  );
}
