import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart'
    show kGameSectionTabOrder;
import 'package:fushi/src/pages/implementations/home_game_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

/// 游戏顶栏切子区时指示条要滑动（用户反馈「小说漫画游戏导航栏都没动画」）。
///
/// 游戏的七个子区在 IndexedStack 里一起常驻，每页各挂一份 `selected` 为常量的页签：
/// 切到别的子区时那一页的页签早就停在自己的位置上，指示条没有起点可滑。
/// [HomeGamePage] 当时用 [LibrarySectionFollowScope] 广播真实所在子区，隐藏页的
/// 页签跟着它走。2026-10-06 起外壳浮动工具栏只画一份页签（ad8496b2b86），
/// `selected` 随子区变化，同一个 State 的指示器从来源子区滑到目标子区——本测试守
/// 的「切子区时指示条在滑」这个用户可见结果不变。
Widget _stubDashboard(BuildContext _, VoidCallback __) => const SizedBox();

Widget _stubLibrary(
  BuildContext _,
  GalHookSessionController __,
  VoidCallback ___,
) =>
    const SizedBox();

/// 镜像生产 [ModuleSettingsView] 的顶栏形状，但不构建需要 provider 的设置正文。
Widget _stubSettings(BuildContext _, Widget navigation) => Column(
      children: <Widget>[FushiPageHeader.customTitle(title: navigation)],
    );

void main() {
  setUp(() {
    LocaleSettings.setLocaleRaw('zh-CN');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TexthookerService.instance.clear();
    gameSectionNotifier.value = GameSection.library;
  });
  tearDown(() {
    TexthookerService.instance.clear();
    gameSectionNotifier.value = GameSection.dashboard;
    LocaleSettings.setLocaleRaw('en');
  });

  TabController shellController(WidgetTester tester) {
    // 2026-10-06 起分区页签由外壳浮动工具栏统一画一份（ad8496b2b86，
    // [GameSectionTabsHostScope]），子区页头里那份留空：全树（含 offstage 子区）
    // 恰好一份。MD3 下 FushiTabBar 把原 TabBar 渲染在自己下面一层。
    final Finder bar = find.byType(
      FushiSectionTabBar<GameSection>,
      skipOffstage: false,
    );
    expect(bar, findsOneWidget, reason: '游戏外壳应恰好一份分区页签');
    final TabBar tabBar = tester.widget<TabBar>(
      find.descendant(of: bar, matching: find.byType(TabBar)),
    );
    return tabBar.controller!;
  }

  testWidgets('库 → 设置：外壳页签从「库」滑到「设置」，而不是原地落位',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(testPlatformServices()),
        ],
        child: MaterialApp(
          home: HomeGamePage(
            dashboardBuilder: _stubDashboard,
            libraryBuilder: _stubLibrary,
            settingsBuilder: _stubSettings,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final double from =
        kGameSectionTabOrder.indexOf(GameSection.library).toDouble();
    final double to =
        kGameSectionTabOrder.indexOf(GameSection.settings).toDouble();
    final TabController settingsTabs = shellController(tester);
    expect(settingsTabs.animation!.value, from,
        reason: '外壳页签应停在用户真正所在的「库」');

    gameSectionNotifier.value = GameSection.settings;
    await tester.pump();
    // 投影在帧末 animateTo；Ticker 第一帧只记起点，再推一帧才有中途值。
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));

    expect(settingsTabs.index, to.toInt());
    expect(settingsTabs.animation!.value, greaterThan(from));
    expect(settingsTabs.animation!.value, lessThan(to),
        reason: '切出来的那一刻指示条应正在滑动');

    await tester.pumpAndSettle();
    expect(settingsTabs.animation!.value, to);
  });
}
