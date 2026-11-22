import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_line_cache.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_painter.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_timing.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_visualizer.dart';

import '../visualizer_test_helpers.dart';

LyricVisualizerLine _line(List<(String, int)> parts, {int start = 1000}) {
  final List<LyricSyllable> syl = <LyricSyllable>[];
  int t = start;
  for (final (String text, int d) in parts) {
    syl.add(LyricSyllable(text: text, startMs: t, endMs: t + d));
    t += d;
  }
  return LyricVisualizerRuntime(
    LyricTimeline(
      format: 'ttml',
      timingQuality: LyricTimingQuality.word,
      lines: <LyricLine>[LyricLine(startMs: start, endMs: t, syllables: syl)],
    ),
  ).lines.single;
}

LyricVisualizerLine _lrc(String text, int start, int end) =>
    LyricVisualizerRuntime(
      LyricTimeline(
        format: 'lrc',
        lines: <LyricLine>[
          LyricLine(
            startMs: start,
            endMs: end,
            syllables: <LyricSyllable>[
              LyricSyllable(text: text, startMs: start, endMs: end),
            ],
          ),
        ],
      ),
    ).lines.single;

List<String> _texts(List<PartitaUnit> u) =>
    u.map((PartitaUnit x) => x.text).toList();

void main() {
  group('layout unit', () {
    test('CJK 句末标点粘到前一个字上，计时词保留', () {
      final LyricVisualizerLine l = _line(<(String, int)>[
        ('世', 200),
        ('界', 200),
        ('。', 100),
      ]);
      final List<PartitaUnit> u = buildPartitaLayoutUnits(l, semantic: false);
      expect(_texts(u), <String>['世', '界。']);
      expect(u.last.isSticky, isTrue);
      expect(u.last.words, hasLength(2));
      // 粘滞的非语义单元合成一个显示词，字形区间连续。
      final List<LyricVisualizerWord> d = partitaDisplayWords(u, l.glyphs);
      expect(d.map((LyricVisualizerWord w) => w.text), <String>['世', '界。']);
      expect(d.last.startMs, 1200);
      expect(d.last.endMs, 1500);
    });

    test('语义分组：汉字两两一组、送假名并进前组，再粘标点', () {
      final LyricVisualizerLine l = _line(<(String, int)>[
        ('夜', 200),
        ('空', 200),
        ('に', 200),
        ('光', 200),
        ('！', 100),
      ]);
      final List<PartitaUnit> u = buildPartitaLayoutUnits(l, semantic: true);
      expect(_texts(u), <String>['夜空に', '光！']);
      expect(u.first.isSemantic, isTrue);
      // 语义单元显示时仍逐字。
      final List<LyricVisualizerWord> d = partitaDisplayWords(u, l.glyphs);
      expect(d.map((LyricVisualizerWord w) => w.text), <String>[
        '夜',
        '空',
        'に',
        '光！',
      ]);
    });

    test('中文长串两两分组，余一并进最后一组；关掉语义则逐字', () {
      final LyricVisualizerLine l = _line(<(String, int)>[
        for (final String c in '我们一起走'.split('')) (c, 200),
      ]);
      expect(_texts(buildPartitaLayoutUnits(l, semantic: true)), <String>[
        '我们',
        '一起走',
      ]);
      expect(buildPartitaLayoutUnits(l, semantic: false), hasLength(5));
    });

    test('英文分开的缩写 / 逗号粘回前词', () {
      final LyricVisualizerLine l = _line(<(String, int)>[
        ('we ', 200),
        ("'re ", 200),
        ('home ', 200),
        (', ', 100),
        ('now', 200),
      ]);
      expect(_texts(buildPartitaLayoutUnits(l, semantic: true)), <String>[
        "we're",
        'home,',
        'now',
      ]);
    });
  });

  group('chunk 切分', () {
    test('段数 = min(单元数, 目标行数)，每段至少 1 个、全部用完', () {
      final List<PartitaUnit> units = <PartitaUnit>[
        for (int i = 0; i < 11; i++)
          PartitaUnit(
            words: <LyricVisualizerWord>[
              LyricVisualizerWord(
                text: 'w$i',
                startMs: i * 100,
                endMs: i * 100 + 100,
                firstGlyph: i,
                glyphCount: 1,
              ),
            ],
            text: 'w$i',
          ),
      ];
      for (final int seed in <int>[1, 2, 3, 99, 12345]) {
        final LyricVisualizerRandom r = LyricVisualizerRandom(seed);
        final List<List<PartitaUnit>> c = splitPartitaChunks(units, 4, r.next);
        expect(c, hasLength(4));
        expect(c.every((List<PartitaUnit> x) => x.isNotEmpty), isTrue);
        expect(
          c.fold<int>(0, (int a, List<PartitaUnit> x) => a + x.length),
          11,
        );
      }
      expect(
        splitPartitaChunks(units.sublist(0, 2), 5, () => 0.5),
        hasLength(2),
      );
      expect(partitaTargetRowCount(720), 4);
      expect(partitaTargetRowCount(100), 1);
    });

    test('行错位左右交替、幅度落在参数区间；calm 不缩放不偏移', () {
      final LyricVisualizerLine l = _lrc(
        'one two three four five six seven eight',
        0,
        4000,
      );
      const PartitaSettings s = PartitaSettings(staggerMin: 30, staggerMax: 60);
      final PartitaLinePlan p = planPartitaLine(
        l,
        windowHeight: 720,
        settings: s,
        random: LyricVisualizerRandom(7).next,
      );
      expect(p.rows, hasLength(4));
      for (final PartitaRowPlan r in p.rows) {
        expect(r.config.x.abs(), inInclusiveRange(30, 60));
        expect(r.config.x < 0, r.rowIndex.isEven);
        expect(r.config.scale, inInclusiveRange(0.8, 1.7));
        expect(r.wordPoses, hasLength(r.displayWords.length));
      }
      final PartitaLinePlan calm = planPartitaLine(
        l,
        windowHeight: 720,
        settings: const PartitaSettings(intensity: PartitaIntensity.calm),
        random: LyricVisualizerRandom(7).next,
      );
      for (final PartitaRowPlan r in calm.rows) {
        expect(r.config.scale, 1);
        expect(r.config.y, 0);
        for (final PartitaPose w in r.wordPoses) {
          expect(w.x, 0);
          expect(w.rotate, 0);
        }
      }
    });

    test('参数两端夹到 0–180 并排好序', () {
      final PartitaSettings s = PartitaSettings.fromTuning(
        LyricVisualizerTuning(
          partitaVisualizerEntry.tunings,
          const <String, Object?>{'staggerMin': 150.0, 'staggerMax': 40.0},
        ),
        motion: true,
      );
      expect(s.staggerMin, 40);
      expect(s.staggerMax, 150);
      final PartitaSettings off = PartitaSettings.fromTuning(
        LyricVisualizerTuning.defaults(partitaVisualizerEntry.tunings),
        motion: false,
      );
      expect(off.intensity, PartitaIntensity.calm);
    });
  });

  group('几何', () {
    PartitaLinePlan plan() => planPartitaLine(
      _lrc('alpha beta gamma delta epsilon zeta', 0, 3000),
      windowHeight: 400,
      settings: const PartitaSettings(),
      random: LyricVisualizerRandom(3).next,
    );

    test('行框逐行向下、词不相交；防重叠只会拉开间距', () {
      final PartitaLinePlan p = plan();
      final List<List<double>> widths = <List<double>>[
        for (final PartitaRowPlan r in p.rows)
          <double>[
            for (final LyricVisualizerWord w in r.displayWords)
              w.text.length * 30.0,
          ],
      ];
      final PartitaBlockGeometry a = layoutPartitaBlock(
        rows: p.rows,
        widths: widths,
        fontSize: 60,
        avoidOverlap: false,
      );
      final PartitaBlockGeometry b = layoutPartitaBlock(
        rows: p.rows,
        widths: widths,
        fontSize: 60,
        avoidOverlap: true,
      );
      for (int r = 1; r < a.rows.length; r++) {
        expect(a.rows[r].box.top, greaterThan(a.rows[r - 1].box.bottom));
      }
      for (final PartitaRowGeometry g in a.rows) {
        for (int i = 1; i < g.wordBoxes.length; i++) {
          expect(
            g.wordBoxes[i].left - g.wordBoxes[i - 1].right,
            closeTo(partitaWordGap, 1e-9),
          );
        }
      }
      expect(b.size.height, greaterThanOrEqualTo(a.size.height));
      expect(b.size.width, greaterThanOrEqualTo(a.size.width));
      final double fit = partitaFitScale(
        block: b,
        rows: p.rows,
        area: const Size(390, 844),
      );
      expect(fit, inInclusiveRange(0.3, 1.0));
    });

    test('字号跟宽度走并在 40–72 之间，长句打 0.8 折', () {
      expect(partitaFontSize(width: 390, totalGraphemes: 5, fontScale: 1), 40);
      expect(partitaFontSize(width: 2000, totalGraphemes: 5, fontScale: 1), 72);
      expect(
        partitaFontSize(width: 2000, totalGraphemes: 41, fontScale: 1),
        closeTo(57.6, 1e-9),
      );
    });
  });

  group('时序', () {
    test('按行时长分档：正常 / 短 / 极短', () {
      final PartitaRenderProfile n = partitaRenderProfileOf(
        _lrc('abc', 0, 2000),
      );
      expect(n.transition, PartitaLineTransition.normal);
      expect(n.lookaheadMs, 150);
      expect(n.renderEndMs, greaterThanOrEqualTo(2000));
      final PartitaRenderProfile f = partitaRenderProfileOf(_lrc('a', 0, 150));
      expect(f.reveal, PartitaWordReveal.fast);
      final PartitaRenderProfile m = partitaRenderProfileOf(_lrc('a', 0, 50));
      expect(m.transition, PartitaLineTransition.none);
      expect(m.renderEndMs, 67);
      expect(partitaActiveEndMs(0, 10, m), m.renderEndMs);
    });

    test('三态切换点：预读但不早于行出现', () {
      final PartitaRenderProfile p = partitaRenderProfileOf(
        _lrc('abc', 1000, 3000),
      );
      final PartitaStateTimes first = PartitaStateTimes.of(
        startMs: 1000,
        activeEndMs: 1500,
        lineStartMs: 1000,
        profile: p,
      );
      expect(first.activeAtMs, 1000);
      final PartitaStateTimes later = PartitaStateTimes.of(
        startMs: 2000,
        activeEndMs: 2500,
        lineStartMs: 1000,
        profile: p,
      );
      expect(later.activeAtMs, 1850);
      expect(later.phaseAt(1849), PartitaPhase.waiting);
      expect(later.phaseAt(2200), PartitaPhase.active);
      expect(later.phaseAt(2501), PartitaPhase.passed);
    });

    test('spring 从 0 出发、略过冲后收敛到 1', () {
      expect(partitaSpring(0), 0);
      double peak = 0;
      for (double s = 0; s < 1; s += 0.01) {
        peak = math.max(peak, partitaSpring(s));
      }
      expect(peak, greaterThan(1));
      expect(partitaSpring(2), closeTo(1, 1e-3));
    });

    test('词：waiting 隐形 → active 放大到 1.4 倍 → passed 回原大并慢转', () {
      const PartitaPose pose = PartitaPose(
        x: 4,
        y: -2,
        rotate: 2,
        scale: 1.2,
        passedRotate: 8,
      );
      const PartitaStateTimes times = PartitaStateTimes(
        activeAtMs: 1000,
        passedAtMs: 3000,
      );
      final PartitaAnimState w = partitaWordStateAt(
        pose,
        times,
        500,
        intensity: PartitaIntensity.normal,
      );
      expect(w.opacity, 0);
      final PartitaAnimState a = partitaWordStateAt(
        pose,
        times,
        2900,
        intensity: PartitaIntensity.normal,
      );
      expect(a.opacity, 1);
      expect(a.scale, closeTo(1.2 * partitaActiveScale, 1e-3));
      final PartitaAnimState p = partitaWordStateAt(
        pose,
        times,
        3000 + 6000,
        intensity: PartitaIntensity.normal,
      );
      expect(p.opacity, closeTo(0.82, 1e-6));
      expect(p.scale, closeTo(1.2, 1e-6));
      expect(p.rotate, closeTo(10, 1e-6));
    });

    test('发光：多字逐字扫过、单字持续亮，passed 后淡出', () {
      const PartitaStateTimes times = PartitaStateTimes(
        activeAtMs: 0,
        passedAtMs: 1000,
      );
      double g(int glyphStart, int glyphEnd, bool per, int t) => partitaGlowAt(
        times: times,
        reveal: PartitaWordReveal.normal,
        durationMs: 1000,
        wordStartMs: 0,
        glyphStartMs: glyphStart,
        glyphEndMs: glyphEnd,
        perGlyph: per,
        timeMs: t,
      );
      // 第二个字（500–1000）在自己的起点前不亮。
      expect(g(500, 1000, true, 400), 0);
      expect(g(500, 1000, true, 1000), greaterThan(0));
      expect(g(0, 1000, false, 950), closeTo(1, 1e-6));
      expect(g(0, 1000, false, 1000 + 2000), 0);
    });

    test('整句容器：进场淡入、离场放大模糊消失', () {
      final PartitaRenderProfile p = partitaRenderProfileOf(
        _lrc('abc', 0, 2000),
      );
      final ({double opacity, double scale, double blur}) enter =
          partitaLineContainerAt(
            profile: p,
            lineStartMs: 0,
            leaveAtMs: 2000,
            timeMs: 0,
          );
      expect(enter.opacity, 0);
      expect(enter.blur, 10);
      final ({double opacity, double scale, double blur}) mid =
          partitaLineContainerAt(
            profile: p,
            lineStartMs: 0,
            leaveAtMs: 2000,
            timeMs: 1500,
          );
      expect(mid.opacity, 1);
      expect(mid.blur, 0);
      final ({double opacity, double scale, double blur}) gone =
          partitaLineContainerAt(
            profile: p,
            lineStartMs: 0,
            leaveAtMs: 2000,
            timeMs: 2300,
          );
      expect(gone.opacity, 0);
      expect(gone.scale, closeTo(1.1, 1e-6));
    });
  });

  test('排版缓存：同句复用，超过上限淘汰并释放', () {
    final PartitaLineCache cache = PartitaLineCache();
    addTearDown(cache.dispose);
    final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
      sampleWordTimeline(),
    );
    cache.bindTo(rt);
    PartitaLinePaint get(LyricVisualizerLine l, double w) => cache.lineFor(
      line: l,
      area: Size(w, 720),
      fontScale: 1,
      settings: const PartitaSettings(),
      style: const TextStyle(),
      seed: 1,
    );
    final PartitaLinePaint a = get(rt.lines.first, 1280);
    expect(identical(get(rt.lines.first, 1280), a), isTrue);
    expect(a.rows, isNotEmpty);
    expect(a.fitScale, inInclusiveRange(0.3, 1.0));
    for (int i = 0; i < 60; i++) {
      get(rt.lines.first, 300.0 + i * 10);
    }
    expect(cache.length, 48);
    cache.bindTo(Object());
    expect(cache.length, 0);
  });

  group('冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, partitaVisualizerEntry);
    });

    testWidgets('混乱强度 + 防重叠 + 关引导线 + 关语义', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        partitaVisualizerEntry,
        tuning: const <String, Object?>{
          'intensity': 'chaotic',
          'avoidOverlap': true,
          'showGuideLines': false,
          'useSemanticLayout': false,
          'staggerMin': 180.0,
          'staggerMax': 0.0,
        },
      );
    });

    testWidgets('平静强度', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        partitaVisualizerEntry,
        tuning: const <String, Object?>{'intensity': 'calm'},
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        partitaVisualizerEntry,
        timeline: sampleLineTimeline(),
        timesMs: const <int>[0, 600, 2000, 2990, 3100, 4500, 5990, 6400, 9000],
      );
    });

    testWidgets('减弱动态效果 + 暂停', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        partitaVisualizerEntry,
        timeline: sampleLineTimeline(),
        motion: false,
        playing: false,
      );
    });

    testWidgets('窄屏竖屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        partitaVisualizerEntry,
        size: const Size(390, 844),
        tuning: const <String, Object?>{'avoidOverlap': true},
      );
    });

    testWidgets('不吞点击（纯展示）', (WidgetTester tester) async {
      final FakeVisualizerClock clock = FakeVisualizerClock(1500);
      final LyricVisualizerContext c = visualizerContextFor(
        partitaVisualizerEntry,
        clock: clock,
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: partitaVisualizerEntry.builder(c))),
      );
      await tester.pump(const Duration(milliseconds: 16));
      final Finder root = find.byType(PartitaVisualizer);
      expect(
        find.descendant(of: root, matching: find.byType(GestureDetector)),
        findsNothing,
      );
      expect(
        find.descendant(of: root, matching: find.byType(CustomPaint)),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
