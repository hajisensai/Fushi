import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/monet_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

import '../visualizer_test_helpers.dart';
import 'background_test_helpers.dart';

void main() {
  group('像素处理', () {
    test('水洗：暗端映射到阴影色、亮端映射到高光色', () {
      const MonetRgb bg = (r: 10, g: 10, b: 12);
      const MonetRgb accent = (r: 200, g: 40, b: 40);
      const MonetRgb primary = (r: 245, g: 245, b: 245);
      expect(monetWashColor(0, bg, accent, primary), bg);
      expect(monetWashColor(0.55, bg, accent, primary), accent);
      final MonetRgb hi = monetWashColor(1, bg, accent, primary);
      expect(hi.r, closeTo(245, 1e-6));
      expect(hi.g, closeTo(245, 1e-6));
      expect(hi.b, closeTo(245, 1e-6));
      // 浅色主题（背景比主色亮）两端对调。
      expect(monetWashEndpoints(primary, bg).shadow, bg);
    });

    test('逐像素：恒等参数不动，全去色变灰，透明像素跳过', () {
      final Uint8List px = Uint8List.fromList(<int>[
        200,
        100,
        50,
        255,
        1,
        2,
        3,
        0,
      ]);
      const MonetRgb c = (r: 0, g: 0, b: 0);
      MonetPixelJob job(double grayscale) => MonetPixelJob(
        pixels: Uint8List.fromList(px),
        grayscale: grayscale,
        saturation: 1,
        wash: 0,
        background: c,
        accent: c,
        primary: c,
      );
      expect(monetProcessPixels(job(0)), px);
      final Uint8List gray = monetProcessPixels(job(1));
      expect(gray[0], gray[1]);
      expect(gray[1], gray[2]);
      expect(gray.sublist(4), <int>[1, 2, 3, 0]);
    });

    test('漂移：平移不超过预算，缩放始终盖住边缘', () {
      for (double s = 0; s < 480; s += 3.7) {
        final MonetDrift d = monetDriftAt(s, 1);
        expect(d.txPercent.abs(), lessThanOrEqualTo(3.4 + 1e-9));
        expect(d.tyPercent.abs(), lessThanOrEqualTo(3.4 + 1e-9));
        expect(d.scale, greaterThanOrEqualTo(1 + 0.034 * 2));
      }
      final MonetDrift zero = monetDriftAt(10, 0);
      expect(zero.txPercent, 0);
      expect(zero.scale, closeTo(1.01, 1e-9));
    });
  });

  group('参数', () {
    test('默认值与 folia 一致；自定义水洗色只在 custom 时生效', () {
      final MonetBackgroundConfig d = MonetBackgroundConfig.from(
        LyricVisualizerTuning.defaults(monetBackgroundTunings),
      );
      expect(d.uploaded, isFalse);
      expect(d.halfPane, isFalse);
      expect(d.driftEnabled, isTrue);
      expect(d.driftStrength, 0.5);
      expect(d.treatment.blurPx, 6);
      expect(d.treatment.overlay, 0.74);
      expect(d.treatment.saturation, 1.05);
      expect(d.treatment.wash, 0.34);
      expect(d.treatment.washColor, isNull);
      final MonetBackgroundConfig custom = MonetBackgroundConfig.from(
        LyricVisualizerTuning(monetBackgroundTunings, const <String, Object?>{
          MonetBackgroundKeys.backgroundWashColorMode: 'custom',
          MonetBackgroundKeys.backgroundSource: 'uploaded-global',
        }),
      );
      expect(custom.treatment.washColor, const Color(0xFF8FB7FF));
      expect(custom.uploaded, isTrue);
    });
  });

  group('烘焙', () {
    test('烘焙尺寸：盖住视口的 16:9 框，按物理像素取整并夹在上下限内', () {
      // 1280×720 逻辑 × 2 = 2560 宽。
      expect(monetBakeSize(const Size(1280, 720), 2), const Size(2560, 1440));
      // 竖屏手机：按高度盖住，宽度封顶。
      expect(monetBakeSize(const Size(400, 900), 3), const Size(2560, 1440));
      // 小预览：不低于下限。
      expect(monetBakeSize(const Size(200, 120), 1), const Size(640, 360));
      // 1000 宽 → 向上取整到 128 的倍数（1024），保持 16:9。
      expect(monetBakeSize(const Size(1000, 500), 1), const Size(1024, 576));
      // 4K 视口不再按 1280 放大三倍：取上限 2560。
      expect(monetBakeSize(const Size(3840, 2160), 1).width, 2560);
    });

    testWidgets('封面默认烘焙成 folia 画布 1920×1080，水洗色变了图就变', (
      WidgetTester tester,
    ) async {
      final ui.Image src = await gradientImage(tester);
      final LyricVisualizerPalette p = backgroundContext().palette;
      const MonetBackgroundTreatment a = MonetBackgroundTreatment(
        blurPx: 0,
        overlay: 0.2,
        grayscale: 0,
        saturation: 1,
        wash: 1,
        streaks: false,
      );
      const MonetBackgroundTreatment b = MonetBackgroundTreatment(
        blurPx: 0,
        overlay: 0.2,
        grayscale: 0,
        saturation: 1,
        wash: 1,
        streaks: false,
        washColor: Color(0xFF00FF00),
      );
      final ui.Image? ia = await tester.runAsync(
        () => bakeMonetBackground(src, p, a),
      );
      final ui.Image? ib = await tester.runAsync(
        () => bakeMonetBackground(src, p, b),
      );
      // 默认是 folia 画布原尺寸 1920×1080。
      expect(ia!.width, 1920);
      expect(ia.height, 1080);
      expect(
        pixelDifference(
          await pixelsOf(tester, ia),
          await pixelsOf(tester, ib!),
        ),
        greaterThan(0),
      );
      ia.dispose();
      ib.dispose();
      src.dispose();
    });

    testWidgets('没有封面：全屏与半屏布局画法不同', (WidgetTester tester) async {
      Future<Uint8List> draw(String layout) => renderScene(
        tester,
        MonetBackgroundScene(),
        backgroundContext(),
        LyricVisualizerTuning(monetBackgroundTunings, <String, Object?>{
          MonetBackgroundKeys.backgroundLayout: layout,
        }),
      );
      expect(
        pixelDifference(
          await draw('full-overlay'),
          await draw('half-pane-gradient'),
        ),
        greaterThan(0),
      );
    });
  });

  group('冒烟', () {
    testWidgets('默认 + 有音频', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        monetBackgroundEntry,
        audio: SyntheticVisualizerAudio(),
      );
    });
    testWidgets('半屏 + 关漂移 + 自定义水洗 + 减弱动态效果 + 窄屏', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        monetBackgroundEntry,
        motion: false,
        playing: false,
        size: const Size(390, 844),
        tuning: const <String, Object?>{
          MonetBackgroundKeys.backgroundLayout: 'half-pane-gradient',
          MonetBackgroundKeys.backgroundDriftEnabled: false,
          MonetBackgroundKeys.backgroundWashColorMode: 'custom',
        },
      );
    });
    test('已注册', () {
      expect(lyricVisualizerBackgroundOf('monet'), same(monetBackgroundEntry));
    });
  });
}
