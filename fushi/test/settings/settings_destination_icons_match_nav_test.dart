import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_game.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart';
import 'package:fushi/src/settings/settings_schema_manga.dart';
import 'package:fushi/src/settings/settings_schema_reading.dart';
import 'package:fushi/src/settings/settings_schema_video.dart';

/// 2026-10-05 用户反馈「设置页的漫画图标要改到和底部栏一致」：设置一级分类
/// 「漫画」用的是 auto_stories（与「阅读」分类撞图标），底栏漫画 tab 是
/// photo_library。根因同 BUG-1921：设置页手写了第二份图标，与底栏的
/// [homeNavItemFor] 各改各的。
///
/// 守卫钉死：对应底栏 tab 的设置一级分类，图标取值与 [homeNavItemFor] 相等
/// （咬值不咬源码字面量）。「阅读」分类管的是书架里小说的阅读器，对应底栏
/// 「书架」。
void main() {
  final Map<String, (SettingsDestination, HomeTab)> destinations =
      <String, (SettingsDestination, HomeTab)>{
        'reading': (buildReadingDestination(), HomeTab.books),
        'manga': (buildMangaDestination(), HomeTab.manga),
        'video': (buildVideoDestination(), HomeTab.video),
        'game': (buildGameDestination(), HomeTab.games),
        'lookup': (buildLookupDestination(), HomeTab.dictionaries),
      };

  for (final MapEntry<String, (SettingsDestination, HomeTab)> entry
      in destinations.entries) {
    test('设置分类 ${entry.key} 的图标与底栏 tab 一致', () {
      final (SettingsDestination destination, HomeTab tab) = entry.value;
      expect(
        destination.icon,
        homeNavItemFor(tab).icon,
        reason:
            '设置分类 ${entry.key} 的图标与底栏 ${tab.name} 不一致，'
            '取 homeNavItemFor(tab).icon，别手写第二份',
      );
    });
  }

  test('查词底部停靠的模块细分开关图标与底栏一致', () {
    final SettingsDestination lookup = buildLookupDestination();
    final Map<String, IconData?> iconById = <String, IconData?>{
      for (final SettingsSection section in lookup.sections)
        for (final SettingsItem item in section.items) item.id: item.icon,
    };
    const Map<ModuleId, HomeTab> moduleTabs = <ModuleId, HomeTab>{
      ModuleId.books: HomeTab.books,
      ModuleId.manga: HomeTab.manga,
      ModuleId.video: HomeTab.video,
      ModuleId.games: HomeTab.games,
    };
    int checked = 0;
    for (final MapEntry<ModuleId, HomeTab> e in moduleTabs.entries) {
      final String id = 'lookup.popup_bottom_docked.${e.key.name}';
      if (!iconById.containsKey(id)) continue;
      checked++;
      expect(iconById[id], homeNavItemFor(e.value).icon, reason: id);
    }
    expect(checked, greaterThan(0), reason: '找不到底部停靠的模块细分开关');
  });
}
