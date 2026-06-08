import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

/// 锁定首页顶层 tab 顺序与「实验视频」开关的条件插入（用户需求：视频 tab 放在
/// 书架与词典管理之间，且仅在开启实验功能时显示）。
///
/// 用纯函数 [homeActiveTabs] 测，不必实例化整个 HomePage（它依赖 AppModel + DB +
/// 一堆子系统）。设置覆盖率测试（settings_schema_coverage_test）另行验证开关写穿
/// DB；此处验证它的「生效」= tab 的出现/位置。
void main() {
  group('homeActiveTabs', () {
    test('关闭实验视频：无视频 tab，顺序为 书架→词典→texthooker→设置', () {
      final List<HomeTab> tabs =
          homeActiveTabs(videoEnabled: false, texthookerEnabled: true);
      expect(tabs, <HomeTab>[
        HomeTab.books,
        HomeTab.dictionaries,
        HomeTab.texthooker,
        HomeTab.settings,
      ]);
      expect(tabs.contains(HomeTab.video), isFalse);
    });

    test('开启实验视频：视频 tab 出现，顺序为 书架→视频→词典→texthooker→设置', () {
      final List<HomeTab> tabs =
          homeActiveTabs(videoEnabled: true, texthookerEnabled: true);
      expect(tabs, <HomeTab>[
        HomeTab.books,
        HomeTab.video,
        HomeTab.dictionaries,
        HomeTab.texthooker,
        HomeTab.settings,
      ]);
    });

    test('视频 tab 恰好夹在书架与词典之间（用户要求的位置）', () {
      final List<HomeTab> tabs =
          homeActiveTabs(videoEnabled: true, texthookerEnabled: true);
      final int books = tabs.indexOf(HomeTab.books);
      final int video = tabs.indexOf(HomeTab.video);
      final int dict = tabs.indexOf(HomeTab.dictionaries);
      expect(books, lessThan(video));
      expect(video, lessThan(dict));
      // 紧邻：书架与词典之间没有其它 tab。
      expect(video, equals(books + 1));
      expect(dict, equals(video + 1));
    });

    test('开关只增删视频 tab，不动其它 tab 的相对顺序', () {
      final List<HomeTab> off =
          homeActiveTabs(videoEnabled: false, texthookerEnabled: true);
      final List<HomeTab> on =
          homeActiveTabs(videoEnabled: true, texthookerEnabled: true);
      // 去掉视频后两者应完全一致（视频是唯一的差异）。
      expect(on.where((HomeTab t) => t != HomeTab.video).toList(), equals(off));
    });
  });
}
