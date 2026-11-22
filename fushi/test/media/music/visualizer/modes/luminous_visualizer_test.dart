import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_timing.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_visualizer.dart';

import '../visualizer_test_helpers.dart';

LyricVisualizerRuntime _runtimeOf(List<LyricLine> lines) =>
    LyricVisualizerRuntime(LyricTimeline(format: 'ttml', lines: lines));

LyricLine _line(int start, List<(String, int)> parts) {
  final List<LyricSyllable> syl = <LyricSyllable>[];
  int t = start;
  for (final (String text, int d) in parts) {
    syl.add(LyricSyllable(text: text, startMs: t, endMs: t + d));
    t += d;
  }
  return LyricLine(startMs: start, endMs: t, syllables: syl);
}

const LuminousLayoutParams _normal = LuminousLayoutParams(
  intensity: LuminousIntensity.normal,
  rotation: true,
  legacy: false,
  wordSpacing: 0.7,
  avoidOverlap: false,
);

double _fakeMeasure(String text, double fontSize) =>
    text.length * fontSize * 0.6;

void main() {
  group('时序', () {
    test('渲染提示按行长分档', () {
      final LuminousRenderProfile normal = LuminousRenderProfile.fromTimes(
        startS: 1,
        endS: 3,
        lastWordEndS: 3,
      );
      expect(normal.lineTransition, LuminousLineTransition.normal);
      expect(normal.wordReveal, LuminousWordReveal.normal);
      expect(normal.wordLookahead, 0.15);
      // 尾巴：passStart = 3.06，exit = min(.32, max(.18, 2*.18)) = .32
      expect(normal.lineRenderEnd, closeTo(3.38, 1e-9));

      final LuminousRenderProfile fast = LuminousRenderProfile.fromTimes(
        startS: 1,
        endS: 1.15,
        lastWordEndS: 1.15,
      );
      expect(fast.lineTransition, LuminousLineTransition.fast);
      expect(fast.wordReveal, LuminousWordReveal.fast);
      expect(fast.wordLookahead, 0.08);

      final LuminousRenderProfile micro = LuminousRenderProfile.fromTimes(
        startS: 1,
        endS: 1.02,
        lastWordEndS: 1.02,
      );
      expect(micro.lineTransition, LuminousLineTransition.none);
      expect(micro.wordReveal, LuminousWordReveal.instant);
      expect(micro.lineRenderEnd, closeTo(1.067, 1e-9));
      // instant：词一直亮到行尾
      expect(micro.activeEnd(1, 1.01), micro.lineRenderEnd);
    });

    test('弹簧：0 起步、过冲、收敛到 1', () {
      expect(luminousSpring(0), 0);
      double peak = 0;
      for (double t = 0; t < 1; t += 0.01) {
        peak = math.max(peak, luminousSpring(t));
      }
      expect(peak, greaterThan(1)); // ζ≈0.707 欠阻尼
      expect(luminousSpring(1.5), closeTo(1, 1e-3));
    });

    test('关键帧逐段插值', () {
      expect(
        luminousKeyframes(
          0.5,
          1,
          <double>[0, 1, 0],
          <double>[0, 0.5, 1],
          Curves.linear,
        ),
        closeTo(1, 1e-9),
      );
      expect(
        luminousKeyframes(
          0.75,
          1,
          <double>[0, 1, 0],
          <double>[0, 0.5, 1],
          Curves.linear,
        ),
        closeTo(0.5, 1e-9),
      );
      expect(
        luminousKeyframes(
          2,
          1,
          <double>[0, 1, 0.3],
          <double>[0, 0.5, 1],
          Curves.linear,
        ),
        0.3,
      );
    });

    test('词三态姿态', () {
      final LuminousRenderProfile p = LuminousRenderProfile.fromTimes(
        startS: 1,
        endS: 3,
        lastWordEndS: 3,
      );
      final LuminousWordSchedule s = LuminousWordSchedule.of(
        profile: p,
        wordStart: 1.5,
        wordEnd: 2,
        mountAt: 1,
      );
      expect(s.activeAt, closeTo(1.35, 1e-9));
      expect(s.passedAt, 2);
      const LuminousWordConfig c = LuminousWordConfig(
        x: 4,
        y: -6,
        rotate: 3,
        scale: 1.2,
        passedRotate: 10,
      );
      final LuminousWordPose waiting = luminousWordPoseAt(
        t: 1.2,
        schedule: s,
        config: c,
        rotation: true,
        intensity: LuminousIntensity.normal,
      );
      expect(waiting.opacity, 0);
      expect(waiting.scale, 0.5);
      expect(waiting.rotate, 23);
      expect(waiting.x, closeTo(4 + math.sin(-6) * 100, 1e-9));

      // 足够长的 active 区间后贴近 active 姿态
      final LuminousWordSchedule longActive = LuminousWordSchedule.of(
        profile: p,
        wordStart: 1.5,
        wordEnd: 3,
        mountAt: 1,
      );
      final LuminousWordPose active = luminousWordPoseAt(
        t: 2.9,
        schedule: longActive,
        config: c,
        rotation: true,
        intensity: LuminousIntensity.normal,
      );
      expect(active.opacity, 1);
      expect(active.scale, closeTo(1.2 * luminousActiveScale, 1e-3));
      expect(active.rotate, closeTo(3, 1e-2));

      final LuminousWordPose passed = luminousWordPoseAt(
        t: 9,
        schedule: s,
        config: c,
        rotation: true,
        intensity: LuminousIntensity.normal,
      );
      expect(passed.opacity, closeTo(0.82, 1e-9));
      expect(passed.scale, closeTo(1.2, 1e-9));
      expect(passed.rotate, closeTo(13, 1e-9));
      // passed 后旋转 5 秒线性，2.5 秒时转过一半
      final LuminousWordPose half = luminousWordPoseAt(
        t: 4.5,
        schedule: s,
        config: c,
        rotation: true,
        intensity: LuminousIntensity.normal,
      );
      expect(half.rotate, greaterThan(3));
      expect(half.rotate, lessThan(13));
    });

    test('正文颜色与光晕包络', () {
      final LuminousRenderProfile p = LuminousRenderProfile.fromTimes(
        startS: 0,
        endS: 4,
        lastWordEndS: 4,
      );
      final LuminousWordSchedule s = LuminousWordSchedule.of(
        profile: p,
        wordStart: 1,
        wordEnd: 2,
        mountAt: 0,
      );
      expect(
        luminousBodyAt(t: 0.5, schedule: s, reveal: p.wordReveal).blur,
        10,
      );
      final LuminousBodyState mid = luminousBodyAt(
        t: s.activeAt + s.duration / 2,
        schedule: s,
        reveal: p.wordReveal,
      );
      expect(mid.highlight, closeTo(0.5, 1e-9));
      expect(mid.blur, 0);
      expect(
        luminousBodyAt(t: 5, schedule: s, reveal: p.wordReveal).highlight,
        0,
      );

      // 单字：持续发光，到 90% 时长到峰值
      expect(
        luminousGlowAt(
          t: s.activeAt + s.duration * 0.95,
          schedule: s,
          reveal: p.wordReveal,
          glyphCount: 1,
        ),
        1,
      );
      // 多字：后面的字形按自己的起点延迟
      expect(
        luminousGlowAt(
          t: s.activeAt + 0.05,
          schedule: s,
          reveal: p.wordReveal,
          glyphCount: 4,
          charStart: 1.75,
          charEnd: 2,
          glyphIndex: 3,
        ),
        0,
      );
      expect(
        luminousGlowAt(
          t: s.activeAt + 0.75 + 0.25 * 6 * 0.3,
          schedule: s,
          reveal: p.wordReveal,
          glyphCount: 4,
          charStart: 1.75,
          charEnd: 2,
          glyphIndex: 3,
        ),
        greaterThan(0),
      );
      // passed 0.9 秒后熄灭
      expect(
        luminousGlowAt(
          t: 3.5,
          schedule: s,
          reveal: p.wordReveal,
          glyphCount: 1,
        ),
        0,
      );
    });

    test('呼吸浮动', () {
      expect(luminousBreathAt(3, 0, LuminousIntensity.normal).dy, 0);
      final LuminousBreath quarter = luminousBreathAt(
        7 * 0.25,
        1,
        LuminousIntensity.normal,
      );
      expect(quarter.dy, closeTo(-14, 1e-9));
      expect(quarter.scale, closeTo(1.01, 1e-9));
      expect(
        luminousBreathAt(8.5 * 0.25, 2, LuminousIntensity.calm).dy,
        closeTo(-20, 1e-9),
      );
    });

    test('入场 / 离场', () {
      expect(luminousLineEnterFx(LuminousLineTransition.normal, 0).opacity, 0);
      expect(
        luminousLineEnterFx(LuminousLineTransition.normal, 2).isSteady,
        isTrue,
      );
      final LuminousLineFx out = luminousLineExitFx(
        LuminousLineTransition.normal,
        0.3,
      );
      expect(out.opacity, 0);
      expect(out.scale, closeTo(1.1, 1e-9));
      expect(out.blur, closeTo(20, 1e-9));
    });
  });

  group('排版', () {
    test('哈希随机与 folia 同式', () {
      final double x = math.sin(12.5 + 3 + 4) * 10000;
      expect(luminousHashRandom(12.5, 3, 4), closeTo(x - x.floor(), 1e-12));
      final double r = luminousHashRandom(1.234, 0, 1);
      expect(r, inInclusiveRange(0, 1));
    });

    test('粘连标点并入前一个词；旧版不并', () {
      final LyricVisualizerRuntime rt = _runtimeOf(<LyricLine>[
        _line(0, <(String, int)>[('世', 200), ('界', 200), ('。', 100)]),
      ]);
      final List<LuminousDisplayWord> adaptive = luminousDisplayWords(
        rt.lines.first,
        adaptive: true,
      );
      expect(adaptive.map((LuminousDisplayWord w) => w.text).toList(), <String>[
        '世',
        '界。',
      ]);
      expect(adaptive.last.glyphs.length, 2);
      expect(luminousDisplayWords(rt.lines.first, adaptive: false).length, 3);
    });

    test('间奏与 RTL 判定', () {
      expect(luminousIsInterlude('......'), isTrue);
      expect(luminousIsInterlude('…'), isFalse);
      expect(luminousIsInterlude('Hello'), isFalse);
      expect(luminousIsRtl('مرحبا بالعالم'), isTrue);
      expect(luminousIsRtl('Hello مرحبا'), isFalse);
    });

    test('字号 clamp', () {
      expect(luminousFontSize(390, 1), 36);
      expect(luminousFontSize(1000, 1), 60);
      expect(luminousFontSize(1920, 1), 72);
      expect(luminousFontSize(1920, 0.5), 36);
    });

    test('平静强度：居中、不旋转不偏移；边距不小于下限', () {
      final LuminousLinePlan plan = luminousPlanLine(
        seed: 3.4,
        wordWidths: <double>[100, 80, 120],
        fontSize: 40,
        params: const LuminousLayoutParams(
          intensity: LuminousIntensity.calm,
          rotation: true,
          legacy: false,
          wordSpacing: 0.7,
          avoidOverlap: false,
        ),
        interlude: false,
        rtl: false,
      );
      expect(plan.justify, LuminousJustify.center);
      for (final LuminousWordConfig c in plan.configs) {
        expect(c.rotate, 0);
        expect(c.x, 0);
        expect(c.y, 0);
        expect(c.scale, inInclusiveRange(1.1, 1.3));
      }
      for (final double m in plan.margins) {
        expect(m, greaterThanOrEqualTo(0.12 * 40 * 0.7 - 0.05));
      }
      expect(plan.rowGap, isNull);
    });

    test('justify 下标 = floor(seed % 5)', () {
      LuminousJustify j(double seed) => luminousPlanLine(
        seed: seed,
        wordWidths: <double>[50],
        fontSize: 40,
        params: _normal,
        interlude: false,
        rtl: false,
      ).justify;
      expect(j(0.5), LuminousJustify.start);
      expect(j(1.5), LuminousJustify.center);
      expect(j(7.2), LuminousJustify.end);
      expect(j(13.9), LuminousJustify.around);
      expect(j(4.1), LuminousJustify.between);
    });

    test('旧版边距 0.8rem；关旋转无角度；旧版不防重叠', () {
      final LuminousLinePlan plan = luminousPlanLine(
        seed: 7.2,
        wordWidths: <double>[50, 50],
        fontSize: 40,
        params: const LuminousLayoutParams(
          intensity: LuminousIntensity.normal,
          rotation: false,
          legacy: true,
          wordSpacing: 0.7,
          avoidOverlap: true,
        ),
        interlude: false,
        rtl: false,
      );
      expect(plan.margins, <double>[12.8, 12.8]);
      for (final LuminousWordConfig c in plan.configs) {
        expect(c.rotate, 0);
        expect(c.passedRotate, 0);
      }
      expect(plan.rowGap, isNull);
    });

    test('防重叠：边距不小于两词伸出量之和，留出行距', () {
      const LuminousLayoutParams p = LuminousLayoutParams(
        intensity: LuminousIntensity.chaotic,
        rotation: true,
        legacy: false,
        wordSpacing: 0,
        avoidOverlap: true,
      );
      final List<double> widths = <double>[120, 90, 150];
      final LuminousLinePlan plan = luminousPlanLine(
        seed: 2.25,
        wordWidths: widths,
        fontSize: 48,
        params: p,
        interlude: false,
        rtl: false,
      );
      for (int i = 0; i + 1 < widths.length; i++) {
        final double pair = luminousPairGap(
          widths[i],
          plan.configs[i],
          widths[i + 1],
          plan.configs[i + 1],
          48,
        );
        expect(plan.margins[i], greaterThanOrEqualTo(pair - 0.06));
      }
      expect(plan.rowGap, isNotNull);
      expect(plan.rowGap, greaterThan(0));
    });

    test('间奏：放大 1.5、不旋转、3rem 边距', () {
      final LuminousLinePlan plan = luminousPlanLine(
        seed: 2,
        wordWidths: <double>[60],
        fontSize: 40,
        params: _normal,
        interlude: true,
        rtl: false,
      );
      expect(plan.justify, LuminousJustify.center);
      expect(plan.configs.single.scale, 1.5);
      expect(plan.configs.single.rotate, 0);
      expect(plan.margins.single, 48);
    });

    test('flex-wrap：换行、居中、RTL 镜像', () {
      final LuminousFlow flow = luminousFlow(
        widths: <double>[100, 100, 100],
        margins: <double>[10, 10, 10],
        containerWidth: 250,
        rowHeight: 50,
        justify: LuminousJustify.center,
        rtl: false,
      );
      expect(flow.rows, 2);
      expect(flow.slots[0].left, closeTo((250 - 220) / 2, 1e-9));
      expect(flow.slots[2].top, greaterThan(flow.slots[0].top));
      expect(flow.height, 300); // min-height
      expect(flow.slots[0].top, closeTo((300 - 100) / 2, 1e-9));

      final LuminousFlow rtl = luminousFlow(
        widths: <double>[100, 50],
        margins: <double>[10, 10],
        containerWidth: 400,
        rowHeight: 50,
        justify: LuminousJustify.start,
        rtl: true,
      );
      expect(rtl.slots[0].left, 300);
      expect(rtl.slots[1].left, 400 - 110 - 50);

      final LuminousFlow between = luminousFlow(
        widths: <double>[100, 100],
        margins: <double>[0, 0],
        containerWidth: 400,
        rowHeight: 50,
        justify: LuminousJustify.between,
        rtl: false,
        rowGap: 20,
        reachTop: 5,
        reachBottom: 7,
      );
      expect(between.slots[1].left, 300);
      expect(between.height, 50 + 5 + 7);
    });

    test('整句排版：窄屏长词缩到放得下；防重叠高度放得下', () {
      final LyricVisualizerRuntime rt = _runtimeOf(<LyricLine>[
        _line(0, <(String, int)>[('Supercalifragilisticexpialidocious', 900)]),
      ]);
      final LuminousLineLayout l = luminousLayoutLine(
        line: rt.lines.first,
        area: const Size(390, 844),
        fontScale: 1,
        params: _normal,
        measure: _fakeMeasure,
      );
      expect(l.widths.single, lessThanOrEqualTo(390 - 64));

      final LyricVisualizerRuntime many = _runtimeOf(<LyricLine>[
        _line(0, <(String, int)>[for (int i = 0; i < 40; i++) ('字', 50)]),
      ]);
      final LuminousLineLayout fit = luminousLayoutLine(
        line: many.lines.first,
        area: const Size(390, 500),
        fontScale: 1,
        params: const LuminousLayoutParams(
          intensity: LuminousIntensity.normal,
          rotation: true,
          legacy: false,
          wordSpacing: 0.7,
          avoidOverlap: true,
        ),
        measure: _fakeMeasure,
      );
      expect(fit.fontSize, lessThan(36));
      expect(fit.fontSize, greaterThanOrEqualTo(18));
    });

    test('可见句：换句时上一句离场', () {
      final LyricVisualizerRuntime rt = _runtimeOf(<LyricLine>[
        _line(1000, <(String, int)>[('a', 1000)]),
        _line(2000, <(String, int)>[('b', 1000)]),
      ]);
      final List<LuminousVisibleLine> v = luminousVisibleLines(
        rt,
        2.1,
        motion: true,
      );
      expect(v.length, 2);
      expect(v.first.index, 0);
      expect(v.first.exiting, isTrue);
      expect(v.last.index, 1);
      expect(v.last.exiting, isFalse);
      expect(luminousVisibleLines(rt, 2.1, motion: false).length, 1);
      expect(luminousVisibleLines(rt, 0.5, motion: true), isEmpty);
      // 最后一句渲染尾巴结束后再离场完就空了
      expect(luminousVisibleLines(rt, 10, motion: true), isEmpty);
    });

    test('参数读取', () {
      final LuminousLayoutParams p = luminousParamsOf(
        LyricVisualizerTuning(luminousTunings, const <String, Object?>{
          LuminousTuningKeys.animationIntensity: 'chaotic',
          LuminousTuningKeys.layoutMode: 'legacy',
          LuminousTuningKeys.wordSpacing: 5.0,
        }),
      );
      expect(p.intensity, LuminousIntensity.chaotic);
      expect(p.legacy, isTrue);
      expect(p.wordSpacing, 2); // 夹到上限
      expect(p.rotation, isTrue);
    });
  });

  group('流光冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, luminousVisualizerEntry);
    });

    testWidgets('混乱强度 + 防重叠 + 关旋转 + 呼吸 2×', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        luminousVisualizerEntry,
        tuning: <String, Object?>{
          LuminousTuningKeys.animationIntensity: 'chaotic',
          LuminousTuningKeys.avoidOverlap: true,
          LuminousTuningKeys.enableWordRotation: false,
          LuminousTuningKeys.breathingFloatMultiplier: 2.0,
          LuminousTuningKeys.wordSpacing: 1.5,
        },
      );
    });

    testWidgets('旧版排版 + 平静', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        luminousVisualizerEntry,
        tuning: <String, Object?>{
          LuminousTuningKeys.layoutMode: 'legacy',
          LuminousTuningKeys.animationIntensity: 'calm',
          LuminousTuningKeys.breathingFloatMultiplier: 0.0,
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        luminousVisualizerEntry,
        timeline: sampleLineTimeline(),
        timesMs: const <int>[0, 600, 1500, 2990, 3100, 4500, 5900, 7000],
      );
    });

    testWidgets('减弱动态效果', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        luminousVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('窄屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        luminousVisualizerEntry,
        size: const Size(390, 844),
        timeline: sampleLineTimeline(),
        timesMs: const <int>[600, 2000, 3500, 5500],
      );
      await pumpVisualizerAcross(
        tester,
        luminousVisualizerEntry,
        size: const Size(390, 844),
        tuning: <String, Object?>{LuminousTuningKeys.avoidOverlap: true},
      );
    });

    testWidgets('有句子时确实在画', (WidgetTester tester) async {
      final FakeVisualizerClock clock = FakeVisualizerClock(1500);
      final LyricVisualizerContext c = visualizerContextFor(
        luminousVisualizerEntry,
        clock: clock,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox.expand(child: luminousVisualizerEntry.builder(c)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(LuminousVisualizer), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
