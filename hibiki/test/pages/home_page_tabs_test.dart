import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

/// 守卫 texthooker tab 在首页顶层导航中的存在与位置。v14 时这里断言魔数
/// `kHomeTabCount`/`kHomeSettingsTabIndex`；v23 首页改用 [HomeTab] 枚举建模 tab 身份，
/// 魔数已删除，改为用真实 API 锁定 texthooker 的可见性与位置。
///
/// 文本钩子 tab 仅在文本钩子开关开启时出现（用户要求「只有开了文本钩子才会显示」），
/// 开启后固定夹在词典与设置之间。
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
      final List<HomeTab> tabs =
          homeActiveTabs(videoEnabled: true, texthookerEnabled: false);
      final HomeTab initial = homeInitialTab(
        startupDefaultDictionaryTab: true,
        fallback: HomeTab.books,
      );

      expect(initial, HomeTab.dictionaries);
      expect(
        homeVisualIndexForTab(
          tabs: tabs,
          tab: initial,
          reversed: false,
        ),
        tabs.indexOf(HomeTab.dictionaries),
      );
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

  group('texthooker home tab', () {
    test('HomeTab 枚举包含 texthooker', () {
      expect(HomeTab.values, contains(HomeTab.texthooker));
    });

    test('文本钩子关闭时不出现在可见 tab 列表中（与视频开关无关）', () {
      expect(
        homeActiveTabs(videoEnabled: false, texthookerEnabled: false),
        isNot(contains(HomeTab.texthooker)),
      );
      expect(
        homeActiveTabs(videoEnabled: true, texthookerEnabled: false),
        isNot(contains(HomeTab.texthooker)),
      );
    });

    test('文本钩子开启时出现在可见 tab 列表中（与视频开关无关）', () {
      expect(
        homeActiveTabs(videoEnabled: false, texthookerEnabled: true),
        contains(HomeTab.texthooker),
      );
      expect(
        homeActiveTabs(videoEnabled: true, texthookerEnabled: true),
        contains(HomeTab.texthooker),
      );
    });

    test('texthooker 开启时恰好夹在词典与设置之间', () {
      final List<HomeTab> tabs =
          homeActiveTabs(videoEnabled: true, texthookerEnabled: true);
      final int dict = tabs.indexOf(HomeTab.dictionaries);
      final int texthooker = tabs.indexOf(HomeTab.texthooker);
      final int settings = tabs.indexOf(HomeTab.settings);
      expect(texthooker, equals(dict + 1));
      expect(settings, equals(texthooker + 1));
    });

    test('文本钩子关闭时词典与设置相邻（中间无 texthooker）', () {
      final List<HomeTab> tabs =
          homeActiveTabs(videoEnabled: true, texthookerEnabled: false);
      final int dict = tabs.indexOf(HomeTab.dictionaries);
      final int settings = tabs.indexOf(HomeTab.settings);
      expect(settings, equals(dict + 1));
    });
  });
}
