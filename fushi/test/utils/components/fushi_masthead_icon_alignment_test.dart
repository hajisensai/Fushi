import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadGeometry;
import 'package:fushi/src/utils/components/fushi_page_title_metrics.dart'
    show FushiPageTitleMetrics;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 页头大字顶栏：返回键、右侧动作、主按钮、徽标的中线都落在页名（或顶替页名的
/// 一级切换）的字面中心上，展开 / 收缩过程 / 收起各进度、宽窄两档都成立
/// （2026-11-26 用户截图：二级页页名缩小后返回键高出一截，库页动作组与页名
/// 上下错开）。
void main() {
  /// 页名首行字面中心的全局 y（页名在绘制层缩放，按变换换算）。
  double titleInkY(WidgetTester tester, String title) {
    final RenderParagraph p = tester.renderObject(find.text(title));
    final double baseline = p.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final double font = p.text.style!.fontSize!;
    return MatrixUtils.transformPoint(
      p.getTransformTo(null),
      Offset(0, baseline - FushiPageTitleMetrics.inkCenterEm * font),
    ).dy;
  }

  Future<void> pumpHeader(
    WidgetTester tester, {
    required Size size,
    required String title,
    required double progress,
    bool titleInBody = false,
    Widget? subtitle,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: FushiMastheadHeader(
              title: title,
              progress: progress,
              titleInBody: titleInBody,
              titleReveal: 1,
              subtitle: subtitle,
              onBack: () {},
              actions: <Widget>[
                FushiIconButton(
                  tooltip: 'Search',
                  onTap: () {},
                  icon: FushiIcons.search,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final Size size in const <Size>[Size(402, 874), Size(1400, 900)]) {
    for (final double progress in const <double>[0, 0.5, 1]) {
      testWidgets('二级页 ${size.width.toInt()} 宽 p=$progress：返回键 / 动作与页名同一条中线', (
        WidgetTester tester,
      ) async {
        const String title = '字幕';
        await pumpHeader(
          tester,
          size: size,
          title: title,
          progress: progress,
          subtitle: const Text('Jimaku'),
        );
        final double ink = titleInkY(tester, title);
        final Rect back = tester.getRect(find.byType(FushiIconButton).first);
        final Rect search = tester.getRect(find.byTooltip('Search'));
        expect(back.center.dy, moreOrLessEquals(ink, epsilon: 0.5));
        expect(search.center.dy, moreOrLessEquals(ink, epsilon: 0.5));
      });
    }
  }

  testWidgets('二级页 titleInBody 裸图标行：页名字面中心在行中线上', (WidgetTester tester) async {
    const String title = '字幕';
    await pumpHeader(
      tester,
      size: const Size(402, 874),
      title: title,
      progress: 1,
      titleInBody: true,
    );
    final Rect back = tester.getRect(find.byType(FushiIconButton).first);
    expect(
      back.center.dy,
      moreOrLessEquals(titleInkY(tester, title), epsilon: 0.5),
    );
  });

  group('库页页头几何', () {
    // 版面尺寸取真实量级：页名一行、动作组 48、主按钮 48 / 56、徽标。
    FushiMastheadGeometry geometry({
      required bool compact,
      bool title = true,
      bool buttons = true,
    }) {
      final double font = compact ? 46 : 84;
      final double line = font * FushiPageTitleMetrics.titleLineHeight;
      final double baseline = font * 0.2;
      return FushiMastheadGeometry(
        compact: compact,
        width: compact ? 402 : 1400,
        leading: buttons ? const Size(48, 48) : Size.zero,
        title: title ? Size(font * 2, line) : Size.zero,
        titleBaseline: baseline,
        titleInkCenter: baseline + FushiPageTitleMetrics.inkCenterEm * font,
        titleLineHeight: line,
        badge: compact ? const Size(22, 22) : const Size(44, 44),
        switcher: title ? const Size(120, 30) : Size(font * 2, line),
        switchBaseline: baseline,
        actions: buttons ? const Size(150, 48) : Size.zero,
        primary: !buttons
            ? Size.zero
            : compact
            ? const Size(48, 48)
            : const Size(56, 56),
        secondary: Size.zero,
      );
    }

    for (final bool compact in const <bool>[true, false]) {
      for (final double p in const <double>[0, 0.5, 1]) {
        test('${compact ? '窄窗' : '宽窗'} p=$p：图标中线 = 页名字面中心', () {
          final FushiMastheadGeometry g = geometry(compact: compact);
          final double rowBottom = g.topPadAt(p) + g.firstRowHeightAt(p);
          final double titleBottom = rowBottom - g.titleLiftAt(p);
          final double ink = titleBottom - g.titleInkCenter * g.titleScaleAt(p);
          expect(g.actionCenterAt(p), moreOrLessEquals(ink, epsilon: 1e-6));
          final double badgeCenter =
              rowBottom -
              g.badgeLiftAt(p) -
              g.badge.height * g.badgeScaleAt(p) / 2;
          expect(badgeCenter, moreOrLessEquals(ink, epsilon: 1e-6));
          // 图标不越出第一行、不压过下边距。
          final double half = g.primary.height * g.primaryScaleAt(p) / 2;
          expect(
            g.actionCenterAt(p) + half,
            lessThanOrEqualTo(rowBottom - g.actionLiftAt(p) + 1e-6),
          );
          expect(
            g.actionCenterAt(p) - half,
            greaterThanOrEqualTo(g.topPadAt(p) - 1e-6),
          );
        });
      }
    }

    test('窄窗没有任何按钮的页（设置）：页名基线与有按钮的模块页同一条线', () {
      final FushiMastheadGeometry withButtons = geometry(compact: true);
      final FushiMastheadGeometry bare = geometry(
        compact: true,
        buttons: false,
      );
      for (final double p in const <double>[0, 0.5, 1]) {
        double baselineY(FushiMastheadGeometry g) =>
            g.topPadAt(p) +
            g.firstRowHeightAt(p) -
            g.titleLiftAt(p) -
            g.titleBaseline * g.titleScaleAt(p);
        expect(
          baselineY(bare),
          moreOrLessEquals(baselineY(withButtons), epsilon: 1e-6),
        );
      }
    });

    // Apple 导航栏的前导 / 动作 / 主按钮在栏行里垂直居中，不跟主标题的字面中心
    // （窄窗大标题在栏下另起一行；宽窗常驻工具栏同一行居中）。
    for (final bool compact in const <bool>[true, false]) {
      test('Apple ${compact ? '窄窗' : '宽窗'}：动作在导航栏行内垂直居中', () {
        final FushiMastheadGeometry g = FushiMastheadGeometry(
          compact: compact,
          stacked: compact,
          apple: true,
          width: compact ? 402 : 1400,
          leading: const Size(44, 44),
          title: const Size(120, 41),
          titleBaseline: 9,
          titleInkCenter: 21,
          titleLineHeight: 41,
          badge: Size.zero,
          switcher: Size.zero,
          switchBaseline: 0,
          actions: const Size(96, 44),
          primary: Size.zero,
          secondary: Size.zero,
        );
        final double row = g.appleActionRowExtent;
        for (final double p in const <double>[0, 0.5, 1]) {
          expect(
            g.actionCenterAt(p),
            moreOrLessEquals(g.topPadAt(p) + row / 2, epsilon: 1e-6),
          );
          expect(
            g.actionCenterAt(p) - g.actions.height / 2,
            greaterThanOrEqualTo(g.topPadAt(p) - 1e-6),
          );
        }
      });
    }

    test('窄窗一级切换顶替页名：图标中线 = 切换大字的字面中心', () {
      final FushiMastheadGeometry g = geometry(compact: true, title: false);
      for (final double p in const <double>[0, 0.5, 1]) {
        final double rowBottom = g.topPadAt(p) + g.firstRowHeightAt(p);
        final double s = g.switchScaleAt(p);
        final double switchBaselineY =
            rowBottom - g.switchBottomLiftAt(p) - g.switchBaseline * s;
        final double ink =
            switchBaselineY -
            (g.titleInkCenter - g.titleBaseline) * g.titleScaleAt(p);
        expect(g.actionCenterAt(p), moreOrLessEquals(ink, epsilon: 1e-6));
      }
    });
  });
}
