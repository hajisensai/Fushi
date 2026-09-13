import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';

/// 测试用：把「一串具名 bool」翻成一个可见性快照。迁移前 [homeActiveTabs] 收的正是
/// 这串具名 bool（`videoEnabled` 必填，books/manga/downloads/lookup 默认开，
/// games/browserExtension 默认关），默认值在这里逐字保留，用例语义不变。
///
/// games/browserExtension 的平台判据在这里**显式给出**（[ModuleVisibility] 直接收
/// 最终可见集合），与生产的 [ModuleVisibility.resolve] 同语义——生产侧平台判据在
/// [ModuleId.availableOn]。
ModuleVisibility _visibility({
  required bool video,
  bool books = true,
  bool manga = true,
  bool games = false,
  bool downloads = true,
  bool lookup = true,
  bool browserExtension = false,
}) => ModuleVisibility(<ModuleId>{
  if (books) ModuleId.books,
  if (manga) ModuleId.manga,
  if (video) ModuleId.video,
  if (games) ModuleId.games,
  if (downloads) ModuleId.downloads,
  if (lookup) ModuleId.lookup,
  if (browserExtension) ModuleId.browserExtension,
});

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

    test('查词模块关掉时「启动默认查词」不得把初始 tab 指到隐藏 tab', () {
      // 渲染侧有 _visibleTab 兜底成首页，但 _currentTab 会从第一帧起就是脏的
      // （底栏高亮与 _previousTab 都跟着错），所以门控必须在取值处。
      expect(
        homeInitialTab(
          startupDefaultDictionaryTab: true,
          dictionariesEnabled: false,
          fallback: HomeTab.books,
        ),
        HomeTab.books,
      );
      expect(
        homeInitialTab(
          startupDefaultDictionaryTab: true,
          dictionariesEnabled: false,
          fallback: HomeTab.home,
        ),
        HomeTab.home,
      );
      // 落点必须真的在可见 tab 列表里。
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, lookup: false),
      );
      expect(
        tabs,
        contains(
          homeInitialTab(
            startupDefaultDictionaryTab: true,
            dictionariesEnabled: false,
            fallback: HomeTab.home,
          ),
        ),
      );
    });

    test('查词模块开着时行为不变（dictionariesEnabled 默认 true）', () {
      expect(
        homeInitialTab(
          startupDefaultDictionaryTab: true,
          dictionariesEnabled: true,
          fallback: HomeTab.books,
        ),
        HomeTab.dictionaries,
      );
    });

    test('反向导航和视频 tab 插入只影响视觉索引，不改变启动逻辑 tab', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
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
      expect(homeActiveTabs(_visibility(video: false)).first, HomeTab.home);
      expect(homeActiveTabs(_visibility(video: true)).first, HomeTab.home);
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

    test('下载 tab 恒在（统一下载中心）：视频关也出现', () {
      expect(
        homeActiveTabs(_visibility(video: false)),
        contains(HomeTab.downloads),
      );
    });

    test('视频开启时下载 tab 出现且紧随视频', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      final int video = tabs.indexOf(HomeTab.video);
      final int downloads = tabs.indexOf(HomeTab.downloads);
      expect(video, isNonNegative);
      expect(downloads, equals(video + 1));
    });

    test('每个可见 tab 都有导航项（图标+标签），含 downloads', () {
      for (final HomeTab tab in homeActiveTabs(_visibility(video: true))) {
        final AdaptiveNavItem item = homeNavItemFor(tab);
        expect(item.label, isNotEmpty);
      }
    });
  });

  group('manga home tab', () {
    test('漫画固定紧随普通书架，且有独立导航项', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      expect(tabs.indexOf(HomeTab.manga), tabs.indexOf(HomeTab.books) + 1);

      final AdaptiveNavItem item = homeNavItemFor(HomeTab.manga);
      expect(item.icon, Icons.photo_library_outlined);
      expect(item.selectedIcon, Icons.photo_library);
      expect(item.label, t.manga_library);
    });
  });

  group('module tab visibility (功能模块显隐)', () {
    test('默认参数下漫画/视频可见（升级用户行为不变）', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      expect(tabs, contains(HomeTab.manga));
      expect(tabs, contains(HomeTab.video));
    });

    test('manga=false 只隐藏漫画 tab，其余不动', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, manga: false),
      );
      expect(tabs, isNot(contains(HomeTab.manga)));
      expect(tabs, contains(HomeTab.books));
      expect(tabs, contains(HomeTab.video));
      expect(tabs, contains(HomeTab.downloads));
      expect(tabs, contains(HomeTab.dictionaries));
      expect(tabs, contains(HomeTab.settings));
    });

    test('books=false 只隐藏书架 tab，首页/词典/设置不动', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, books: false),
      );
      expect(tabs, isNot(contains(HomeTab.books)));
      expect(tabs, contains(HomeTab.home));
      expect(tabs, contains(HomeTab.dictionaries));
      expect(tabs, contains(HomeTab.settings));
    });

    test('browserExtension=false 隐藏扩展 tab', () {
      final List<HomeTab> withExt = homeActiveTabs(
        _visibility(video: true, browserExtension: true),
      );
      final List<HomeTab> withoutExt = homeActiveTabs(
        _visibility(video: true, browserExtension: false),
      );
      expect(withExt, contains(HomeTab.browserExtension));
      expect(withoutExt, isNot(contains(HomeTab.browserExtension)));
    });

    test('五个模块全关时首页/词典/设置/下载仍恒在（安全回退面）', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(
          video: false,
          books: false,
          manga: false,
          games: false,
          browserExtension: false,
        ),
      );
      expect(
        tabs,
        <HomeTab>[
          HomeTab.home,
          HomeTab.downloads,
          HomeTab.dictionaries,
          HomeTab.settings,
        ],
      );
    });

    test('downloads=false 只隐藏下载 tab，词典仍紧随最后一个媒体库页', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, games: true, downloads: false),
      );
      expect(tabs, isNot(contains(HomeTab.downloads)));
      expect(
          tabs.indexOf(HomeTab.dictionaries), tabs.indexOf(HomeTab.games) + 1);
      expect(tabs, contains(HomeTab.settings));
    });

    test('lookup=false 只隐藏查词 tab，下载仍在', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, browserExtension: true, lookup: false),
      );
      expect(tabs, isNot(contains(HomeTab.dictionaries)));
      expect(tabs, contains(HomeTab.downloads));
      expect(
        tabs.indexOf(HomeTab.browserExtension),
        tabs.indexOf(HomeTab.downloads) + 1,
      );
    });

    test('七个模块全关时只剩首页/设置（安全回退面）', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(
          video: false,
          books: false,
          manga: false,
          games: false,
          downloads: false,
          lookup: false,
          browserExtension: false,
        ),
      );
      expect(tabs, <HomeTab>[HomeTab.home, HomeTab.settings]);
    });

    test('隐藏 tab 后越界视觉索引回退到恒在的 home（不再是可隐藏的书架）', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: false, books: false, manga: false),
      );
      expect(
        homeTabForVisualIndex(tabs: tabs, visualIndex: 99, reversed: false),
        HomeTab.home,
      );
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
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
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
