import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';

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

/// 锁定首页顶层 tab 顺序与「实验视频」开关的条件插入（用户需求：视频 tab 放在
/// 书架与词典管理之间，且仅在开启实验功能时显示）。用 games（galgame 库）作为紧跟视频
/// 之后的条件 tab 陪测（texthooker tab 已删）。
///
/// 用纯函数 [homeActiveTabs] 测，不必实例化整个 HomePage（它依赖 AppModel + DB +
/// 一堆子系统）。设置覆盖率测试（settings_schema_coverage_test）另行验证开关写穿
/// DB；此处验证它的「生效」= tab 的出现/位置。
void main() {
  group('homeActiveTabs', () {
    test('关闭实验视频：无视频 tab；下载 tab 恒在（统一下载中心），顺序为 首页→书架→漫画→游戏→下载→词典→设置', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: false, games: true),
      );
      expect(tabs, <HomeTab>[
        HomeTab.home,
        HomeTab.books,
        HomeTab.manga,
        HomeTab.games,
        HomeTab.downloads,
        HomeTab.dictionaries,
        HomeTab.settings,
      ]);
      expect(tabs.contains(HomeTab.video), isFalse);
    });

    test('开启实验视频：视频+下载 tab 出现，顺序为 首页→书架→漫画→视频→游戏→下载→词典→设置', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, games: true),
      );
      expect(tabs, <HomeTab>[
        HomeTab.home,
        HomeTab.books,
        HomeTab.manga,
        HomeTab.video,
        HomeTab.games,
        HomeTab.downloads,
        HomeTab.dictionaries,
        HomeTab.settings,
      ]);
      expect(tabs.indexOf(HomeTab.video), tabs.indexOf(HomeTab.manga) + 1);
    });

    test('视频后紧随游戏，再到下载与词典（用户要求：游戏移到视频后面）', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, games: true),
      );
      final int books = tabs.indexOf(HomeTab.books);
      final int manga = tabs.indexOf(HomeTab.manga);
      final int video = tabs.indexOf(HomeTab.video);
      final int games = tabs.indexOf(HomeTab.games);
      final int downloads = tabs.indexOf(HomeTab.downloads);
      final int dict = tabs.indexOf(HomeTab.dictionaries);
      expect(manga, equals(books + 1));
      expect(video, equals(manga + 1));
      expect(games, equals(video + 1));
      expect(downloads, equals(games + 1));
      expect(dict, equals(downloads + 1));
    });

    test('视频开关只增删视频 tab（下载 tab 不随动，统一下载中心），不动其它 tab 顺序', () {
      final List<HomeTab> off = homeActiveTabs(
        _visibility(video: false, games: true),
      );
      final List<HomeTab> on = homeActiveTabs(
        _visibility(video: true, games: true),
      );
      // 去掉视频后两者应完全一致（视频是仅有的差异；下载恒在）。
      expect(
        on.where((HomeTab t) => t != HomeTab.video).toList(),
        equals(off),
      );
    });
  });
}
