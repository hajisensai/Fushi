import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_coverage.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_learning.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_live.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiTermToken;
import 'package:fushi_music/fushi_music.dart';

LyricLine _line(
  int start,
  int end,
  List<(String, int, int)> syl, {
  LyricRole role = LyricRole.main,
  String? zh,
}) => LyricLine(
  startMs: start,
  endMs: end,
  role: role,
  syllables: <LyricSyllable>[
    for (final (String t, int s, int e) in syl)
      LyricSyllable(text: t, startMs: s, endMs: e),
  ],
  translations: zh == null
      ? const <LyricTranslation>[]
      : <LyricTranslation>[LyricTranslation('zh', zh)],
);

/// 三行：第二行带和声；最后一行没有结束时刻（LRC 末行）。
LyricTimeline _timeline({int offsetMs = 0}) => LyricTimeline(
  format: 'ttml',
  timingQuality: LyricTimingQuality.syllable,
  offsetMs: offsetMs,
  lines: <LyricLine>[
    _line(1000, 3000, <(String, int, int)>[
      ('夜に', 1000, 2000),
      ('駆ける', 2000, 3000),
    ], zh: '在夜里奔跑'),
    _line(4000, 6000, <(String, int, int)>[
      ('沈む', 4000, 5000),
      ('ように', 5000, 6000),
    ]),
    _line(4500, 5500, <(String, int, int)>[
      ('ah', 4500, 5500),
    ], role: LyricRole.background),
    _line(8000, 8000, <(String, int, int)>[(' 溶けて ', 8000, 8000)]),
  ],
);

void main() {
  group('行时间窗（歌词时间 → 曲目时间）', () {
    test('减回整首偏移、带翻译；起点夹 0', () {
      final MusicLyricLineWindow w = musicLyricLineWindow(
        _timeline(offsetMs: 300),
        0,
      )!;
      expect(w.startMs, 700);
      expect(w.endMs, 2700);
      expect(w.text, '夜に駆ける');
      expect(w.translation, '在夜里奔跑');
      expect(
        musicLyricLineWindow(_timeline(offsetMs: 5000), 0)!.startMs,
        0,
        reason: '偏移超过行起点时夹 0',
      );
    });

    test('没有结束时刻：退到曲长；越界 / 无时间为 null', () {
      final LyricTimeline t = _timeline();
      expect(musicLyricLineWindow(t, 3, trackDurationMs: 12000)!.endMs, 12000);
      expect(musicLyricLineWindow(t, 3)!.durationMs, 0);
      expect(musicLyricLineWindow(t, 9), isNull);
      final LyricTimeline unsynced = LyricTimeline(
        format: 'txt',
        timingQuality: LyricTimingQuality.unsynced,
        lines: t.lines,
      );
      expect(musicLyricLineWindow(unsynced, 0), isNull);
    });

    test('音频片段：前后各扩 0.5 s、夹 0 与曲长，再加 CUE 段首', () {
      final MusicLyricLineWindow w = musicLyricLineWindow(_timeline(), 0)!;
      expect(w.clipInFile(), (startMs: 500, endMs: 3500));
      expect(w.clipInFile(fileOffsetMs: 60000, trackDurationMs: 3200), (
        startMs: 60500,
        endMs: 63200,
      ));
      final MusicLyricLineWindow first = MusicLyricLineWindow(
        lineIndex: 0,
        text: 'x',
        startMs: 200,
        endMs: 900,
      );
      expect(first.clipInFile().startMs, 0);
    });
  });

  group('当前行与 AB 循环', () {
    test('当前主行（和声并入主行组）；前奏为 -1', () {
      final LyricTimeline t = _timeline();
      expect(musicLyricCurrentLine(t, 500), -1);
      expect(musicLyricCurrentLine(t, 1500), 0);
      expect(musicLyricCurrentLine(t, 4800), 1);
      expect(musicLyricCurrentLine(t, 7000), 1, reason: '间奏保持上一行');
      expect(
        musicLyricCurrentLine(_timeline(offsetMs: 600), 3500),
        1,
        reason: '正偏移 = 歌词提前',
      );
    });

    test('循环一行 / 多行（行号顺序无关）；下一主行跳过和声', () {
      final LyricTimeline t = _timeline();
      expect(
        musicAbLoopForLines(t, 1, 1),
        const MusicAbLoop(
          Duration(milliseconds: 4000),
          Duration(milliseconds: 6000),
        ),
      );
      expect(
        musicAbLoopForLines(t, 1, 0),
        const MusicAbLoop(
          Duration(milliseconds: 1000),
          Duration(milliseconds: 6000),
        ),
      );
      expect(musicLyricNextMainLine(t, 1), 3);
      expect(musicLyricNextMainLine(t, 3), -1);
      expect(musicAbLoopForLines(t, 3, 3), isNull, reason: '零长区间不开循环');
    });
  });

  group('桌面歌词块', () {
    test('当前行 + 下一行；前奏显示第一行但没有当前行标记', () {
      final LyricTimeline t = _timeline();
      expect(
        musicDesktopLyricsBlock(t, 0),
        const MusicDesktopLyricsBlock(
          text: '夜に駆ける\n沈むように',
          currentStart: 0,
          currentLength: 5,
        ),
      );
      expect(musicDesktopLyricsBlock(t, -1).currentStart, -1);
      expect(musicDesktopLyricsBlock(t, -1).text, '夜に駆ける\n沈むように');
      expect(musicDesktopLyricsBlock(t, 3).text, '溶けて');
    });

    test('已唱长度按音节、对齐 trim；下一个音节边界', () {
      final LyricLine l = _timeline().lines[0];
      expect(musicDesktopSungLength(l, 900), 0);
      expect(musicDesktopSungLength(l, 1000), 2);
      expect(musicDesktopSungLength(l, 2500), 5);
      expect(musicNextSyllableBoundary(l, 1200), 2000);
      expect(musicNextSyllableBoundary(l, 2000), isNull);
      final LyricLine padded = _timeline().lines[3];
      expect(musicDesktopSungLength(padded, 8000), 3, reason: '行首空白不算');
    });
  });

  group('生词覆盖率', () {
    Future<List<List<FushiTermToken>>?> tokenize(List<String> texts) async =>
        <List<FushiTermToken>>[
          for (final String s in texts)
            switch (s) {
              '夜に駆ける' => <FushiTermToken>[
                (length: 1, reading: 'よる', expression: '夜'),
                (length: 1, reading: '', expression: 'に'),
                (length: 3, reading: 'かける', expression: '駆ける'),
              ],
              '沈むように' => <FushiTermToken>[
                (length: 2, reading: 'しずむ', expression: '沈む'),
                (length: 3, reading: '', expression: ''),
              ],
              _ => <FushiTermToken>[
                (length: s.length, reading: '', expression: ''),
              ],
            },
        ];

    test('按出现次数、词头归一；和声行不算；未命中段不算', () async {
      final MusicLyricsCoverage c = (await computeMusicLyricsCoverage(
        _timeline(),
        tokenize: tokenize,
        knownTerms: (List<({String expression, String reading})> terms) async {
          expect(terms.map((t) => t.expression), <String>[
            '夜',
            'に',
            '駆ける',
            '沈む',
          ]);
          return <String>{'に', '沈む'};
        },
      ))!;
      expect(c.totalTokens, 4);
      expect(c.knownTokens, 2);
      expect(c.percent, 50);
      expect(c.unknownTerms, <String>['夜', '駆ける']);
    });

    test('没词典 / 复习模块关着 / 一个词都没命中：不显示（null），不硬造 0%', () async {
      Future<Set<String>?> none(
        List<({String expression, String reading})> _,
      ) async => <String>{};
      expect(
        await computeMusicLyricsCoverage(
          _timeline(),
          tokenize: (_) async => null,
          knownTerms: none,
        ),
        isNull,
      );
      expect(
        await computeMusicLyricsCoverage(
          _timeline(),
          tokenize: tokenize,
          knownTerms: (_) async => null,
        ),
        isNull,
      );
      expect(
        await computeMusicLyricsCoverage(
          _timeline(),
          tokenize: (List<String> texts) async => <List<FushiTermToken>>[
            for (final String s in texts)
              <FushiTermToken>[(length: s.length, reading: '', expression: '')],
          ],
          knownTerms: none,
        ),
        isNull,
      );
    });

    test('标点段即使词典命中也不算词', () {
      expect(musicTermIsWordLike('、'), isFalse);
      expect(musicTermIsWordLike('！？'), isFalse);
      expect(musicTermIsWordLike(' '), isFalse);
      expect(musicTermIsWordLike('ok'), isTrue);
      expect(musicTermIsWordLike('夜'), isTrue);
      expect(musicTermIsWordLike('ありがとう'), isTrue);
    });
  });
}
