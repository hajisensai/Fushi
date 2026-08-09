import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';

/// BUG-1299：[PortraitCoverImage] 槽向自适应行为（此前该组件零测试覆盖）。
///
/// 四象限契约：
/// - 竖槽 + 竖图（海报 2:3）→ `BoxFit.cover` 铺满，无模糊垫底；
/// - 竖槽 + 横图（16:9 截帧）→ 模糊垫底 + 前景 `BoxFit.contain`；
/// - 横槽（[PortraitCoverImage.landscapeSlot]）+ 横图 → cover 铺满，无垫底；
/// - 横槽 + 竖图 → 垫底 + contain（合集详情 16:9 缩略图里的刮削海报）。
void main() {
  const Key fgKey = Key('portrait_cover_foreground');

  /// 生成 [width]×[height] 的纯色 PNG（真实可解码，供 [MemoryImage] 用）。
  Future<Uint8List> pngBytes(int width, int height) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF3355FF),
    );
    final ui.Image image = await recorder.endRecording().toImage(width, height);
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// 装配组件并等真实解码完成（[ImageStream] 尺寸回调驱动 rebuild）。
  Future<void> pumpCover(
    WidgetTester tester, {
    required int imageWidth,
    required int imageHeight,
    required bool landscapeSlot,
  }) async {
    final Uint8List? bytes = await tester.runAsync<Uint8List>(
      () => pngBytes(imageWidth, imageHeight),
    );
    final MemoryImage provider = MemoryImage(bytes!);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: landscapeSlot ? 96 : 100,
            height: landscapeSlot ? 54 : 150,
            child: PortraitCoverImage(
              image: provider,
              imageKey: fgKey,
              landscapeSlot: landscapeSlot,
            ),
          ),
        ),
      ),
    );
    // 真实异步解码在 runAsync 区里完成，随后 pump 应用尺寸回调的 setState。
    await tester.runAsync<void>(
      () => precacheImage(provider, tester.element(find.byKey(fgKey))),
    );
    await tester.pump();
  }

  BoxFit? foregroundFit(WidgetTester tester) =>
      tester.widget<Image>(find.byKey(fgKey)).fit;

  testWidgets('竖槽 + 竖图：cover 铺满，无模糊垫底', (WidgetTester tester) async {
    await pumpCover(tester,
        imageWidth: 20, imageHeight: 30, landscapeSlot: false);
    expect(foregroundFit(tester), BoxFit.cover);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('竖槽 + 横图：模糊垫底 + contain 前景', (WidgetTester tester) async {
    await pumpCover(tester,
        imageWidth: 32, imageHeight: 18, landscapeSlot: false);
    expect(foregroundFit(tester), BoxFit.contain);
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('横槽 + 横图：cover 铺满，无模糊垫底', (WidgetTester tester) async {
    await pumpCover(tester,
        imageWidth: 32, imageHeight: 18, landscapeSlot: true);
    expect(foregroundFit(tester), BoxFit.cover);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('横槽 + 竖图（BUG-1299 主诉）：模糊垫底 + contain，不再裁成中间一条',
      (WidgetTester tester) async {
    await pumpCover(tester,
        imageWidth: 20, imageHeight: 30, landscapeSlot: true);
    expect(foregroundFit(tester), BoxFit.contain);
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('方图两种槽向都不合槽：均走垫底（cover 会裁掉四成以上）', (WidgetTester tester) async {
    await pumpCover(tester,
        imageWidth: 24, imageHeight: 24, landscapeSlot: false);
    expect(foregroundFit(tester), BoxFit.contain);
    await pumpCover(tester,
        imageWidth: 24, imageHeight: 24, landscapeSlot: true);
    expect(foregroundFit(tester), BoxFit.contain);
  });
}
