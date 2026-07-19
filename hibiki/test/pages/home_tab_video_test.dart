import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

void main() {
  group('homeActiveTabs video insertion', () {
    test('关闭视频时仍保留常驻游戏 tab', () {
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

    test('开启视频时插在书架与游戏之间', () {
      final List<HomeTab> tabs = homeActiveTabs(videoEnabled: true);
      expect(tabs, <HomeTab>[
        HomeTab.books,
        HomeTab.video,
        HomeTab.games,
        HomeTab.dictionaries,
        HomeTab.settings,
      ]);
      expect(tabs.indexOf(HomeTab.video), tabs.indexOf(HomeTab.books) + 1);
      expect(tabs.indexOf(HomeTab.games), tabs.indexOf(HomeTab.video) + 1);
    });

    test('视频开关只增删视频，不改变其它 tab 顺序', () {
      final List<HomeTab> off = homeActiveTabs(videoEnabled: false);
      final List<HomeTab> on = homeActiveTabs(videoEnabled: true);
      expect(on.where((HomeTab tab) => tab != HomeTab.video).toList(), off);
    });
  });
}
