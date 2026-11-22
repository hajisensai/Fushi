import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_geometry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_visualizer.dart';

import '../visualizer_test_helpers.dart';

void main() {
  group('轮盘布局', () {
    const PendoloTuning tuning = PendoloTuning();

    test('焦点句在刻度针方向（角度 0），后面的句子往下排', () {
      final List<PendoloLineItem> items = calculatePendoloWheelLayout(
        lineCount: 20,
        targetLineIndex: 5,
        viewportWidth: 1280,
        viewportHeight: 720,
        tuning: tuning,
      );
      final PendoloLineItem focal = items.firstWhere(
        (PendoloLineItem i) => i.index == 5,
      );
      expect(focal.isActive, isTrue);
      expect(focal.angleRad, 0);
      expect(focal.scale, tuning.activeScale);
      expect(focal.x, closeTo(720 * 0.42, 1e-9));
      expect(focal.y, closeTo(360, 1e-9));
      final PendoloLineItem next = items.firstWhere(
        (PendoloLineItem i) => i.index == 6,
      );
      expect(next.angleRad, closeTo(pendoloAngleStepRad(100), 1e-9));
      expect(next.y, greaterThan(focal.y));
      expect(next.alpha, lessThan(focal.alpha));
      // 只排在右半圆内。
      for (final PendoloLineItem i in items) {
        expect(i.angleRad.abs(), lessThan(math.pi / 2));
      }
    });

    test('块高度大时间距撑开', () {
      final List<PendoloLineItem> tight = calculatePendoloWheelLayout(
        lineCount: 10,
        targetLineIndex: 2,
        viewportWidth: 1280,
        viewportHeight: 720,
        tuning: tuning,
      );
      final List<PendoloLineItem> wide = calculatePendoloWheelLayout(
        lineCount: 10,
        targetLineIndex: 2,
        viewportWidth: 1280,
        viewportHeight: 720,
        tuning: tuning,
        lineBlockHeights: List<double>.filled(10, 200),
      );
      double angleOf(List<PendoloLineItem> l, int i) =>
          l.firstWhere((PendoloLineItem x) => x.index == i).angleRad;
      expect(angleOf(wide, 3), greaterThan(angleOf(tight, 3)));
      expect(
        angleOf(wide, 3),
        closeTo((200 + 200 + 24) / (2 * 720 * 0.42), 1e-9),
      );
    });

    test('镜像：轮心在右，弧朝左', () {
      const PendoloTuning mirrored = PendoloTuning(mirrored: true);
      final List<PendoloLineItem> items = calculatePendoloWheelLayout(
        lineCount: 5,
        targetLineIndex: 0,
        viewportWidth: 1000,
        viewportHeight: 800,
        tuning: mirrored,
      );
      expect(pendoloWheelCenterX(1000, mirrored), 1000);
      expect(items.first.x, lessThan(1000));
    });

    test('间奏里锚点在两句之间：没有焦点句，两边对称', () {
      final List<PendoloLineItem> items = calculatePendoloWheelLayout(
        lineCount: 6,
        targetLineIndex: 2.5,
        viewportWidth: 1280,
        viewportHeight: 720,
        tuning: tuning,
      );
      expect(items.any((PendoloLineItem i) => i.isActive), isFalse);
      final double a2 = items
          .firstWhere((PendoloLineItem i) => i.index == 2)
          .angleRad;
      final double a3 = items
          .firstWhere((PendoloLineItem i) => i.index == 3)
          .angleRad;
      expect(a2, closeTo(-a3, 1e-9));
    });
  });

  group('时间线', () {
    test('锚点：焦点 / 间奏 / 开头之前 / 全曲唱完', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      expect(pendoloTargetIndexAt(rt, 500), -1);
      expect(pendoloTargetIndexAt(rt, 2000), 0);
      expect(pendoloTargetIndexAt(rt, 3300), 0.5);
      expect(pendoloTargetIndexAt(rt, 3600), 1);
      expect(pendoloTargetIndexAt(rt, 8000), 1.5);
      expect(pendoloTargetIndexAt(rt, 60000), rt.lines.length.toDouble());
    });

    test('没有歌词时每 5 秒走一格', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        const LyricTimeline(format: 'lrc', lines: <LyricLine>[]),
      );
      expect(pendoloTargetIndexAt(rt, 12000), 2);
    });

    test('可见弧：110° 外看不见，边缘 28° 淡入', () {
      expect(pendoloRotatingLineOpacity(100, 15, 1), 0);
      expect(pendoloRotatingLineOpacity(0, 0, 0.8), 0.8);
      expect(pendoloRotatingLineOpacity(96, 0, 1), closeTo(0.5, 1e-9));
      expect(pendoloStandEdgeFade(70), closeTo(0.5, 1e-9));
      expect(pendoloStandSideLineAlpha(1), closeTo(0.18, 1e-9));
      expect(pendoloStandSideLineAlpha(4), 1);
    });
  });

  group('擒纵与机芯', () {
    test('弹簧趋向目标并停稳', () {
      final PendoloSpring spring = PendoloSpring(0);
      double peak = 0;
      for (int i = 0; i < 120; i++) {
        spring.step(1, 1 / 60, 2);
        peak = math.max(peak, spring.value);
      }
      expect(spring.value, closeTo(1, 1e-3));
      expect(peak, lessThan(1.2));
    });

    test('秒齿轮每秒走一齿；暂停冻结相位', () {
      final PendoloClockworkMotion m = PendoloClockworkMotion();
      for (int i = 0; i < 150; i++) {
        m.step(1 / 60, 0.2, paused: false);
      }
      expect(m.secondGearStep, 2);
      expect(m.secondGearAngle, greaterThan(0));
      final double phase = m.phase;
      m.step(0.05, 0.2, paused: true);
      expect(m.phase, phase);
    });
  });

  group('投影', () {
    test('不倾斜是单位阵；倾斜时轮心不动', () {
      final PendoloDialProjection flat = buildPendoloTiltProjection(
        0,
        0,
        1280,
        720,
      );
      expect(flat.flat, isTrue);
      final ({double x, double y, double depthScale}) p = flat.project(30, -40);
      expect(p.x, 30);
      expect(p.y, -40);
      final PendoloDialProjection tilted = buildPendoloTiltProjection(
        40,
        0,
        1280,
        720,
      );
      expect(tilted.flat, isFalse);
      final ({double x, double y, double depthScale}) hub = tilted.project(
        0,
        0,
      );
      expect(hub.x, 0);
      expect(hub.y, 0);
      // 水平轴前后俯仰：轴上方往里退（缩小），下方朝外（放大）。
      expect(tilted.project(0, -100).depthScale, lessThan(1));
      expect(tilted.project(0, 100).depthScale, greaterThan(1));
    });

    test('镜像翻转横坐标；平放时分层高度不起作用', () {
      final PendoloDialProjection flat = buildPendoloTiltProjection(
        0,
        0,
        1280,
        720,
      );
      final PendoloDialProjection mirror = buildPendoloDialProjection(
        flat,
        mirrored: true,
      );
      expect(mirror.project(50, 10).x, -50);
      expect(identical(buildPendoloLayerProjection(flat, 40), flat), isTrue);
    });

    test('轮心视角把焦点句投到屏幕固定位置', () {
      final PendoloDialProjection hub = buildPendoloHubViewProjection(
        cameraHeightPx: 400,
        backDistancePx: 300,
        targetDistancePx: 350,
        side: 1,
        hubX: 0,
        hubY: 360,
        viewportWidth: 1280,
        viewportHeight: 720,
      );
      final ({double x, double y, double depthScale}) p = hub.project(350, 0);
      expect(p.x, closeTo(640, 1e-6));
      expect(p.y, closeTo(720 * 0.42 - 360, 1e-6));
      expect(p.depthScale, closeTo(1, 1e-9));
      expect(hub.frontHalfPlane(0.08, 1000)!.minX, lessThan(0));
    });
  });

  group('逐字扫光', () {
    const PendoloSweepRow row = PendoloSweepRow(
      left: 0,
      right: 60,
      top: 0,
      bottom: 30,
      glyphs: <PendoloSweepGlyph>[
        PendoloSweepGlyph(left: 0, right: 30, startMs: 1000, endMs: 1400),
        PendoloSweepGlyph(left: 30, right: 60, startMs: 1600, endMs: 2000),
      ],
    );

    test('起唱前不亮，字内线性推进，字间停在下一字左端，唱完到行尾', () {
      expect(pendoloSweepEdge(row, 900, 2000), isNull);
      expect(pendoloSweepEdge(row, 1200, 2000), closeTo(15, 1e-9));
      expect(pendoloSweepEdge(row, 1500, 2000), 30);
      expect(pendoloSweepEdge(row, 5000, 2000), 60);
    });

    testWidgets('焦点句按字形分行：CJK 与英文都拿到每个非空白字', (WidgetTester tester) async {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      for (final LyricVisualizerLine line in rt.lines) {
        final PendoloLineBlock block = PendoloLineBlock.build(
          line: line,
          focal: true,
          fontScale: 1,
          maxWidth: 120,
          align: PendoloAlign.left,
          primary: Colors.white,
          fillColor: Colors.amber,
          secondary: Colors.grey,
        );
        final int glyphs = block.rows.fold<int>(
          0,
          (int n, PendoloSweepRow r) => n + r.glyphs.length,
        );
        expect(
          glyphs,
          line.glyphs.where((LyricVisualizerGlyph g) => !g.isSpace).length,
        );
        expect(block.width, lessThanOrEqualTo(120.5));
        block.dispose();
      }
    });
  });

  group('冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, pendoloVisualizerEntry);
    });

    testWidgets('镜像 + 倾斜 + 完整饰线 + 发光', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        tuning: <String, Object?>{
          PendoloTuningKeys.mirrorLayout: true,
          PendoloTuningKeys.tiltDeg: 35.0,
          PendoloTuningKeys.tiltAxisDeg: 20.0,
          PendoloTuningKeys.parallaxDepth: 1.65,
          PendoloTuningKeys.showGearDecor: 'full',
          PendoloTuningKeys.enableLineGlow: true,
          PendoloTuningKeys.showCoverOnWatchFace: true,
          PendoloTuningKeys.wheelCenterX: 0.1,
          PendoloTuningKeys.activeScale: 1.5,
        },
      );
    });

    testWidgets('轮心视角 + 无饰线 + 无渐变', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        tuning: <String, Object?>{
          PendoloTuningKeys.hubView: true,
          PendoloTuningKeys.hubViewHeight: 0.6,
          PendoloTuningKeys.hubViewBack: 0.2,
          PendoloTuningKeys.showGearDecor: 'none',
          PendoloTuningKeys.showCenterGradient: false,
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('减弱动态 + 暂停', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('窄屏竖屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        size: const Size(390, 844),
      );
    });

    test('参数声明：默认值与 folia 一致', () {
      final LyricVisualizerTuning defaults = LyricVisualizerTuning.defaults(
        pendoloVisualizerEntry.tunings,
      );
      final PendoloTuning tu = PendoloTuning.read(defaults);
      expect(tu.arcRadius, 0.42);
      expect(tu.arcAngleDeg, 100);
      expect(tu.tickSnappiness, 2);
      expect(tu.activeScale, 1.25);
      expect(tu.gearDecor, PendoloGearDecor.subtle);
      expect(tu.showCenterGradient, isTrue);
      expect(pendoloVisualizerEntry.sharedSubtitle, isFalse);
    });
  });
}
