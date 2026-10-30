import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart'
    show gameSectionGroupOf;
import 'package:fushi/src/pages/implementations/home_game_page.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart'
    show LibrarySectionGroup;
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1719：游戏模块切到「捕获工作台」页签时，顶栏分段条几何突变（下沉/跳动）。
///
/// 根因（settings_shared.dart `estimateSegmentedStripWidth`）：Material
/// [SegmentedButton] 把每段铺成同一宽度——最宽段的固有宽（framework
/// `_calculateHorizontalChildSize`），分段条自然宽是「段数 × 最宽段」；旧估算却按
/// 各段自身宽求和，对段长不一的条系统性低估。捕获工作台页头的动作药丸把标题位挤
/// 窄后，恰落进「求和 ≤ 可用 < 等宽合计」区间：误判「摆得下」，框架把每段钳到比
/// 最长标签更窄，「捕获工作台」折成两行，分段条比兄弟页签高 8px——顶栏肉眼可见地
/// 下沉/跳动。（该页签其后已改短为「工作台」，TODO-2937 拍板；测试断言当前标签。）
///
/// 2026-08-24 起顶栏改走 MD3 tabs（[LibrarySectionTabs] / [FushiSectionTabBar]）：
/// 等宽布局连同上面那个估算一起退出顶栏，tab 各自按文案取宽，本 bug 的成因在结构上
/// 消失。两条不变式**原样保留**——它们守的是「切页签时顶栏不许动、标签不许折行」这个
/// 用户可见结果，与用什么控件实现无关，换控件后同样必须成立。
///
/// 守卫两条不变式（zh-CN，多档窗宽）：
/// 1. 各子区的一级分区导航 top 与 height 完全一致（切页签顶栏纹丝不动）；
///    「游戏库」组内子区的二级胶囊同样一致（2026-10-30 起两级页签）；
/// 2. 「工作台」（monitor 页签，现在二级胶囊里）标签永远单行（任何分支都不允许
///    把段挤到折行）。
Widget _stubDashboard(BuildContext _, VoidCallback __) => const SizedBox();

Widget _stubLibrary(
  BuildContext _,
  GalHookSessionController __,
  VoidCallback ___,
) => const Center(child: Icon(Icons.sports_esports_outlined));

/// 发现子区桩：FushiPageHeader.customTitle 包分段导航，不构建需要 provider 的
/// 发现正文（「设置」子区已于 2026-10-09 移除，几何守卫改由发现子区补位）。
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

  /// 一级（「游戏库 / 发现」两组）或二级（组内子区胶囊）分区导航。
  Finder strip({required bool secondary, bool skipOffstage = true}) =>
      find.byWidgetPredicate(
        (Widget w) =>
            w is FushiSectionTabBar<GameSection> && w.secondary == secondary,
        skipOffstage: skipOffstage,
      );

  /// 切到 [section]，返回（一级导航 rect，二级导航 rect 或 null）。
  Future<(Rect, Rect?)> stripRectsIn(
    WidgetTester tester,
    GameSection section,
    Key sectionKey,
  ) async {
    gameSectionNotifier.value = section;
    await tester.pump();
    await tester.pump();
    // 2026-10-06 起分区页签由外壳浮动工具栏统一画（ad8496b2b86，
    // [GameSectionTabsHostScope]）：子区页头里那一份在外壳下留空。2026-10-30
    // 起一级只放两组、组内子区在顶栏下方的二级胶囊里——全树（含 offstage 子区）
    // 一级恰好一份，二级至多一份，子区里不许再冒出自己的。
    expect(
      strip(secondary: false, skipOffstage: false),
      findsOneWidget,
      reason: '子区 $section 时全树应恰好一份一级分区导航（外壳那份）',
    );
    expect(
      find.descendant(
        of: find.byKey(sectionKey, skipOffstage: false),
        matching: find.byType(
          FushiSectionTabBar<GameSection>,
          skipOffstage: false,
        ),
      ),
      findsNothing,
      reason: '子区 $section 的页头不该再画自己的分区导航',
    );
    final bool inLibraryGroup =
        gameSectionGroupOf(section) == LibrarySectionGroup.library;
    final Finder sub = strip(secondary: true, skipOffstage: false);
    expect(
      sub,
      inLibraryGroup ? findsOneWidget : findsNothing,
      reason: '「游戏库」组内（首页 / 全部游戏 / 工作台 / 串流）才有二级胶囊',
    );
    final Rect top = tester.getRect(strip(secondary: false));
    if (!inLibraryGroup) return (top, null);
    // 「工作台」在二级胶囊里必须单行（高度 = 一行行高）。折行是 BUG-1719 的
    // 直接症状：段被钳到比最长标签窄。
    final Finder label = find.descendant(
      of: strip(secondary: true),
      matching: find.text('工作台'),
    );
    expect(label, findsOneWidget);
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      label,
    );
    final double lineHeight =
        (paragraph.text.style!.height ?? 1.0) * paragraph.text.style!.fontSize!;
    expect(
      paragraph.size.height,
      moreOrLessEquals(lineHeight, epsilon: 1.0),
      reason: '子区 $section 的「工作台」标签折行了（段宽被钳到比最长标签窄）',
    );
    return (top, tester.getRect(strip(secondary: true)));
  }

  for (final double width in <double>[1000, 1440, 2560]) {
    testWidgets('BUG-1719 顶栏分段条几何跨子区一致 @${width.toInt()}px', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
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
              discoverBuilder: _stubDiscover,
            ),
          ),
        ),
      );
      await tester.pump();

      final Map<GameSection, Key> sections = <GameSection, Key>{
        GameSection.library: HomeGamePage.libraryKey,
        GameSection.monitor: HomeGamePage.monitorKey,
        GameSection.importGames: HomeGamePage.importKey,
        GameSection.discover: HomeGamePage.discoverKey,
      };
      final Map<GameSection, (Rect, Rect?)> rects =
          <GameSection, (Rect, Rect?)>{
            for (final MapEntry<GameSection, Key> entry in sections.entries)
              entry.key: await stripRectsIn(tester, entry.key, entry.value),
          };

      final (Rect reference, Rect? subReference) = rects[GameSection.library]!;
      for (final MapEntry<GameSection, (Rect, Rect?)> entry in rects.entries) {
        expect(
          entry.value.$1.top,
          reference.top,
          reason: '子区 ${entry.key} 的一级分段条 top 与库页不一致（顶栏跳动）',
        );
        expect(
          entry.value.$1.height,
          reference.height,
          reason: '子区 ${entry.key} 的一级分段条高度与库页不一致（顶栏下沉）',
        );
        final Rect? sub = entry.value.$2;
        if (sub == null) continue;
        expect(
          sub.top,
          subReference!.top,
          reason: '子区 ${entry.key} 的二级胶囊 top 与库页不一致（跳动）',
        );
        expect(
          sub.height,
          subReference.height,
          reason: '子区 ${entry.key} 的二级胶囊高度与库页不一致（下沉）',
        );
      }
    });
  }
}
