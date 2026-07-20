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

  test('gamesEnabled 开启时夹在词典与设置之间', () {
    final List<HomeTab> tabs = homeActiveTabs(
      videoEnabled: true,
      gamesEnabled: true,
    );
    final int dict = tabs.indexOf(HomeTab.dictionaries);
    final int games = tabs.indexOf(HomeTab.games);
    final int settings = tabs.indexOf(HomeTab.settings);
    expect(games, equals(dict + 1));
    expect(settings, equals(games + 1));
  });

  test('无视频时 games 仍夹在词典与设置之间', () {
    final List<HomeTab> tabs = homeActiveTabs(
      videoEnabled: false,
      gamesEnabled: true,
    );
    final int dict = tabs.indexOf(HomeTab.dictionaries);
    final int games = tabs.indexOf(HomeTab.games);
    final int settings = tabs.indexOf(HomeTab.settings);
    expect(games, equals(dict + 1));
    expect(settings, equals(games + 1));
  });
}
