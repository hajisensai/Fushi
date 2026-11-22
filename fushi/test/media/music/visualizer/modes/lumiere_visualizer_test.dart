import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_line_art.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_profile.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_rig.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_visualizer.dart';

import '../visualizer_test_helpers.dart';

LumiereLine _l(
  int index,
  double start,
  double end, [
  String text = 'la la la la',
]) => LumiereLine(
  index: index,
  start: start,
  end: end,
  text: text,
  wordCount: text.split(' ').length,
);

LyricLine _line(int start, List<(String, int)> parts) {
  final List<LyricSyllable> syl = <LyricSyllable>[];
  int t = start;
  for (final (String text, int d) in parts) {
    syl.add(LyricSyllable(text: text, startMs: t, endMs: t + d));
    t += d;
  }
  return LyricLine(startMs: start, endMs: t, syllables: syl);
}

void main() {
  group('光位目录', () {
    test('10 族 × 10 种，kind 唯一，未知退回天井', () {
      expect(lumiereProfiles, hasLength(100));
      expect(lumiereKinds.toSet(), hasLength(100));
      final Map<String, int> families = <String, int>{};
      for (final LumiereProfile p in lumiereProfiles) {
        families[p.family] = (families[p.family] ?? 0) + 1;
      }
      expect(families.keys.toList(), <String>[
        'zenith',
        'lattice',
        'prism',
        'caustic',
        'optics',
        'wave',
        'botany',
        'astral',
        'stage',
        'motes',
      ]);
      expect(families.values.every((int n) => n == 10), isTrue);
      expect(profileOf('nope').kind, 'zenith-shaft');
      expect(profileOf('botany-sprout').heroSize, 0.08);
    });

    test('每个光位在横竖两种画幅下都能构造，光束不超过上限', () {
      for (final double aspect in <double>[16 / 9, 390 / 844]) {
        for (final LumiereProfile p in lumiereProfiles) {
          final LightRig rig = p.light(
            RigContext(aspect, lumiereRng('t:${p.kind}')),
          );
          expect(
            rig.beams.length,
            inInclusiveRange(1, kMaxBeams),
            reason: p.kind,
          );
          final LineArtSpec art = p.lineArt(
            RigContext(aspect, lumiereRng('a:${p.kind}')),
          );
          for (final LinePath path in art.paths) {
            expect(
              path.points.every((Pt q) => q.$1.isFinite && q.$2.isFinite),
              isTrue,
              reason: p.kind,
            );
          }
        }
      }
    });
  });

  group('光场', () {
    test('光束轴线上有光、束外为零、窗影留漏光', () {
      final List<ResolvedBeam> beams = resolveBeams(
        const LightRig(beams: <BeamSpec>[kShaft]),
        0,
        16 / 9,
        const LightDrive(intensity: 1, bass: 0, color: kWhite),
      );
      const double aspect = 16 / 9;
      expect(beamMask(beams.first, aspect * 0.5, 0.3), greaterThan(0.05));
      expect(beamMask(beams.first, aspect * 0.05, 0.3), 0);
      expect(beamMask(beams.first, aspect * 0.5, -0.2), 0);
      expect(
        goboMask(const GoboSpec(GoboPattern.cross, 0, 0.16, 0), 0, 0, 0.3),
        closeTo(kGoboLeak, 1e-9),
      );
      expect(compressLight(0), 0);
      expect(compressLight(10), lessThan(1));
    });

    test('调色：光色归一到峰值 1', () {
      final LumierePalette p = LumierePalette.resolve(
        accent: const Color(0xFF3366FF),
        primary: const Color(0xFFFF8800),
        secondary: const Color(0xFF22AA88),
        background: const Color(0xFF101010),
        themeMix: 0.3,
      );
      expect(p.light.peak, closeTo(1, 1e-9));
      final LumierePalette dark = LumierePalette.resolve(
        accent: const Color(0xFF000000),
        primary: const Color(0xFF000000),
        secondary: const Color(0xFF000000),
        background: const Color(0xFF000000),
        themeMix: 1,
      );
      // 全黑主题退回香槟金
      expect(dark.light.r, closeTo(1, 1e-9));
    });
  });

  group('节目单', () {
    final List<LumiereLine> lines = <LumiereLine>[
      _l(0, 1, 3),
      _l(1, 3.2, 5),
      _l(2, 5.2, 7),
      _l(3, 7.2, 9),
      _l(4, 20, 22),
      _l(5, 22.3, 24),
      _l(6, 24.3, 26),
    ];

    test('短行两两成镜头，长行单独成镜头', () {
      final List<StructureLine> s = buildStructureLines(<LumiereLine>[
        _l(0, 0, 2),
        _l(1, 2, 4),
        _l(2, 4, 9),
        _l(3, 9, 10),
      ]);
      final List<List<StructureLine>> groups = groupLines(s);
      expect(groups.map((List<StructureLine> g) => g.length).toList(), <int>[
        2,
        1,
        1,
      ]);
    });

    test('长空隙切段落、出间奏镜头，确定性', () {
      final LumiereProgram a = compileLumiereProgram(
        lines,
        'seed',
        seamless: false,
      );
      final LumiereProgram b = compileLumiereProgram(
        lines,
        'seed',
        seamless: false,
      );
      expect(a.paragraphs.length, 2);
      expect(a.paragraphs.first.start, 0);
      expect(a.paragraphs.first.end, 20);
      expect(a.paragraphs.last.end, closeTo(26, 1e-9));
      final List<LumiereShot> first = a.paragraphs.first.shots;
      expect(first.any((LumiereShot s) => s.isBridge), isTrue);
      expect(first.last.isBridge, isTrue);
      expect(
        <String>[
          for (final LumiereParagraph p in a.paragraphs)
            for (final LumiereShot s in p.shots) s.kind,
        ],
        <String>[
          for (final LumiereParagraph p in b.paragraphs)
            for (final LumiereShot s in p.shots) s.kind,
        ],
      );
      // 间奏镜头只用萤尘 / 星象 / 天光里不喧哗的
      for (final LumiereShot s in first.where((LumiereShot s) => s.isBridge)) {
        expect(<String>[
          'motes',
          'astral',
          'zenith',
        ], contains(profileOf(s.kind).family));
        expect(profileOf(s.kind).mood, isNot(LumiereMood.loud));
      }
      // 相邻镜头不重复同一光位
      final List<String> kinds = <String>[
        for (final LumiereParagraph p in a.paragraphs)
          for (final LumiereShot s in p.shots) s.kind,
      ];
      for (int i = 1; i < kinds.length; i++) {
        expect(kinds[i], isNot(kinds[i - 1]));
      }
      expect(a.paragraphs.first.transitionOut, isNotNull);
      expect(a.paragraphs.last.transitionOut, isNull);
      expect(a.paragraphs.last.opening, isTrue);
    });

    test('轨迹过渡把整首并成一个单元，保留段落范围', () {
      final LumiereProgram p = compileLumiereProgram(lines, 'seed');
      expect(p.paragraphs, hasLength(1));
      expect(p.paragraphs.single.sections, hasLength(2));
      expect(p.paragraphs.single.transitionOut, isNull);
      expect(p.paragraphs.single.lineIndices, <int>[0, 1, 2, 3, 4, 5, 6]);
    });

    test('前奏够长出前奏段；纯音乐按 32 秒切段', () {
      final LumiereProgram intro = compileLumiereProgram(
        <LumiereLine>[_l(0, 6, 8), _l(1, 8.2, 10)],
        's',
        seamless: false,
      );
      expect(intro.paragraphs.first.kind, ParagraphKind.breakKind);
      expect(intro.paragraphs.first.shots.single.isBridge, isTrue);
      final LumiereProgram instrumental = compileLumiereProgram(
        const <LumiereLine>[],
        's',
        duration: 96,
        seamless: false,
      );
      expect(instrumental.instrumental, isTrue);
      expect(instrumental.paragraphs, hasLength(3));
      expect(instrumental.lyricEnd, isNull);
    });

    test('转场：不连续重复，帧的形状对', () {
      LumiereTransitionKind? previous;
      for (int i = 0; i < 20; i++) {
        final LumiereTransitionKind k = chooseTransition('x', i, previous);
        expect(k, isNot(previous));
        previous = k;
      }
      expect(
        transitionFrame(
          LumiereTransitionKind.lightsOut,
          exit: true,
          progress: 1,
        ).alpha,
        0,
      );
      expect(
        transitionFrame(
          LumiereTransitionKind.flareCut,
          exit: true,
          progress: 1,
        ).blur,
        closeTo(7, 1e-9),
      );
      expect(
        transitionFrame(
          LumiereTransitionKind.focusPull,
          exit: false,
          progress: 1,
        ).blur,
        0,
      );
      expect(transitionDuration(LumiereTransitionKind.focusPull, 0), 0.45);
      expect(transitionDuration(LumiereTransitionKind.lightsOut, 10), 1.1);
      expect(
        transitionEnterDuration(LumiereTransitionKind.lightsOut, 0, 0.1),
        0.4,
      );
    });
  });

  group('歌词窗口', () {
    final LyricVisualizerRuntime runtime = LyricVisualizerRuntime(
      LyricTimeline(
        format: 'ttml',
        lines: <LyricLine>[
          _line(2000, <(String, int)>[
            ('hello ', 400),
            ('bright ', 400),
            ('world', 400),
          ]),
          _line(4000, <(String, int)>[('光', 300), ('の', 300), ('中', 300)]),
          _line(6000, <(String, int)>[('again', 600)]),
        ],
      ),
    );
    double advance(String c) => 0.6;

    test('放不下就换行，放得下就一行', () {
      final LyricVisualizerLine line = runtime.lines.first;
      final List<double> ones = List<double>.filled(line.glyphs.length, 1);
      final LineShape wide = shapeHorizontal(line, advance, ones, 100);
      expect(wide.ys.toSet(), hasLength(1));
      final LineShape narrow = shapeHorizontal(line, advance, ones, 4);
      expect(narrow.ys.toSet().length, greaterThan(1));
      expect(narrow.width, lessThanOrEqualTo(4 + 1e-9));
      final LineShape vertical = shapeVertical(
        runtime.lines[1],
        List<double>.filled(3, 1),
        10,
      );
      expect(vertical.xs.toSet(), hasLength(1));
      expect(lineIsCjk(runtime.lines[1]), isTrue);
    });

    test('开唱前提前成为当前行；唱到的字点亮', () {
      expect(focusOf(runtime.lines, 0.5), -1);
      expect(focusOf(runtime.lines, 2 - kLead + 0.01), 0);
      final List<LineShape> shapes = <LineShape>[
        for (final LyricVisualizerLine l in runtime.lines)
          shapeHorizontal(
            l,
            advance,
            List<double>.filled(l.glyphs.length, 1),
            20,
          ),
      ];
      List<GlyphPlacement> at(double t, {bool motion = false}) => layoutWindow(
        WindowInput(
          lines: runtime.lines,
          shapes: shapes,
          randoms: <GlyphRandoms>[
            for (final LyricVisualizerLine l in runtime.lines)
              GlyphRandoms('g${l.index}', l.glyphs.length),
          ],
          time: t,
          animTime: t,
          motion: motion,
          typography: WindowTypography.horizontal,
          regionCx: 640,
          regionCy: 360,
          regionW: 900,
          regionH: 360,
          heroPx: 60,
          neighbors: 2,
          unlitAlpha: 0.22,
          decay: const DecaySpec(1, 1),
          decayGain: 1,
          trails: true,
        ),
        vertical: false,
      );
      final List<GlyphPlacement> early = at(2.05);
      final List<GlyphPlacement> current = early
          .where((GlyphPlacement g) => g.current)
          .toList();
      expect(current.first.lit, greaterThan(0));
      expect(current.last.lit, 0);
      // 下一行（「光の中」）作为邻行已经露面
      expect(early.any((GlyphPlacement g) => g.char == '光'), isTrue);
      final List<GlyphPlacement> later = at(3.5);
      // 1.2 秒前导之后「光の中」成了当前行，唱完的第一行退到上一行、全亮
      expect(later.firstWhere((GlyphPlacement g) => g.current).char, '光');
      expect(
        later
            .where((GlyphPlacement g) => 'hlobrtwd'.contains(g.char))
            .every((GlyphPlacement g) => g.lit == 1),
        isTrue,
      );
      // 动态开着时，聚拢中的字带轨迹线
      final List<GlyphPlacement> gathering = at(1.0, motion: true);
      expect(
        gathering.any((GlyphPlacement g) => g.flying > 0 && g.trackX != null),
        isTrue,
      );
      expect(flashEnvelope(kFlashAttack), closeTo(1, 1e-9));
      expect(flashEnvelope(-1), 0);
    });

    test('词的字号：关键词放大、虚词缩小', () {
      final List<double> s = glyphScalesOf(runtime.lines.first, 'k');
      expect(s.reduce(math.max), 1.45);
    });
  });

  group('绘光 冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, lumiereVisualizerEntry);
    });

    testWidgets('段落转场 + 只显示下一行关 + 省电 + 关线稿 + 隐藏轨迹', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        lumiereVisualizerEntry,
        tuning: <String, Object?>{
          LumiereTuningKeys.seamlessTransitions: false,
          LumiereTuningKeys.windowNeighbors: '1',
          LumiereTuningKeys.renderQuality: 'low',
          LumiereTuningKeys.lineArt: false,
          LumiereTuningKeys.hideTrails: true,
          LumiereTuningKeys.trails: false,
          LumiereTuningKeys.fogOctaves: 2.0,
          LumiereTuningKeys.themeColorMix: 1.0,
          LumiereTuningKeys.bloom: 0.0,
        },
      );
    });

    testWidgets('仅显示歌词文字 + 均衡', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        lumiereVisualizerEntry,
        tuning: <String, Object?>{
          LumiereTuningKeys.textOnly: true,
          LumiereTuningKeys.renderQuality: 'balanced',
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        lumiereVisualizerEntry,
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('减弱动态效果', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, lumiereVisualizerEntry, motion: false);
    });

    testWidgets('竖屏窄画幅', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        lumiereVisualizerEntry,
        size: const Size(390, 844),
      );
    });
  });
}
