// BUG-2977：M3E 浮动页头的标题胶囊下半截被裁（底边一条直线、下圆角消失），
// 返回圆底部的投影被切平。
//
// 根因：FushiPageChromeCapsule 外层 minHeight 56 + 标题胶囊竖向 padding 6×2 +
// 内层又一层 minHeight 56 → 标题胶囊实高 68；而 FushiAppBar 的工具栏只有 56，
// AppBar 默认用 Clip.hardEdge 把工具栏裁在 56 里——多出的 12 被一刀切掉。
// 守住：胶囊恒为 kFushiPageChromeExtent、完整落在 AppBar 内、栏不裁投影。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show kFushiFloatingCapsuleScale;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';

/// Material 下浮动胶囊整体按 [kFushiFloatingCapsuleScale] 缩：胶囊在屏幕上
/// （带缩放变换的全局坐标）的高度。
const double _kScaledChromeExtent =
    kFushiPageChromeExtent * kFushiFloatingCapsuleScale;

/// [finder] 在屏幕上的高度（走 localToGlobal，含缩放变换；`getSize` 只给缩放
/// 前的局部尺寸）。
double _screenHeight(WidgetTester tester, Finder finder) =>
    tester.getRect(finder).height;

void main() {
  Future<void> pumpBar(WidgetTester tester, Widget title) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          appBar: FushiAppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {},
            ),
            title: title,
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
  }

  // 2026-11-15 所有者「二级页还是胶囊」：FushiAppBar 的 M3E 分支改成二级页
  // 现行页头的一行（返回裸图标 + 页头大字页名 + 平铺裸图标动作），不再装
  // 标题胶囊 / 返回圆。BUG-2977 守的「标题不被工具栏裁掉」照旧守：页名完整
  // 落在顶栏内、栏不裁。
  testWidgets('BUG-2977 顶栏不再装标题胶囊 / 返回圆，页名完整落在顶栏内', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, const Text('搜索字幕'));
    expect(find.byType(FushiPageChromeTitle), findsNothing);
    expect(find.byType(FushiPageChromeCircle), findsNothing);
    final Rect titleRect = tester.getRect(find.text('搜索字幕'));
    final Rect barRect = tester.getRect(find.byType(AppBar));
    expect(titleRect.top, greaterThanOrEqualTo(barRect.top));
    expect(titleRect.bottom, lessThanOrEqualTo(barRect.bottom));
    final Rect backRect = tester.getRect(find.byType(IconButton));
    expect(backRect.bottom, lessThanOrEqualTo(barRect.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('BUG-2977 调用方大行高撑不出顶栏；副标题胶囊本体仍定高', (WidgetTester tester) async {
    await pumpBar(
      tester,
      const Text('作品资料', style: TextStyle(fontSize: 22, height: 2.4)),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.text('作品资料')).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom + 0.5),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: FushiPageChromeTitle(
              title: Text('统计中心'),
              subtitle: Text('副标题'),
            ),
          ),
        ),
      ),
    );
    expect(
      _screenHeight(tester, find.byType(FushiPageChromeTitle)),
      moreOrLessEquals(_kScaledChromeExtent),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('BUG-2977 悬浮顶栏不再把工具栏裁在 toolbarHeight 里', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, const Text('自定义主题'));
    // 深度优先的第一个 ClipRect 就是 AppBar 包工具栏的那层。
    final ClipRect toolbarClip = tester
        .widgetList<ClipRect>(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(ClipRect),
          ),
        )
        .first;
    expect(toolbarClip.clipBehavior, Clip.none);
  });
  // HBK-AUDIT-007：标题 + 副标题都跟随系统字体缩放。56 高胶囊的文字预算 54；
  // titleLarge 22 / labelMedium 12 两行需要 (22×1.2 + 12×1.25)×s = 41.4×s，
  // 阈值 s ≈ 1.304：1.3 倍（53.82）仍放得下，1.4 倍（57.96）起放不下。胶囊不能
  // 长高（BUG-2977），放不下时副标题降级为 tooltip；标题封顶到单行不溢出。
  // （HBK-AUDIT-032：此前把 1.3 倍当成放不下，是测试期望错误。）
  for (final double scale in <double>[1.0, 1.3, 1.4, 2.0]) {
    testWidgets('HBK-AUDIT-007 字体 ${scale}x：双行标题胶囊定高且不溢出', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FushiPageChromeTitle(
                      title: Text('统计中心'),
                      subtitle: Text('当前档案：默认'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        _screenHeight(tester, find.byType(FushiPageChromeTitle)),
        moreOrLessEquals(_kScaledChromeExtent),
      );
      expect(find.text('统计中心'), findsOneWidget);
      if (scale <= 1.3) {
        expect(find.text('当前档案：默认'), findsOneWidget);
      } else {
        expect(find.text('当前档案：默认'), findsNothing);
        final Tooltip tooltip = tester.widget<Tooltip>(
          find.descendant(
            of: find.byType(FushiPageChromeTitle),
            matching: find.byType(Tooltip),
          ),
        );
        expect(tooltip.message, '当前档案：默认');
      }
    });

    testWidgets('HBK-AUDIT-007 字体 ${scale}x：AppBar 页名封顶在栏内不溢出', (
      WidgetTester tester,
    ) async {
      tester.view.padding = const FakeViewPadding(top: 72);
      addTearDown(tester.view.resetPadding);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            appBar: FushiAppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {},
              ),
              title: const Text('AI 下视频'),
            ),
            body: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(FushiPageChromeTitle), findsNothing);
      final Rect titleRect = tester.getRect(find.text('AI 下视频'));
      final Rect barRect = tester.getRect(find.byType(AppBar));
      // 安全区（状态栏）之下、栏底之上。
      expect(titleRect.top, greaterThanOrEqualTo(barRect.top + 24));
      expect(titleRect.bottom, lessThanOrEqualTo(barRect.bottom + 0.5));
    });
  }

  test('HBK-AUDIT-007 副标题容量判据：1.0 / 1.3 放得下、1.4 放不下', () {
    expect(
      FushiPageChromeTitle.subtitleFits(
        textScaler: TextScaler.noScaling,
        titleFontSize: 22,
        subtitleFontSize: 12,
      ),
      isTrue,
    );
    // 1.3 倍：(26.4 + 15) × 1.3 = 53.82 ≤ 54，恰好放得下。
    expect(
      FushiPageChromeTitle.subtitleFits(
        textScaler: const TextScaler.linear(1.3),
        titleFontSize: 22,
        subtitleFontSize: 12,
      ),
      isTrue,
    );
    // 1.4 倍：57.96 > 54，放不下。
    expect(
      FushiPageChromeTitle.subtitleFits(
        textScaler: const TextScaler.linear(1.4),
        titleFontSize: 22,
        subtitleFontSize: 12,
      ),
      isFalse,
    );
    expect(
      FushiPageChromeTitle.maxTitleScaleFactor(22) * 22 * 1.2,
      lessThanOrEqualTo(kFushiPageChromeExtent),
    );
  });
}
