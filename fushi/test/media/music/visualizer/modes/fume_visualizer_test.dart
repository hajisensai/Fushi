import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_article_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_camera.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_stage.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_timeline.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_visualizer.dart';

import '../visualizer_test_helpers.dart';

/// 假量字：拉丁 0.6em、CJK 1em，按字贪心折行。
class _FakeMeasurer implements FumeTextMeasurer {
  double _w(String g) => fumeIsCjk(g) ? 1 : 0.6;

  @override
  double naturalWidthPerPx(String text, FumeVariant variant) =>
      text.split('').fold(0, (double a, String g) => a + _w(g));

  @override
  List<(int, int)> wrap(
    List<String> graphemes,
    FumeVariant variant,
    double fontPx,
    double width,
  ) {
    final List<(int, int)> out = <(int, int)>[];
    int s = 0;
    double x = 0;
    for (int i = 0; i < graphemes.length; i++) {
      final double w = _w(graphemes[i]) * fontPx;
      if (x + w > width && i > s) {
        out.add((s, i));
        s = i;
        x = 0;
      }
      x += w;
    }
    out.add((s, graphemes.length));
    return out;
  }

  @override
  List<double> glyphOffsets(
    List<String> graphemes,
    FumeVariant variant,
    double fontPx,
  ) {
    final List<double> out = <double>[0];
    for (final String g in graphemes) {
      out.add(out.last + _w(g) * fontPx);
    }
    return out;
  }

  @override
  double paintHeight(FumeVariant variant, double fontPx) => fontPx * 1.2;
}

/// 40 句的长歌：日文 / 英文交替，逐字时间。
LyricTimeline _longTimeline() {
  final List<LyricLine> lines = <LyricLine>[];
  int t = 1000;
  for (int i = 0; i < 40; i++) {
    final List<String> parts = i.isEven
        ? <String>['夜', '空', 'に', '光', '$i']
        : <String>['Shine ', 'on ', 'me ', 'line ', '$i'];
    final List<LyricSyllable> syl = <LyricSyllable>[];
    for (final String p in parts) {
      syl.add(LyricSyllable(text: p, startMs: t, endMs: t + 300));
      t += 300;
    }
    lines.add(LyricLine(startMs: syl.first.startMs, endMs: t, syllables: syl));
    t += 400;
  }
  return LyricTimeline(
    format: 'ttml',
    timingQuality: LyricTimingQuality.word,
    lines: lines,
  );
}

/// 行级时间轴：「君の名を呼ぶ」唱三遍（共享启发式判成副歌），其余各不相同。
LyricTimeline _chorusTimeline() {
  const List<String> texts = <String>[
    '遠い街の灯り',
    '君の名を呼ぶ',
    '風が吹いていた',
    '君の名を呼ぶ',
    '夜明けはまだ遠く',
    '君の名を呼ぶ',
    '最後のひとこと',
  ];
  return LyricTimeline(
    format: 'lrc',
    lines: <LyricLine>[
      for (int i = 0; i < texts.length; i++)
        LyricLine(
          startMs: 1000 + i * 3000,
          endMs: 3800 + i * 3000,
          syllables: <LyricSyllable>[
            LyricSyllable(
              text: texts[i],
              startMs: 1000 + i * 3000,
              endMs: 3800 + i * 3000,
            ),
          ],
        ),
    ],
  );
}

List<FumeLine> _linesOf(LyricTimeline t) =>
    fumeLinesOf(LyricVisualizerRuntime(t));

FumeArticle _article(List<FumeLine> lines, Size size) => buildFumeArticle(
  lines: lines,
  viewport: size,
  measurer: _FakeMeasurer(),
  fontScale: 1,
  heroScale: 1,
  seedKey: 'test',
)!;

void main() {
  group('时序', () {
    test('渲染结束取运行时共享的句尾离场窗口', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      final List<FumeLine> lines = fumeLinesOf(rt);
      for (int i = 0; i < lines.length; i++) {
        expect(lines[i].renderEnd, rt.lines[i].renderEndMs / 1000);
        expect(lines[i].renderEnd, greaterThanOrEqualTo(lines[i].end));
        expect(lines[i].hints, rt.lines[i].renderHints);
      }
    });

    test('词区间吞掉其后空白，字形去首尾空白', () {
      final List<FumeLine> lines = _linesOf(sampleWordTimeline());
      final FumeLine hello = lines[1];
      expect(hello.text, 'Hello bright world');
      expect(hello.ranges, hasLength(3));
      expect(hello.ranges[0].start, 0);
      expect(hello.ranges[0].end, 6); // 'Hello ' 含空格
      expect(hello.ranges[1].start, 6);
      expect(hello.ranges.last.end, hello.graphemes.length);
      expect(hello.ranges[0].timings, hasLength(5));
    });

    test('已打印字数：开唱前 0、唱完全部、中途单调', () {
      final FumeLine line = _linesOf(sampleWordTimeline()).first;
      expect(fumePrintedGraphemeCount(line, 0.5), 0);
      expect(fumePrintedGraphemeCount(line, 10), line.graphemes.length);
      int prev = 0;
      double prevP = 0;
      for (double t = 1.0; t <= 3.3; t += 0.05) {
        final int c = fumePrintedGraphemeCount(line, t);
        final double p = fumePrintedGraphemeProgress(line, t);
        expect(c, greaterThanOrEqualTo(prev));
        expect(p, greaterThanOrEqualTo(prevP - 1e-9));
        prev = c;
        prevP = p;
      }
      expect(fumePrintedGraphemeCount(line, 1.35), 2);
    });

    test('行级歌词也能逐字打印', () {
      final FumeLine line = _linesOf(sampleLineTimeline()).first;
      expect(fumePrintedGraphemeCount(line, 0.6), greaterThan(0));
      expect(
        fumePrintedGraphemeCount(line, 1.7),
        lessThan(line.graphemes.length),
      );
    });

    test('唱过停留：比例 1 永不淡，比例 0 取下限 2.4 秒', () {
      final List<FumeLine> lines = _linesOf(_longTimeline());
      expect(fumePassedFadeDuration(lines, 1), double.infinity);
      expect(fumePassedFadeDuration(lines, 0), 2.4);
      final double half = fumePassedFadeDuration(lines, 0.5);
      expect(half, greaterThan(2.4));
      expect(half, lessThanOrEqualTo(130));
    });

    test('截止点压缩动画', () {
      expect(fumeVisualProgressWithCutoff(0, 1, 0.5, 10), closeTo(0.5, 1e-9));
      expect(fumeVisualProgressWithCutoff(0, 1, 0.5, 0.5), 1);
    });

    test('唱过样式：等待淡、标准与变暗交叉', () {
      final FumeArticle a = _article(
        _linesOf(sampleWordTimeline()),
        const Size(1280, 720),
      );
      final FumeBlock b = a.blockByLine[0]!;
      final FumeBlockTiming waiting = FumeBlockTiming(b, 0, 3.4, 1);
      expect(waiting.staticState, FumeStaticState.waiting);
      final FumeUniformStyle ws = fumeStaticStyle(
        block: b,
        timing: waiting,
        t: 0,
        text: const Color(0xFFFFFFFF),
        passedGlowBase: 0.62,
        passedFadeDuration: double.infinity,
        overviewRestore: 0,
      );
      expect(ws.fill.a, closeTo(waiting.waitingOpacity, 0.01));

      final FumeBlockTiming passed = FumeBlockTiming(b, 30, 3.4, 0);
      expect(passed.staticState, FumeStaticState.passed);
      final FumeUniformStyle dim = fumeStaticStyle(
        block: b,
        timing: passed,
        t: 30,
        text: const Color(0xFFFFFFFF),
        passedGlowBase: 0.62,
        passedFadeDuration: 2.4,
        overviewRestore: 0,
      );
      expect(dim.fill.a, closeTo(passed.passedStyle.opacity, 0.01));
      // 全景飞入时恢复标准样式。
      final FumeUniformStyle restored = fumeStaticStyle(
        block: b,
        timing: passed,
        t: 30,
        text: const Color(0xFFFFFFFF),
        passedGlowBase: 0.62,
        passedFadeDuration: 2.4,
        overviewRestore: 1,
      );
      expect(restored.fill.a, closeTo(passed.transitionStyle.opacity, 0.01));
    });
  });

  group('排版', () {
    test('每句一块，全在纸内，至少一句大标题，同栏不重叠', () {
      final List<FumeLine> lines = _linesOf(_longTimeline());
      final FumeArticle a = _article(lines, const Size(1280, 720));
      expect(a.blocks, hasLength(lines.length));
      expect(a.blocks.where((FumeBlock b) => b.hero), isNotEmpty);
      expect(a.columns, greaterThan(1));
      for (final FumeBlock b in a.blocks) {
        expect(b.x, greaterThanOrEqualTo(a.paperBounds.left - 1e-6));
        expect(b.x + b.width, lessThanOrEqualTo(a.paperBounds.right + 1e-6));
        expect(b.y, greaterThanOrEqualTo(a.paperBounds.top - 1e-6));
        expect(b.renderLines, isNotEmpty);
        for (final FumeRenderLine rl in b.renderLines) {
          expect(rl.width, lessThanOrEqualTo(b.width + 1e-6));
        }
      }
      final List<FumeBlock> bodies = a.blocks
          .where((FumeBlock b) => !b.hero)
          .toList();
      for (int i = 0; i < bodies.length; i++) {
        for (int j = i + 1; j < bodies.length; j++) {
          final Rect ri = Rect.fromLTWH(
            bodies[i].x,
            bodies[i].y,
            bodies[i].width,
            bodies[i].height,
          ).deflate(0.5);
          final Rect rj = Rect.fromLTWH(
            bodies[j].x,
            bodies[j].y,
            bodies[j].width,
            bodies[j].height,
          ).deflate(0.5);
          expect(ri.overlaps(rj), isFalse);
        }
      }
    });

    test('同输入同排版（种子稳定）', () {
      final List<FumeLine> lines = _linesOf(_longTimeline());
      final FumeArticle a = _article(lines, const Size(390, 844));
      final FumeArticle b = _article(lines, const Size(390, 844));
      for (int i = 0; i < a.blocks.length; i++) {
        expect(a.blocks[i].x, b.blocks[i].x);
        expect(a.blocks[i].y, b.blocks[i].y);
        expect(a.blocks[i].variant, b.blocks[i].variant);
      }
    });

    test('字号：能单行放下取最大，放不下退最小字号并折行', () {
      final FumeLine short = _linesOf(sampleWordTimeline()).first;
      final (double px, int count) = fumeChooseFontPx(
        measurer: _FakeMeasurer(),
        line: short,
        variant: FumeVariant.body,
        width: 400,
        fontScale: 1,
        densityScale: 1,
        heroScale: 1,
      );
      expect(count, 1);
      expect(px, greaterThan(28));
      final FumeLine long = _linesOf(sampleLineTimeline())[1];
      final (double px2, int count2) = fumeChooseFontPx(
        measurer: _FakeMeasurer(),
        line: long,
        variant: FumeVariant.body,
        width: 120,
        fontScale: 1,
        densityScale: 1,
        heroScale: 1,
      );
      expect(px2, 10);
      expect(count2, greaterThan(1));
    });

    test('副歌句（≤22 字）自然成大标题', () {
      final List<FumeLine> lines = _linesOf(_chorusTimeline());
      expect(lines[1].isChorus, isTrue);
      expect(lines[0].isChorus, isFalse);
      for (final int i in <int>[1, 3, 5]) {
        expect(fumeNaturalVariant(lines[i], i, lines.length), FumeVariant.hero);
      }
      // 有了自然大标题就不再强行挑。
      expect(fumeFallbackHeroIndex(lines), -1);
      final FumeArticle a = _article(lines, const Size(1280, 720));
      expect(
        a.blocks
            .where((FumeBlock b) => b.line.isChorus)
            .every((FumeBlock b) => b.hero),
        isTrue,
      );
    });

    test('一句大标题都没挑中时强行挑一句', () {
      final List<FumeLine> lines = _linesOf(sampleWordTimeline());
      final int forced = fumeFallbackHeroIndex(lines);
      final bool natural = <int>[for (int i = 0; i < lines.length; i++) i].any(
        (int i) =>
            fumeNaturalVariant(lines[i], i, lines.length) == FumeVariant.hero,
      );
      expect(natural ? forced == -1 : forced >= 0, isTrue);
    });
  });

  group('镜头', () {
    test('追焦点：定格落在字边界，平滑随进度前移', () {
      final FumeArticle a = _article(
        _linesOf(sampleWordTimeline()),
        const Size(1280, 720),
      );
      final FumeBlock b = a.blockByLine[1]!;
      final Offset start = fumeSteppedFocusPoint(b, 0);
      expect(start.dx, closeTo(b.x + b.renderLines.first.left, 1e-6));
      double prevX = -1;
      for (double p = 0; p <= b.graphemeCount; p += 0.5) {
        final Offset o = fumeSmoothFocusPoint(b, p);
        if (b.renderLines.length == 1) {
          expect(o.dx, greaterThanOrEqualTo(prevX - 1e-6));
        }
        prevX = o.dx;
      }
    });

    test('弹簧镜头收敛到当前句；减弱动态直接落点', () {
      final List<FumeLine> lines = _linesOf(_longTimeline());
      final FumeArticle a = _article(lines, const Size(1280, 720));
      const Size vp = Size(1280, 720);
      final FumeBlock target = a.blockByLine[5]!;
      final double t = target.line.start + 239 / 60; // 打印完
      final FumeCameraState s = FumeCameraState()..syncToArticle(a);
      for (int i = 0; i < 240; i++) {
        fumeStepCamera(
          s,
          article: a,
          time: target.line.start + i / 60,
          wallSeconds: 0,
          dt: 1 / 60,
          lineIndex: 5,
          viewport: vp,
          overview: fumeArticleOverviewCamera(a, vp),
          overviewStartTime: double.infinity,
          cameraSpeed: 1,
          tracking: FumeTrackingMode.smooth,
          motion: true,
        );
      }
      final Offset focus = fumeSmoothFocusPoint(
        target,
        fumePrintedGraphemeProgress(target.line, t),
      );
      // 漂浮幅度 ≤ 18 屏幕像素。
      expect((s.camera.x - focus.dx).abs(), lessThan(40));
      expect((s.camera.y - focus.dy).abs(), lessThan(40));

      final FumeCameraState still = FumeCameraState()..syncToArticle(a);
      fumeStepCamera(
        still,
        article: a,
        time: t,
        wallSeconds: 0,
        dt: 0,
        lineIndex: 5,
        viewport: vp,
        overview: null,
        overviewStartTime: double.infinity,
        cameraSpeed: 1,
        tracking: FumeTrackingMode.stepped,
        motion: false,
      );
      expect(
        still.camera.scale,
        closeTo(fumeCameraScaleForBlock(target, vp), 1e-9),
      );
    });

    test('全景：缩到能装下所有块、不超过 0.72', () {
      final FumeArticle a = _article(
        _linesOf(_longTimeline()),
        const Size(1280, 720),
      );
      final FumeViewTarget o = fumeArticleOverviewCamera(
        a,
        const Size(1280, 720),
      );
      expect(o.scale, lessThanOrEqualTo(0.72));
      expect(o.scale, greaterThanOrEqualTo(fumeCameraScaleMin));
      expect(
        fumeOverviewStartTime(_linesOf(_longTimeline())),
        lessThan(_linesOf(_longTimeline()).last.renderEnd),
      );
    });

    test('远距离换句走全景桥，近处不走', () {
      const Size vp = Size(1280, 720);
      const FumeViewTarget o = FumeViewTarget(1500, 1500, 0.3);
      expect(
        fumeOverviewFlightBridge(
          fromX: 0,
          fromY: 0,
          fromScale: 1.2,
          targetX: 10,
          targetY: 10,
          targetScale: 1.2,
          overview: o,
          viewport: vp,
        ),
        isNull,
      );
      expect(
        fumeOverviewFlightBridge(
          fromX: 0,
          fromY: 0,
          fromScale: 1.2,
          targetX: 3000,
          targetY: 3000,
          targetScale: 1.2,
          overview: o,
          viewport: vp,
        ),
        isNotNull,
      );
    });
  });

  test('背景：宽屏 8 个大物体 + 12 颗火花，种子稳定、按深度排序', () {
    FumeBackgroundScene make() => buildFumeBackgroundScene(
      viewport: const Size(1280, 720),
      world: const Size(4000, 2400),
      seed: 'x',
    );
    final FumeBackgroundScene a = make();
    final FumeBackgroundScene b = make();
    expect(a.shapes, hasLength(20));
    expect(
      a.shapes.where((FumeBackgroundShape s) => s.kind == FumeShapeKind.spark),
      hasLength(12),
    );
    for (int i = 0; i < a.shapes.length; i++) {
      expect(a.shapes[i].x, b.shapes[i].x);
      if (i > 0) {
        expect(a.shapes[i].depth, greaterThanOrEqualTo(a.shapes[i - 1].depth));
      }
    }
  });

  test('真实量字：折行区间首尾相接、字形偏移单调', () {
    final FumeTextPainterMeasurer m = FumeTextPainterMeasurer();
    final List<String> g = 'A line level lyric that wraps'.split('');
    final List<(int, int)> r = m.wrap(g, FumeVariant.body, 20, 120);
    expect(r.first.$1, 0);
    expect(r.last.$2, g.length);
    for (int i = 1; i < r.length; i++) {
      expect(r[i].$1, r[i - 1].$2);
    }
    expect(r.length, greaterThan(1));
    final List<double> off = m.glyphOffsets(g, FumeVariant.hero, 20);
    expect(off, hasLength(g.length + 1));
    for (int i = 1; i < off.length; i++) {
      expect(off[i], greaterThanOrEqualTo(off[i - 1]));
    }
    expect(m.naturalWidthPerPx('abc', FumeVariant.body), greaterThan(0));
  });

  group('冒烟', () {
    setUp(FumeArticleCache.clear);

    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, fumeVisualizerEntry);
    });

    testWidgets('非默认参数：定格追焦、隐藏方块、短停留、强辉光', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        fumeVisualizerEntry,
        tuning: <String, Object?>{
          FumeTuningKeys.cameraTrackingMode: 'stepped',
          FumeTuningKeys.hidePrintSymbols: true,
          FumeTuningKeys.textHoldRatio: 0.1,
          FumeTuningKeys.glowIntensity: 1.8,
          FumeTuningKeys.heroScale: 1.32,
          FumeTuningKeys.cameraSpeed: 1.85,
          FumeTuningKeys.backgroundObjectOpacity: 1.0,
        },
      );
    });

    testWidgets('辉光为 0、停留 0', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        fumeVisualizerEntry,
        tuning: <String, Object?>{
          FumeTuningKeys.glowIntensity: 0.0,
          FumeTuningKeys.textHoldRatio: 0.0,
          FumeTuningKeys.backgroundObjectOpacity: 0.0,
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        fumeVisualizerEntry,
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('减弱动态 + 暂停', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        fumeVisualizerEntry,
        timeline: sampleLineTimeline(),
        motion: false,
        playing: false,
      );
    });

    testWidgets('窄屏竖屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        fumeVisualizerEntry,
        size: const Size(390, 844),
      );
    });

    testWidgets('长歌：多栏排版、远距离换句、末尾全景', (WidgetTester tester) async {
      final LyricTimeline long = _longTimeline();
      final int end = long.lines.last.endMs;
      await pumpVisualizerAcross(
        tester,
        fumeVisualizerEntry,
        timeline: long,
        timesMs: <int>[
          0,
          1500,
          9000,
          20000,
          40000,
          end - 800,
          end + 500,
          end + 4000,
          math.max(0, end ~/ 3),
        ],
      );
    });

    testWidgets('空歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        fumeVisualizerEntry,
        timeline: const LyricTimeline(format: 'lrc', lines: <LyricLine>[]),
        timesMs: const <int>[0, 1000],
      );
    });

    testWidgets('音频分析 + AI 主题（按词着色 / 字重）+ 各档强度', (WidgetTester tester) async {
      for (final LyricVisualizerIntensity it
          in LyricVisualizerIntensity.values) {
        await pumpVisualizerAcross(
          tester,
          fumeVisualizerEntry,
          audio: SyntheticVisualizerAudio(),
          intensity: it,
          theme: const LyricVisualizerTheme(
            wordColors: <String, Color>{'夜空': Color(0xFFFF4081)},
            fontWeight: FontWeight.w300,
          ),
        );
      }
    });

    testWidgets('副歌时间轴', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        fumeVisualizerEntry,
        timeline: _chorusTimeline(),
        timesMs: const <int>[0, 1500, 4500, 7600, 13000, 19500, 26000],
      );
    });
  });

  group('共享框架', () {
    test('强度：辉光底数照 folia（calm / normal / chaotic）乘辉光强度', () {
      expect(fumeGlowBases(LyricVisualizerIntensity.calm, 1), (0.72, 0.35));
      expect(fumeGlowBases(LyricVisualizerIntensity.normal, 1), (0.92, 0.62));
      final (double a, double p) = fumeGlowBases(
        LyricVisualizerIntensity.chaotic,
        2,
      );
      expect(a, closeTo(2.3, 1e-9));
      expect(p, closeTo(1.9, 1e-9));
    });

    test('音频帧 → 火花频段电平（10–200）', () {
      final LyricVisualizerAudioFrame f = SyntheticVisualizerAudio().frameAt(
        1000,
      );
      final FumeBackgroundLevels lv = fumeBackgroundLevelsOf(f);
      expect(lv[FumeAudioBand.bass], closeTo(10 + 190 * f.low, 1e-9));
      expect(lv[FumeAudioBand.mid], closeTo(10 + 190 * f.mid, 1e-9));
      expect(lv[FumeAudioBand.lowMid], lv[FumeAudioBand.mid]);
      expect(lv[FumeAudioBand.vocal], closeTo(10 + 190 * f.vocal, 1e-9));
      expect(lv[FumeAudioBand.treble], closeTo(10 + 190 * f.high, 1e-9));
      final FumeBackgroundLevels quiet = fumeBackgroundLevelsOf(
        LyricVisualizerAudioFrame.silent,
      );
      expect(quiet[FumeAudioBand.bass], 10);
    });

    test('正在唱的字色：主题 wordColors 互相包含即命中，否则 accent', () {
      const LyricVisualizerTheme theme = LyricVisualizerTheme(
        wordColors: <String, Color>{'夜空': Color(0xFFFF4081)},
      );
      final List<FumeLine> lines = _linesOf(sampleWordTimeline());
      final FumeArticle a = _article(lines, const Size(1280, 720));
      FumeScene sceneWith(LyricVisualizerTheme? th) => FumeScene(
        runtime: LyricVisualizerRuntime(sampleWordTimeline()),
        lines: lines,
        article: a,
        viewport: const Size(1280, 720),
        background: buildFumeBackgroundScene(
          viewport: const Size(1280, 720),
          world: Size(a.width, a.height),
          paperBounds: a.paperBounds,
          seed: 'x',
        ),
        overview: null,
        overviewStartTime: double.infinity,
        passedFadeDuration: double.infinity,
        text: const Color(0xFFFFFFFF),
        secondary: const Color(0xFF888888),
        accent: const Color(0xFF00FF00),
        cameraSpeed: 1,
        tracking: FumeTrackingMode.smooth,
        glowIntensity: 1,
        backgroundObjectOpacity: 0.5,
        showPrintStamp: true,
        textHoldRatio: 1,
        motion: true,
        theme: th,
      );
      final FumeScene themed = sceneWith(theme);
      expect(themed.activeColorFor('夜'), const Color(0xFFFF4081));
      expect(themed.activeColorFor('夜空に'), const Color(0xFFFF4081));
      expect(themed.activeColorFor('光'), const Color(0xFF00FF00));
      expect(sceneWith(null).activeColorFor('夜'), const Color(0xFF00FF00));
    });

    test('主题字重 / 字体进字形样式与排版缓存键', () {
      const FumeFont f = FumeFont(weight: FontWeight.w300, family: 'serif');
      expect(fumeFontWeight(FumeVariant.hero, f), FontWeight.w300);
      expect(fumeFontWeight(FumeVariant.hero), FontWeight.w800);
      expect(fumeTextStyle(FumeVariant.body, 20, f).fontFamily, 'serif');
      final List<FumeLine> lines = _linesOf(sampleWordTimeline());
      String key(FumeFont font) => FumeArticleCache.keyOf(
        lines: lines,
        viewport: const Size(800, 600),
        fontScale: 1,
        heroScale: 1,
        seedKey: 's',
        textScale: 1,
        font: font,
      );
      expect(key(f), isNot(key(FumeFont.standard)));
    });

    test('背景：用户选的共享背景；默认关掉几何背景层（folia fumeBackgroundConfig），开关打开才画', () {
      final LyricVisualizerBackgroundRequest off = fumeVisualizerEntry
          .backgroundFor(
            LyricVisualizerTuning.defaults(fumeVisualizerEntry.tunings),
          );
      expect(off.kind, LyricVisualizerBackgroundKind.selected);
      expect(off.tuningOverrides, <String, Object>{
        'disableGeometricBackground': true,
      });
      expect(
        fumeVisualizerEntry.backgroundFor(
          LyricVisualizerTuning(
            fumeVisualizerEntry.tunings,
            const <String, Object?>{FumeTuningKeys.geometricBackground: true},
          ),
        ),
        LyricVisualizerBackgroundRequest.selected,
      );
    });
  });
}
