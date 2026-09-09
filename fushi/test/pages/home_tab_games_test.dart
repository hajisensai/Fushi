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

/// 守卫「游戏」tab（galgame 库）在首页顶层导航中的可见性与位置。galgame UX 统一后 games
/// 是唯一的 galgame 入口（点游戏 → 台词进悬浮查词面板），生产里由 [ModuleId.games] 门控：
/// 平台判据在 [ModuleId.availableOn]（仅 Windows——galgame 引擎-hook 注入本就 Windows-only），
/// 用户意愿在 `module_games_enabled` 偏好，两者由 [ModuleVisibility.resolve] 合成。
void main() {
  test('HomeTab 枚举包含 games', () {
    expect(HomeTab.values, contains(HomeTab.games));
  });

  test('games 关闭（本文件默认）时不出现', () {
    expect(
      homeActiveTabs(_visibility(video: true)),
      isNot(contains(HomeTab.games)),
    );
    expect(
      homeActiveTabs(_visibility(video: false, games: false)),
      isNot(contains(HomeTab.games)),
    );
  });

  test('games 开启时紧跟视频之后、下载之前', () {
    final List<HomeTab> tabs = homeActiveTabs(
      _visibility(video: true, games: true),
    );
    final int video = tabs.indexOf(HomeTab.video);
    final int games = tabs.indexOf(HomeTab.games);
    final int downloads = tabs.indexOf(HomeTab.downloads);
    expect(games, equals(video + 1));
    expect(downloads, equals(games + 1));
  });

  test('无视频时 games 接在漫画之后、下载之前', () {
    final List<HomeTab> tabs = homeActiveTabs(
      _visibility(video: false, games: true),
    );
    final int manga = tabs.indexOf(HomeTab.manga);
    final int games = tabs.indexOf(HomeTab.games);
    final int downloads = tabs.indexOf(HomeTab.downloads);
    expect(games, equals(manga + 1));
    expect(downloads, equals(games + 1));
  });
}
