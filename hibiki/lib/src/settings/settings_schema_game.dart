import 'dart:io';

import 'package:flutter/material.dart';

import 'package:hibiki/src/pages/implementations/game_shared.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';

/// 「游戏」一级设置分类（审计 K / Phase 3.12：游戏域此前没有任何 destination，
/// 游戏库 / 捕获工作台 / 兼容性诊断从设置主页既不可达也不可搜）。
///
/// 三条导航项直达 games 顶层 tab 的对应子区：不 push 第二份页面实例（捕获工作台
/// 持有 Hook 会话，[TexthookerPage] 由 [HomeGamePage] 的 IndexedStack 保态），
/// 而是复用既有跳转真相源——`homeShellTabNotifier` 切 tab + `gameSectionNotifier`
/// 选子区（与原生 Hook 浮窗 `openWorkbench` / 首页 dashboard 卡片同一条路径）。
///
/// 门控：与 games 顶层 tab 完全一致（`homeActiveTabs` 的
/// `gamesEnabled: Platform.isWindows`——galgame 引擎-hook 注入 Windows-only）。
/// 非 Windows 平台整个分类不可见、不进搜索索引。
///
/// 浏览器扩展页不属于游戏域（它是查词域的桌面扩展安装助手），其搜索入口登记在
/// 「查词」分类（settings_schema_lookup 的 `lookup.browser_extension`），不在此处。
SettingsDestination buildGameDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.game,
    title: t.nav_game,
    summary: t.game_home_subtitle,
    icon: Icons.sports_esports_outlined,
    visible: (SettingsContext settingsContext) => Platform.isWindows,
    sections: <SettingsSection>[
      SettingsSection(
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'game.library',
            title: t.game_library,
            subtitle: t.game_home_subtitle,
            icon: Icons.videogame_asset_outlined,
            showIcon: true,
            onTap: (SettingsContext settingsContext) {
              homeShellTabNotifier.value = HomeTab.games;
              gameSectionNotifier.value = GameSection.library;
            },
          ),
          SettingsNavigationItem(
            id: 'game.capture_workspace',
            title: t.game_capture_workbench,
            icon: Icons.sensors_outlined,
            showIcon: true,
            onTap: (SettingsContext settingsContext) {
              homeShellTabNotifier.value = HomeTab.games;
              gameSectionNotifier.value = GameSection.monitor;
            },
          ),
          SettingsNavigationItem(
            id: 'game.diagnostics',
            title: t.game_diagnostics,
            icon: Icons.monitor_heart_outlined,
            showIcon: true,
            onTap: (SettingsContext settingsContext) {
              homeShellTabNotifier.value = HomeTab.games;
              gameSectionNotifier.value = GameSection.diagnostics;
            },
          ),
        ],
      ),
    ],
  );
}
