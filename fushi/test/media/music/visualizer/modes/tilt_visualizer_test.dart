import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_sentence_split.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_visualizer.dart';

import '../visualizer_test_helpers.dart';

/// 等宽假量尺：每个 UTF-16 单元 0.6em。
double _fakeMeasure(String text, double px, bool tilt) =>
    text.length * px * (tilt ? 0.66 : 0.6);

void _expectOffsetsMatch(String fullText, TiltLayout layout) {
  for (final TiltSegment s in layout.segments) {
    expect(
      fullText.substring(s.charOffset, s.charOffset + s.text.length),
      s.text,
      reason: 'segment $s',
    );
  }
}

void main() {
  group('拆句', () {
    test('目标 0–1 原样返回', () {
      expect(tiltSplitIntoSentences('夜空に光', 1), <String>['夜空に光']);
      expect(tiltSplitIntoSentences('夜空に光', 0), <String>['夜空に光']);
    });

    test('先按标点切，标点与其后空白跟在前一段', () {
      expect(tiltSplitIntoSentences('あなたと、わたし。そして', 3), <String>[
        'あなたと、',
        'わたし。',
        'そして',
      ]);
      expect(tiltSplitIntoSentences('Hello, my friend', 2), <String>[
        'Hello, ',
        'my friend',
      ]);
    });

    test('切多了按相邻最短合并', () {
      final List<String> parts = tiltSplitIntoSentences('a,b,cc,dddd', 2);
      expect(parts, hasLength(2));
      expect(parts.join(), 'a,b,cc,dddd');
      expect(parts.first, 'a,b,cc,');
    });

    test('成对括号整段成行', () {
      expect(tiltSplitIntoSentences('君の「さよなら」を聞いた', 3), <String>[
        '君の',
        '「さよなら」',
        'を聞いた',
      ]);
    });

    test('CJK 后的空格断开', () {
      expect(tiltSplitIntoSentences('君を想う 夜が来る', 2), <String>['君を想う ', '夜が来る']);
    });

    test('切不出来时在最靠中间的词边界二次切分', () {
      expect(tiltSplitIntoSentences('Hello world again', 2), <String>[
        'Hello ',
        'world again',
      ]);
    });

    test('像词的片段：拉丁连写、假名连写、汉字一字一词', () {
      expect(tiltWordLikeSpans("don't 夜空 きらきら"), <(int, int)>[
        (0, 5),
        (6, 7),
        (7, 8),
        (9, 13),
      ]);
    });

    test('拆出来拼回去等于原文', () {
      const String text = 'I wanna be the one 君のそばにいたい forever and ever';
      for (int n = 1; n <= 4; n++) {
        expect(tiltSplitIntoSentences(text, n).join(), text);
      }
    });
  });

  group('分行与斜体', () {
    test('seededRandom 稳定且落在 [0, 1)', () {
      for (int i = 0; i < 50; i++) {
        final double r = tiltSeededRandom(12.345, i);
        expect(r, greaterThanOrEqualTo(0));
        expect(r, lessThan(1));
        expect(r, tiltSeededRandom(12.345, i));
      }
    });

    test('分行概率 0 恒为一行，长句高概率拆成多行', () {
      expect(tiltDetermineLineCount(80, 3.2, 0), 1);
      expect(tiltDetermineLineCount(2, 3.2, 0.5), 1);
      expect(tiltDetermineLineCount(80, 3.2, 1), greaterThanOrEqualTo(2));
    });

    test('斜体概率 0 不出斜体，1 恰好一行斜体', () {
      const String text = '夜空に光る星を、君と数えた。あの夏の日';
      final TiltLayout none = buildTiltLayout(
        fullText: text,
        lineSeed: 4.2,
        tuning: const TiltTuning(splitProbability: 1, tiltStyleProbability: 0),
        viewportWidth: 1280,
        fontScale: 1,
        measure: _fakeMeasure,
      );
      expect(none.segments.where((TiltSegment s) => s.isTilt), isEmpty);
      _expectOffsetsMatch(text, none);

      final TiltLayout one = buildTiltLayout(
        fullText: text,
        lineSeed: 4.2,
        tuning: const TiltTuning(splitProbability: 1, tiltStyleProbability: 1),
        viewportWidth: 1280,
        fontScale: 1,
        measure: _fakeMeasure,
      );
      expect(one.segments.where((TiltSegment s) => s.isTilt), hasLength(1));
      _expectOffsetsMatch(text, one);
    });

    test('太宽时缩小，下限 0.5 / 0.55', () {
      const String text = 'Supercalifragilisticexpialidocious';
      final TiltLayout layout = buildTiltLayout(
        fullText: text,
        lineSeed: 1,
        tuning: const TiltTuning(splitProbability: 0, tiltStyleProbability: 0),
        viewportWidth: 390,
        fontScale: 1,
        measure: _fakeMeasure,
      );
      expect(layout.scaleMultiplier, lessThan(1));
      expect(layout.scaleMultiplier, greaterThanOrEqualTo(0.5));
      _expectOffsetsMatch(text, layout);
    });

    test('只有省略号的句子不拆', () {
      final TiltLayout layout = buildTiltLayout(
        fullText: '……',
        lineSeed: 1,
        tuning: const TiltTuning(splitProbability: 1),
        viewportWidth: 1280,
        fontScale: 1,
        measure: _fakeMeasure,
      );
      expect(layout.segments, hasLength(1));
    });

    test('末行只剩一两个字时标成短末行（正体放大）', () {
      // 宽到必须重拆，重拆结果的最后一段很短。
      final TiltLayout layout = buildTiltLayout(
        fullText: '一二三四五六七八，九',
        lineSeed: 2,
        tuning: const TiltTuning(splitProbability: 0, tiltStyleProbability: 0),
        viewportWidth: 1280,
        fontScale: 1,
        measure: (String text, double px, bool tilt) => text.length * px * 2.0,
      );
      expect(layout.segments.length, greaterThanOrEqualTo(2));
      expect(layout.segments.last.text, '九');
      expect(layout.segments.last.isShortLastLine, isTrue);
    });

    test('实际字号按 clamp(50px, 6.875vw, 90px) 乘倍数', () {
      expect(tiltRenderFontPx(1280, 1), closeTo(88, 1e-9));
      expect(tiltRenderFontPx(390, 1), 50);
      expect(tiltRenderFontPx(3000, 1), 90);
      expect(tiltRenderFontPx(1280, 0.5), closeTo(44, 1e-9));
      expect(tiltStaggerOffsetPx(1280, 1), closeTo(88 / 6, 1e-9));
    });
  });

  group('时间', () {
    final LyricVisualizerRuntime runtime = LyricVisualizerRuntime(
      sampleWordTimeline(),
    );

    test('段的字与时间取自字形时间线', () {
      final LyricVisualizerLine line = runtime.lines[1]; // Hello bright world
      final String full = tiltLineFullText(line);
      final TiltLayout layout = buildTiltLayout(
        fullText: full,
        lineSeed: line.startMs / 1000,
        tuning: const TiltTuning(splitProbability: 1),
        viewportWidth: 1280,
        fontScale: 1,
        measure: _fakeMeasure,
      );
      final List<TiltSegmentPlan> plans = buildTiltSegmentPlans(layout, line);
      expect(plans, hasLength(layout.segments.length));
      expect(plans.first.startMs, line.startMs);
      expect(plans.last.endMs, line.endMs);
      for (final TiltSegmentPlan p in plans) {
        expect(p.chars.map((TiltChar c) => c.text).join(), p.segment.text);
        final List<TiltChar> voiced = p.chars
            .where((TiltChar c) => !c.isSpace)
            .toList();
        for (int k = 0; k < voiced.length; k++) {
          expect(voiced[k].visualIndex, k);
          if (k > 0) {
            expect(
              voiced[k].startMs,
              greaterThanOrEqualTo(voiced[k - 1].startMs),
            );
          }
        }
      }
    });

    test('行级歌词的字形也按时间均分，各段依次显现', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleLineTimeline(),
      );
      final LyricVisualizerLine line = rt.lines[1];
      final TiltLayout layout = buildTiltLayout(
        fullText: tiltLineFullText(line),
        lineSeed: line.startMs / 1000,
        tuning: const TiltTuning(splitProbability: 1),
        viewportWidth: 1280,
        fontScale: 1,
        measure: _fakeMeasure,
      );
      final List<TiltSegmentPlan> plans = buildTiltSegmentPlans(layout, line);
      expect(plans.length, greaterThan(1));
      for (int i = 1; i < plans.length; i++) {
        expect(plans[i].startMs, greaterThan(plans[i - 1].startMs));
      }
      expect(tiltVisibleSegmentIndex(plans, line, line.startMs), 0);
      expect(
        tiltVisibleSegmentIndex(plans, line, line.endMs - 1),
        plans.length - 1,
      );
      expect(tiltVisibleSegmentIndex(plans, line, line.endMs + 1), -1);
      expect(tiltSegmentRevealAt(plans, 0, line.startMs), line.startMs);
      expect(
        tiltSegmentRevealAt(plans, 1, line.startMs),
        plans[1].startMs - kTiltSegmentLeadMs,
      );
    });

    test('字的脉动：sin 鼓起，之后余辉爬到 0.25', () {
      expect(tiltCharPulse(900, 1000, 1400), 0);
      expect(tiltCharPulse(1200, 1000, 1400), closeTo(1, 1e-9));
      expect(tiltCharPulse(1400, 1000, 1400), closeTo(0, 1e-9));
      expect(tiltCharPulse(1400 + 240, 1000, 1400), closeTo(0.125, 1e-9));
      expect(tiltCharPulse(5000, 1000, 1400), 0.25);
      // 时长夹到 0.2s 下限。
      expect(tiltCharPulse(1100, 1000, 1010), closeTo(1, 1e-9));
      expect(tiltCharPulseScale(1, true), closeTo(1.18, 1e-9));
      expect(tiltCharPulseScale(1, false), closeTo(1.15, 1e-9));
    });

    test('显隐过渡：显现带延迟，隐去从当时值回落', () {
      expect(
        tiltTransition(
          timeMs: 900,
          revealAtMs: 1000,
          hideAtMs: 3000,
          durationMs: 500,
        ),
        0,
      );
      expect(
        tiltTransition(
          timeMs: 1100,
          revealAtMs: 1000,
          hideAtMs: 3000,
          durationMs: 500,
          delayMs: 200,
        ),
        0,
      );
      expect(
        tiltTransition(
          timeMs: 2000,
          revealAtMs: 1000,
          hideAtMs: 3000,
          durationMs: 500,
        ),
        1,
      );
      final double mid = tiltTransition(
        timeMs: 1250,
        revealAtMs: 1000,
        hideAtMs: 1250,
        durationMs: 500,
      );
      expect(mid, closeTo(kTiltEase.transform(0.5), 1e-9));
      expect(
        tiltTransition(
          timeMs: 1500,
          revealAtMs: 1000,
          hideAtMs: 1250,
          durationMs: 500,
        ),
        closeTo(mid * (1 - kTiltEase.transform(0.5)), 1e-9),
      );
      expect(
        tiltTransition(
          timeMs: 4000,
          revealAtMs: 1000,
          hideAtMs: 3000,
          durationMs: 500,
        ),
        0,
      );
    });
  });

  group('参数', () {
    test('默认值与 folia 一致，概率夹在 0–1', () {
      final TiltTuning d = TiltTuning.of(
        LyricVisualizerTuning.defaults(tiltTuningSpecs),
      );
      expect(d, const TiltTuning());
      expect(d.splitProbability, 0.75);
      expect(d.tiltStyleProbability, 0.35);
      expect(d.colorScheme, TiltColorScheme.dual);
      final TiltTuning s = TiltTuning.of(
        LyricVisualizerTuning(tiltTuningSpecs, const <String, Object?>{
          TiltTuningKeys.splitProbability: 3.0,
          TiltTuningKeys.colorScheme: 'swap',
        }),
      );
      expect(s.splitProbability, 1);
      expect(s.colorScheme, TiltColorScheme.swap);
    });

    test('配色方案：正体 / 斜体用主色还是强调色', () {
      const LyricVisualizerPalette p = LyricVisualizerPalette(
        background: Color(0xFF000000),
        primary: Color(0xFFFF0000),
        secondary: Color(0xFF00FF00),
        accent: Color(0xFF0000FF),
        text: Color(0xFFFFFFFF),
        dimText: Color(0x80FFFFFF),
        brightness: Brightness.dark,
      );
      final TiltColors dual = resolveTiltColors(TiltColorScheme.dual, p);
      expect(dual.normal, p.text);
      expect(dual.tilt, p.primary);
      final TiltColors swap = resolveTiltColors(TiltColorScheme.swap, p);
      expect(swap.normal, p.primary);
      expect(swap.tilt, p.text);
      expect(resolveTiltColors(TiltColorScheme.accentAll, p).normal, p.primary);
      expect(resolveTiltColors(TiltColorScheme.primaryAll, p).tilt, p.text);
    });
  });

  group('挂载', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, tiltVisualizerEntry);
    });

    testWidgets('全拆分 + 必斜体 + 换配色', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        tiltVisualizerEntry,
        tuning: <String, Object?>{
          TiltTuningKeys.splitProbability: 1.0,
          TiltTuningKeys.tiltStyleProbability: 1.0,
          TiltTuningKeys.colorScheme: 'accentAll',
        },
      );
    });

    testWidgets('不拆分 + 不斜体', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        tiltVisualizerEntry,
        tuning: <String, Object?>{
          TiltTuningKeys.splitProbability: 0.0,
          TiltTuningKeys.tiltStyleProbability: 0.0,
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        tiltVisualizerEntry,
        timeline: sampleLineTimeline(),
        timesMs: const <int>[0, 600, 1500, 2900, 3100, 4500, 5900, 6500],
      );
    });

    testWidgets('减弱动态效果', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, tiltVisualizerEntry, motion: false);
    });

    testWidgets('窄屏 + 行级长句', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        tiltVisualizerEntry,
        size: const Size(390, 844),
        timeline: sampleLineTimeline(),
        tuning: <String, Object?>{TiltTuningKeys.tiltStyleProbability: 1.0},
      );
      await pumpVisualizerAcross(
        tester,
        tiltVisualizerEntry,
        size: const Size(390, 844),
      );
    });
  });
}
