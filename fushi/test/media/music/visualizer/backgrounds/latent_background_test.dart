import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/latent_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';

import '../visualizer_test_helpers.dart';
import 'background_test_helpers.dart';

LyricVisualizerAudioFrame _frame(double v) => LyricVisualizerAudioFrame(
  power: v,
  low: v,
  mid: v,
  high: v,
  vocal: v,
  onset: v,
  beatImpact: 0,
  downbeatImpact: 0,
  drumImpact: 0,
);

void main() {
  group('folia 公式', () {
    test('宽频能量：0 → 0，满 → 1，单调', () {
      expect(latentBroadbandEnergy(_frame(0)), 0);
      expect(latentBroadbandEnergy(_frame(1)), closeTo(1, 1e-9));
      expect(
        latentBroadbandEnergy(_frame(0.3)),
        lessThan(latentBroadbandEnergy(_frame(0.6))),
      );
    });

    test('起音脉冲：上升沿 ×7，否则按 0.84 衰减', () {
      expect(latentOnsetPulse(0.5, 0.4, 0), closeTo(0.7, 1e-9));
      expect(latentOnsetPulse(0.4, 0.5, 0.5), closeTo(0.42, 1e-9));
      expect(latentOnsetPulse(1, 0, 0), 1);
    });

    test('速度：暂停时 12%，播放时朝音频速度插值，夹在 0–2', () {
      expect(latentShaderSpeed(1, 2, 0.5, true), closeTo(0.12, 1e-9));
      expect(latentShaderSpeed(0.3, 2, 0.5, false), closeTo(1.15, 1e-9));
      expect(latentShaderSpeed(2, 2, 1, false), 2);
      expect(latentAudioSpeedTarget(0.5, 0.4, false), 0.5);
      expect(latentAudioSpeedTarget(0.5, 0.4, true), closeTo(0.55, 1e-9));
    });

    test('颜色：封面与主题 / 仅封面；没有封面色时回落主题', () {
      final LyricVisualizerPalette p = backgroundContext().palette;
      const List<Color> cover = <Color>[
        Color(0xFF110000),
        Color(0xFF002200),
        Color(0xFF000033),
      ];
      final ({Color ditheringBack, Color ditheringFront, List<Color> mesh}) a =
          latentShaderColors(cover, p, 'cover-theme');
      expect(a.ditheringBack, p.background);
      expect(a.ditheringFront, cover[0]);
      expect(a.mesh, <Color>[
        cover[0],
        cover[1],
        cover[2],
        cover[1],
        p.background,
        p.accent,
      ]);
      final ({Color ditheringBack, Color ditheringFront, List<Color> mesh}) b =
          latentShaderColors(cover, p, 'cover-only');
      expect(b.ditheringBack, cover[2]);
      expect(b.mesh.last, cover[2]);
      final ({Color ditheringBack, Color ditheringFront, List<Color> mesh}) e =
          latentShaderColors(const <Color>[], p, 'cover-theme');
      expect(e.ditheringFront, p.secondary);
      expect(e.mesh[1], p.primary);
    });

    test('4×4 Bayer：16 个格子正好是 16 个不同阈值', () {
      final Set<double> values = <double>{
        for (int y = 0; y < 4; y++)
          for (int x = 0; x < 4; x++) latentBayer4(x.toDouble(), y.toDouble()),
      };
      expect(values, hasLength(16));
      for (final double v in values) {
        expect(v, inInclusiveRange(0, 1));
      }
    });
  });

  group('场景', () {
    testWidgets('音频推高扭曲 / 旋涡 / 缩放，暂停时回落', (WidgetTester tester) async {
      final LatentBackgroundScene loud = LatentBackgroundScene();
      final LatentBackgroundScene quiet = LatentBackgroundScene();
      final LyricVisualizerTuning tu = LyricVisualizerTuning.defaults(
        latentBackgroundTunings,
      );
      loud.configure(
        backgroundContext(audio: SyntheticVisualizerAudio()),
        tu,
        1,
      );
      quiet.configure(backgroundContext(playing: false), tu, 1);
      for (int i = 0; i < 60; i++) {
        final LyricVisualizerTick tick = LyricVisualizerTick(
          timeMs: 1000 + i * 16,
          elapsed: i / 60,
          dt: 1 / 60,
        );
        loud.advance(tick);
        quiet.advance(tick);
      }
      final LatentFrame a = loud.frame();
      final LatentFrame b = quiet.frame();
      expect(a.distortion, greaterThan(b.distortion));
      expect(a.meshScale, greaterThan(b.meshScale));
      expect(a.meshTime, greaterThan(b.meshTime));
      expect(b.distortion, closeTo(0.8, 0.05));
      loud.dispose();
      quiet.dispose();
    });

    testWidgets('显示图层 / 叠色 / 像素尺寸改变输出（CPU 路径）', (WidgetTester tester) async {
      Future<Uint8List> draw(Map<String, Object?> v) => renderScene(
        tester,
        LatentBackgroundScene(useShader: false),
        backgroundContext(),
        LyricVisualizerTuning(latentBackgroundTunings, v),
        size: const Size(256, 144),
      );
      final Uint8List both = await draw(const <String, Object?>{});
      final Uint8List mesh = await draw(const <String, Object?>{
        LatentBackgroundKeys.displayMode: 'mesh',
      });
      final Uint8List dither = await draw(const <String, Object?>{
        LatentBackgroundKeys.displayMode: 'dithering',
      });
      final Uint8List noOverlay = await draw(const <String, Object?>{
        LatentBackgroundKeys.overlayEnabled: false,
      });
      final Uint8List big = await draw(const <String, Object?>{
        LatentBackgroundKeys.displayMode: 'dithering',
        LatentBackgroundKeys.ditheringSize: 8.0,
      });
      expect(pixelDifference(both, mesh), greaterThan(0));
      expect(pixelDifference(both, dither), greaterThan(0));
      expect(pixelDifference(mesh, dither), greaterThan(0));
      expect(pixelDifference(both, noOverlay), greaterThan(0));
      expect(pixelDifference(dither, big), greaterThan(0));
    });

    testWidgets('着色器路径：编进测试包后能画，图层模式改变输出', (WidgetTester tester) async {
      final ui.FragmentProgram? program = await tester
          .runAsync<ui.FragmentProgram>(
            () => ui.FragmentProgram.fromAsset(
              'shaders/visualizer_bg_latent.frag',
            ),
          );
      Future<Uint8List> draw(String mode) => renderScene(
        tester,
        LatentBackgroundScene(program: program),
        backgroundContext(),
        LyricVisualizerTuning(latentBackgroundTunings, <String, Object?>{
          LatentBackgroundKeys.displayMode: mode,
        }),
        size: const Size(256, 144),
      );
      final Uint8List mesh = await draw('mesh');
      final Uint8List both = await draw('both');
      expect(program, isNotNull);
      expect(mesh.toSet().length, greaterThan(8));
      expect(pixelDifference(mesh, both), greaterThan(0));
    });

    testWidgets('流体随时间流动', (WidgetTester tester) async {
      final LyricVisualizerTuning tu = LyricVisualizerTuning(
        latentBackgroundTunings,
        const <String, Object?>{LatentBackgroundKeys.displayMode: 'mesh'},
      );
      final Uint8List a = await renderScene(
        tester,
        LatentBackgroundScene(useShader: false),
        backgroundContext(),
        tu,
        steps: 2,
      );
      final Uint8List b = await renderScene(
        tester,
        LatentBackgroundScene(useShader: false),
        backgroundContext(),
        tu,
        steps: 120,
        dt: 0.1,
      );
      expect(pixelDifference(a, b), greaterThan(0));
    });
  });

  group('冒烟', () {
    testWidgets('默认 + 有音频', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        latentBackgroundEntry,
        audio: SyntheticVisualizerAudio(),
      );
    });
    testWidgets('仅像素 + 仅封面取色 + 关节拍响应', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        latentBackgroundEntry,
        tuning: const <String, Object?>{
          LatentBackgroundKeys.displayMode: 'dithering',
          LatentBackgroundKeys.colorSource: 'cover-only',
          LatentBackgroundKeys.enhancedBeatResponse: false,
        },
      );
    });
    testWidgets('暂停 + 减弱动态效果 + 窄屏', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        latentBackgroundEntry,
        motion: false,
        playing: false,
        size: const Size(390, 844),
      );
    });
    test('已注册', () {
      expect(
        lyricVisualizerBackgroundOf('latent'),
        same(latentBackgroundEntry),
      );
    });
  });
}
