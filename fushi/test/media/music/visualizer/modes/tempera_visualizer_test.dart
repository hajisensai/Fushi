import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_compositions.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_ink.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_motion.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_profiles.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_random.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_shapes.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_visualizer.dart';

import '../visualizer_test_helpers.dart';

TemperaProgram _program(LyricTimeline timeline, {bool wholeLine = false}) =>
    compileTemperaProgram(
      LyricVisualizerRuntime(timeline).lines,
      seed: 'test',
      wholeLineLyrics: wholeLine,
    );

/// 很多段、带长间奏的行级时间轴：保证有多个段落、桥接分镜与段落转场。
LyricTimeline _longTimeline() => LyricTimeline(
  format: 'lrc',
  lines: <LyricLine>[
    for (int i = 0; i < 16; i++)
      LyricLine(
        startMs: i * 2600 + (i ~/ 4) * 6000,
        endMs: i * 2600 + (i ~/ 4) * 6000 + 2400,
        syllables: <LyricSyllable>[
          LyricSyllable(
            text: i.isEven ? '君の声が聞こえる夜 $i' : 'Every light in town $i',
            startMs: i * 2600 + (i ~/ 4) * 6000,
            endMs: i * 2600 + (i ~/ 4) * 6000 + 2400,
          ),
        ],
      ),
  ],
);

TemperaPalette _palette(
  TemperaColorMode mode, [
  List<Color> cover = const <Color>[],
]) => resolveTemperaPalette(
  background: const Color(0xFF15121C),
  primary: const Color(0xFFEDE6F5),
  secondary: const Color(0xFF7D6A9A),
  accent: const Color(0xFFD08A5C),
  mode: mode,
  coverColors: cover,
);

LyricVisualizerLine _lineOf(String text) => LyricVisualizerRuntime(
  LyricTimeline(
    format: 'lrc',
    lines: <LyricLine>[
      LyricLine(
        startMs: 0,
        endMs: 2000,
        syllables: <LyricSyllable>[
          LyricSyllable(text: text, startMs: 0, endMs: 2000),
        ],
      ),
    ],
  ),
).lines.first;

LyricLine _tagged(int i, String text, String part) => LyricLine(
  startMs: i * 2500,
  endMs: i * 2500 + 2300,
  songPart: part,
  syllables: <LyricSyllable>[
    LyricSyllable(text: text, startMs: i * 2500, endMs: i * 2500 + 2300),
  ],
);

double _fakeMeasure(String text, double size) => text.runes.length * size * 0.6;

void main() {
  group('tempera random', () {
    test('hash is deterministic and in [0, 1)', () {
      for (int i = 0; i < 200; i++) {
        final double v = temperaHash01(1234, i, 97);
        expect(v, inInclusiveRange(0, 1));
        expect(v < 1, isTrue);
        expect(temperaHash01(1234, i, 97), v);
      }
      expect(temperaHashSeed('abc'), temperaHashSeed('abc'));
      expect(temperaHashSeed('abc'), isNot(temperaHashSeed('abd')));
    });
  });

  group('tempera program', () {
    test('segmenter splits CJK / Latin / mixed text', () {
      final List<(int, int, bool)> latin = temperaSegmentRanges(
        _lineOf('Hello world'),
      );
      expect(latin.where(((int, int, bool) r) => r.$3).length, 2);
      final List<(int, int, bool)> ja = temperaSegmentRanges(_lineOf('夜空に光'));
      expect(ja.where(((int, int, bool) r) => r.$3), isNotEmpty);
      final List<(int, int, bool)> mixed = temperaSegmentRanges(
        _lineOf('君とdance'),
      );
      expect(
        mixed.where(((int, int, bool) r) => r.$3).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('compiles word and line timelines deterministically', () {
      for (final LyricTimeline tl in <LyricTimeline>[
        sampleWordTimeline(),
        sampleLineTimeline(),
        _longTimeline(),
      ]) {
        final TemperaProgram a = _program(tl);
        final TemperaProgram b = _program(tl);
        expect(a.paragraphs, isNotEmpty);
        final List<String> kindsA = <String>[
          for (final TemperaParagraph p in a.paragraphs)
            for (final TemperaShot s in p.shots) s.kind,
        ];
        final List<String> kindsB = <String>[
          for (final TemperaParagraph p in b.paragraphs)
            for (final TemperaShot s in p.shots) s.kind,
        ];
        expect(kindsA, kindsB);
        for (final String k in kindsA) {
          expect(temperaShotKinds, contains(k));
        }
        for (final TemperaParagraph p in a.paragraphs) {
          expect(p.endTime, greaterThanOrEqualTo(p.startTime));
          for (final TemperaShot s in p.shots) {
            expect(s.endTime, greaterThanOrEqualTo(s.startTime));
          }
        }
      }
    });

    test('long song has several paragraphs and transitions', () {
      final TemperaProgram p = _program(_longTimeline());
      expect(p.paragraphs.length, greaterThan(1));
      expect(
        p.paragraphs.any((TemperaParagraph x) => x.transitionOut != null),
        isTrue,
      );
      expect(temperaParagraphIndexAt(p, 0), 0);
      expect(temperaParagraphIndexAt(p, 1e6), p.paragraphs.length - 1);
    });

    test('whole-line mode keeps a line in one shot', () {
      final TemperaProgram p = _program(sampleLineTimeline(), wholeLine: true);
      for (final TemperaParagraph para in p.paragraphs) {
        for (final TemperaShot s in para.shots.where(
          (TemperaShot s) => !s.isBridge,
        )) {
          expect(s.slices.length, lessThanOrEqualTo(2));
        }
      }
    });
  });

  group('tempera compositions', () {
    test('registry covers every shot kind', () {
      expect(temperaShotKinds.length, 121);
      for (final String kind in temperaShotKinds) {
        expect(temperaCompositions.containsKey(kind), isTrue, reason: kind);
      }
    });

    test('every composition builds blocks at both sizes', () {
      final TemperaShot shot = _program(
        sampleWordTimeline(),
      ).paragraphs.first.shots.first;
      for (final Size size in const <Size>[Size(1280, 720), Size(390, 844)]) {
        for (final TemperaColorMode mode in TemperaColorMode.values) {
          for (final String kind in temperaShotKinds) {
            final TemperaComposer c = TemperaComposer(
              kind: kind,
              palette: _palette(mode),
              decor: shot.decor,
              width: size.width,
              height: size.height,
              seed: 42,
              showDecor: true,
              flowAngle: shot.flowAngle,
            );
            drawTemperaComposition(c);
            expect(c.items, isNotEmpty, reason: kind);
            final TemperaBlocks blocks = TemperaBlocks(
              c.items,
              size.width,
              size.height,
              shot.flowAngle,
            );
            blocks.update(1, 0, 3, 2);
            blocks.update(5, 0, 3, 2, still: true);
            expect(
              blocks.items.every((TemperaBlockItem i) => i.visible),
              isTrue,
            );
          }
        }
      }
    });
  });

  group('tempera layout', () {
    test('places every visible grapheme inside a sane box', () {
      final TemperaProgram p = _program(sampleWordTimeline());
      for (final TemperaParagraph para in p.paragraphs) {
        for (final TemperaShot shot in para.shots) {
          final List<List<TemperaSegment>> lines = <List<TemperaSegment>>[
            for (final TemperaShotSlice slice in shot.slices)
              para.lines
                  .firstWhere(
                    (TemperaCompiledLine l) => l.sourceIndex == slice.lineIndex,
                  )
                  .segments
                  .sublist(slice.segmentStart, slice.segmentEnd)
                  .where(temperaIsLayoutSegment)
                  .toList(),
          ];
          final int expected = lines.fold(
            0,
            (int n, List<TemperaSegment> segs) =>
                n +
                segs.fold(
                  0,
                  (int m, TemperaSegment s) =>
                      m +
                      s.graphemes
                          .where(
                            (TemperaGrapheme g) => g.char.trim().isNotEmpty,
                          )
                          .length,
                ),
          );
          for (final Size size in const <Size>[
            Size(1280, 720),
            Size(390, 844),
          ]) {
            final List<TemperaGlyphPlacement> placed = resolveTemperaLayout(
              lines: lines,
              shotKind: shot.kind,
              width: size.width,
              height: size.height,
              baseFontSize: 80,
              seed: 7,
              measure: _fakeMeasure,
            );
            expect(placed.length, expected);
            for (final TemperaGlyphPlacement g in placed) {
              expect(g.fontSize, greaterThan(0));
              expect(g.x, inInclusiveRange(-size.width, size.width * 2));
              expect(g.y, inInclusiveRange(-size.height, size.height * 2));
              expect(
                g.settleTime,
                greaterThanOrEqualTo(g.startTime + 0.34 - 1e-9),
              );
              expect(g.releaseTime, greaterThanOrEqualTo(g.settleTime));
            }
          }
        }
      }
    });

    test('hero word is the biggest in its line', () {
      final List<TemperaSegment> segs = buildTemperaSegments(
        LyricVisualizerRuntime(sampleWordTimeline()).lines[1],
      );
      final List<double> scales = temperaWordScales(segs, 3, 0);
      expect(scales.where((double s) => s >= 1.34).length, 1);
    });

    test('glyph depth normalises by the biggest glyph', () {
      final List<double> d = temperaGlyphDepths(<double>[100, 40, 70]);
      expect(d[0], closeTo(1, 1e-9));
      expect(d[1], closeTo(0, 1e-9));
      expect(d[2], closeTo(0.5, 1e-9));
      expect(temperaGlyphDepths(const <double>[]), isEmpty);
    });
  });

  group('tempera motion', () {
    test('glyph motion settles to its placement', () {
      const TemperaGlyphMotionInput g = TemperaGlyphMotionInput(
        startTime: 1,
        settleTime: 1.5,
        endTime: 2,
        enterX: 80,
        enterY: -40,
        enterRotation: 0.3,
        enterScale: 0.7,
        rotation: 0.02,
        enterStyle: TemperaEnterStyle.slide,
        releaseTime: 3,
        trackingX: 0,
        trackingY: 0,
      );
      expect(temperaGlyphMotion(g, 0.5, 1).visible, isFalse);
      final TemperaGlyphMotionFrame settled = temperaGlyphMotion(g, 2.5, 1);
      expect(settled.visible, isTrue);
      expect(settled.alpha, closeTo(1, 1e-6));
      expect(settled.x.abs(), lessThan(1e-6));
      final TemperaGlyphMotionFrame calm = temperaGlyphMotion(g, 1.1, 0);
      expect(calm.x, 0);
      expect(calm.echoAlpha, 0);
    });

    test('credits fade the lyric out and the poster in', () {
      final TemperaCreditsFrame before = temperaCreditsFrame(10, 20);
      expect(before.active, isFalse);
      expect(before.lyricAlpha, closeTo(1, 1e-6));
      final TemperaCreditsFrame after = temperaCreditsFrame(30, 20);
      expect(after.active, isTrue);
      expect(after.lyricAlpha, closeTo(0, 1e-6));
      expect(after.posterAlpha, closeTo(1, 1e-6));
    });
  });

  group('tempera palette', () {
    test('tone ladder runs monotonically from paper to ink', () {
      for (final TemperaColorMode mode in TemperaColorMode.values) {
        final TemperaPalette p = _palette(mode, const <Color>[
          Color(0xFFE04040),
          Color(0xFF40A0E0),
          Color(0xFF30C060),
        ]);
        final List<double> l = <double>[
          temperaLuminance(p.paper),
          temperaLuminance(p.tone1),
          temperaLuminance(p.tone2),
          temperaLuminance(p.tone3),
          temperaLuminance(p.tone4),
          temperaLuminance(p.ink),
        ];
        for (int i = 1; i < l.length; i++) {
          expect(l[i], greaterThanOrEqualTo(l[i - 1] - 2), reason: '$mode $l');
        }
        expect(p.gradient != null, mode == TemperaColorMode.gradient);
      }
    });

    test('inversion picks the farther of ink and paper', () {
      final TemperaPalette p = _palette(TemperaColorMode.duo);
      expect(temperaPrefersPaper(p.paper, p.ink, p.paper), isFalse);
      expect(temperaPrefersPaper(p.ink, p.ink, p.paper), isTrue);
    });

    test('cover colours pick distinct dominant buckets', () {
      final Uint8List rgba = Uint8List(16 * 16 * 4);
      for (int i = 0; i < 256; i++) {
        final bool red = i < 160;
        rgba
          ..[i * 4] = red ? 220 : 20
          ..[i * 4 + 1] = red ? 30 : 40
          ..[i * 4 + 2] = red ? 30 : 230
          ..[i * 4 + 3] = 255;
      }
      final List<Color> colors = temperaCoverColors(rgba, 16, 16);
      expect(colors.length, 2);
      expect((colors.first.r * 255).round(), 220);
      expect(temperaCoverColors(Uint8List(0), 0, 0), isEmpty);
    });
  });

  group('tempera engine', () {
    test('paints every paragraph, transition and the credits', () {
      final TemperaProgram program = _program(_longTimeline());
      for (final bool motion in <bool>[true, false]) {
        final TemperaEngine engine = TemperaEngine(
          TemperaSceneConfig(
            program: program,
            programSeed: 'test',
            palette: _palette(TemperaColorMode.gradient),
            settings: const TemperaSettings(depth: true, contrast: 0.5),
            motion: motion,
            fontScale: 1,
            cornerColor: const Color(0xFFFFFFFF),
            title: 'Title',
            artist: 'Artist',
          ),
        );
        final double end = program.paragraphs.last.endTime + 4;
        for (double t = 0; t < end; t += 0.37) {
          final ui.PictureRecorder rec = ui.PictureRecorder();
          engine.paint(Canvas(rec), const Size(390, 844), t, t);
          rec.endRecording().dispose();
          expect(engine.cachedParagraphs.length, lessThanOrEqualTo(3));
        }
        engine.dispose();
      }
    });
  });

  group('tempera widget', () {
    testWidgets('default tuning', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, temperaVisualizerEntry);
    });

    testWidgets('non-default tuning', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        temperaVisualizerEntry,
        tuning: const <String, Object?>{
          kTemperaColorMode: 'gradient',
          kTemperaTextInversion: false,
          kTemperaDepth: true,
          kTemperaCoverLayer: true,
          kTemperaLayerDepth: 'front',
          kTemperaWholeLine: true,
          kTemperaPostProcess: false,
          kTemperaShowDecor: false,
          kTemperaCornerMarks: false,
          kTemperaCameraIntensity: 2.0,
          kTemperaGlyphMotion: 0.0,
        },
      );
      await pumpVisualizerAcross(
        tester,
        temperaVisualizerEntry,
        tuning: const <String, Object?>{
          kTemperaColorMode: 'mono',
          kTemperaShowBlocks: false,
          kTemperaTransitions: false,
          kTemperaContrast: 0.8,
          kTemperaGrain: 1.0,
        },
      );
    });

    testWidgets('line-level timeline', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        temperaVisualizerEntry,
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('motion off', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        temperaVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('narrow size', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        temperaVisualizerEntry,
        size: const Size(390, 844),
      );
    });

    test('entry is registered with shared backdrop and subtitle', () {
      expect(temperaVisualizerEntry.mode, LyricVisualizerMode.tempera);
      expect(
        temperaVisualizerEntry.backgroundFor(
          LyricVisualizerTuning.defaults(temperaTunings),
        ),
        LyricVisualizerBackgroundRequest.selected,
      );
      expect(temperaVisualizerEntry.sharedSubtitle, isTrue);
      expect(temperaVisualizerEntry.tunings, isNotEmpty);
      final TemperaSettings s = temperaSettingsOf(
        LyricVisualizerTuning(temperaTunings, const <String, Object?>{}),
      );
      expect(s.colorMode, TemperaColorMode.duo);
      expect(s.textInversion, isTrue);
    });
  });

  group('tempera shared framework', () {
    test('segments come from the shared word groups and cover every glyph', () {
      final LyricVisualizerLine line = _lineOf('夜明けの空を見上げた。Hello');
      final List<(int, int, bool)> r = temperaSegmentRanges(line);
      expect(r.first.$1, 0);
      expect(r.last.$2, line.glyphs.length);
      for (int i = 1; i < r.length; i++) {
        expect(r[i].$1, r[i - 1].$2);
      }
      expect(
        r.where(((int, int, bool) x) => x.$3).length,
        line.segments.length,
      );
    });

    test('song parts: chorus / bridge kinds and metadata boundaries', () {
      final TemperaProgram p = _program(
        LyricTimeline(
          format: 'ttml',
          lines: <LyricLine>[
            _tagged(0, '静かな夜に歩いてた', 'Verse'),
            _tagged(1, '君の声を探してた', 'Verse'),
            _tagged(2, '光の中へ飛び込んで', 'Chorus'),
            _tagged(3, '永遠に歌い続けて', 'Chorus'),
            _tagged(4, 'ひとりきりの間奏', 'Bridge'),
            _tagged(5, 'おわりのことば', 'Outro'),
          ],
        ),
      );
      expect(p.paragraphs.length, 4);
      expect(p.paragraphs[1].kind, TemperaParagraphKind.chorus);
      expect(p.paragraphs[2].kind, TemperaParagraphKind.breakPart);
      expect(p.paragraphs[3].kind, TemperaParagraphKind.outro);
    });

    test('keyword colours map onto segments by UTF-16 span', () {
      const LyricVisualizerTheme theme = LyricVisualizerTheme(
        wordColors: <String, Color>{'Hello': Color(0xFFFF0000)},
      );
      final TemperaProgram p = _program(
        LyricTimeline(
          format: 'lrc',
          lines: <LyricLine>[
            LyricLine(
              startMs: 0,
              endMs: 3000,
              syllables: <LyricSyllable>[
                LyricSyllable(text: '君と Hello world', startMs: 0, endMs: 3000),
              ],
            ),
          ],
        ),
      );
      final TemperaCompiledLine line = p.paragraphs.first.lines.first;
      final List<Color?> colors = temperaSegmentKeywordColors(
        line,
        theme.colorRangesFor(line.text),
      );
      final int hello = line.segments.indexWhere(
        (TemperaSegment s) => s.text.startsWith('Hello'),
      );
      expect(colors[hello], const Color(0xFFFF0000));
      expect(colors.whereType<Color>().length, 1);
    });

    test('ink flash: envelope, gap filter, last hit, hits from drum hits', () {
      expect(temperaInkFlashEnvelope(-0.1), 0);
      expect(temperaInkFlashEnvelope(0.1), 1);
      expect(temperaInkFlashEnvelope(0.6), lessThan(0.02));
      expect(temperaInkFlashHits(<double>[0, 0.1, 0.25, 0.3, 1]), <double>[
        0,
        0.25,
        1,
      ]);
      expect(temperaInkLastHit(<double>[0, 0.5, 1], 0.7), 1);
      expect(temperaInkLastHit(<double>[0, 0.5, 1], -1), -1);
      final LyricVisualizerContext withAudio = visualizerContextFor(
        temperaVisualizerEntry,
        clock: FakeVisualizerClock(),
        audio: SyntheticVisualizerAudio(),
        offsetMs: 100,
      );
      // 合成音频：底鼓 / 军鼓落在每拍上，镲片在反拍（不出墨）。
      final List<double> hits = temperaInkHitsOf(withAudio);
      expect(hits.take(3), <double>[0.1, 0.6, 1.1]);
      final LyricVisualizerContext noAudio = visualizerContextFor(
        temperaVisualizerEntry,
        clock: FakeVisualizerClock(),
      );
      expect(temperaInkHitsOf(noAudio), isEmpty);
    });

    test('intensity scale, layer image pick and background request', () {
      expect(temperaAnimationScale(LyricVisualizerIntensity.calm), 0.65);
      expect(temperaAnimationScale(LyricVisualizerIntensity.chaotic), 1.35);
      expect(temperaPickLayerImage(5, 0, -1), -1);
      for (int seed = 0; seed < 40; seed++) {
        final int a = temperaPickLayerImage(seed, 3, -1);
        expect(a, inInclusiveRange(0, 2));
        expect(temperaPickLayerImage(seed, 3, a), isNot(a));
      }
      expect(
        temperaVisualizerEntry.backgroundFor(
          LyricVisualizerTuning.defaults(temperaVisualizerEntry.tunings),
        ),
        LyricVisualizerBackgroundRequest.selected,
      );
    });

    testWidgets('audio + depth + AI theme + chaotic intensity', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        temperaVisualizerEntry,
        audio: SyntheticVisualizerAudio(),
        intensity: LyricVisualizerIntensity.chaotic,
        tuning: <String, Object?>{'depth': true, 'inkFlash': 2.0},
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'light': Color(0xFF40C4FF)},
          fontWeight: FontWeight.w800,
        ),
      );
    });

    testWidgets('beats only (no envelope), ink off, calm', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        temperaVisualizerEntry,
        audio: SyntheticVisualizerAudio(envelopeReady: false),
        intensity: LyricVisualizerIntensity.calm,
        tuning: <String, Object?>{'inkFlash': 0.0},
      );
    });
  });
}
