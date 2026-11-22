import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_camera.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_figures.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_shapes.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_visualizer.dart';

import '../visualizer_test_helpers.dart';

double _measure(String c) => lyricVisualizerIsCjk(c) ? 1.0 : 0.55;

List<MetaphorProgramLine> _programLines(LyricTimeline t) {
  final LyricVisualizerRuntime r = LyricVisualizerRuntime(t);
  return <MetaphorProgramLine>[
    for (int i = 0; i < r.lines.length; i++)
      MetaphorProgramLine.fromRuntime(i, r.lines[i]),
  ];
}

MetaphorLayout _layoutOf(
  LyricVisualizerLine line,
  MetaphorComposition composition,
) => buildMetaphorLayout(
  MetaphorLayoutInput(
    tokens: buildMetaphorTokens(line),
    composition: composition,
    measure: _measure,
    rng: metaphorRng('test'),
  ),
);

void main() {
  group('分镜表', () {
    test('cue 首尾相接、镜头铺满、同一首每次一样', () {
      final List<MetaphorProgramLine> lines = _programLines(
        sampleWordTimeline(),
      );
      final MetaphorProgram a = compileMetaphorProgram(
        lines,
        seed: 42,
        title: 'Song',
      );
      final MetaphorProgram b = compileMetaphorProgram(
        lines,
        seed: 42,
        title: 'Song',
      );
      expect(a.cues, isNotEmpty);
      for (int i = 0; i + 1 < a.cues.length; i++) {
        expect(a.cues[i].end, closeTo(a.cues[i + 1].start, 1e-9));
      }
      for (final MetaphorCue cue in a.cues) {
        expect(cue.shots, isNotEmpty);
        expect(cue.shots.first.start, cue.start);
        final double end = cue.loop > 0 ? cue.start + cue.loop : cue.end;
        expect(cue.shots.last.end, closeTo(end, 1e-9));
        for (int s = 0; s + 1 < cue.shots.length; s++) {
          expect(cue.shots[s].end, cue.shots[s + 1].start);
        }
      }
      expect(
        a.cues.map((MetaphorCue c) => c.shots.map((MetaphorShot s) => s.kind)),
        b.cues.map((MetaphorCue c) => c.shots.map((MetaphorShot s) => s.kind)),
      );
      // 第一句前有 0.4s 的空，不足以插间奏；歌词 cue 都在，最后是一个循环的 cue
      final List<MetaphorCue> sung = a.cues
          .where((MetaphorCue c) => c.lineIndex >= 0)
          .toList();
      expect(sung.length, 3);
      expect(a.cues.last.loop, 48);
      expect(a.cues.last.end, double.infinity);
      expect(sung.first.transition, MetaphorTransition.cut);
    });

    test('没有歌词：整首是间奏，曲名在第一段', () {
      final MetaphorProgram p = compileMetaphorProgram(
        const <MetaphorProgramLine>[],
        seed: 1,
        title: ' Title ',
      );
      expect(p.cues.every((MetaphorCue c) => c.lineIndex < 0), isTrue);
      expect(p.cues.first.text, 'Title');
      expect(p.cues.skip(1).every((MetaphorCue c) => c.text.isEmpty), isTrue);
      // 720 秒切成约 24 秒一段，后面接循环的 cue
      expect(p.cues.length, greaterThan(20));
      expect(p.cues.last.loop, 48);
      expect(findMetaphorCue(p, 5000), p.cues.length - 1);
      final MetaphorCue loop = p.cues.last;
      expect(
        resolveMetaphorCueTime(loop, loop.start + 48 * 3 + 5),
        closeTo(loop.start + 5, 1e-9),
      );
    });

    test('只有标点的句子不算歌词；转场关掉全是硬切；反相关掉没有反相镜头', () {
      final List<MetaphorProgramLine> lines = <MetaphorProgramLine>[
        for (int i = 0; i < 12; i++)
          MetaphorProgramLine(
            lineIndex: i,
            text: i == 3 ? '......' : 'line number $i here',
            start: 2.0 + i * 5,
            end: 6.0 + i * 5,
            wordStarts: <double>[2.0 + i * 5, 3.0 + i * 5, 4.5 + i * 5],
          ),
      ];
      final MetaphorProgram p = compileMetaphorProgram(
        lines,
        seed: 7,
        negative: false,
        transitions: false,
      );
      expect(p.cues.any((MetaphorCue c) => c.lineIndex == 3), isFalse);
      expect(
        p.cues.every((MetaphorCue c) => c.transition == MetaphorTransition.cut),
        isTrue,
      );
      expect(
        p.cues.every(
          (MetaphorCue c) => c.shots.every((MetaphorShot s) => !s.invert),
        ),
        isTrue,
      );
    });

    test('切点吸到附近的词开唱上', () {
      final List<double> cuts = metaphorPlanCuts(0, 10, 2, <double>[4.4, 8]);
      expect(cuts, <double>[4.4]);
      final List<double> far = metaphorPlanCuts(0, 10, 2, <double>[1]);
      expect(far, <double>[5]);
    });
  });

  group('排版', () {
    final LyricVisualizerRuntime runtime = LyricVisualizerRuntime(
      sampleWordTimeline(),
    );

    test('每种构图都以原点为中心、每个字都摆上了', () {
      for (final LyricVisualizerLine line in runtime.lines) {
        final int visible = line.glyphs
            .where((LyricVisualizerGlyph g) => !g.isSpace)
            .length;
        for (final MetaphorComposition comp in MetaphorComposition.values) {
          final MetaphorLayout l = _layoutOf(line, comp);
          expect(l.glyphs.length, visible, reason: '$comp ${line.text}');
          expect(l.bounds.x0 + l.bounds.x1, closeTo(0, 1e-9));
          expect(l.bounds.y0 + l.bounds.y1, closeTo(0, 1e-9));
          for (final MetaphorGlyph g in l.glyphs) {
            expect(g.x.isFinite && g.y.isFinite, isTrue);
            expect(g.x, inInclusiveRange(l.bounds.x0, l.bounds.x1));
          }
        }
      }
    });

    test('token：中日文一字一个，英文按空白断开，时间是秒', () {
      final List<MetaphorToken> ja = buildMetaphorTokens(runtime.lines[0]);
      expect(ja.map((MetaphorToken t) => t.text), <String>['夜', '空', 'に', '光']);
      expect(ja.first.chars.first.t0, closeTo(1.0, 1e-9));
      final List<MetaphorToken> en = buildMetaphorTokens(runtime.lines[1]);
      expect(
        en
            .where((MetaphorToken t) => !t.space)
            .map((MetaphorToken t) => t.text),
        <String>['Hello', 'bright', 'world'],
      );
      expect(en.where((MetaphorToken t) => t.space), isNotEmpty);
    });

    test('竖排：从右往左一列最多六个字', () {
      final LyricVisualizerRuntime r = LyricVisualizerRuntime(
        sampleLineTimeline(),
      );
      final MetaphorLayout l = _layoutOf(
        r.lines[0],
        MetaphorComposition.column,
      );
      final Set<double> columns = l.glyphs
          .map((MetaphorGlyph g) => (g.x * 1000).roundToDouble())
          .toSet();
      expect(columns.length, 2);
      expect(l.glyphs.first.x, greaterThan(l.glyphs.last.x));
    });

    test('长的英文句子会折行', () {
      final LyricVisualizerRuntime r = LyricVisualizerRuntime(
        sampleLineTimeline(),
      );
      final MetaphorLayout l = _layoutOf(r.lines[1], MetaphorComposition.block);
      expect(l.bounds.width, lessThanOrEqualTo(11.5));
      expect(l.bounds.height, greaterThan(2));
    });
  });

  group('镜头', () {
    final LyricVisualizerRuntime runtime = LyricVisualizerRuntime(
      sampleWordTimeline(),
    );
    final MetaphorLayout layout = _layoutOf(
      runtime.lines[1],
      MetaphorComposition.block,
    );
    MetaphorShot shot(MetaphorShotKind kind) => MetaphorShot(
      start: 3.0,
      end: 6.0,
      kind: kind,
      roll: 0,
      offsetX: 0,
      offsetY: 0,
      invert: false,
      screenAngle: 0.5,
      seed: 0.3,
    );

    test('全景装得下整句（留一圈边）', () {
      for (final double aspect in <double>[16 / 9, 390 / 844]) {
        final MetaphorPose p = metaphorPlannedPose(
          MetaphorPoseInput(
            shot: shot(MetaphorShotKind.wide),
            layout: layout,
            time: 3.0,
            aspect: aspect,
            motion: 0,
          ),
        );
        expect(p.halfHeight, greaterThanOrEqualTo(layout.bounds.height / 2));
        expect(
          p.halfHeight * aspect,
          greaterThanOrEqualTo(layout.bounds.width / 2),
        );
      }
    });

    test('冲镜隔 0.16 秒一格地推近，之后不动', () {
      double distAt(double t) => metaphorPlannedPose(
        MetaphorPoseInput(
          shot: shot(MetaphorShotKind.pushin),
          layout: layout,
          time: t,
          aspect: 1.6,
          motion: 0,
        ),
      ).distance;
      expect(distAt(3.0), greaterThan(distAt(3.17)));
      expect(distAt(3.17), greaterThan(distAt(3.33)));
      expect(distAt(3.5), closeTo(distAt(5.0), 1e-9));
    });

    test('跟字时正在唱的词总在画面里', () {
      final MetaphorPoseTracker tracker = MetaphorPoseTracker();
      for (double t = 3.0; t < 6.0; t += 0.1) {
        final MetaphorPose p = tracker.resolve(
          MetaphorPoseInput(
            shot: shot(MetaphorShotKind.macro),
            layout: layout,
            time: t,
            aspect: 1.6,
            motion: 1,
          ),
        );
        expect(p.distance.isFinite && p.x.isFinite && p.y.isFinite, isTrue);
      }
    });

    test('静态机位 / 漫墨 / 化开', () {
      final MetaphorPose still = resolveMetaphorStillPose(layout, 1.6);
      expect(still.roll, 0);
      final List<MetaphorProgramLine> lines = <MetaphorProgramLine>[
        for (int i = 0; i < 30; i++)
          MetaphorProgramLine(
            lineIndex: i,
            text: 'word word word $i',
            start: 1.0 + i * 3,
            end: 3.0 + i * 3,
            wordStarts: <double>[1.0 + i * 3],
          ),
      ];
      final MetaphorProgram p = compileMetaphorProgram(lines, seed: 3);
      final int flooded = p.cues.indexWhere(
        (MetaphorCue c) => c.transition == MetaphorTransition.flood,
      );
      expect(flooded, greaterThan(0));
      final MetaphorCue c = p.cues[flooded];
      expect(resolveMetaphorFlood(p, flooded, c.start), closeTo(1.15, 1e-9));
      expect(resolveMetaphorFlood(p, flooded, c.start + 2), 0);
      expect(
        resolveMetaphorFlood(p, flooded - 1, c.start - 0.01),
        greaterThan(1),
      );
      // 紧跟下一句的不化开
      expect(resolveMetaphorMelt(p.cues[flooded], c.end - 0.01), 0);
      expect(resolveMetaphorReveal(c, c.start), 0);
      expect(resolveMetaphorReveal(c, c.start + 0.6), 1);
    });
  });

  group('融球与线稿', () {
    test('规划确定、对撞和成对粒子写得进实例数据', () {
      const MetaphorRect bounds = MetaphorRect(-3, -1, 3, 1);
      final List<MetaphorShape> a = planMetaphorShapes(
        bounds,
        metaphorRng('x'),
        1,
        false,
      );
      final List<MetaphorShape> b = planMetaphorShapes(
        bounds,
        metaphorRng('x'),
        1,
        false,
      );
      expect(a.length, b.length);
      expect(a.length, lessThanOrEqualTo(80));
      expect(planMetaphorShapes(bounds, metaphorRng('x'), 0, false), isEmpty);
      final List<MetaphorCollision> hits = planMetaphorCollisions(
        bounds,
        metaphorRng('c'),
        <double>[5],
        1,
        false,
      );
      final MetaphorInstances out = MetaphorInstances();
      writeMetaphorCollisions(hits, 4, out);
      expect(out.count, 8); // 相向飞来的两颗墨球各带三个尾点
      out.clear();
      writeMetaphorCollisions(hits, 5.5, out);
      expect(out.count, greaterThan(2));
      out.clear();
      writeMetaphorCollisions(hits, 20, out);
      expect(out.count, 0);
      final MetaphorLayout layout = _layoutOf(
        LyricVisualizerRuntime(sampleWordTimeline()).lines[0],
        MetaphorComposition.block,
      );
      out.clear();
      writeMetaphorPairs(layout.glyphs, 1.35, out);
      expect(out.count, 4); // 夜、空 已经唱到
      out.clear();
      writeMetaphorShapes(a, 10, 0.5, 1, out);
      expect(out.count, a.length);
    });

    test('拼接时小墨滴的 parent 跟着挪', () {
      const MetaphorShape head = MetaphorShape(shape: metaphorShapeBlob);
      const MetaphorShape drop = MetaphorShape(
        shape: metaphorShapeBlob,
        parent: 0,
        orbit: 1,
      );
      final List<MetaphorShape> joined = joinMetaphorShapes(
        <List<MetaphorShape>>[
          <MetaphorShape>[head, head],
          <MetaphorShape>[head, drop],
        ],
      );
      expect(joined[3].parent, 2);
    });

    test('十九种图都画得出来，数值有限', () {
      for (final MetaphorFigureKind kind in MetaphorFigureKind.values) {
        final MetaphorFigures f = drawMetaphorFigure(
          kind,
          metaphorRng('$kind'),
        );
        expect(f.shapes, isNotEmpty, reason: '$kind');
        expect(f.notes, isNotEmpty, reason: '$kind');
        for (final MetaphorShape s in f.shapes) {
          expect(
            <double>[
              s.x,
              s.y,
              s.sx,
              s.sy,
              s.rot,
            ].every((double v) => v.isFinite),
            isTrue,
            reason: '$kind',
          );
        }
        final MetaphorFigures toned = drawMetaphorFigure(
          kind,
          metaphorRng('$kind'),
          toned: true,
        );
        expect(toned.notes, isEmpty);
        expect(toned.shapes.every((MetaphorShape s) => s.ink == 0), isTrue);
      }
    });

    test('版面带行号和时间码；图摆在字外面', () {
      const MetaphorRect bounds = MetaphorRect(-2, -0.6, 2, 0.6);
      bool sawTimecode = false;
      for (int i = 0; i < 20; i++) {
        final MetaphorFigures b = planMetaphorBackdrop(
          bounds,
          metaphorRng('b$i'),
          1,
          false,
          index: 3,
          time: 75,
        );
        if (b.notes.any((MetaphorNote n) => n.text.contains('01:15'))) {
          sawTimecode = true;
        }
      }
      expect(sawTimecode, isTrue);
      final MetaphorFigures figs = planMetaphorFigures(
        bounds,
        metaphorRng('f'),
        1,
        false,
      );
      expect(figs.notes, isNotEmpty);
      final List<MetaphorNoteGlyph> glyphs = layoutMetaphorNotes(<MetaphorNote>[
        const MetaphorNote(
          text: 'ab c',
          x: 0,
          y: 0,
          size: 1,
          rot: 0,
          align: 1,
          born: 0,
        ),
      ], (String _) => 0.5);
      expect(glyphs.length, 3);
      expect(glyphs.last.x, closeTo(-0.25, 1e-9));
      expect(
        planMetaphorFigures(bounds, metaphorRng('f'), 0, false).shapes,
        isEmpty,
      );
    });
  });

  test('配色：反相对调纸墨，强调色和墨分得开', () {
    final LyricVisualizerPalette base = LyricVisualizerPalette.fromScheme(
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: Brightness.dark,
      ),
    );
    final MetaphorPalette p = resolveMetaphorPalette(base);
    final MetaphorPalette f = resolveMetaphorPalette(base, flip: true);
    expect(p.paper, f.ink);
    expect(p.ink, f.paper);
    double dist(Color a, Color b) => math.sqrt(
      math.pow(a.r - b.r, 2) + math.pow(a.g - b.g, 2) + math.pow(a.b - b.b, 2),
    );
    expect(dist(p.accent, p.ink), greaterThanOrEqualTo(0.25 - 1e-9));
  });

  group('挂载', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, metaphorVisualizerEntry);
    });

    testWidgets('非默认参数组合', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        metaphorVisualizerEntry,
        tuning: const <String, Object?>{
          'cutPace': 2.0,
          'cameraMotion': 2.0,
          'flow': 0.0,
          'blobs': 2.0,
          'halftone': 2.5,
          'grain': 0.0,
          'negative': false,
          'flip': true,
          'transitions': false,
        },
      );
    });

    testWidgets('没有装饰、颗粒拉满', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        metaphorVisualizerEntry,
        tuning: const <String, Object?>{
          'blobs': 0.0,
          'grain': 2.0,
          'flow': 2.0,
          'halftone': 0.5,
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        metaphorVisualizerEntry,
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('减弱动态 + 暂停', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        metaphorVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('窄屏竖屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        metaphorVisualizerEntry,
        size: const Size(390, 844),
      );
    });

    testWidgets('纯音乐（没有歌词）', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        metaphorVisualizerEntry,
        timeline: const LyricTimeline(format: 'lrc', lines: <LyricLine>[]),
        timesMs: const <int>[0, 3000, 40000, 800000],
      );
    });
  });
}
