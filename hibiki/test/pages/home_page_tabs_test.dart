import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

/// 守卫 texthooker tab 在首页顶层导航中的存在与位置。v14 时这里断言魔数
/// `kHomeTabCount`/`kHomeSettingsTabIndex`；v23 首页改用 [HomeTab] 枚举建模 tab 身份，
/// 魔数已删除，改为用真实 API 锁定 texthooker 始终是一个独立 tab，且固定夹在词典与
/// 设置之间（用户要求的位置）。
void main() {
  group('texthooker home tab', () {
    test('HomeTab 枚举包含 texthooker', () {
      expect(HomeTab.values, contains(HomeTab.texthooker));
    });

    test('texthooker 出现在可见 tab 列表中（与视频开关无关）', () {
      expect(
        homeActiveTabs(videoEnabled: false),
        contains(HomeTab.texthooker),
      );
      expect(
        homeActiveTabs(videoEnabled: true),
        contains(HomeTab.texthooker),
      );
    });

    test('texthooker 恰好夹在词典与设置之间', () {
      final List<HomeTab> tabs = homeActiveTabs(videoEnabled: true);
      final int dict = tabs.indexOf(HomeTab.dictionaries);
      final int texthooker = tabs.indexOf(HomeTab.texthooker);
      final int settings = tabs.indexOf(HomeTab.settings);
      expect(texthooker, equals(dict + 1));
      expect(settings, equals(texthooker + 1));
    });
  });
}
