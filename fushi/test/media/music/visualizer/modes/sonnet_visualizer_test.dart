import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_beat_fx.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_graphics.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_motion.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_typography.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_visualizer.dart';

import '../visualizer_test_helpers.dart';

SonnetSourceLine _line(String text, double start, double end) {
  final List<String> chars = text.split('');
  final double step = (end - start) / chars.length;
  return SonnetSourceLine(
    text: text,
    start: start,
    end: end,
    graphemes: <SonnetGrapheme>[
      for (int i = 0; i < chars.length; i++)
        SonnetGrapheme(chars[i], start + i * step, start + (i + 1) * step),
    ],
  );
}

List<SonnetSourceLine> _song() => <SonnetSourceLine>[
  for (int i = 0; i < 14; i++)
    _line(
      i.isEven ? '夜明けの空を見上げていた' : 'Sing a song for the morning light',
      i * 3.0 + (i >= 7 ? 6 : 0),
      i * 3.0 + 2.6 + (i >= 7 ? 6 : 0),
    ),
];

const SonnetColors _colors = SonnetColors(
  primary: Color(0xFFF5F5F5),
  secondary: Color(0xFF90CAF9),
  accent: Color(0xFFFFB74D),
  background: Color(0xFF101014),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('种子与随机', () {
    test('FNV 哈希稳定、随机流可复现且落在 [0,1)', () {
      expect(hashSonnetSeed('sonnet'), hashSonnetSeed('sonnet'));
      expect(hashSonnetSeed('a'), isNot(hashSonnetSeed('b')));
      final SonnetRng a = SonnetRng(42);
      final SonnetRng b = SonnetRng(42);
      for (int i = 0; i < 50; i++) {
        final double v = a.next();
        expect(v, b.next());
        expect(v, inInclusiveRange(0, 0.9999999));
      }
      expect(sonnetHash01(7, 3, 11), inInclusiveRange(0, 1));
    });
  });

  group('分词与编排', () {
    test('分段覆盖整行、不丢字', () {
      final SonnetSourceLine line = _line('夜明けの空を見上げていた。Hello world', 0, 4);
      final List<SonnetSegment> segs = buildSonnetSegments(line);
      expect(segs, isNotEmpty);
      expect(
        segs.map((SonnetSegment s) => s.text).join().replaceAll(' ', ''),
        line.text.replaceAll(' ', ''),
      );
      for (final SonnetSegment s in segs) {
        expect(s.end, greaterThanOrEqualTo(s.start));
      }
    });

    test('段落 / 镜头：时间有序、镜头至多 4 行、同种子结果一致', () {
      final SonnetProgram p = compileSonnetProgram(_song(), 'seed-a');
      final SonnetProgram q = compileSonnetProgram(_song(), 'seed-a');
      expect(p.paragraphs.length, greaterThanOrEqualTo(2), reason: '6 秒的停顿要切段');
      double last = -1;
      for (final SonnetParagraph para in p.paragraphs) {
        expect(para.shots, isNotEmpty);
        expect(para.lines.length, lessThanOrEqualTo(6));
        for (final SonnetShot s in para.shots) {
          expect(s.lineIndices.length, inInclusiveRange(1, 4));
          expect(s.start, greaterThanOrEqualTo(last));
          expect(s.end, greaterThan(s.start));
          last = s.start;
        }
      }
      expect(
        q.paragraphs
            .expand((SonnetParagraph x) => x.shots)
            .map((SonnetShot s) => s.kind)
            .toList(),
        p.paragraphs
            .expand((SonnetParagraph x) => x.shots)
            .map((SonnetShot s) => s.kind)
            .toList(),
      );
      expect(p.paragraphIndexAt(-5), 0);
      expect(p.paragraphIndexAt(1e6), p.paragraphs.length - 1);
    });

    test('没有歌词时生成「♪」虚拟行', () {
      final List<SonnetSourceLine> lines = sonnetSourceLinesOf(
        LyricVisualizerRuntime(
          const LyricTimeline(format: 'lrc', lines: <LyricLine>[]),
        ),
      );
      expect(lines, hasLength(60));
      expect(lines.every((SonnetSourceLine l) => l.text == '♪'), isTrue);
      expect(compileSonnetProgram(lines, 'x').paragraphs, isNotEmpty);
    });
  });

  group('运动', () {
    test('缓动端点与焦点权重归一', () {
      expect(easeSonnetExpoOut(0), closeTo(0, 1e-9));
      expect(easeSonnetExpoOut(1), 1);
      expect(easeSonnetInOut(0.5), closeTo(0.5, 0.02));
      final List<double> w = resolveSonnetFocusWeights(<(double, double)>[
        (0, 1),
        (2, 3),
        (5, 6),
      ], 2.5);
      expect(
        w.fold<double>(0, (double a, double b) => a + b),
        closeTo(1, 1e-9),
      );
      expect(w[1], greaterThan(w[0]));
    });

    test('关掉转场时一直是静止帧；片尾在末句后升起', () {
      final SonnetProgram p = compileSonnetProgram(_song(), 'seed-b');
      for (int i = 0; i < p.paragraphs.length; i++) {
        final SonnetParagraph para = p.paragraphs[i];
        for (double t = para.start; t < para.end; t += 0.1) {
          final int shot = findSonnetActiveShotIndex(para.shots, t);
          expect(
            resolveSonnetSceneTransition(p, i, shot, t, false).isIdle,
            isTrue,
          );
        }
      }
      expect(resolveSonnetCreditsFrame(10, 20).active, isFalse);
      final SonnetCreditsFrame end = resolveSonnetCreditsFrame(24, 20);
      expect(end.active, isTrue);
      expect(end.posterAlpha, closeTo(1, 1e-6));
      expect(end.lyricAlpha, closeTo(0, 1e-6));
    });
  });

  group('场景构建', () {
    test('每段的镜头齐全，逐字入场时间不早于镜头、不倒序', () {
      final SonnetProgram p = compileSonnetProgram(_song(), 'seed-c');
      for (final Size size in <Size>[
        const Size(1280, 720),
        const Size(390, 844),
      ]) {
        final SonnetSceneInputs inputs = SonnetSceneInputs(
          program: p,
          size: size,
          settings: const SonnetSettings(),
          colors: _colors,
          measurer: SonnetTextMeasurer(),
          fontScale: 1,
          motion: true,
          title: 'T',
          artist: 'A',
          album: 'B',
        );
        for (int i = 0; i < p.paragraphs.length; i++) {
          final SonnetSceneView scene = buildSonnetScene(inputs, i);
          expect(scene.shots, hasLength(p.paragraphs[i].shots.length));
          int glyphs = 0;
          for (final SonnetShotView shot in scene.shots) {
            for (final SonnetSegmentView seg in shot.segments) {
              for (final SonnetGlyphView g in seg.glyphs) {
                expect(g.settle, greaterThanOrEqualTo(g.start));
                expect(g.baseX.isFinite && g.baseY.isFinite, isTrue);
                if (g.isTextGlyph) glyphs++;
              }
            }
          }
          expect(glyphs, greaterThan(0));
          scene.dispose();
        }
      }
    });

    test('只显示文字时不建 MG 背景线与元信息', () {
      final SonnetProgram p = compileSonnetProgram(_song(), 'seed-d');
      final SonnetSceneView scene = buildSonnetScene(
        SonnetSceneInputs(
          program: p,
          size: const Size(1280, 720),
          settings: const SonnetSettings(showOnlyText: true),
          colors: _colors,
          measurer: SonnetTextMeasurer(),
          fontScale: 1,
          motion: true,
          title: 'T',
        ),
        0,
      );
      expect(scene.bgLines, isEmpty);
      expect(scene.metaTitle, isNull);
      for (final SonnetShotView s in scene.shots) {
        expect(
          s.segments.where(
            (SonnetSegmentView x) => x.role == SonnetSegmentRole.decoration,
          ),
          isEmpty,
        );
      }
      scene.dispose();
    });
  });

  group('可生长矢量', () {
    test('空路径描边不录命令；任意进度都能画', () {
      final SonnetAnimatedGraphics g = SonnetAnimatedGraphics(3);
      g.stroke(const Color(0xFFFFFFFF));
      expect(g.isEmpty, isTrue);
      g.moveTo(0, 0).lineTo(100, 0).stroke(const Color(0xFFFFFFFF), width: 2);
      g.rect(0, 0, 50, 20).fill(const Color(0xFFFF0000), alpha: 0.5);
      g.circle(10, 10, 30).stroke(const Color(0xFF00FF00));
      expect(g.isEmpty, isFalse);
      for (final double p in <double>[0, 0.25, 0.5, 0.99, 1, 1]) {
        final ui.PictureRecorder rec = ui.PictureRecorder();
        g.paint(Canvas(rec), p);
        rec.endRecording().dispose();
      }
      g.dispose();
    });
  });

  group('冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, sonnetVisualizerEntry);
    });

    testWidgets('非默认组合：后期 + 外框 + 关转场 + 关装饰字', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        sonnetVisualizerEntry,
        tuning: <String, Object?>{
          'cameraIntensity': 2.0,
          'typographyMotion': 0.0,
          'mgDensity': 2.0,
          'showGuide': false,
          'showGiantDecorativeText': false,
          'enableTransitions': false,
          'outerFrameMode': 'frame',
          'postProcessEnabled': true,
          'postProcessGrain': 1.0,
          'postProcessContrast': 0.6,
          'postProcessRgbShift': 0.8,
          'postProcessHalftone': 0.5,
          'postProcessVignette': 2.0,
        },
      );
    });

    testWidgets('只显示文字 + 无外框', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        sonnetVisualizerEntry,
        tuning: <String, Object?>{
          'showOnlyText': true,
          'outerFrameMode': 'none',
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        sonnetVisualizerEntry,
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('减弱动态 + 暂停', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        sonnetVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('窄屏竖屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        sonnetVisualizerEntry,
        size: const Size(390, 844),
      );
    });

    testWidgets('纯音乐（无歌词）', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        sonnetVisualizerEntry,
        timeline: const LyricTimeline(format: 'lrc', lines: <LyricLine>[]),
      );
    });
  });

  group('共享框架接入', () {
    test('分词来自共享词组：拉丁词各成一词，句号粘到前一词', () {
      final SonnetSourceLine line = _line('夜明けの空を見上げていた。Hello world', 0, 4);
      final List<String> words = <String>[
        for (final SonnetSegment s in buildSonnetSegments(line))
          if (s.isWordLike) s.text,
      ];
      expect(words, contains('Hello'));
      expect(words, contains('world'));
      expect(words.any((String w) => w.endsWith('。')), isTrue);
      // 中文无词典逐字成词（与共享分词一致）。
      final List<SonnetSegment> zh = buildSonnetSegments(_line('我爱你', 0, 3));
      expect(zh.where((SonnetSegment s) => s.isWordLike).length, 3);
    });

    test('副歌行 → chorus 段；Bridge 标注 → break 段；段落编号变化即断段', () {
      SonnetSourceLine tagged(
        String text,
        double start, {
        bool chorus = false,
        String? part,
        int? block,
      }) {
        final SonnetSourceLine b = _line(text, start, start + 2.4);
        return SonnetSourceLine(
          text: b.text,
          start: b.start,
          end: b.end,
          graphemes: b.graphemes,
          isChorus: chorus,
          songPart: part,
          blockIndex: block,
        );
      }

      final List<SonnetSourceLine> lines = <SonnetSourceLine>[
        tagged('静かな夜に歩いてた', 0, part: 'Verse', block: 0),
        tagged('君の声を探してた', 2.5, part: 'Verse', block: 0),
        tagged('光の中へ飛び込んで', 5, chorus: true, part: 'Chorus', block: 1),
        tagged('永遠に歌い続けて', 7.5, chorus: true, part: 'Chorus', block: 1),
        tagged('ひとりきりの間奏', 10, part: 'Bridge', block: 2),
        tagged('おわりのことば', 12.5, part: 'Outro', block: 3),
      ];
      final SonnetProgram p = compileSonnetProgram(lines, 'tags');
      expect(p.paragraphs.length, 4);
      expect(p.paragraphs[1].kind, SonnetParagraphKind.chorus);
      expect(p.paragraphs[1].boundary, SonnetParagraphBoundary.metadata);
      expect(p.paragraphs[2].kind, SonnetParagraphKind.breakPart);
      expect(p.paragraphs[3].kind, SonnetParagraphKind.outro);
    });

    test('随拍特效：拍上推镜、强拍撕裂与光晕，没有节拍网格时不出随拍帧', () {
      final LyricVisualizerContext withAudio = visualizerContextFor(
        sonnetVisualizerEntry,
        clock: FakeVisualizerClock(),
        audio: SyntheticVisualizerAudio(),
      );
      final SonnetBeatFxReader reader = SonnetBeatFxReader();
      final SonnetBeatFxFrame onBeat = reader.read(
        withAudio,
        withAudio.audioFrameAt(1000),
        1000,
        wallTimeSec: 1,
      )!;
      expect(onBeat.zoom, closeTo(1.06, 1e-3));
      expect(onBeat.rotation.abs(), greaterThan(0));
      expect(onBeat.tear, 0);
      final SonnetBeatFxFrame onDown = reader.read(
        withAudio,
        withAudio.audioFrameAt(2000),
        2000,
        wallTimeSec: 2,
      )!;
      expect(onDown.tear, closeTo(0.6, 1e-6));
      expect(onDown.flare, closeTo(0.7, 1e-6));
      // 相邻两拍倾斜方向相反。
      final SonnetBeatFxFrame next = reader.read(
        withAudio,
        withAudio.audioFrameAt(1500),
        1500,
        wallTimeSec: 1.5,
      )!;
      expect(onBeat.rotation.sign, isNot(next.rotation.sign));

      final LyricVisualizerContext noAudio = visualizerContextFor(
        sonnetVisualizerEntry,
        clock: FakeVisualizerClock(),
      );
      final LyricVisualizerAudioFrame lyric = noAudio.audioFrameAt(1200);
      expect(lyric.fallback, isTrue);
      expect(reader.read(noAudio, lyric, 1200, wallTimeSec: 1), isNull);
      // 没有节拍时图标按（歌词包络代用的）频段呼吸，目标值落在 0–1。
      expect(resolveSonnetIconAudioTarget(lyric), inInclusiveRange(0, 1));
    });

    test('小节位置、起跳包络、线条闪亮与重音塑形', () {
      final List<int> beats = <int>[0, 500, 1000, 1500, 2000];
      final List<int> downs = <int>[0, 2000];
      expect(sonnetBarPosition(beats, downs, 1600), 3);
      expect(sonnetBarPosition(beats, downs, 2100), 0);
      expect(
        resolveSonnetBeatFxAccent(hasAccents: true, barPosition: 3).$2,
        0.5,
      );
      expect(
        resolveSonnetBeatFxAccent(hasAccents: false, barPosition: 3).$2,
        1,
      );
      expect(resolveSonnetIconOnsetPop(1.0, <double>[0.2, 1.0]), 1);
      expect(resolveSonnetIconOnsetPop(0.1, <double>[0.2]), 0);
      expect(resolveSonnetIconPopScale(1), closeTo(1.4, 1e-9));
      expect(resolveSonnetLineFlashAlpha(0), 0.78);
      expect(resolveSonnetLineFlashAlpha(1), 1);
    });

    test('主题强度倍数与关键词着色', () {
      expect(sonnetAnimationScale(LyricVisualizerIntensity.calm), 0.65);
      expect(sonnetAnimationScale(LyricVisualizerIntensity.normal), 1);
      expect(sonnetAnimationScale(LyricVisualizerIntensity.chaotic), 1.35);
      const SonnetColors c = SonnetColors(
        primary: Color(0xFFFFFFFF),
        secondary: Color(0xFF000000),
        accent: Color(0xFF000000),
        background: Color(0xFF000000),
        keywords: <String, Color>{'hello': Color(0xFFFF0000)},
      );
      expect(c.keywordColorOf('Hello'), const Color(0xFFFF0000));
      expect(c.keywordColorOf('world'), isNull);
    });

    test('背景请求：用户选的共享背景', () {
      expect(
        sonnetVisualizerEntry.backgroundFor(
          LyricVisualizerTuning.defaults(sonnetVisualizerEntry.tunings),
        ),
        LyricVisualizerBackgroundRequest.selected,
      );
    });

    testWidgets('有音频分析 + AI 主题（关键词 / 字重）+ 热烈强度', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        sonnetVisualizerEntry,
        audio: SyntheticVisualizerAudio(),
        intensity: LyricVisualizerIntensity.chaotic,
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'Sing': Color(0xFFFF4081)},
          fontWeight: FontWeight.w500,
        ),
      );
    });

    testWidgets('只有节拍网格（包络未就绪）+ 舒缓强度', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        sonnetVisualizerEntry,
        audio: SyntheticVisualizerAudio(envelopeReady: false),
        intensity: LyricVisualizerIntensity.calm,
      );
    });
  });
}
