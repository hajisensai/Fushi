import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/nomand_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

import '../visualizer_test_helpers.dart';
import 'background_test_helpers.dart';

/// 64×48 的合成源图：横向灰度渐变，左上角一块红。
NomandJob _job(
  NomandEffect effect, {
  Map<String, double> params = const <String, double>{},
  bool daylight = false,
}) {
  const int sw = 64;
  const int sh = 48;
  final Uint8List src = Uint8List(sw * sh * 4);
  for (int y = 0; y < sh; y++) {
    for (int x = 0; x < sw; x++) {
      final int i = (y * sw + x) * 4;
      final int v = (x * 255 / (sw - 1)).round();
      final bool red = x < 12 && y < 12;
      src[i] = red ? 220 : v;
      src[i + 1] = red ? 30 : v;
      src[i + 2] = red ? 30 : v;
      src[i + 3] = 255;
    }
  }
  return NomandJob(
    source: src,
    sourceWidth: sw,
    sourceHeight: sh,
    width: 96,
    height: 54,
    pixelRatio: 1,
    effect: effect,
    params: params,
    back: 0xFF101018,
    front: 0xFFE0B040,
    highlight: 0xFFFFFFFF,
    shadow: 0xFF203060,
    daylight: daylight,
  );
}

void main() {
  group('folia 调整函数', () {
    test('明暗自适应反色：浅色主题且非原色时翻一次；半调基准相反', () {
      expect(nomandDaylightInversion(false, false, false), isFalse);
      expect(nomandDaylightInversion(false, false, true), isTrue);
      expect(nomandDaylightInversion(false, true, true), isFalse);
      expect(nomandHalftoneInversion(false, false, false), isTrue);
      expect(nomandHalftoneInversion(true, false, true), isTrue);
    });

    test('预放大：纸张随粗糙度增大；镜头收缩时只为色散留量、膨胀越大放得越多、封顶 1.8', () {
      expect(nomandPaperOverscan(1, 1), greaterThan(nomandPaperOverscan(0, 0)));
      expect(nomandPaperOverscan(0, 0), greaterThan(1));
      expect(nomandLensOverscan(-0.5, 0), 1);
      expect(nomandLensOverscan(-0.5, 1), greaterThan(1));
      final double small = nomandLensOverscan(0.1, 0.45);
      final double big = nomandLensOverscan(0.6, 0.45);
      expect(big, greaterThanOrEqualTo(small));
      expect(nomandLensOverscan(1, 1), lessThanOrEqualTo(1.8));
    });

    test('Bayer：n×n 个格子恰好是 n² 个不同阈值', () {
      for (final int n in <int>[2, 4, 8]) {
        final Set<double> v = <double>{
          for (int y = 0; y < n; y++)
            for (int x = 0; x < n; x++) nomandBayer(n, x, y),
        };
        expect(v, hasLength(n * n));
      }
      expect(nomandBayer(2, 0, 0), lessThan(nomandBayer(2, 1, 1)));
    });

    test('量化：两端保持，色阶数决定档位', () {
      expect(nomandQuantize(0, 4, 0.5), 0);
      expect(nomandQuantize(1, 4, 0.5), 1);
      expect(nomandQuantize(0.5, 1, 0.3), 0);
      expect(nomandQuantize(0.5, 1, 0.7), 1);
    });
  });

  group('逐像素效果', () {
    test('五种效果都产出整张不透明图，彼此不同', () {
      final Map<NomandEffect, Uint8List> out = <NomandEffect, Uint8List>{
        for (final NomandEffect e in NomandEffect.values)
          e: nomandRender(_job(e)),
      };
      for (final MapEntry<NomandEffect, Uint8List> e in out.entries) {
        expect(e.value.length, 96 * 54 * 4, reason: e.key.name);
        for (int i = 3; i < e.value.length; i += 4) {
          expect(e.value[i], 255);
        }
      }
      final List<Uint8List> all = out.values.toList();
      for (int i = 0; i < all.length; i++) {
        for (int j = i + 1; j < all.length; j++) {
          expect(pixelDifference(all[i], all[j]), greaterThan(0));
        }
      }
    });

    test('像素画：非原色只用底 / 前景 / 高光之间的颜色；格子内同色', () {
      final Uint8List px = nomandRender(
        _job(
          NomandEffect.dithering,
          params: const <String, double>{
            NomandBackgroundKeys.size: 6,
            NomandBackgroundKeys.colorSteps: 1,
          },
        ),
      );
      final Set<int> colors = <int>{
        for (int i = 0; i < px.length; i += 4)
          (px[i] << 16) | (px[i + 1] << 8) | px[i + 2],
      };
      expect(colors, <int>{0x101018, 0xE0B040});
      // 第一个 6×6 格子全同色。
      for (int y = 0; y < 6; y++) {
        for (int x = 0; x < 6; x++) {
          expect(px[(y * 96 + x) * 4], px[0]);
        }
      }
    });

    test('参数改变输出：像素尺寸、色阶、反色、玻璃扭曲、网点半径、镜头膨胀', () {
      void differs(
        NomandEffect e,
        Map<String, double> a,
        Map<String, double> b,
      ) {
        expect(
          pixelDifference(
            nomandRender(_job(e, params: a)),
            nomandRender(_job(e, params: b)),
          ),
          greaterThan(0),
          reason: '$e $a vs $b',
        );
      }

      differs(
        NomandEffect.dithering,
        const <String, double>{NomandBackgroundKeys.size: 2},
        const <String, double>{NomandBackgroundKeys.size: 8},
      );
      differs(
        NomandEffect.dithering,
        const <String, double>{NomandBackgroundKeys.colorSteps: 2},
        const <String, double>{NomandBackgroundKeys.colorSteps: 6},
      );
      differs(
        NomandEffect.dithering,
        const <String, double>{},
        const <String, double>{NomandBackgroundKeys.inverted: 1},
      );
      differs(
        NomandEffect.flutedGlass,
        const <String, double>{NomandBackgroundKeys.flutedGlassDistortion: 0},
        const <String, double>{NomandBackgroundKeys.flutedGlassDistortion: 1},
      );
      differs(
        NomandEffect.halftoneDots,
        const <String, double>{NomandBackgroundKeys.halftoneDotsRadius: 0.5},
        const <String, double>{NomandBackgroundKeys.halftoneDotsRadius: 1.8},
      );
      differs(
        NomandEffect.lensDistortion,
        const <String, double>{NomandBackgroundKeys.lensDistortionBulge: -0.5},
        const <String, double>{NomandBackgroundKeys.lensDistortionBulge: 0.8},
      );
      differs(
        NomandEffect.paperTexture,
        const <String, double>{NomandBackgroundKeys.paperTextureContrast: 0},
        const <String, double>{NomandBackgroundKeys.paperTextureContrast: 1},
      );
    });

    test('参数表：布尔记 0 / 1，图案记 n', () {
      final Map<String, double> m = nomandParamsOf(
        LyricVisualizerTuning(nomandBackgroundTunings, const <String, Object?>{
          NomandBackgroundKeys.ditheringType: '4x4',
          NomandBackgroundKeys.inverted: true,
        }),
      );
      expect(m[NomandBackgroundKeys.ditheringType], 4);
      expect(m[NomandBackgroundKeys.inverted], 1);
      expect(m[NomandBackgroundKeys.size], 3);
    });
  });

  group('烘焙', () {
    testWidgets('isolate 烘焙出指定尺寸的图', (WidgetTester tester) async {
      final ui.Image src = await gradientImage(tester);
      final ui.Image? out = await tester.runAsync(
        () => bakeNomandBackground(
          src,
          width: 64,
          height: 36,
          pixelRatio: 1,
          effect: NomandEffect.halftoneDots,
          params: const <String, double>{},
          palette: backgroundContext().palette,
        ),
      );
      expect(out!.width, 64);
      expect(out.height, 36);
      out.dispose();
      src.dispose();
    });

    testWidgets('没有封面时铺底色', (WidgetTester tester) async {
      final Uint8List a = await renderScene(
        tester,
        NomandBackgroundScene(),
        backgroundContext(),
        LyricVisualizerTuning.defaults(nomandBackgroundTunings),
      );
      final Color bg = backgroundContext().palette.background;
      expect(a[0], (bg.r * 255).round());
    });
  });

  group('冒烟', () {
    for (final NomandEffect e in NomandEffect.values) {
      testWidgets('效果 ${e.value}', (WidgetTester tester) async {
        await pumpBackgroundAcross(
          tester,
          nomandBackgroundEntry,
          audio: SyntheticVisualizerAudio(),
          tuning: <String, Object?>{NomandBackgroundKeys.effect: e.value},
        );
      });
    }
    testWidgets('日间 + 减弱动态效果 + 窄屏', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        nomandBackgroundEntry,
        brightness: Brightness.light,
        motion: false,
        playing: false,
        size: const Size(390, 844),
      );
    });
    test('已注册', () {
      expect(
        lyricVisualizerBackgroundOf('nomand'),
        same(nomandBackgroundEntry),
      );
    });
  });
}
