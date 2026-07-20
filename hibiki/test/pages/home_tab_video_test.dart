import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

/// 锁定首页顶层 tab 顺序与「实验视频」开关的条件插入（用户需求：视频 tab 放在
/// 书架与词典管理之间，且仅在开启实验功能时显示）。用 games（galgame 库）作为词典与
/// 设置之间的条件 tab 陪测（texthooker tab 已删）。
///
/// 用纯函数 [homeActiveTabs] 测，不必实例化整个 HomePage（它依赖 AppModel + DB +
/// 一堆子系统）。设置覆盖率测试（settings_schema_coverage_test）另行验证开关写穿
/// DB；此处验证它的「生效」= tab 的出现/位置。
void main() {
  group('homeActiveTabs', () {
    test('关闭实验视频：无视频/下载 tab，顺序为 首页→书架→词典→游戏→设置', () {
      final List<HomeTab> tabs =
          homeActiveTabs(videoEnabled: false, gamesEnabled: true);
      expect(tabs, <HomeTab>[
        HomeTab.home,
        HomeTab.books,
        HomeTab.dictionaries,
        HomeTab.games,
        HomeTab.settings,
      ]);
      expect(tabs.contains(HomeTab.video), isFalse);
    });

    test('开启实验视频：视频+下载 tab 出现，顺序为 首页→书架→视频→下载→词典→游戏→设置', () {
      final List<HomeTab> tabs =
          homeActiveTabs(videoEnabled: true, gamesEnabled: true);
      expect(tabs, <HomeTab>[
        HomeTab.home,
        HomeTab.books,
        HomeTab.video,
        HomeTab.downloads,
        HomeTab.dictionaries,
        HomeTab.games,
        HomeTab.settings,
      ]);
    });

    test('视频后紧随下载 tab，再到词典（用户要求：下载单独拿出来）', () {
      final List<HomeTab> tabs =
          homeActiveTabs(videoEnabled: true, gamesEnabled: true);
      final int books = tabs.indexOf(HomeTab.books);
      final int video = tabs.indexOf(HomeTab.video);
      final int downloads = tabs.indexOf(HomeTab.downloads);
      final int dict = tabs.indexOf(HomeTab.dictionaries);
      expect(video, equals(books + 1));
      expect(downloads, equals(video + 1));
      expect(dict, equals(downloads + 1));
    });

    test('视频开关增删 视频+下载 两个 tab（同门控），不动其它 tab 顺序', () {
      final List<HomeTab> off =
          homeActiveTabs(videoEnabled: false, gamesEnabled: true);
      final List<HomeTab> on =
          homeActiveTabs(videoEnabled: true, gamesEnabled: true);
      // 去掉视频+下载后两者应完全一致（这两个是仅有的差异）。
      expect(
        on
            .where((HomeTab t) => t != HomeTab.video && t != HomeTab.downloads)
            .toList(),
        equals(off),
      );
    });
  });
}
