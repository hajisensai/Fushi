import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/common_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

import '../visualizer_test_helpers.dart';
import 'background_test_helpers.dart';

void main() {
  group('布局', () {
    test('15 个图形 + 20 个粒子，按 seed 固定、换 seed 变', () {
      final List<CommonShape> a = commonBackgroundShapes(42);
      final List<CommonShape> b = commonBackgroundShapes(42);
      final List<CommonShape> c = commonBackgroundShapes(43);
      expect(a, hasLength(15));
      expect(commonBackgroundParticles(42), hasLength(20));
      expect(a.map((CommonShape s) => s.x), b.map((CommonShape s) => s.x));
      expect(
        a.map((CommonShape s) => s.x),
        isNot(c.map((CommonShape s) => s.x)),
      );
      for (final CommonShape s in a) {
        expect(s.size, inInclusiveRange(40, 140));
        expect(s.opacity, inInclusiveRange(0.11, 0.19));
        expect(s.duration, inInclusiveRange(20, 60));
      }
    });

    test('循环：延时内停首帧，之后按时长绕圈', () {
      expect(commonLoopPhase(2, 10, 3), 0);
      expect(commonLoopPhase(8, 10, 3), closeTo(0.5, 1e-9));
      expect(commonLoopPhase(13, 10, 3), closeTo(0, 1e-9));
    });

    test('漂移关键帧：0 与 100% 相同，50% 在另一端并转半圈', () {
      final CommonShape s = commonBackgroundShapes(1).first;
      final ({Offset offset, double rotation}) start = commonShapeDrift(s, 0);
      final ({Offset offset, double rotation}) mid = commonShapeDrift(s, 0.5);
      expect(start.offset, -mid.offset);
      expect(mid.rotation - start.rotation, closeTo(180, 1e-9));
    });

    test('频段缩放：10 以下 0.95，200 以上 1.45', () {
      expect(commonBandScale(0), 0.95);
      expect(commonBandScale(105), closeTo(1.2, 1e-9));
      expect(commonBandScale(255), 1.45);
    });
  });

  group('画面', () {
    testWidgets('参数改变输出：隐藏图形、关暗角、叠封面色彩层', (WidgetTester tester) async {
      Future<Uint8List> draw(Map<String, Object?> v) => renderScene(
        tester,
        CommonBackgroundScene(),
        backgroundContext(),
        LyricVisualizerTuning(commonBackgroundTunings, v),
      );
      final Uint8List base = await draw(const <String, Object?>{});
      final Uint8List hidden = await draw(const <String, Object?>{
        CommonBackgroundKeys.disableGeometricBackground: true,
      });
      final Uint8List noVignette = await draw(const <String, Object?>{
        CommonBackgroundKeys.disableVignette: true,
      });
      final Uint8List cover = await draw(const <String, Object?>{
        CommonBackgroundKeys.useCoverColorBg: true,
        CommonBackgroundKeys.opacity: 0.3,
      });
      expect(pixelDifference(base, hidden), greaterThan(0));
      expect(pixelDifference(base, noVignette), greaterThan(0));
      expect(pixelDifference(base, cover), greaterThan(0));
    });

    testWidgets('有音频时图形随频段缩放（与无音频不同）', (WidgetTester tester) async {
      final LyricVisualizerTuning tu = LyricVisualizerTuning.defaults(
        commonBackgroundTunings,
      );
      final Uint8List quiet = await renderScene(
        tester,
        CommonBackgroundScene(),
        backgroundContext(),
        tu,
        size: const Size(320, 180),
      );
      final Uint8List loud = await renderScene(
        tester,
        CommonBackgroundScene(),
        backgroundContext(audio: SyntheticVisualizerAudio()),
        tu,
        size: const Size(320, 180),
      );
      expect(pixelDifference(quiet, loud), greaterThan(0));
    });

    testWidgets('随时间漂移', (WidgetTester tester) async {
      final LyricVisualizerTuning tu = LyricVisualizerTuning.defaults(
        commonBackgroundTunings,
      );
      final Uint8List a = await renderScene(
        tester,
        CommonBackgroundScene(),
        backgroundContext(),
        tu,
        steps: 10,
      );
      final Uint8List b = await renderScene(
        tester,
        CommonBackgroundScene(),
        backgroundContext(),
        tu,
        steps: 200,
        dt: 0.1,
      );
      expect(pixelDifference(a, b), greaterThan(0));
    });
  });

  group('冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpBackgroundAcross(tester, commonBackgroundEntry);
    });
    testWidgets('有音频 + 封面色彩层', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        commonBackgroundEntry,
        audio: SyntheticVisualizerAudio(),
        tuning: const <String, Object?>{
          CommonBackgroundKeys.useCoverColorBg: true,
        },
      );
    });
    testWidgets('暂停 + 减弱动态效果 + 窄屏', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        commonBackgroundEntry,
        motion: false,
        playing: false,
        size: const Size(390, 844),
      );
    });
    test('已注册', () {
      expect(
        lyricVisualizerBackgroundOf('common'),
        same(commonBackgroundEntry),
      );
    });
  });
}
