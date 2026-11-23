/// 框架共享能力：歌曲结构、渲染提示、词级分组、主题（按词着色 / 配色覆盖）、音频契约与回落。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

import 'visualizer_test_helpers.dart';

LyricLine _line(int start, int end, String text, {String? part}) => LyricLine(
  startMs: start,
  endMs: end,
  syllables: <LyricSyllable>[
    LyricSyllable(text: text, startMs: start, endMs: end),
  ],
  songPart: part,
);

List<String> _segTexts(String text) => buildLyricVisualizerSegments(
  buildLyricVisualizerGlyphs(_line(0, 1000, text)),
).map((LyricVisualizerSegment s) => s.text).toList();

class _FakeAudio implements LyricVisualizerAudio {
  _FakeAudio({this.envelopeReady = true});

  final List<int> asked = <int>[];

  @override
  final bool envelopeReady;

  @override
  bool get beatsReady => true;

  @override
  LyricVisualizerAudioFrame frameAt(int audioMs) {
    asked.add(audioMs);
    return LyricVisualizerAudioFrame(
      power: 0.5,
      low: 0.4,
      mid: 0.3,
      high: 0.2,
      vocal: 0.1,
      onset: 0,
      beatImpact: 1,
      downbeatImpact: 0,
      drumImpact: 0,
      bpm: 120,
      envelopeReady: true,
      beatsReady: true,
    );
  }

  @override
  List<int> get beatTimesMs => const <int>[1000, 1500, 2000];

  @override
  List<int> get downbeatTimesMs => const <int>[1000];

  @override
  double? get bpm => 120;

  @override
  List<LyricVisualizerBeat> get beats => <LyricVisualizerBeat>[
    for (final int t in beatTimesMs)
      LyricVisualizerBeat(timeMs: t, downbeat: downbeatTimesMs.contains(t)),
  ];

  @override
  bool get hasBeatAccents => false;

  @override
  double get trackScale => 1;

  @override
  List<LyricVisualizerDrumHit> get drumHits => const <LyricVisualizerDrumHit>[];

  @override
  bool get drumsReady => false;

  @override
  List<int> get vocalOnsetsMs => const <int>[];

  @override
  int? get vocalCoveredUntilMs => null;
}

void main() {
  group('字幕偏好', () {
    test('双行：罗马音在前译文在后；重复、与原文相同、不可读的不要', () {
      const LyricVisualizerSubtitleSettings both =
          LyricVisualizerSubtitleSettings(
            content: LyricVisualizerSubtitleContent.both,
          );
      expect(
        both.rowsFor(
          lineText: '夜空',
          translation: '夜空中的光',
          romanization: 'yozora',
        ),
        <LyricVisualizerSubtitleRow>[
          (kind: LyricVisualizerSubtitleRowKind.romanization, text: 'yozora'),
          (kind: LyricVisualizerSubtitleRowKind.translation, text: '夜空中的光'),
        ],
      );
      expect(
        both.rowsFor(lineText: 'a', translation: ' x ', romanization: 'x'),
        <LyricVisualizerSubtitleRow>[
          (kind: LyricVisualizerSubtitleRowKind.romanization, text: 'x'),
        ],
      );
      expect(
        both.rowsFor(lineText: 'same', translation: 'same', romanization: '//'),
        isEmpty,
      );
      expect(
        const LyricVisualizerSubtitleSettings(
          content: LyricVisualizerSubtitleContent.romanization,
        ).rowsFor(lineText: 'a', translation: 't', romanization: 'r'),
        <LyricVisualizerSubtitleRow>[
          (kind: LyricVisualizerSubtitleRowKind.romanization, text: 'r'),
        ],
      );
      expect(
        const LyricVisualizerSubtitleSettings(
          hideTranslation: true,
        ).rowsFor(lineText: 'a', translation: 't', romanization: 'r'),
        isEmpty,
      );
      expect(
        LyricVisualizerSubtitleContent.fromPref('bogus'),
        LyricVisualizerSubtitleContent.translation,
      );
      expect(
        const LyricVisualizerSubtitleSettings(fontScale: 9).effectiveFontScale,
        LyricVisualizerSubtitleSettings.maxFontScale,
      );
    });

    test('字体：跟随歌词套主题字体，单独选只换字族', () {
      const TextStyle base = TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w500,
      );
      const LyricVisualizerTheme theme = LyricVisualizerTheme(
        fontFamily: 'serif',
        fontWeight: FontWeight.w800,
      );
      expect(
        LyricVisualizerSubtitleSettings.defaults.applyFont(base, theme),
        base.copyWith(fontFamily: 'serif', fontWeight: FontWeight.w800),
      );
      expect(
        const LyricVisualizerSubtitleSettings(
          font: LyricVisualizerSubtitleFont.mono,
        ).applyFont(base, theme),
        base.copyWith(fontFamily: 'monospace'),
      );
      expect(
        const LyricVisualizerSubtitleSettings(
          font: LyricVisualizerSubtitleFont.sans,
        ).applyFont(base, theme),
        base,
      );
    });
  });

  group('主题图标', () {
    test('认 id 与 Lucide 名、去重保序、封顶', () {
      expect(
        LyricVisualizerThemeIcon.fromName('CloudRain'),
        LyricVisualizerThemeIcon.cloud,
      );
      expect(
        LyricVisualizerThemeIcon.fromName('party-popper'),
        LyricVisualizerThemeIcon.party,
      );
      expect(LyricVisualizerThemeIcon.fromName('nope'), isNull);
      expect(LyricVisualizerThemeIcon.fromName(3), isNull);
      expect(
        LyricVisualizerThemeIcon.listFrom(<Object?>[
          'moon',
          'Moon',
          'star',
          'x',
          'sun',
          'heart',
          'cloud',
          'music',
          'mic',
        ]),
        <LyricVisualizerThemeIcon>[
          LyricVisualizerThemeIcon.moon,
          LyricVisualizerThemeIcon.star,
          LyricVisualizerThemeIcon.sun,
          LyricVisualizerThemeIcon.heart,
          LyricVisualizerThemeIcon.cloud,
          LyricVisualizerThemeIcon.music,
        ],
      );
      // wire 唯一（落盘冻结）。
      expect(
        LyricVisualizerThemeIcon.values
            .map((LyricVisualizerThemeIcon i) => i.wire)
            .toSet(),
        hasLength(LyricVisualizerThemeIcon.values.length),
      );
      const LyricVisualizerTheme theme = LyricVisualizerTheme(
        lyricsIcons: <LyricVisualizerThemeIcon>[
          LyricVisualizerThemeIcon.flower,
          LyricVisualizerThemeIcon.moon,
        ],
      );
      expect(theme.glyphIcons, <IconData>[
        LyricVisualizerThemeIcon.moon.glyph!,
      ]);
    });
  });

  group('渲染提示（folia renderHints）', () {
    test('按时长分三档', () {
      expect(
        LyricVisualizerRenderHints.of(startMs: 0, endMs: 50).timingClass,
        LyricVisualizerTimingClass.micro,
      );
      expect(
        LyricVisualizerRenderHints.of(startMs: 0, endMs: 150).timingClass,
        LyricVisualizerTimingClass.short,
      );
      final LyricVisualizerRenderHints n = LyricVisualizerRenderHints.of(
        startMs: 0,
        endMs: 2000,
      );
      expect(n.timingClass, LyricVisualizerTimingClass.normal);
      expect(n.lineTransition, LyricVisualizerLineTransition.normal);
      expect(n.wordReveal, LyricVisualizerWordReveal.normal);
      // micro：离场下限 67ms。
      expect(
        LyricVisualizerRenderHints.of(startMs: 0, endMs: 10).renderEndMs,
        67,
      );
    });

    test('行分级与离场窗口（folia renderHints 逐值）', () {
      // normal：passStart = 3060，exit = min(320, max(180, 2*180)) = 320。
      final LyricVisualizerRenderHints normal = LyricVisualizerRenderHints.of(
        startMs: 1000,
        endMs: 3000,
        lastWordEndMs: 3000,
      );
      expect(normal.lineTransition, LyricVisualizerLineTransition.normal);
      expect(normal.wordReveal, LyricVisualizerWordReveal.normal);
      expect(normal.wordLookaheadMs, 150);
      expect(normal.renderEndMs, 3380);
      final LyricVisualizerRenderHints fast = LyricVisualizerRenderHints.of(
        startMs: 1000,
        endMs: 1150,
        lastWordEndMs: 1150,
      );
      expect(fast.lineTransition, LyricVisualizerLineTransition.fast);
      expect(fast.wordReveal, LyricVisualizerWordReveal.fast);
      expect(fast.wordLookaheadMs, 80);
      final LyricVisualizerRenderHints micro = LyricVisualizerRenderHints.of(
        startMs: 1000,
        endMs: 1020,
        lastWordEndMs: 1020,
      );
      expect(micro.lineTransition, LyricVisualizerLineTransition.none);
      expect(micro.wordReveal, LyricVisualizerWordReveal.instant);
      expect(micro.renderEndMs, 1067);
      // 瞬显：词一直亮到行的离场窗口结束。
      expect(micro.wordActiveEndMs(1000, 1010), micro.renderEndMs);
    });

    test('displayedLineAt 含句尾离场窗口', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        LyricTimeline(
          format: 'lrc',
          lines: <LyricLine>[
            _line(1000, 2000, 'one'),
            _line(5000, 6000, 'two'),
          ],
        ),
      );
      final int end = rt.lines[0].renderEndMs;
      expect(end, greaterThan(2000));
      expect(rt.activeLineAt(2010), -1);
      expect(rt.displayedLineAt(2010), 0);
      expect(rt.displayedLineAt(end + 1), -1);
      expect(rt.visualEndMsOf(0), end);
    });
  });

  group('歌曲结构', () {
    test('段落字符串映射', () {
      expect(
        lyricVisualizerSongPartOf('Chorus'),
        LyricVisualizerSongPart.chorus,
      );
      expect(
        lyricVisualizerSongPartOf('PreChorus'),
        LyricVisualizerSongPart.preChorus,
      );
      expect(lyricVisualizerSongPartOf('Hook'), LyricVisualizerSongPart.chorus);
      expect(lyricVisualizerSongPartOf('verse'), LyricVisualizerSongPart.verse);
      expect(
        lyricVisualizerSongPartOf('Bridge'),
        LyricVisualizerSongPart.bridge,
      );
      expect(lyricVisualizerSongPartOf(null), LyricVisualizerSongPart.unknown);
    });

    test('folia 副歌启发式：重复最多的行', () {
      expect(
        lyricVisualizerDetectChorusTexts(<String>[
          'a b',
          'x y',
          'a b',
          'x y',
          'a b',
        ]),
        <String>{'a b'},
      );
      expect(
        lyricVisualizerDetectChorusTexts(<String>['a', 'a', 'bc']),
        isEmpty,
      );
      expect(lyricVisualizerDetectChorusTexts(<String>['ab', 'cd']), isEmpty);
    });

    test('来源标注：副歌与段编号随标注', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        LyricTimeline(
          format: 'ttml',
          lines: <LyricLine>[
            _line(1000, 2000, 'v1', part: 'Verse'),
            _line(2000, 3000, 'v2', part: 'Verse'),
            _line(3000, 4000, 'c1', part: 'Chorus'),
            _line(4000, 5000, 'c2', part: 'Chorus'),
            _line(5000, 6000, 'b1', part: 'Bridge'),
          ],
        ),
      );
      expect(rt.hasSourceSongParts, isTrue);
      expect(
        rt.lines.map((LyricVisualizerLine l) => l.isChorus).toList(),
        <bool>[false, false, true, true, false],
      );
      expect(
        rt.lines.map((LyricVisualizerLine l) => l.blockIndex).toList(),
        <int>[0, 0, 1, 1, 2],
      );
      expect(rt.lines[4].songPart, LyricVisualizerSongPart.bridge);
      expect(rt.lines[2].songPartLabel, 'Chorus');
      expect(rt.lines[2].chorusEffect, isNotNull);
      expect(rt.isChorusAt(3500), isTrue);
      expect(rt.blockRange(1), (2, 3));
    });

    test('无标注：文本启发式 + 时间空隙切段', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        LyricTimeline(
          format: 'lrc',
          lines: <LyricLine>[
            _line(1000, 2000, 'hello there'),
            _line(2100, 3000, 'la la la'),
            _line(12000, 13000, 'la la la'),
            _line(13100, 14000, 'again'),
          ],
        ),
      );
      expect(rt.hasSourceSongParts, isFalse);
      expect(
        rt.lines.map((LyricVisualizerLine l) => l.isChorus).toList(),
        <bool>[false, true, true, false],
      );
      expect(rt.lines[1].songPart, LyricVisualizerSongPart.chorus);
      expect(rt.lines[0].songPart, LyricVisualizerSongPart.unknown);
      expect(
        rt.lines.map((LyricVisualizerLine l) => l.blockIndex).toList(),
        <int>[0, 0, 1, 1],
      );
    });
  });

  group('词级分组', () {
    test('日文：汉字 + 送假名、助词单列', () {
      expect(_segTexts('夜空に光'), <String>['夜空', 'に', '光']);
      expect(_segTexts('君のことが好き'), <String>['君', 'の', 'こと', 'が', '好き']);
      expect(_segTexts('思いを届けて'), <String>['思い', 'を', '届けて']);
      expect(_segTexts('カタカナです'), <String>['カタカナ', 'です']);
      expect(_segTexts('「光」を'), <String>['「光」', 'を']);
    });

    test('中文逐字、拉丁按词、标点粘连', () {
      expect(_segTexts('夜空中的光'), <String>['夜', '空', '中', '的', '光']);
      expect(_segTexts("Hello, don't stop!"), <String>[
        'Hello,',
        "don't",
        'stop!',
      ]);
      expect(_segTexts('사랑해 너를'), <String>['사랑해', '너를']);
      final List<LyricVisualizerSegment> segs = buildLyricVisualizerSegments(
        buildLyricVisualizerGlyphs(_line(0, 1000, 'a b')),
      );
      expect(segs[1].spaceBefore, isTrue);
      expect(segs[0].spaceBefore, isFalse);
    });

    test('时间取有声字形', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      final LyricVisualizerLine first = rt.lines.first;
      expect(
        first.segments.map((LyricVisualizerSegment s) => s.text).toList(),
        <String>['夜空', 'に', '光'],
      );
      expect(first.segments[0].startMs, 1000);
      expect(first.segments[0].endMs, 1600);
      expect(first.segments[2].endMs, 3200);
      // 旧的逐字 words 不变。
      expect(first.words.length, 4);
    });
  });

  group('主题', () {
    const LyricVisualizerTheme theme = LyricVisualizerTheme(
      wordColors: <String, Color>{
        '光': Color(0xFFFF0000),
        'bright world': Color(0xFF00FF00),
        '夜空': Color(0xFF0000FF),
      },
      intensity: LyricVisualizerIntensity.chaotic,
    );

    test('resolveWordColor（folia 规则）', () {
      const Color fb = Color(0xFF111111);
      expect(theme.resolveWordColor('光', fb), const Color(0xFFFF0000));
      expect(theme.resolveWordColor('空', fb), const Color(0xFF0000FF));
      expect(theme.resolveWordColor('World!', fb), const Color(0xFF00FF00));
      expect(theme.resolveWordColor('hello', fb), fb);
      expect(
        theme.resolveWordColor(
          '空',
          fb,
          cjkMatch: LyricVisualizerCjkMatch.exact,
        ),
        fb,
      );
    });

    test('colorRangesFor：长关键字优先、不重叠', () {
      final List<LyricVisualizerWordColorRange> r = theme.colorRangesFor(
        '夜空に光 bright world',
      );
      expect(
        r.map((LyricVisualizerWordColorRange e) => (e.start, e.end)).toList(),
        <(int, int)>[(0, 2), (3, 4), (5, 11), (12, 17)],
      );
      expect(
        LyricVisualizerTheme.colorForSpan(r, 3, 4),
        const Color(0xFFFF0000),
      );
      expect(LyricVisualizerTheme.colorForSpan(r, 2, 3), isNull);
    });

    test('配色覆盖', () {
      final LyricVisualizerPalette base = LyricVisualizerPalette.fromScheme(
        ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      expect(base.applyOverride(null), same(base));
      final LyricVisualizerPalette p = base.applyOverride(
        const LyricVisualizerPaletteOverride(
          background: Color(0xFF000000),
          text: Color(0xFFFFFFFF),
        ),
      );
      expect(p.background, const Color(0xFF000000));
      expect(p.brightness, Brightness.dark);
      expect(p.dimText.a, closeTo(0.45, 0.01));
      expect(p.primary, base.primary);
    });

    test('强度落库值', () {
      expect(
        LyricVisualizerIntensity.fromPref('calm'),
        LyricVisualizerIntensity.calm,
      );
      expect(
        LyricVisualizerIntensity.fromPref('x'),
        LyricVisualizerIntensity.normal,
      );
      expect(LyricVisualizerIntensity.chaotic.pick(1, 2, 3), 3);
    });
  });

  group('音频契约', () {
    LyricVisualizerContext ctx({LyricVisualizerAudio? audio, int offset = 0}) {
      final LyricTimeline t = sampleWordTimeline();
      return LyricVisualizerContext(
        timeline: t,
        runtime: LyricVisualizerRuntime(t),
        clock: FakeVisualizerClock(),
        offsetMs: offset,
        playing: true,
        palette: LyricVisualizerPalette.fromScheme(
          ColorScheme.fromSeed(seedColor: Colors.blue),
        ),
        tuning: LyricVisualizerTuning.defaults(
          const <LyricVisualizerTuningSpec>[],
        ),
        seed: 1,
        motion: true,
        audio: audio,
      );
    }

    test('没有音频：歌词包络回落', () {
      final LyricVisualizerContext c = ctx();
      final LyricVisualizerAudioFrame f = c.audioFrameAt(1010);
      expect(f.fallback, isTrue);
      expect(f.power, closeTo(c.runtime.pulseAt(1010), 1e-9));
      expect(f.vocal, greaterThan(0));
      expect(c.audioFrameAt(9000), LyricVisualizerAudioFrame.silent);
    });

    test('有音频：按音频时间取帧（减偏移）', () {
      final _FakeAudio a = _FakeAudio();
      final LyricVisualizerContext c = ctx(audio: a, offset: 300);
      final LyricVisualizerAudioFrame f = c.audioFrameAt(1300);
      expect(f.fallback, isFalse);
      expect(a.asked.single, 1000);
      expect(c.audioTimeOf(1300), 1000);
      expect(c.displayTimeOfAudio(1000), 1300);
    });

    test('只有拍点：冲击量来自真拍点', () {
      final LyricVisualizerContext c = ctx(
        audio: _FakeAudio(envelopeReady: false),
      );
      final LyricVisualizerAudioFrame f = c.audioFrameAt(1500);
      expect(f.fallback, isTrue);
      expect(f.beatsReady, isTrue);
      expect(f.beatImpact, closeTo(1, 1e-9));
      expect(f.bpm, 120);
    });

    test('拍点工具', () {
      const List<int> beats = <int>[1000, 1500, 2000];
      expect(lyricVisualizerLastAtOrBefore(beats, 999), -1);
      expect(lyricVisualizerLastAtOrBefore(beats, 1500), 1);
      expect(lyricVisualizerBeatPhaseAt(beats, 1250), closeTo(0.5, 1e-9));
      expect(lyricVisualizerBeatPhaseAt(beats, 2100), isNull);
      expect(lyricVisualizerImpactAt(beats, 900), 0);
    });

    test('context copyWith / ==', () {
      final LyricVisualizerContext a = ctx();
      expect(a.copyWith(), a);
      expect(a.copyWith().hashCode, a.hashCode);
      final LyricVisualizerContext b = a.copyWith(
        intensity: LyricVisualizerIntensity.calm,
      );
      expect(b == a, isFalse);
      expect(b.intensity, LyricVisualizerIntensity.calm);
      final LyricVisualizerContext withTheme = a.copyWith(
        theme: const LyricVisualizerTheme(fontWeight: FontWeight.w700),
      );
      expect(withTheme.copyWith(clearTheme: true).theme, isNull);
      expect(
        withTheme.applyThemeFont(const TextStyle()).fontWeight,
        FontWeight.w700,
      );
    });
  });
}
