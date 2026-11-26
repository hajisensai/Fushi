// 2026-11-25 用户 iPhone 截图（Cupertino，库页「音乐」，深色 / 浅色都有）：内容滚到
// 栏下面后，状态栏下沿 = 顶栏行上沿那一横有一条分界线——状态栏区与下面的顶栏区
// 是两种底。iOS 27 导航栏 scroll edge 应是从窗口顶（含状态栏）到最深一行吸顶工具
// 下沿的**一整块**模糊 + 压暗底（[FushiAppleScrollEdgeBackdrop]）。
//
// 根因有三处，这里各钉一处：
// 1. 库页 overlay（`FushiFloatingChromeOverlay(masthead: true)`）的底板向上铺进了
//    状态栏，内容层却没有（只在桌面自绘标题行时铺）：状态栏那段的模糊只能糊到纯
//    页面底色，下面一段糊的是内容。判据：底与滚动视口都从窗口顶（y = 0）起。
// 2. 外壳（home_page `_withAppleTopEdge`）在内容区顶部（= 状态栏下沿）又叠一条
//    不透明页面底色的 soft 带，横在 overlay 自己的底中间。判据：
//    [homeTabOwnsTopScrollEdge] 对挂 overlay 的 tab 为真。
// 3. 二级页大标题导航栏（`FushiMastheadFrame` Apple 分支）把栏行排在 Column 里，
//    正文与底只排在栏下面，状态栏 + 栏行是纯页面底色。判据同 1。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:material_ui/material_ui.dart';

const double _statusBar = 47;

ThemeData _appleTheme(Brightness brightness) => ThemeData(
  brightness: brightness,
  extensions: const <ThemeExtension<dynamic>>[
    FushiGlassTheme(FushiGlassMaterial.standard, glassDesign: true),
  ],
);

/// 手机竖屏：MediaQuery 带状态栏 padding（与真机同），外壳照 home_page 移动布局
/// 包 `ShellStageTopBleed` + `SafeArea`。
Widget _phone({
  required Widget child,
  Brightness brightness = Brightness.dark,
}) {
  return MaterialApp(
    theme: _appleTheme(brightness),
    home: Builder(
      builder: (BuildContext context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: _statusBar),
          viewPadding: const EdgeInsets.only(top: _statusBar),
        ),
        child: child,
      ),
    ),
  );
}

Widget _list() => Builder(
  builder: (BuildContext context) => ListView.builder(
    padding: EdgeInsets.only(
      top:
          FushiFloatingChromeInset.of(context) +
          MediaQuery.paddingOf(context).top,
    ),
    itemCount: 60,
    itemBuilder: (BuildContext context, int i) =>
        SizedBox(height: 80, child: Text('row $i')),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final Brightness brightness in Brightness.values) {
    testWidgets('库页 overlay：滚动后 scroll edge 底与内容都从窗口顶起（$brightness）', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final FushiFloatingChromeController controller =
          FushiFloatingChromeController();
      addTearDown(controller.dispose);
      final FushiShellActionsSlot slot = FushiShellActionsSlot();
      addTearDown(slot.dispose);
      await tester.pumpWidget(
        _phone(
          brightness: brightness,
          child: Scaffold(
            body: ShellStageTopBleed(
              top: _statusBar,
              child: SafeArea(
                bottom: false,
                child: FushiShellTitleScope(
                  title: 'Music',
                  child: FushiFloatingChromeScope(
                    controller: controller,
                    child: FushiFloatingChromeOverlay(
                      masthead: true,
                      chrome: FushiFloatingChromeBar(
                        tabs: const SizedBox.shrink(),
                        slot: slot,
                      ),
                      child: _list(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();

      final Finder backdrop = find.byType(FushiAppleScrollEdgeBackdrop);
      expect(backdrop, findsOneWidget, reason: '前提：滚动后底已淡入');
      expect(
        tester.getTopLeft(backdrop).dy,
        0,
        reason: 'scroll edge 底必须从窗口顶（含状态栏）起画，只有一块',
      );
      expect(
        tester.getTopLeft(find.byType(Scrollable)).dy,
        0,
        reason:
            '内容视口必须铺到窗口顶：状态栏底下没有内容，那一段的模糊只糊到纯'
            '页面底色，与下面糊内容的一段在状态栏下沿接成分界线',
      );
    });
  }

  test('挂 FushiFloatingChromeOverlay 的 tab 自己画顶部 scroll edge，外壳不叠带', () {
    for (final HomeTab tab in <HomeTab>[
      HomeTab.books,
      HomeTab.manga,
      HomeTab.video,
      HomeTab.music,
      HomeTab.games,
      HomeTab.browse,
      HomeTab.web,
      HomeTab.settings,
    ]) {
      for (final bool redesign in <bool>[true, false]) {
        expect(
          homeTabOwnsTopScrollEdge(tab, redesign: redesign),
          isTrue,
          reason: '$tab redesign=$redesign',
        );
      }
    }
    // 首页只在重设计外壳（页头大字 overlay）下自带。
    expect(homeTabOwnsTopScrollEdge(HomeTab.home, redesign: true), isTrue);
    expect(homeTabOwnsTopScrollEdge(HomeTab.home, redesign: false), isFalse);
    expect(homeTabOwnsTopScrollEdge(HomeTab.srs, redesign: true), isFalse);
  });

  testWidgets('二级页大标题导航栏：滚到大标题收起后底与正文都从窗口顶起', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _phone(
        child: Scaffold(
          body: FushiMastheadFrame(
            title: 'Detail',
            implyBack: false,
            body: _list(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    final Finder backdrop = find.byType(FushiAppleScrollEdgeBackdrop);
    expect(backdrop, findsOneWidget);
    expect(
      tester.getTopLeft(backdrop).dy,
      0,
      reason: '导航栏 scroll edge 底必须从窗口顶（含状态栏与栏行）起画',
    );
    final FushiAppleScrollEdgeBackdrop widget = tester
        .widget<FushiAppleScrollEdgeBackdrop>(backdrop);
    expect(widget.progress, greaterThan(0), reason: '前提：底已显示');
    expect(
      widget.height,
      greaterThan(_statusBar + kToolbarHeight - 0.5),
      reason: '底至少盖住状态栏 + 栏行',
    );
    expect(
      tester.getTopLeft(find.byType(Scrollable)).dy,
      0,
      reason: '正文视口必须铺到窗口顶，栏行与状态栏背后才有内容可糊',
    );
  });
}
