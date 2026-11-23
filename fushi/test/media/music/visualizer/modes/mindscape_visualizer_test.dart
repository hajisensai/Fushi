import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/mindscape/mindscape_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/mindscape/mindscape_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/mindscape/mindscape_timing.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/mindscape/mindscape_visualizer.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import '../visualizer_test_helpers.dart';

/// 假尺子：CJK 一个字 = 1em，其余 0.55em。
double _fakeMeasure(String text, double fontPx) {
  double w = 0;
  for (final int r in text.runes) {
    final String ch = String.fromCharCode(r);
    w += lyricVisualizerIsCjk(ch) ? fontPx : fontPx * 0.55;
  }
  return w;
}

LyricTimeline _repeatTimeline() => const LyricTimeline(
  format: 'lrc',
  lines: <LyricLine>[
    LyricLine(
      startMs: 0,
      endMs: 1000,
      syllables: <LyricSyllable>[
        LyricSyllable(text: 'la la', startMs: 0, endMs: 1000),
      ],
    ),
    LyricLine(
      startMs: 1000,
      endMs: 2000,
      syllables: <LyricSyllable>[
        LyricSyllable(text: 'verse', startMs: 1000, endMs: 2000),
      ],
    ),
    LyricLine(
      startMs: 2000,
      endMs: 3000,
      syllables: <LyricSyllable>[
        LyricSyllable(text: 'la la', startMs: 2000, endMs: 3000),
      ],
    ),
  ],
);

void main() {
  group('时序', () {
    test('行时长分档：极短 / 短 / 正常', () {
      final MindscapeLineTiming micro = resolveMindscapeLineTiming(
        startTime: 1,
        endTime: 1.05,
        lastWordEndTime: 1.05,
      );
      expect(micro.wordReveal, LyricVisualizerWordReveal.instant);
      expect(micro.lineTransition, LyricVisualizerLineTransition.none);
      expect(micro.lineRenderEndTime, closeTo(1.067, 1e-9));

      final MindscapeLineTiming short = resolveMindscapeLineTiming(
        startTime: 1,
        endTime: 1.15,
        lastWordEndTime: 1.15,
      );
      expect(short.wordReveal, LyricVisualizerWordReveal.fast);

      final MindscapeLineTiming normal = resolveMindscapeLineTiming(
        startTime: 1,
        endTime: 3,
        lastWordEndTime: 2.9,
      );
      expect(normal.wordReveal, LyricVisualizerWordReveal.normal);
      expect(normal.transition.enterDuration, closeTo(0.42, 1e-9));
      expect(normal.transition.exitDuration, closeTo(0.32, 1e-9));
      // 离场在 endTime - exit 开始，渲染尾不早于行尾。
      expect(normal.lineRenderEndTime, greaterThanOrEqualTo(3));
    });

    test('词状态：提前 0.18s 进入 active，唱完转 passed', () {
      final MindscapeLineTiming line = resolveMindscapeLineTiming(
        startTime: 0,
        endTime: 4,
        lastWordEndTime: 4,
      );
      const MindscapeWordTime w = MindscapeWordTime(1, 2);
      expect(mindscapeWordStatus(0.7, line, w), MindscapeWordStatus.waiting);
      expect(mindscapeWordStatus(0.85, line, w), MindscapeWordStatus.active);
      expect(mindscapeWordStatus(2.01, line, w), MindscapeWordStatus.passed);
    });

    test('发光包络：起唱前 0，唱中 1，唱完后回落到 0', () {
      final MindscapeLineTiming line = resolveMindscapeLineTiming(
        startTime: 0,
        endTime: 4,
        lastWordEndTime: 4,
      );
      const MindscapeWordTime w = MindscapeWordTime(1, 2);
      expect(mindscapeGlowEnvelope(0.9, line, w), 0);
      expect(mindscapeGlowEnvelope(1.5, line, w), 1);
      expect(mindscapeGlowEnvelope(2, line, w), closeTo(0.9, 1e-9));
      expect(mindscapeGlowEnvelope(3, line, w), 0);
      expect(mindscapeBodyMix(1.5, line, w), closeTo(0.5, 1e-9));
      expect(mindscapeBodyMix(3, line, w), 0);
    });

    test('逐字发光在字长 6 倍内先亮后灭', () {
      const MindscapeWordTime w = MindscapeWordTime(0, 0.4);
      const List<MindscapeGlyphTime> g = <MindscapeGlyphTime>[
        MindscapeGlyphTime(0, 0.1),
        MindscapeGlyphTime(0.1, 0.2),
      ];
      expect(mindscapeCharGlow(0.18, w, 0, 2, g), closeTo(1, 1e-9));
      expect(mindscapeCharGlow(0.05, w, 1, 2, g), 0);
      expect(mindscapeCharGlow(0.7, w, 0, 2, g), 0);
    });

    test('整行包络：入场前透明，唱中实，离场放大模糊', () {
      final MindscapeLineTiming line = resolveMindscapeLineTiming(
        startTime: 1,
        endTime: 3,
        lastWordEndTime: 3,
      );
      expect(mindscapeLineEnvelope(0.5, line).opacity, 0);
      final MindscapeLineEnvelope mid = mindscapeLineEnvelope(2, line);
      expect(mid.opacity, 1);
      expect(mid.scale, 1);
      expect(mid.blur, 0);
      final MindscapeLineEnvelope out = mindscapeLineEnvelope(
        line.lineRenderEndTime,
        line,
      );
      expect(out.opacity, closeTo(0, 1e-9));
      expect(out.scale, closeTo(1.1, 1e-9));
      expect(out.blur, closeTo(20, 1e-9));
    });

    test('唱过的漂移 5 秒走完', () {
      const MindscapeWordTime w = MindscapeWordTime(0, 1);
      expect(mindscapePassedDrift(1, w), 0);
      expect(mindscapePassedDrift(3.5, w), closeTo(0.5, 1e-9));
      expect(mindscapePassedDrift(9, w), 1);
    });
  });

  group('布局', () {
    test('字号随屏宽，字多收小', () {
      expect(mindscapeChooseFontPx(1280, 8, 3), 94);
      expect(mindscapeChooseFontPx(1280, 20, 3), closeTo(94 - 8 * 1.8, 1e-9));
      expect(mindscapeChooseFontPx(390, 8, 3), 34);
      expect(mindscapeChooseFontPx(390, 60, 30), 28);
    });

    test('贪心换行：每行不超宽，超长词在字形处断开，避头标点黏前行', () {
      final List<String> latin = 'hello brave new world of words'
          .split('')
          .toList();
      final MindscapeTextLayout l = mindscapeLayoutText(
        latin,
        20,
        140,
        _fakeMeasure,
      );
      expect(l.lines.length, greaterThan(1));
      for (final MindscapeLayoutLine line in l.lines) {
        expect(line.width, lessThanOrEqualTo(140 + 1e-9));
      }
      expect(l.lines.first.start, 0);
      expect(l.lines.last.end, latin.length);
      // 不在词中间断（这些词都放得下）。
      for (final MindscapeLayoutLine line in l.lines.skip(1)) {
        expect(latin[line.start - 1], ' ');
      }

      final List<String> longWord = 'supercalifragilistic'.split('');
      final MindscapeTextLayout lw = mindscapeLayoutText(
        longWord,
        20,
        100,
        _fakeMeasure,
      );
      expect(lw.lines.length, greaterThan(1));

      final List<String> cjk = '夜空に光る星の数だけ、'.split('');
      final MindscapeTextLayout lc = mindscapeLayoutText(
        cjk,
        20,
        200,
        _fakeMeasure,
      );
      expect(lc.lines.first.end, 11);
      expect(lc.lines.length, 1);
    });

    test('落点：主角居中放大，其余片段互不重叠且布局稳定', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      final MindscapeSourceLine src = mindscapeSourceOf(rt.lines[1]);
      expect(src.text, 'Hello bright world');
      expect(src.words.map((MindscapeSourceWord w) => w.text), <String>[
        'Hello',
        'bright',
        'world',
      ]);
      MindscapePrepared prep() => mindscapePrepare(
        src,
        viewportWidth: 1280,
        viewportHeight: 720,
        fontScale: 1.12,
        widthRatio: 0.72,
        intensity: LyricVisualizerIntensity.normal,
        measure: _fakeMeasure,
      )!;
      final MindscapePrepared a = prep();
      final MindscapePrepared b = prep();
      expect(a.placements.length, 3);
      final MindscapePlacement hero = a.placements.first;
      expect(hero.emphasis, greaterThan(1));
      // 主角在焦点附近（半行高的小圈里找位）。
      expect((hero.x + hero.width / 2).abs(), lessThanOrEqualTo(a.lineHeight));
      expect(hero.y.abs(), lessThanOrEqualTo(a.lineHeight));
      for (int i = 0; i < a.placements.length; i++) {
        expect(a.placements[i].x, b.placements[i].x);
        expect(a.placements[i].y, b.placements[i].y);
      }
      // 视觉框（缩放后）两两不重叠。
      Rect box(MindscapePlacement p) => Rect.fromLTWH(
        p.x + p.width / 2 - p.width * p.scale / 2,
        p.y - p.height,
        p.width * p.scale,
        p.height,
      );
      for (int i = 0; i < a.placements.length; i++) {
        for (int j = i + 1; j < a.placements.length; j++) {
          final Rect o = box(a.placements[i]).intersect(box(a.placements[j]));
          expect(
            o.width <= 0 || o.height <= 0,
            isTrue,
            reason: '${a.placements[i].text} vs ${a.placements[j].text}',
          );
        }
      }
    });

    test('CJK 行每字一词；窄屏长句换行', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleLineTimeline(),
      );
      final MindscapeSourceLine cjk = mindscapeSourceOf(rt.lines[0]);
      expect(cjk.words.length, 7);
      final MindscapeSourceLine long = mindscapeSourceOf(rt.lines[1]);
      final MindscapePrepared p = mindscapePrepare(
        long,
        viewportWidth: 390,
        viewportHeight: 844,
        fontScale: 1.12,
        widthRatio: 0.72,
        intensity: LyricVisualizerIntensity.calm,
        measure: _fakeMeasure,
      )!;
      expect(p.layout.lines.length, greaterThan(2));
      expect(p.maxWidth, lessThanOrEqualTo(390 - 48));
      // 行级歌词的词时间按 folia buildTimedWords 加权估出，单调递增；只占行时长（3–6 s）的 90%。
      double last = -1;
      for (final MindscapeSourceWord w in long.words) {
        expect(w.time.startTime, greaterThanOrEqualTo(last));
        last = w.time.startTime;
      }
      expect(long.words.last.time.endTime, closeTo(5.7, 1e-9));
    });

    test('副歌读共享歌曲结构；行时序读共享 renderHints', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        _repeatTimeline(),
      );
      expect(
        <int>{
          for (int i = 0; i < rt.lines.length; i++)
            if (mindscapeSourceOf(rt.lines[i]).isChorus) i,
        },
        <int>{
          for (int i = 0; i < rt.lines.length; i++)
            if (rt.lines[i].isChorus) i,
        },
      );
      expect(mindscapeSourceOf(rt.lines[0]).isChorus, isTrue);
      final LyricVisualizerRuntime plain = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      expect(
        plain.lines.map(
          (LyricVisualizerLine l) => mindscapeSourceOf(l).isChorus,
        ),
        everyElement(isFalse),
      );
      final MindscapeLineTiming t = mindscapeSourceOf(plain.lines[0]).timing;
      expect(t.lineRenderEndTime, plain.lines[0].renderEndMs / 1000);
      expect(
        t.transition.enterDuration,
        plain.lines[0].renderHints.enterMs / 1000,
      );
    });

    test('主题按词着色、字重、共享强度与背景', () {
      final LyricVisualizerContext c = visualizerContextFor(
        mindscapeVisualizerEntry,
        clock: FakeVisualizerClock(1500),
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'world': Color(0xFFFF0000)},
          fontWeight: FontWeight.w300,
          intensity: LyricVisualizerIntensity.calm,
        ),
        audio: SyntheticVisualizerAudio(),
      );
      final MindscapeConfig cfg = MindscapeConfig.of(c, const TextStyle());
      expect(cfg.activeColorFor('world'), const Color(0xFFFF0000));
      expect(cfg.activeColorFor('hello'), c.palette.accent);
      expect(cfg.fontWeight, FontWeight.w300);
      expect(cfg.intensity, LyricVisualizerIntensity.calm);
      // 音频响度来自共享音频帧（有分析时是真音频，拍点上冲高）。
      expect(cfg.audioPower!(1000), closeTo(0.9, 1e-6));
      expect(cfg.audioPower!(1250), lessThan(0.9));
      expect(
        mindscapeTunings.map((LyricVisualizerTuningSpec s) => s.key),
        isNot(contains('animationIntensity')),
      );
      expect(
        mindscapeVisualizerEntry.backgroundFor(
          LyricVisualizerTuning.defaults(mindscapeTunings),
        ),
        LyricVisualizerBackgroundRequest.selected,
      );
    });
  });

  group('场景', () {
    testWidgets('按时间画当前行，间奏后离场窗口结束即清空', (WidgetTester tester) async {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      final ColorScheme scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: Brightness.dark,
      );
      MindscapeConfig cfg(bool motion) => MindscapeConfig(
        runtime: rt,
        palette: LyricVisualizerPalette.fromScheme(scheme),
        baseStyle: const TextStyle(),
        motion: motion,
        fontScale: 1.12,
        widthRatio: 0.72,
        motionAmount: 1,
        glowIntensity: 1,
        intensity: LyricVisualizerIntensity.chaotic,
      );
      final MindscapeScene scene = MindscapeScene();
      void frame(int ms, double elapsed, {bool motion = true}) {
        final ui.PictureRecorder rec = ui.PictureRecorder();
        scene.paint(
          Canvas(rec),
          const Size(1280, 720),
          cfg(motion),
          ms,
          elapsed,
        );
        rec.endRecording().dispose();
      }

      frame(500, 0);
      expect(scene.drawnLine, isNull);
      frame(1500, 0.1);
      expect(scene.drawnLine, 0);
      expect(scene.currentPlacements.length, 4);
      for (int i = 0; i < 30; i++) {
        frame(1500 + i * 16, 0.1 + i * 0.016);
      }
      frame(3600, 1, motion: false);
      expect(scene.drawnLine, 1);
      frame(8000, 2);
      expect(scene.drawnLine, isNull);
      scene.dispose();
    });
  });

  group('冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, mindscapeVisualizerEntry);
    });
    testWidgets('非默认参数组合', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        mindscapeVisualizerEntry,
        tuning: <String, Object?>{
          MindscapeTuningKeys.fontScale: 1.8,
          MindscapeTuningKeys.widthRatio: 0.4,
          MindscapeTuningKeys.motionAmount: 2.0,
          MindscapeTuningKeys.glowIntensity: 2.0,
        },
        intensity: LyricVisualizerIntensity.chaotic,
      );
    });
    testWidgets('行级歌词 + 平静', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        mindscapeVisualizerEntry,
        timeline: sampleLineTimeline(),
        timesMs: const <int>[0, 600, 1500, 2900, 3100, 4500, 5900, 7000],
        intensity: LyricVisualizerIntensity.calm,
      );
    });
    testWidgets('副歌 + 主题 + 音频', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        mindscapeVisualizerEntry,
        timeline: _repeatTimeline(),
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'夜': Color(0xFFFF4081)},
          fontWeight: FontWeight.w300,
          intensity: LyricVisualizerIntensity.chaotic,
        ),
        audio: SyntheticVisualizerAudio(),
      );
    });
    testWidgets('减弱动态 + 暂停', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        mindscapeVisualizerEntry,
        motion: false,
        playing: false,
      );
    });
    testWidgets('窄屏竖屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        mindscapeVisualizerEntry,
        timeline: sampleLineTimeline(),
        size: const Size(390, 844),
        timesMs: const <int>[600, 2000, 3200, 4000, 5800],
      );
    });
  });
}
