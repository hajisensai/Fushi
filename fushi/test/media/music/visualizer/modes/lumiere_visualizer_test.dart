import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_audio.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_line_art.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_profile.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_rig.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_theme_icons.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_visualizer.dart';

import 'package:fushi/src/utils/fushi_icons.dart';

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
              GlyphRandoms('g${l.position}', l.glyphs.length),
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

  group('主题图标', () {
    test('落点：按种子确定、避开文字区与画面边缘、彼此不重叠；没图标时为空', () {
      const TextRegion avoid = TextRegion(0.89, 0.5, 0.8, 0.3);
      List<LumierePlacedIcon> place(String key) => placeLumiereThemeIcons(
        icons: const <IconData>[
          FushiIcons.star,
          FushiIcons.cloud,
          FushiIcons.favorite,
        ],
        aspect: 16 / 9,
        avoid: avoid,
        random: lumiereRng(key),
        offset: 2,
      );
      final List<LumierePlacedIcon> a = place('s:0:k:icons');
      final List<LumierePlacedIcon> again = place('s:0:k:icons');
      expect(a, isNotEmpty);
      expect(a.length, lessThanOrEqualTo(3));
      expect(a.first.icon, FushiIcons.favorite);
      for (int i = 0; i < a.length; i++) {
        final LumierePlacedIcon p = a[i];
        expect(p.cx, again[i].cx);
        expect(p.size, inInclusiveRange(0.085, 0.13));
        final double half = p.size * 0.72;
        expect(p.cx - half, greaterThanOrEqualTo(0.05 - 1e-9));
        expect(p.cy + half, lessThanOrEqualTo(0.95 + 1e-9));
        final bool overlaps =
            (p.cx - avoid.cx).abs() < half + avoid.w / 2 + 0.05 &&
            (p.cy - avoid.cy).abs() < half + avoid.h / 2 + 0.05;
        expect(overlaps, isFalse);
        for (int j = 0; j < i; j++) {
          final LumierePlacedIcon o = a[j];
          final double d = math.sqrt(
            math.pow(o.cx - p.cx, 2) + math.pow(o.cy - p.cy, 2),
          );
          expect(d, greaterThanOrEqualTo((o.size + p.size) * 0.9));
        }
      }
      expect(
        placeLumiereThemeIcons(
          icons: const <IconData>[],
          aspect: 1.7,
          avoid: avoid,
          random: lumiereRng('x'),
        ),
        isEmpty,
      );
    });

    testWidgets('带主题图标冒烟（开 / 关）', (WidgetTester tester) async {
      const LyricVisualizerTheme theme = LyricVisualizerTheme(
        lyricsIcons: <LyricVisualizerThemeIcon>[
          LyricVisualizerThemeIcon.moon,
          LyricVisualizerThemeIcon.star,
        ],
      );
      await pumpVisualizerAcross(tester, lumiereVisualizerEntry, theme: theme);
      await pumpVisualizerAcross(
        tester,
        lumiereVisualizerEntry,
        theme: theme,
        tuning: const <String, Object?>{LumiereTuningKeys.themeIcons: false},
      );
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

  group('绘光接共享框架', () {
    LumiereLine tagged(int i, String part, {bool chorus = false}) =>
        LumiereLine(
          index: i,
          start: i * 2.5,
          end: i * 2.5 + 2.3,
          text: 'la la la la la',
          wordCount: 5,
          songPart: part,
          isChorus: chorus,
        );

    test('段落标注强制分段，副歌 / 间奏按标注定性', () {
      final List<LumiereLine> lines = <LumiereLine>[
        tagged(0, 'Verse'),
        tagged(1, 'Verse'),
        tagged(2, 'Chorus'),
        tagged(3, 'Chorus'),
        tagged(4, 'Bridge'),
        tagged(5, 'Outro'),
      ];
      final List<StructureLine> structure = buildStructureLines(lines);
      final List<List<StructureLine>> drafts = draftParagraphs(
        structure,
        resolveParagraphGapThreshold(lines),
      );
      expect(drafts.length, 4);
      expect(classifyParagraph(drafts[1], 1, 4), ParagraphKind.chorus);
      expect(classifyParagraph(drafts[2], 2, 4), ParagraphKind.breakKind);
      expect(classifyParagraph(drafts[3], 3, 4), ParagraphKind.outro);
      expect(
        lumiereMetadataChanged(
          tagged(0, 'Verse'),
          const LumiereLine(
            index: 1,
            start: 3,
            end: 4,
            text: 'x',
            wordCount: 1,
          ),
        ),
        isFalse,
      );
    });

    test('共享副歌标记（无源标注）也判 chorus', () {
      final List<LumiereLine> lines = <LumiereLine>[
        for (int i = 0; i < 3; i++)
          LumiereLine(
            index: i,
            start: i * 2.0,
            end: i * 2.0 + 1.8,
            text: 'la la la la la',
            wordCount: 5,
            isChorus: true,
          ),
        const LumiereLine(
          index: 3,
          start: 20,
          end: 22,
          text: 'end end end end',
          wordCount: 4,
        ),
      ];
      final List<List<StructureLine>> drafts = draftParagraphs(
        buildStructureLines(lines),
        resolveParagraphGapThreshold(lines),
      );
      expect(
        classifyParagraph(drafts.first, 0, drafts.length),
        ParagraphKind.chorus,
      );
    });

    test('音频采样：快起慢落、空帧归零', () {
      expect(
        smoothLumiereAudioValue(0, 1, 0.06),
        closeTo(1 - math.exp(-1), 1e-9),
      );
      expect(smoothLumiereAudioValue(1, 0, 0.25), closeTo(math.exp(-1), 1e-9));
      final LumiereAudioSampler sampler = LumiereAudioSampler();
      final LyricVisualizerContext c = visualizerContextFor(
        lumiereVisualizerEntry,
        clock: FakeVisualizerClock(),
        audio: SyntheticVisualizerAudio(),
      );
      for (int i = 0; i < 30; i++) {
        sampler.sample(c.audioFrameAt(1000), 1 / 60);
      }
      final LyricVisualizerAudioFrame frame = c.audioFrameAt(1000);
      expect(sampler.bass, closeTo(math.min(1, frame.low), 0.02));
      expect(sampler.treble, closeTo(frame.high, 0.02));
      expect(sampler.power, closeTo(frame.power, 0.02));
      sampler.sample(null, 1 / 60);
      expect(sampler.bass + sampler.treble + sampler.power, 0);
    });

    test('运镜强度、关键字光色、逐字关键字映射、背景请求', () {
      expect(lumiereCameraMotion(LyricVisualizerIntensity.calm), 0.6);
      expect(lumiereCameraMotion(LyricVisualizerIntensity.chaotic), 1.4);
      const Rgb light = Rgb(1, 0.9, 0.6);
      final Rgb k = lumiereKeywordLight(light, const Rgb(0, 0, 0.4), 0.6);
      expect(k.peak, closeTo(light.peak, 1e-9));
      expect(k.b, greaterThan(light.b));
      const LyricVisualizerTheme theme = LyricVisualizerTheme(
        wordColors: <String, Color>{'夜空': Color(0xFF2040FF)},
      );
      final List<Rgb?> colors = lumiereGlyphKeywordColors(
        '君と夜空'.split(''),
        theme.colorRangesFor('君と夜空'),
      );
      expect(colors[0], isNull);
      expect(colors[2], isNotNull);
      expect(colors[3], isNotNull);
      expect(
        lumiereVisualizerEntry.backgroundFor(
          LyricVisualizerTuning.defaults(lumiereVisualizerEntry.tunings),
        ),
        LyricVisualizerBackgroundRequest.selected,
      );
    });

    testWidgets('真音频 + AI 主题关键字 + 主题字重 + 激烈', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        lumiereVisualizerEntry,
        audio: SyntheticVisualizerAudio(),
        intensity: LyricVisualizerIntensity.chaotic,
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{
            'light': Color(0xFF40C4FF),
            '光': Color(0xFFFF4081),
          },
          fontWeight: FontWeight.w800,
        ),
      );
    });

    testWidgets('只有拍点 + 关键字着色关 + 平静', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        lumiereVisualizerEntry,
        audio: SyntheticVisualizerAudio(envelopeReady: false),
        intensity: LyricVisualizerIntensity.calm,
        tuning: <String, Object?>{'keywordColors': false},
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'light': Color(0xFF40C4FF)},
        ),
      );
    });
  });
}
