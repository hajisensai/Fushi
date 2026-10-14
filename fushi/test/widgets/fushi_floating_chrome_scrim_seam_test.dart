import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';

/// BUG-3338：库页（视频 › 媒体服务器等）外壳页签胶囊正下方横穿一条水平细线。
///
/// 外壳那层遮罩在「下面还有页面自己的工具行」时本应停在薄纱不透明度、由嵌套层
/// 接着画，但 [FushiTopFadeScrim] 把渐隐段下限钳在 1 px：外层在接缝处多画一条
/// 0.72 → 0 的 1 px 渐变，正好叠在嵌套层顶端 0.72 的薄纱上，合成后比上下都深。
/// 接缝 y 不落在物理像素格上时（非整数 DPR / 小数高度），两块矩形的抗锯齿边各盖
/// 半个像素，又会合成出一条比薄纱浅的亮缝。
///
/// 判据用真实像素：暗色遮罩盖在均匀的白色内容上，从视口顶边往下不透明度只降不升，
/// 所以一列像素的亮度必须自上而下**单调不减**——接缝处的暗线、亮缝都会破坏单调。
void main() {
  // 页面底色（暗色主题）与内容色（亮色海报卡片）。
  const Color pageColor = Color(0xFF121212);
  const Color contentColor = Color(0xFFFFFFFF);
  // 小数高度：让接缝在 1.0 / 1.25 / 1.5 DPR 下都不落在物理像素格上。
  const double outerChromeHeight = 56.4;
  const double nestedChromeHeight = 48.3;

  Widget harness(FushiFloatingChromeController controller, Key boundaryKey) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: pageColor,
      ),
      home: RepaintBoundary(
        key: boundaryKey,
        child: Scaffold(
          body: FushiFloatingChromeScope(
            controller: controller,
            child: FushiFloatingChromeOverlay(
              chrome: const SizedBox(height: outerChromeHeight),
              child: NotificationListener<ScrollNotification>(
                onNotification: controller.handleScrollNotification,
                child: FushiFloatingChromeOverlay(
                  chrome: const SizedBox(height: nestedChromeHeight),
                  child: Builder(
                    builder: (BuildContext context) => ListView.builder(
                      padding: EdgeInsets.only(
                        top: FushiFloatingChromeInset.of(context),
                      ),
                      // 一整块连续的亮色内容：分成多张卡片时卡片之间的小数 y
                      // 边界自己就会抗锯齿出缝，混淆遮罩接缝的判据。
                      itemCount: 1,
                      itemBuilder: (BuildContext context, int i) =>
                          const ColoredBox(
                            color: contentColor,
                            child: SizedBox(height: 7200),
                          ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  for (final double dpr in <double>[1.0, 1.25, 1.5]) {
    testWidgets('BUG-3338 外层与嵌套遮罩接缝处没有暗线 / 亮缝（DPR $dpr）', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = Size(400 * dpr, 700 * dpr);
      addTearDown(tester.view.reset);
      final FushiFloatingChromeController controller =
          FushiFloatingChromeController();
      addTearDown(controller.dispose);
      const Key boundaryKey = ValueKey<String>('boundary');
      await tester.pumpWidget(harness(controller, boundaryKey));
      await tester.pumpAndSettle();

      // 往下滚一段再往回拉：工具区弹回，内容停在工具区底下（遮罩出现）。
      await tester.drag(find.byType(ListView), const Offset(0, -900));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(controller.visible, isTrue, reason: '前提：工具区显示');
      expect(controller.contentUnderTop, isTrue, reason: '前提：内容在工具区底下');
      expect(find.byType(FushiTopFadeScrim), findsNWidgets(2));

      final RenderRepaintBoundary boundary = tester
          .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
      final (Uint8List rgba, int width, int height) = (await tester.runAsync(
        () async {
          final ui.Image image = await boundary.toImage(pixelRatio: dpr);
          final ByteData raw = (await image.toByteData())!;
          final String? dir = Platform.environment['FUSHI_SEAM_PNG_DIR'];
          if (dir != null) {
            final ByteData png = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            File(
              '$dir/scrim_seam_dpr_$dpr.png',
            ).writeAsBytesSync(png.buffer.asUint8List());
          }
          final (Uint8List, int, int) result = (
            raw.buffer.asUint8List(),
            image.width,
            image.height,
          );
          image.dispose();
          return result;
        },
      ))!;

      // 扫屏幕中线一列：从视口顶边扫到嵌套工具行下沿再往下渐隐段之后。
      final int x = width ~/ 2;
      final int bottom =
          ((outerChromeHeight +
                      kFushiFloatingChromeGap +
                      nestedChromeHeight +
                      kFushiTopFadeExtent +
                      8) *
                  dpr)
              .ceil()
              .clamp(0, height);
      final List<int> luma = <int>[
        for (int y = 0; y < bottom; y++) rgba[(y * width + x) * 4 + 1],
      ];
      // 渐变抖动最多 ±1 级；接缝暗线 / 亮缝是十几到几十级的突变。
      const int tolerance = 2;
      for (int y = 1; y < luma.length; y++) {
        expect(
          luma[y],
          greaterThanOrEqualTo(luma[y - 1] - tolerance),
          reason:
              '第 $y 行物理像素比上一行暗（${luma[y - 1]} → ${luma[y]}）：'
              '遮罩接缝处出现横线。整列：$luma',
        );
      }
      // 自检：这一列确实扫过了「薄纱 → 渐隐到内容原色」的全程。
      expect(luma.first, lessThan(40), reason: '顶边是页面底色');
      expect(luma.last, greaterThan(240), reason: '渐隐段之后是内容原色');
    });
  }
}
