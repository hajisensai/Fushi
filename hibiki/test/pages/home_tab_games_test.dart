import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

/// 守卫「游戏」tab（galgame 库）在首页顶层导航中的可见性与位置。游戏库与 texthooker
/// 同属 galgame 沉浸制卡，调用方以同一实验开关传入 [homeActiveTabs] 的 gamesEnabled。
void main() {
  test('HomeTab 枚举包含 games', () {
    expect(HomeTab.values, contains(HomeTab.games));
  });

  test('gamesEnabled 关闭（默认）时不出现', () {
    expect(
      homeActiveTabs(videoEnabled: true, texthookerEnabled: true),
      isNot(contains(HomeTab.games)),
    );
    expect(
      homeActiveTabs(
        videoEnabled: false,
        texthookerEnabled: false,
        gamesEnabled: false,
      ),
      isNot(contains(HomeTab.games)),
    );
  });

  test('gamesEnabled 开启时紧邻 texthooker 之后、设置之前', () {
    final List<HomeTab> tabs = homeActiveTabs(
      videoEnabled: true,
      texthookerEnabled: true,
      gamesEnabled: true,
    );
    final int texthooker = tabs.indexOf(HomeTab.texthooker);
    final int games = tabs.indexOf(HomeTab.games);
    final int settings = tabs.indexOf(HomeTab.settings);
    expect(games, equals(texthooker + 1));
    expect(settings, equals(games + 1));
  });

  test('texthooker 关但 games 开：games 落在词典与设置之间', () {
    final List<HomeTab> tabs = homeActiveTabs(
      videoEnabled: false,
      texthookerEnabled: false,
      gamesEnabled: true,
    );
    final int dict = tabs.indexOf(HomeTab.dictionaries);
    final int games = tabs.indexOf(HomeTab.games);
    final int settings = tabs.indexOf(HomeTab.settings);
    expect(games, equals(dict + 1));
    expect(settings, equals(games + 1));
  });
}
