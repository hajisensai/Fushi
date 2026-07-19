import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

void main() {
  group('startup default dictionary tab', () {
    test('开关关闭时保留既有初始 tab', () {
      expect(
        homeInitialTab(
          startupDefaultDictionaryTab: false,
          fallback: HomeTab.books,
        ),
        HomeTab.books,
      );
      expect(
        homeInitialTab(
          startupDefaultDictionaryTab: false,
          fallback: HomeTab.settings,
        ),
        HomeTab.settings,
      );
    });

    test('开关开启时冷启动进入查词 tab', () {
      expect(
        homeInitialTab(
          startupDefaultDictionaryTab: true,
          fallback: HomeTab.books,
        ),
        HomeTab.dictionaries,
      );
    });

    test('反向导航和视频 tab 插入只影响视觉索引，不改变启动逻辑 tab', () {
      final List<HomeTab> tabs = homeActiveTabs(videoEnabled: true);
      final HomeTab initial = homeInitialTab(
        startupDefaultDictionaryTab: true,
        fallback: HomeTab.books,
      );

      expect(initial, HomeTab.dictionaries);
      expect(
        homeTabForVisualIndex(
          tabs: tabs,
          visualIndex: homeVisualIndexForTab(
            tabs: tabs,
            tab: initial,
            reversed: true,
          ),
          reversed: true,
        ),
        HomeTab.dictionaries,
      );
    });
  });

  group('game home tab', () {
    test('游戏是常驻一级 tab，texthooker 不再占一级导航', () {
      expect(HomeTab.values, contains(HomeTab.games));
      expect(HomeTab.values.map((HomeTab tab) => tab.name),
          isNot(contains('texthooker')));
      expect(
        homeActiveTabs(videoEnabled: false),
        <HomeTab>[
          HomeTab.books,
          HomeTab.games,
          HomeTab.dictionaries,
          HomeTab.settings,
        ],
      );
    });

    test('完整顺序为书架→视频→游戏→查词→设置', () {
      expect(
        homeActiveTabs(videoEnabled: true),
        <HomeTab>[
          HomeTab.books,
          HomeTab.video,
          HomeTab.games,
          HomeTab.dictionaries,
          HomeTab.settings,
        ],
      );
    });

    test('游戏导航使用手柄图标与本地化标签', () {
      final item = homeNavItemFor(HomeTab.games);
      expect(item.icon, Icons.sports_esports_outlined);
      expect(item.selectedIcon, Icons.sports_esports);
      expect(item.label, t.nav_game);
    });
  });
}
