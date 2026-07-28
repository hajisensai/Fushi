import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

/// 守卫「游戏」tab（galgame 库）在首页顶层导航中的可见性与位置。galgame UX 统一后 games
/// 是唯一的 galgame 入口（点游戏 → 台词进悬浮查词面板），生产里由 [homeActiveTabs] 的
/// gamesEnabled = Platform.isWindows 门控（galgame 引擎-hook 注入本就 Windows-only）。
void main() {
  test('HomeTab 枚举包含 games', () {
    expect(HomeTab.values, contains(HomeTab.games));
  });

  test('gamesEnabled 关闭（默认）时不出现', () {
    expect(
      homeActiveTabs(videoEnabled: true),
      isNot(contains(HomeTab.games)),
    );
    expect(
      homeActiveTabs(videoEnabled: false, gamesEnabled: false),
      isNot(contains(HomeTab.games)),
    );
  });

  test('gamesEnabled 开启时紧跟视频之后、下载之前', () {
    final List<HomeTab> tabs = homeActiveTabs(
      videoEnabled: true,
      gamesEnabled: true,
    );
    final int video = tabs.indexOf(HomeTab.video);
    final int games = tabs.indexOf(HomeTab.games);
    final int downloads = tabs.indexOf(HomeTab.downloads);
    expect(games, equals(video + 1));
    expect(downloads, equals(games + 1));
  });

  test('无视频时 games 接在漫画之后、下载之前', () {
    final List<HomeTab> tabs = homeActiveTabs(
      videoEnabled: false,
      gamesEnabled: true,
    );
    final int manga = tabs.indexOf(HomeTab.manga);
    final int games = tabs.indexOf(HomeTab.games);
    final int downloads = tabs.indexOf(HomeTab.downloads);
    expect(games, equals(manga + 1));
    expect(downloads, equals(games + 1));
  });
}
