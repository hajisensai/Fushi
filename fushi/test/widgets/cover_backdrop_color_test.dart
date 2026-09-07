import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:fushi/src/media/video/cover_ui/cover_backdrop_color.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';

/// 封面「模糊垫底」在图源自带透明区时的底色补全。
///
/// 原始失败路径：galgame 封面链末端是 exe 内嵌图标（PE 资源里解出的 PNG），
/// 实测 256×256 方图、约一半像素全透明。方图两种槽向都判「不合槽」→ 走垫底；
/// 而垫底是「同图放大 + 模糊」，透明的图模糊之后还是透明，于是那层
/// `Color(0x59000000)` 的压暗直接涂在卡片底色上——用户看到的就是立绘四周一圈死灰。
void main() {
  /// 画一张 [width]×[height] 的图：左半边纯色、右半边**留空（全透明）**，
  /// 用来模拟去背立绘。[opaque] 为 true 时整张铺满（对照组：普通不透明封面）。
  Future<ui.Image> halfTransparentImage(
    int width,
    int height, {
    required Color color,
    bool opaque = false,
  }) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(
        0,
        0,
        opaque ? width.toDouble() : width / 2,
        height.toDouble(),
      ),
      ui.Paint()..color = color,
    );
    return recorder.endRecording().toImage(width, height);
  }

  group('sampleCoverBackdropSeed', () {
    test('去背立绘：取到非透明区的主色，并报出真实不透明比例', () async {
      final ui.Image image = await halfTransparentImage(
        64,
        64,
        color: const Color(0xFFCC3366),
      );
      addTearDown(image.dispose);

      final CoverBackdropSeed? seed = await sampleCoverBackdropSeed(image);

      expect(seed, isNotNull, reason: '半透明图必须给出底色，否则垫底还是空的');
      // 只统计非透明像素：主色应当就是画上去的那个颜色，而不是被透明区拉向黑。
      expect(seed!.color.r, closeTo(0xCC / 255, 0.02));
      expect(seed.color.g, closeTo(0x33 / 255, 0.02));
      expect(seed.color.b, closeTo(0x66 / 255, 0.02));
      expect(seed.opaqueRatio, closeTo(0.5, 0.05));
    });

    test('普通不透明封面：返回 null —— 模糊垫底本就能铺满，不必多铺一层', () async {
      final ui.Image image = await halfTransparentImage(
        64,
        64,
        color: const Color(0xFF2244AA),
        opaque: true,
      );
      addTearDown(image.dispose);

      expect(await sampleCoverBackdropSeed(image), isNull);
    });
  });

  group('harmonizeBackdrop', () {
    test('保留色相，收掉过高饱和度——立绘主色常常很艳，铺满整卡会喧宾夺主', () {
      const Color vivid = Color(0xFFFF0080); // 饱和度 1.0 的荧光粉
      final HSLColor seedHsl = HSLColor.fromColor(vivid);

      final Color tuned = harmonizeBackdrop(vivid, Brightness.dark);
      final HSLColor tunedHsl = HSLColor.fromColor(tuned);

      // 容差 2°：调制要经 HSL→8bit RGB 往返，饱和度压得越低量化误差越大
      // （实测暗色档 0.26 下偏 1.15°）。这个量级肉眼不可辨，色相仍是留住的。
      expect(tunedHsl.hue, closeTo(seedHsl.hue, 2.0),
          reason: '色相是与前景协调的依据，必须留住');
      expect(tunedHsl.saturation,
          lessThanOrEqualTo(kBackdropMaxSaturationDark + 0.01));
      // 暗色收得更紧：同一颗种子在亮色主题下允许更高的饱和度。
      expect(
        HSLColor.fromColor(harmonizeBackdrop(vivid, Brightness.light))
            .saturation,
        greaterThan(tunedHsl.saturation),
      );
      expect(tunedHsl.lightness, closeTo(kBackdropDarkLightness, 0.02));
    });

    test('亮度按主题钉死，不随图片明暗漂移', () {
      const Color dark = Color(0xFF101014);
      const Color light = Color(0xFFF2F0EC);
      for (final Color seed in <Color>[dark, light]) {
        expect(
          HSLColor.fromColor(harmonizeBackdrop(seed, Brightness.light))
              .lightness,
          closeTo(kBackdropLightLightness, 0.02),
        );
        expect(
          HSLColor.fromColor(harmonizeBackdrop(seed, Brightness.dark)).lightness,
          closeTo(kBackdropDarkLightness, 0.02),
        );
      }
    });
  });

  group('PortraitCoverImage 垫底层序', () {
    /// 把 [image] 编码成 PNG 交给 [MemoryImage]（保留 alpha 通道）。
    Future<Uint8List> pngOf(ui.Image image) async {
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }

    /// 主色底层：带渐变的 [DecoratedBox]。
    Iterable<DecoratedBox> tintedLayers(WidgetTester tester) => tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where((DecoratedBox b) =>
            b.decoration is BoxDecoration &&
            (b.decoration as BoxDecoration).gradient != null);

    Future<void> pumpCover(WidgetTester tester, MemoryImage provider) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 100,
              height: 150,
              child: PortraitCoverImage(image: provider),
            ),
          ),
        ),
      );
      // 真实解码 + 异步主色采样都在 runAsync 区里跑完，再 pump 应用 setState。
      // 采样要 `toByteData` 走一趟引擎，不是一个微任务能等到的——轮着 pump，
      // 直到底色层出现或超时（固定 delay 容易在慢机上假红）。
      await tester.runAsync<void>(
        () => precacheImage(provider, tester.element(find.byType(Image).first)),
      );
      await tester.pump();
      for (int i = 0; i < 40; i++) {
        await tester.runAsync<void>(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (tintedLayers(tester).isNotEmpty) break;
      }
    }

    /// 找铺满槽位的纯压暗层：旧实现用它把 `Color(0x59000000)` 涂满整张卡。
    Finder flatDimLayer() => find.byWidgetPredicate(
          (Widget w) => w is ColoredBox && w.color == kCoverBackdropDimColor,
        );

    testWidgets('去背立绘：铺主色底，且压暗不再涂在透明区上', (WidgetTester tester) async {
      final ui.Image raw = (await tester.runAsync<ui.Image>(
        () => halfTransparentImage(64, 64, color: const Color(0xFFCC3366)),
      ))!;
      addTearDown(raw.dispose);
      final MemoryImage provider =
          MemoryImage((await tester.runAsync<Uint8List>(() => pngOf(raw)))!);

      await pumpCover(tester, provider);

      // 方图不合竖槽 → 走垫底路径。
      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(
        flatDimLayer(),
        findsNothing,
        reason: '压暗一旦铺成整层 ColoredBox，透明区就会被涂成死灰——正是本次修复的现象',
      );
      expect(
        tintedLayers(tester),
        isNotEmpty,
        reason: '透明立绘必须拿到由自身主色算出的底色，否则背景仍是一片灰',
      );
    });

    testWidgets('不透明封面：不额外铺底色（模糊垫底本就铺满，观感零变化）',
        (WidgetTester tester) async {
      final ui.Image raw = (await tester.runAsync<ui.Image>(
        () => halfTransparentImage(64, 64,
            color: const Color(0xFF2244AA), opaque: true),
      ))!;
      addTearDown(raw.dispose);
      final MemoryImage provider =
          MemoryImage((await tester.runAsync<Uint8List>(() => pngOf(raw)))!);

      await pumpCover(tester, provider);

      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(tintedLayers(tester), isEmpty);
    });
  });
}
