import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/prebaked_blur_image.dart';

/// [PrebakedBlurImage]：「继续游戏」卡 key art 背景的预烘焙模糊。
///
/// 原始失败路径（协作者 2026-10-05 Windows 录屏）：卡背景是渲染期
/// `ImageFiltered(blur(22))`，每帧重算卷积，滚动 / 悬停缩放时游戏库只有 15–20 fps。
/// 这里钉两件事：① 子树里不再有任何渲染期滤镜（每帧只画一张小纹理）；
/// ② 换实现后画面与原 `ImageFiltered + Image(fit: cover)` 像素级接近。
void main() {
  const Size cardSize = Size(380, 214);

  /// 竖版「封面」：高对比色块 + 细条纹，模糊前后差异明显，能暴露 sigma / fit /
  /// 对齐任一项算错。
  Future<Uint8List> coverPng() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    const Size size = Size(300, 400);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFF4E9D8),
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 150, 220),
      Paint()..color = const Color(0xFFD03050),
    );
    canvas.drawCircle(
      const Offset(220, 260),
      70,
      Paint()..color = const Color(0xFF2050C0),
    );
    for (double x = 0; x < size.width; x += 12) {
      canvas.drawRect(
        Rect.fromLTWH(x, 330, 6, 70),
        Paint()..color = const Color(0xFF101010),
      );
    }
    final ui.Image image = await recorder.endRecording().toImage(300, 400);
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    return bytes!.buffer.asUint8List();
  }

  Future<Uint8List> capture(WidgetTester tester, GlobalKey key) async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage();
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    return data!.buffer.asUint8List();
  }

  Widget host(GlobalKey key, Widget child) => Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(
        key: key,
        child: SizedBox.fromSize(
          size: cardSize,
          child: ColoredBox(color: const Color(0xFF888888), child: child),
        ),
      ),
    ),
  );

  Future<void> expectMatchesImageFiltered(
    WidgetTester tester, {
    required double sigma,
    ColorFilter? colorFilter,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Uint8List png = (await tester.runAsync(coverPng))!;
    final MemoryImage provider = MemoryImage(png);

    // 对照组：#1971 原实现（ImageFiltered 包 cover 铺满的图）。
    final GlobalKey refKey = GlobalKey();
    await tester.pumpWidget(
      host(
        refKey,
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: colorFilter == null
              ? Image(image: provider, fit: BoxFit.cover)
              : ColorFiltered(
                  colorFilter: colorFilter,
                  child: Image(image: provider, fit: BoxFit.cover),
                ),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(provider, tester.element(find.byType(Image))),
    );
    await tester.pump();
    final Uint8List reference = (await tester.runAsync(
      () => capture(tester, refKey),
    ))!;

    final GlobalKey bakedKey = GlobalKey();
    await tester.pumpWidget(
      host(
        bakedKey,
        PrebakedBlurImage(
          image: provider,
          sigma: sigma,
          colorFilter: colorFilter,
        ),
      ),
    );
    // 解码 + 烘焙（Picture.toImage）都是真异步，交给 runAsync 跑完。
    for (int i = 0; i < 10 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsOneWidget, reason: '烘焙结果应已上屏');
    expect(
      find.descendant(
        of: find.byType(PrebakedBlurImage),
        matching: find.byType(ImageFiltered),
      ),
      findsNothing,
      reason: '每帧重算的渲染期模糊正是掉帧根因，不能再出现',
    );
    final RawImage raw = tester.widget<RawImage>(find.byType(RawImage));
    expect(
      raw.image!.width * raw.image!.height,
      lessThan(cardSize.width * cardSize.height / 4),
      reason: '烘焙纹理应按 sigma 降采样（远小于卡片像素数）',
    );

    final Uint8List baked = (await tester.runAsync(
      () => capture(tester, bakedKey),
    ))!;
    expect(baked.length, reference.length);
    int sum = 0;
    int worst = 0;
    for (int i = 0; i < baked.length; i++) {
      if (i % 4 == 3) continue; // alpha 恒 255（灰底不透明）
      final int d = (baked[i] - reference[i]).abs();
      sum += d;
      if (d > worst) worst = d;
    }
    final double mean = sum / (baked.length / 4 * 3);
    debugPrint('[prebaked-blur] mean=${mean.toStringAsFixed(2)} max=$worst');
    expect(mean, lessThan(2.0), reason: '平均每通道偏差应低于 2/255');
    expect(worst, lessThan(16), reason: '任一像素通道偏差不应肉眼可辨');
  }

  testWidgets('游戏卡 key art：与渲染期 ImageFiltered 画面一致，且无渲染期滤镜', (
    WidgetTester tester,
  ) async {
    await expectMatchesImageFiltered(tester, sigma: 22);
  });

  testWidgets('封面垫底（srcATop 压暗后模糊）：与 ImageFiltered + ColorFiltered 一致', (
    WidgetTester tester,
  ) async {
    await expectMatchesImageFiltered(
      tester,
      sigma: 14,
      colorFilter: const ColorFilter.mode(Color(0x59000000), BlendMode.srcATop),
    );
  });
  test('库卡 / 封面垫底不再用渲染期 ImageFiltered（每卡每帧重算模糊即掉帧根因）', () {
    // 滚动列表里每卡一份的封面模糊：游戏库「继续游戏」卡、视频 / 合集封面比例
    // 不符时的垫底。任何一处退回 ImageFiltered，滚动就重新按卡数线性地每帧做
    // 高斯卷积（Impeller 无 raster cache，Skia 滚动中缓存失效）。游戏首页大卡
    // 2026-10 M3E 重做后改成饱和 primaryContainer 色块 + 清晰大封面，不再有
    // 模糊垫底，故不在此列（它若重新引入模糊，仍须走 PrebakedBlurImage）。
    const List<String> files = <String>[
      'lib/src/pages/implementations/games_library_page.dart',
      'lib/src/media/video/cover_ui/portrait_cover_image.dart',
      'lib/src/media/video/cover_ui/landscape_cover_image.dart',
    ];
    for (final String path in files) {
      final String source = File(path).readAsStringSync();
      expect(
        RegExp(r'ImageFiltered\(').hasMatch(source),
        isFalse,
        reason: '$path 又出现了渲染期 ImageFiltered，改用 PrebakedBlurImage',
      );
      expect(source, contains('PrebakedBlurImage('), reason: path);
    }
  });
}
