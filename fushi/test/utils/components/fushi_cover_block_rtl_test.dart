import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:fushi/src/utils/components/fushi_bleed_title.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart';
import 'package:material_ui/material_ui.dart';

// 色块（[FushiCoverBlock] / [FushiPosterBlock]）在 RTL（阿拉伯语等）下整块水平
// 镜像：封面换到另一侧、文字区让到对面、大字水印从右起、悬停横移方向翻转。
// 之前封面 / 文字区按绝对坐标摆、水印写死 left + LTR，RTL 下文字贴向封面侧。
void main() {
  const ValueKey<String> coverKey = ValueKey<String>('cover');
  const ValueKey<String> metaKey = ValueKey<String>('meta');
  const ValueKey<String> blockKey = ValueKey<String>('block');
  const String title = 'Watermark title';

  Future<void> pumpBlock(
    WidgetTester tester, {
    required TextDirection direction,
    required FushiCoverBlockArt art,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: blockKey,
                width: 480,
                height: 220,
                child: FushiCoverBlock(
                  title: title,
                  art: art,
                  metaKey: metaKey,
                  covers: const <Widget>[
                    ColoredBox(key: coverKey, color: Colors.teal),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final FushiCoverBlockArt art in <FushiCoverBlockArt>[
    FushiCoverBlockArt.box,
    FushiCoverBlockArt.square,
    FushiCoverBlockArt.portrait,
  ]) {
    testWidgets('$art：RTL 下封面与文字区左右对调（整块镜像）', (WidgetTester tester) async {
      await pumpBlock(tester, direction: TextDirection.ltr, art: art);
      final Rect block = tester.getRect(find.byKey(blockKey));
      final Rect ltrCover = tester.getRect(find.byKey(coverKey));
      final Rect ltrText = tester.getRect(find.byKey(metaKey));

      await pumpBlock(tester, direction: TextDirection.rtl, art: art);
      final Rect rtlCover = tester.getRect(find.byKey(coverKey));
      final Rect rtlText = tester.getRect(find.byKey(metaKey));

      // 文字区精确镜像（以色块中线为轴）。
      expect(rtlText.left, moreOrLessEquals(block.right - ltrText.right));
      expect(rtlText.right, moreOrLessEquals(block.right - ltrText.left));
      expect(rtlText.top, moreOrLessEquals(ltrText.top));
      // 封面换到文字区的另一侧：LTR 在哪边，RTL 就在对面。
      final bool ltrCoverStart = ltrCover.center.dx < ltrText.center.dx;
      final bool rtlCoverStart = rtlCover.center.dx > rtlText.center.dx;
      expect(rtlCoverStart, ltrCoverStart);
      expect(
        rtlCover.center.dx,
        moreOrLessEquals(block.right - ltrCover.center.dx, epsilon: 1),
      );
    });
  }

  /// 画出血大字的那块 CustomPaint（水印是画出来的，不是 Text）。
  Finder watermarkPaint(String text) => find.byWidgetPredicate(
    (Widget w) =>
        w is CustomPaint &&
        w.painter is FushiBleedTitlePainter &&
        (w.painter! as FushiBleedTitlePainter).text == text,
  );

  FushiBleedTitlePainter watermarkPainter(WidgetTester tester, String text) =>
      tester.widget<CustomPaint>(watermarkPaint(text)).painter!
          as FushiBleedTitlePainter;

  /// 水印大字在屏幕上的实际外框（含当前悬停横移）。
  Rect watermarkRect(WidgetTester tester, String text) {
    final Rect canvas = tester.getRect(watermarkPaint(text));
    return watermarkPainter(
      tester,
      text,
    ).titleRect(canvas.size).shift(canvas.topLeft);
  }

  /// 悬停前后水印在屏幕上的横向位移（屏幕坐标，右为正）。
  Future<double> hoverShift(WidgetTester tester, TextDirection dir) async {
    await pumpBlock(tester, direction: dir, art: FushiCoverBlockArt.box);
    final double rest = watermarkRect(tester, title).left;
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(blockKey)));
    // 首帧只给弹簧定起点，再推一段时间让它走到位。
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    final double shift = watermarkRect(tester, title).left - rest;
    expect(shift.abs(), greaterThan(0.5));
    return shift;
  }

  testWidgets('LTR 悬停：水印往左（起始边）横移', (WidgetTester tester) async {
    expect(await hoverShift(tester, TextDirection.ltr), lessThan(0));
  });

  testWidgets('RTL 悬停：水印往右（起始边）横移', (WidgetTester tester) async {
    expect(await hoverShift(tester, TextDirection.rtl), greaterThan(0));
  });

  testWidgets('RTL 下水印以阅读方向排版、贴右边起', (WidgetTester tester) async {
    await pumpBlock(
      tester,
      direction: TextDirection.ltr,
      art: FushiCoverBlockArt.portrait,
    );
    final Rect ltr = watermarkRect(tester, title);
    await pumpBlock(
      tester,
      direction: TextDirection.rtl,
      art: FushiCoverBlockArt.portrait,
    );
    expect(watermarkPainter(tester, title).direction, TextDirection.rtl);
    final Rect rtl = watermarkRect(tester, title);
    final Rect block = tester.getRect(find.byKey(blockKey));
    expect(rtl.right, moreOrLessEquals(block.right - ltr.left));
  });

  testWidgets('出血大字是画出来的：标题只有一个 Text、语义只读一遍', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await pumpBlock(
      tester,
      direction: TextDirection.ltr,
      art: FushiCoverBlockArt.portrait,
    );
    expect(watermarkPaint(title), findsOneWidget);
    expect(find.text(title), findsOneWidget);
    expect(find.bySemanticsLabel(title), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('海报色块：RTL 下水印贴右边起', (WidgetTester tester) async {
    Future<Rect> watermark(TextDirection dir) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: dir,
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  key: blockKey,
                  width: 400,
                  height: 200,
                  child: Builder(
                    builder: (BuildContext context) => FushiPosterBlock(
                      watermark: 'WM',
                      colors: fushiPosterColors(context, 120),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('WM'), findsNothing);
      return watermarkRect(tester, 'WM');
    }

    final Rect ltr = await watermark(TextDirection.ltr);
    final Rect rtl = await watermark(TextDirection.rtl);
    final Rect block = tester.getRect(find.byKey(blockKey));
    expect(rtl.right, moreOrLessEquals(block.right - ltr.left));
  });
}
