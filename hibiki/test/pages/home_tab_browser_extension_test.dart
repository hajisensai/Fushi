import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

/// 守卫「浏览器扩展」tab 在首页顶层导航中的可见性与位置。用户要求「单独弄一个底栏、电脑
/// 才有」，生产里由 [homeActiveTabs] 的 browserExtensionEnabled = DesktopLookupService.isDesktop
/// 门控（手机浏览器不支持加载未解压扩展），位置固定在设置之前。
void main() {
  test('HomeTab 枚举包含 browserExtension', () {
    expect(HomeTab.values, contains(HomeTab.browserExtension));
  });

  test('browserExtensionEnabled 关闭（默认）时不出现', () {
    expect(
      homeActiveTabs(videoEnabled: true),
      isNot(contains(HomeTab.browserExtension)),
    );
    expect(
      homeActiveTabs(videoEnabled: true, gamesEnabled: true),
      isNot(contains(HomeTab.browserExtension)),
    );
  });

  test('browserExtensionEnabled 开启时紧邻设置之前', () {
    final List<HomeTab> tabs = homeActiveTabs(
      videoEnabled: true,
      browserExtensionEnabled: true,
    );
    final int ext = tabs.indexOf(HomeTab.browserExtension);
    final int settings = tabs.indexOf(HomeTab.settings);
    expect(ext, greaterThanOrEqualTo(0));
    expect(settings, equals(ext + 1));
  });

  test('games 与 browserExtension 同开时顺序为 视频 < 游戏 < 下载 < 词典 < 扩展 < 设置', () {
    final List<HomeTab> tabs = homeActiveTabs(
      videoEnabled: true,
      gamesEnabled: true,
      browserExtensionEnabled: true,
    );
    final int video = tabs.indexOf(HomeTab.video);
    final int games = tabs.indexOf(HomeTab.games);
    final int downloads = tabs.indexOf(HomeTab.downloads);
    final int dict = tabs.indexOf(HomeTab.dictionaries);
    final int ext = tabs.indexOf(HomeTab.browserExtension);
    final int settings = tabs.indexOf(HomeTab.settings);
    expect(games, equals(video + 1));
    expect(downloads, equals(games + 1));
    expect(dict, equals(downloads + 1));
    expect(ext, equals(dict + 1));
    expect(settings, equals(ext + 1));
  });
}
