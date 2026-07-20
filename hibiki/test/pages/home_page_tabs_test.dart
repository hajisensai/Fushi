import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart';

/// 守卫首页顶层导航的 tab 身份建模与启动逻辑。v23 起首页用 [HomeTab] 枚举建模 tab 身份
/// （不再用魔数索引）；galgame UX 统一后独立 texthooker tab 已删，条件 tab 只剩 video
/// （常驻）与 games（galgame 库，仅 Windows）。games 的可见性/位置由 home_tab_games_test
/// 单独守卫，本文件守 startup 逻辑 + 「无 games 时词典与设置相邻」。
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

  group('home dashboard tab', () {
    test('HomeTab 枚举包含 home，且是可见 tab 列表的第一个', () {
      expect(HomeTab.values, contains(HomeTab.home));
      expect(
        homeActiveTabs(videoEnabled: false).first,
        HomeTab.home,
      );
      expect(
        homeActiveTabs(videoEnabled: true).first,
        HomeTab.home,
      );
    });

    test('冷启动（未开默认词典 tab）落在首页 home', () {
      expect(
        homeInitialTab(
          startupDefaultDictionaryTab: false,
          fallback: HomeTab.home,
        ),
        HomeTab.home,
      );
    });
  });

  group('downloads home tab', () {
    test('HomeTab 枚举包含 downloads', () {
      expect(HomeTab.values, contains(HomeTab.downloads));
    });

    test('下载 tab 与视频同门控：视频关则不出现', () {
      expect(
        homeActiveTabs(videoEnabled: false),
        isNot(contains(HomeTab.downloads)),
      );
    });

    test('视频开启时下载 tab 出现且紧随视频', () {
      final List<HomeTab> tabs = homeActiveTabs(videoEnabled: true);
      final int video = tabs.indexOf(HomeTab.video);
      final int downloads = tabs.indexOf(HomeTab.downloads);
      expect(video, isNonNegative);
      expect(downloads, equals(video + 1));
    });

    test('每个可见 tab 都有导航项（图标+标签），含 downloads', () {
      for (final HomeTab tab in homeActiveTabs(videoEnabled: true)) {
        final AdaptiveNavItem item = homeNavItemFor(tab);
        expect(item.label, isNotEmpty);
      }
    });
  });

  group('home tab structure', () {
    test('HomeTab 枚举不再含已删的 texthooker', () {
      expect(
        HomeTab.values.map((HomeTab t) => t.name),
        isNot(contains('texthooker')),
      );
    });

    test('无 games 时词典与设置相邻', () {
      final List<HomeTab> tabs = homeActiveTabs(videoEnabled: true);
      final int dict = tabs.indexOf(HomeTab.dictionaries);
      final int settings = tabs.indexOf(HomeTab.settings);
      expect(settings, equals(dict + 1));
    });

    test('游戏导航使用 Hook 工作台标签与手柄图标', () {
      final AdaptiveNavItem item = homeNavItemFor(HomeTab.games);
      expect(item.icon, Icons.sports_esports_outlined);
      expect(item.selectedIcon, Icons.sports_esports);
      expect(item.label, t.nav_game);
    });
  });
}
