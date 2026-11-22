import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_timeline.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_visualizer.dart';

import '../visualizer_test_helpers.dart';

CladdaghGlyph _g(double s, double e, double angle) => CladdaghGlyph(
  char: 'x',
  startMs: s,
  endMs: e,
  nominalAngle: angle,
  scaleFactor: 1,
);

CladdaghScene _scene({
  bool motion = true,
  Map<String, Object?> tuning = const <String, Object?>{},
}) => CladdaghScene(
  visualizerContextFor(
    claddaghVisualizerEntry,
    clock: FakeVisualizerClock(),
    motion: motion,
    tuning: tuning,
  ),
  const TextStyle(),
);

void main() {
  group('时间轴', () {
    test('零时长空白向邻字借时长，每个至少 60ms', () {
      final List<CladdaghTiming> adjusted = adjustCladdaghTimeline(
        <CladdaghTiming>[
          CladdaghTiming(char: 'a', startMs: 0, endMs: 400),
          CladdaghTiming(char: ' ', startMs: 400, endMs: 400),
          CladdaghTiming(char: 'b', startMs: 400, endMs: 800),
        ],
        0,
        800,
      );
      expect(adjusted[1].endMs - adjusted[1].startMs, closeTo(60, 1e-9));
      expect(adjusted[0].endMs, closeTo(370, 1e-9));
      expect(adjusted[2].startMs, closeTo(430, 1e-9));
    });

    test('小数下标在字起点间插值，末字后外推到 renderEnd 再转两字', () {
      final List<CladdaghGlyph> tl = <CladdaghGlyph>[
        _g(0, 100, -0.2),
        _g(100, 200, 0),
        _g(200, 300, 0.2),
      ];
      expect(claddaghFractionalIndex(tl, -5), 0);
      expect(claddaghFractionalIndex(tl, 50), closeTo(0.5, 1e-9));
      expect(claddaghFractionalIndex(tl, 1200, 1200), closeTo(4, 1e-9));
      expect(claddaghLineWordOffset(tl, 50), closeTo(-0.1, 1e-9));
      // 末字之后按相邻字角差外推
      expect(claddaghLineWordOffset(tl, 700, 1200), closeTo(0.4, 1e-9));
      expect(claddaghLinePlaybackProgress(tl, 100), closeTo(0.5, 1e-9));
      // 没给 renderEnd：最多外推 1.8 字
      expect(claddaghFractionalIndex(tl, 10000), closeTo(3.8, 1e-9));
    });

    test('视觉长度：CJK 1、其余 0.5', () {
      expect(claddaghVisualLength('夜空 ab'), 3.5);
    });
  });

  group('排布', () {
    test('前缀偏移：实测宽 + 跟踪 + 字距偏移，单调', () {
      final List<double> o = claddaghPrefixOffsets(
        <String>['a', 'b', 'c'],
        10,
        2,
        (int n) => n * 6.0,
      );
      final List<double> want = <double>[0, 6, 15.8, 25.6];
      for (int i = 0; i < want.length; i++) {
        expect(o[i], closeTo(want[i], 1e-9));
      }
      // 测量失败回落估宽（拉丁 0.62em）
      final List<double> f = claddaghPrefixOffsets(
        <String>['a'],
        10,
        0,
        (int n) => 0,
      );
      expect(f[1], closeTo(6.2, 1e-9));
    });

    test('名义角以整行中点为 0；超长行压缩到 4.25 弧度', () {
      final List<CladdaghArc> arcs = claddaghArcs(
        <double>[0, 10, 20],
        10,
        100,
        1,
      );
      expect(arcs[0].nominalAngle, closeTo(-0.05, 1e-9));
      expect(arcs[1].nominalAngle, closeTo(0.05, 1e-9));
      final List<CladdaghArc> long = claddaghArcs(
        <double>[0, 500, 1000],
        10,
        100,
        1,
      );
      expect(long.first.scaleFactor, closeTo(0.425, 1e-9));
      expect(
        long.last.nominalAngle - long.first.nominalAngle,
        lessThan(kCladdaghMaxArcSpan),
      );
    });

    test('切线角规整到可读范围', () {
      expect(claddaghReadableAngle(170), -10);
      expect(claddaghReadableAngle(-135), 45);
      expect(claddaghReadableAngle(30), 30);
    });

    test('正前方的字最大最清晰，背面的字缩小模糊', () {
      final CladdaghRing ring = CladdaghRing(
        rx: 500,
        ellipseTiltDeg: 45,
        lineOffset: 0,
      );
      const CladdaghLineState line = CladdaghLineState(
        lineIndex: 0,
        centerLineIndex: 0,
        lineDiffFromCenter: 0,
        wordOffset: 0,
        lengthFade: 1,
        lengthScale: 1,
        upcomingEntry: 0,
      );
      final CladdaghPose front = ring.pose(line: line, nominalAngle: 0);
      final CladdaghPose back = ring.pose(line: line, nominalAngle: math.pi);
      expect(front.depth, closeTo(1, 1e-9));
      expect(front.focus, closeTo(1, 1e-9));
      expect(front.blur, closeTo(0, 1e-9));
      expect(back.depth, closeTo(0, 1e-9));
      expect(back.scale, lessThan(front.scale));
      expect(back.blur, closeTo(8, 1e-9));
      expect(front.opacity, greaterThan(back.opacity));
      // 正前方位于短轴方向（旋转 -45° 后在右下）
      expect(front.x, greaterThan(0));
      expect(front.y, greaterThan(0));
    });

    test('当前行很长时，下一行转到前半环前淡出', () {
      final ({double fade, double scale}) m = claddaghLengthMitigation(
        isUpcoming: true,
        currentLen: 20,
        targetLen: 12,
        lineDiffFromCenter: 1,
      );
      expect(m.fade, closeTo(0, 1e-9));
      expect(m.scale, closeTo(0.75, 1e-9));
      expect(
        claddaghLengthMitigation(
          isUpcoming: false,
          currentLen: 20,
          targetLen: 12,
          lineDiffFromCenter: 1,
        ).fade,
        1,
      );
    });

    test('闪光：唱到瞬间转高亮，发光短暂冲高', () {
      expect(claddaghFlash(0).alpha, 0.55);
      final ({double mix, double alpha, double flashPop}) f = claddaghFlash(
        0.05,
      );
      expect(f.mix, closeTo(0.75, 1e-9));
      expect(f.flashPop, greaterThan(0.3));
      expect(claddaghFlash(1).mix, 1);
    });
  });

  group('环切换弹簧', () {
    test('相邻行之间平滑转半圈，跳行或减弱动态直接到位', () {
      final CladdaghRingSpring s = CladdaghRingSpring();
      expect(s.valueAt(0, 0, animate: true), 0);
      expect(s.valueAt(1, 1000, animate: true), closeTo(0, 1e-9));
      final double mid = s.valueAt(1, 1300, animate: true);
      expect(mid, inExclusiveRange(0, math.pi * 1.2));
      expect(s.valueAt(1, 6000, animate: true), math.pi);
      expect(s.valueAt(5, 6100, animate: true), 5 * math.pi);
      expect(s.valueAt(6, 6200, animate: false), 6 * math.pi);
    });
  });

  group('场景', () {
    testWidgets('当前行正在唱的字排在正前方并发光', (WidgetTester tester) async {
      final CladdaghScene scene = _scene();
      final CladdaghFrame f = scene.compute(1100, const Size(1280, 720));
      expect(f.centerLineIndex, 0);
      expect(f.axis, isNotNull);
      expect(f.glyphs, isNotEmpty);
      final CladdaghDraw brightest = f.glyphs.reduce(
        (CladdaghDraw a, CladdaghDraw b) => a.scale >= b.scale ? a : b,
      );
      expect(brightest.text, '夜');
      expect(brightest.glowRadius, greaterThan(0));
      expect(f.glyphs.any((CladdaghDraw d) => d.translation), isFalse);
    });

    testWidgets('开译文后沿环排出译文；关中轴线', (WidgetTester tester) async {
      final CladdaghScene scene = _scene(
        tuning: const <String, Object?>{
          'showTranslation': true,
          'showAxisLine': false,
        },
      );
      final CladdaghFrame f = scene.compute(1500, const Size(1280, 720));
      expect(f.axis, isNull);
      expect(f.glyphs.any((CladdaghDraw d) => d.translation), isTrue);
    });

    testWidgets('减弱动态：换行时环直接到位，不跟唱词转动', (WidgetTester tester) async {
      final CladdaghScene scene = _scene(motion: false);
      scene.compute(1100, const Size(1280, 720));
      final CladdaghFrame f = scene.compute(3500, const Size(1280, 720));
      expect(f.centerLineIndex, 1);
      expect(f.lineOffset, math.pi);
      expect(f.axis!.scaleX, 1);
    });

    testWidgets('第一句之前：下一句从背面淡入', (WidgetTester tester) async {
      final CladdaghScene scene = _scene();
      final CladdaghFrame f = scene.compute(800, const Size(390, 844));
      expect(f.centerLineIndex, -1);
      for (final CladdaghDraw d in f.glyphs) {
        expect(d.color.a, lessThan(0.6));
      }
    });
  });

  test('参数声明与 folia 默认一致', () {
    final CladdaghTuning t = CladdaghTuning.from(
      LyricVisualizerTuning.defaults(claddaghTuningSpecs),
    );
    expect(t.focusScaleRatio, 0.65);
    expect(t.ellipseTiltDeg, 45);
    expect(t.showAxisLine, isTrue);
    expect(t.showTranslation, isFalse);
    expect(t.focusSpacingScale, 1);
  });

  group('冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, claddaghVisualizerEntry);
    });

    testWidgets('非默认参数：放大、偏移、倾斜、译文、字距', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        claddaghVisualizerEntry,
        tuning: const <String, Object?>{
          'focusScaleRatio': 1.5,
          'radiusScale': 0.5,
          'positionX': -40.0,
          'positionY': 40.0,
          'ellipseTiltDeg': 0.0,
          'showAxisLine': false,
          'letterSpacingOffset': 20.0,
          'showTranslation': true,
          'translationScale': 2.0,
          'translationLetterSpacingOffset': -5.0,
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        claddaghVisualizerEntry,
        timeline: sampleLineTimeline(),
        tuning: const <String, Object?>{'showTranslation': true},
      );
    });

    testWidgets('减弱动态 + 暂停', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        claddaghVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('窄屏竖屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        claddaghVisualizerEntry,
        size: const Size(390, 844),
        tuning: const <String, Object?>{'showTranslation': true},
      );
    });
  });
}
