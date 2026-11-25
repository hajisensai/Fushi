import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/pages/implementations/home_game_page.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:fushi/src/pages/implementations/game_shared.dart'
    show gameSectionGroupOf;
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadSwitch;
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

/// 「导入」子区常驻来源列表的桩：绕开真 [MediaSourcesView] 对 appProvider 的依赖。
Widget _stubSources(BuildContext _, GlobalKey<MediaSourcesViewState> __) =>
    const Text('game-sources');

Widget _stubLibrary(
  BuildContext _,
  GalHookSessionController __,
  VoidCallback ___,
) => const SizedBox();

/// 发现子区桩：只带页头分段导航主位，不构建需要 provider 的发现正文。
Widget _stubDiscover(BuildContext _, Widget navigation) =>
    Column(children: <Widget>[FushiPageHeader.customTitle(title: navigation)]);

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

  /// 外壳一级分区切换（PR #3397 页头大字顶栏：大字「游戏库 / 发现」）。
  Finder shellSwitch() {
    // 2026-10-06 起分区页签由外壳浮动工具栏统一画一份（ad8496b2b86，
    // [GameSectionTabsHostScope]），子区页头里那份留空：全树（含 offstage 子区）
    // 一级恰好一份。2026-10-30 起一级只放「游戏库 / 发现」两组，组内子区在
    // 二级页签里。
    final Finder bar = find.byType(
      FushiMastheadSwitch<GameSection>,
      skipOffstage: false,
    );
    expect(bar, findsOneWidget, reason: '游戏外壳应恰好一份一级分区页签');
    return bar;
  }

  /// 一级切换里第 [index] 段文字此刻画出来的颜色。
  Color labelColor(WidgetTester tester, int index) {
    final FushiMastheadSwitch<GameSection> bar = tester.widget(shellSwitch());
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: shellSwitch(),
        matching: find.text(bar.tabs[index].label),
      ),
    );
    return paragraph.text.style!.color!;
  }

  // 页头大字里选中态是字色（选中 strong、其余淡墨），没有滑动指示条；守的仍是
  // 「切子区时页签有过渡、不是原地跳变」这个用户可见结果：目标段的字色从未选中
  // 渐变到选中，旧段反向渐变。
  testWidgets('库 → 发现：外壳页签从「库」过渡到「发现」，而不是原地落位', (WidgetTester tester) async {
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
            sourcesBuilder: _stubSources,
            discoverBuilder: _stubDiscover,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 一级：「游戏库」组（库所在）是第 0 段，「发现」是第 1 段。
    final FushiMastheadSwitch<GameSection> before = tester.widget(
      shellSwitch(),
    );
    expect(
      gameSectionGroupOf(before.selected),
      gameSectionGroupOf(GameSection.library),
      reason: '外壳页签应停在用户真正所在的「游戏库」组',
    );
    final Element element = tester.element(shellSwitch());
    final Color fromSelected = labelColor(tester, 0);
    final Color fromIdle = labelColor(tester, 1);
    expect(fromSelected, isNot(fromIdle));

    gameSectionNotifier.value = GameSection.discover;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final FushiMastheadSwitch<GameSection> after = tester.widget(shellSwitch());
    expect(after.selected, GameSection.discover);
    expect(
      tester.element(shellSwitch()),
      same(element),
      reason: '外壳只画一份页签，切子区不重新挂一份',
    );
    final Color midTarget = labelColor(tester, 1);
    expect(midTarget, isNot(fromIdle), reason: '「发现」应已开始变成选中色');
    expect(midTarget, isNot(fromSelected), reason: '切出来的那一刻应正在过渡，不是直接落位');

    await tester.pumpAndSettle();
    expect(labelColor(tester, 1), fromSelected);
    expect(labelColor(tester, 0), fromIdle);
  });
}
