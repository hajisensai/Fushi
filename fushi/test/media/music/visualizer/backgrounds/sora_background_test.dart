import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/sora_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

import '../visualizer_test_helpers.dart';
import 'background_test_helpers.dart';

void main() {
  group('星点', () {
    test('位置在画布纵向 5%–95% 内，约一成用强调色', () {
      const Size size = Size(1280, 720);
      int accents = 0;
      for (int i = 0; i < kSoraParticleCount; i++) {
        final SoraStar s = soraStarAt(i, 12.5, size, 2);
        expect(s.center.dy, inInclusiveRange(0.04 * 720, 0.96 * 720));
        expect(s.center.dx, inInclusiveRange(-0.05 * 720, 1280 + 0.05 * 720));
        expect(s.diameter, greaterThanOrEqualTo(2));
        expect(s.intensity, inInclusiveRange(-0.4, 1));
        if (s.accent) accents++;
      }
      expect(accents, inInclusiveRange(3, 35));
    });

    test('随时间向右漂、到边从左边绕回', () {
      const Size size = Size(1280, 720);
      final SoraStar a = soraStarAt(7, 0, size, 2);
      final SoraStar b = soraStarAt(7, 1, size, 2);
      expect(b.center.dx, isNot(a.center.dx));
    });
  });

  group('画面', () {
    testWidgets('夜间黑底、日间白底；完全空白只剩底色', (WidgetTester tester) async {
      final LyricVisualizerTuning blank = LyricVisualizerTuning(
        soraBackgroundTunings,
        const <String, Object?>{SoraBackgroundKeys.blank: true},
      );
      final Uint8List night = await renderScene(
        tester,
        SoraBackgroundScene(),
        backgroundContext(),
        blank,
      );
      final Uint8List day = await renderScene(
        tester,
        SoraBackgroundScene(),
        backgroundContext(brightness: Brightness.light),
        blank,
      );
      expect(night.toSet(), <int>{0, 255});
      expect(day.toSet(), <int>{255});
      final Uint8List stars = await renderScene(
        tester,
        SoraBackgroundScene(),
        backgroundContext(),
        LyricVisualizerTuning.defaults(soraBackgroundTunings),
        size: const Size(640, 360),
      );
      expect(stars.toSet().length, greaterThan(2));
    });

    testWidgets('播放时星空在走，暂停时停住', (WidgetTester tester) async {
      final LyricVisualizerTuning tu = LyricVisualizerTuning.defaults(
        soraBackgroundTunings,
      );
      Future<Uint8List> at(bool playing, int steps) => renderScene(
        tester,
        SoraBackgroundScene(),
        backgroundContext(playing: playing),
        tu,
        size: const Size(640, 360),
        steps: steps,
        dt: 0.1,
      );
      expect(
        pixelDifference(await at(true, 5), await at(true, 80)),
        greaterThan(0),
      );
      expect(pixelDifference(await at(false, 5), await at(false, 80)), 0);
    });
  });

  group('冒烟', () {
    testWidgets('默认 + 有音频', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        soraBackgroundEntry,
        audio: SyntheticVisualizerAudio(),
      );
    });
    testWidgets('日间 + 空白 + 减弱动态效果 + 窄屏', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        soraBackgroundEntry,
        brightness: Brightness.light,
        motion: false,
        tuning: const <String, Object?>{SoraBackgroundKeys.blank: true},
        size: const Size(390, 844),
      );
    });
    test('已注册', () {
      expect(lyricVisualizerBackgroundOf('sora'), same(soraBackgroundEntry));
    });
  });
}
