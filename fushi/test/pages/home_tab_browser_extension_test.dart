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

/// 守卫「浏览器扩展」tab 在首页顶层导航中的可见性与位置。用户要求「单独弄一个底栏、电脑
/// 才有」，生产里由 [ModuleId.browserExtension] 门控：平台判据在 [ModuleId.availableOn]
/// （仅桌面——手机浏览器不支持加载未解压扩展），用户意愿在 `module_browser_extension_enabled`
/// 偏好，两者由 [ModuleVisibility.resolve] 合成。位置固定在设置之前。
void main() {
  test('HomeTab 枚举包含 browserExtension', () {
    expect(HomeTab.values, contains(HomeTab.browserExtension));
  });

  test('browserExtension 关闭（本文件默认）时不出现', () {
    expect(
      homeActiveTabs(_visibility(video: true)),
      isNot(contains(HomeTab.browserExtension)),
    );
    expect(
      homeActiveTabs(_visibility(video: true, games: true)),
      isNot(contains(HomeTab.browserExtension)),
    );
  });

  test('browserExtension 开启时紧邻设置之前', () {
    final List<HomeTab> tabs = homeActiveTabs(
      _visibility(video: true, browserExtension: true),
    );
    final int ext = tabs.indexOf(HomeTab.browserExtension);
    final int settings = tabs.indexOf(HomeTab.settings);
    expect(ext, greaterThanOrEqualTo(0));
    expect(settings, equals(ext + 1));
  });

  test('games 与 browserExtension 同开时顺序为 视频 < 游戏 < 下载 < 词典 < 扩展 < 设置', () {
    final List<HomeTab> tabs = homeActiveTabs(
      _visibility(video: true, games: true, browserExtension: true),
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
