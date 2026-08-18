import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/pages/implementations/home_game_page.dart';
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
/// 守卫两条不变式（zh-CN，多档窗宽）：
/// 1. 六个子区的分段条 top 与 height 完全一致（切页签顶栏纹丝不动）；
/// 2. 「工作台」（monitor 页签）标签永远单行（任何分支都不允许把段挤到折行）。
Widget _stubDashboard(BuildContext _, VoidCallback __) => const SizedBox();

Widget _stubLibrary(
  BuildContext _,
  GalHookSessionController __,
  VoidCallback ___,
) =>
    const Center(child: Icon(Icons.sports_esports_outlined));

/// 镜像生产 [ModuleSettingsView] 的顶栏形状（FushiPageHeader.customTitle 包分段
/// 导航），但不构建需要 provider 的设置正文。
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

  Future<Rect> stripRectIn(
    WidgetTester tester,
    GameSection section,
    Key sectionKey,
  ) async {
    gameSectionNotifier.value = section;
    await tester.pump();
    await tester.pump();
    final Finder f = find.descendant(
      of: find.byKey(sectionKey),
      matching: find.byType(SegmentedButton<GameSection>),
    );
    expect(f, findsOneWidget, reason: '子区 $section 应有分段条');
    // 「工作台」在该子区的分段条里必须单行（高度 = 一行行高）。折行是
    // BUG-1719 的直接症状：段被钳到比最长标签窄。
    final Finder label = find.descendant(
      of: f,
      matching: find.text('工作台'),
    );
    expect(label, findsOneWidget);
    final RenderParagraph paragraph =
        tester.renderObject<RenderParagraph>(label);
    final double lineHeight =
        (paragraph.text.style!.height ?? 1.0) * paragraph.text.style!.fontSize!;
    expect(
      paragraph.size.height,
      moreOrLessEquals(lineHeight, epsilon: 1.0),
      reason: '子区 $section 的「工作台」标签折行了（段宽被钳到比最长标签窄）',
    );
    return tester.getRect(f);
  }

  for (final double width in <double>[1000, 1440, 2560]) {
    testWidgets('BUG-1719 顶栏分段条几何跨六个子区一致 @${width.toInt()}px',
        (WidgetTester tester) async {
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
              settingsBuilder: _stubSettings,
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
        GameSection.settings: HomeGamePage.settingsKey,
      };
      final Map<GameSection, Rect> rects = <GameSection, Rect>{
        for (final MapEntry<GameSection, Key> entry in sections.entries)
          entry.key: await stripRectIn(tester, entry.key, entry.value),
      };

      final Rect reference = rects[GameSection.library]!;
      for (final MapEntry<GameSection, Rect> entry in rects.entries) {
        expect(
          entry.value.top,
          reference.top,
          reason: '子区 ${entry.key} 的分段条 top 与库页不一致（顶栏跳动）',
        );
        expect(
          entry.value.height,
          reference.height,
          reason: '子区 ${entry.key} 的分段条高度与库页不一致（顶栏下沉）',
        );
      }
    });
  }
}
