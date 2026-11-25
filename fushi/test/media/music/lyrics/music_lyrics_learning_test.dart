import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_learning.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_live.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
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

/// 记录里的 List 按身份比较：逐侧比内容。
void expectContext(
  ({List<int> prev, List<int> next}) actual,
  List<int> prev,
  List<int> next, {
  String? reason,
}) {
  expect(actual.prev, prev, reason: reason);
  expect(actual.next, next, reason: reason);
}

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

    test('同时显示句数：当前行居中，跳过伴唱 / 空行，两端有多少给多少', () {
      final LyricTimeline t = _timeline();
      // 主行是 0、1、3（2 是伴唱 / 空行，不占名额）。
      expect(musicLyricPreviousMainLine(t, 3), 1);
      expect(musicLyricPreviousMainLine(t, 0), -1);
      final MusicDesktopLyricsBlock mid = musicDesktopLyricsBlock(
        t,
        1,
        before: 1,
        after: 1,
      );
      expect(mid.text, '夜に駆ける\n沈むように\n溶けて');
      expect(mid.currentStart, '夜に駆ける\n'.length);
      expect(mid.currentLength, '沈むように'.length);
      // 自动档的大半径：开头 / 结尾不够就只给现有的。
      final MusicDesktopLyricsBlock last = musicDesktopLyricsBlock(
        t,
        3,
        before: 12,
        after: 12,
      );
      expect(last.text, '夜に駆ける\n沈むように\n溶けて');
      expect(last.currentStart, '夜に駆ける\n沈むように\n'.length);
      // 前奏：以第一行为锚，没有当前行标记。
      final MusicDesktopLyricsBlock intro = musicDesktopLyricsBlock(
        t,
        -1,
        before: 1,
        after: 1,
      );
      expect(intro.text, '夜に駆ける\n沈むように');
      expect(intro.currentStart, -1);
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
  // 反馈 l8XrV_IfXH：音乐高级制卡选前后文行 + 起止微调。
  group('高级制卡：前后文行与句子音频微调', () {
    test('上 N / 下 N 主行：跳过伴唱、两端封顶、按播放顺序', () {
      final LyricTimeline t = _timeline();
      // 主行是 0、1、3（2 是伴唱）。
      expectContext(
        musicLyricContextLines(t, 1, prevCount: 1, nextCount: 1),
        <int>[0],
        <int>[3],
      );
      expectContext(
        musicLyricContextLines(t, 3, prevCount: 5, nextCount: 5),
        <int>[0, 1],
        <int>[],
        reason: '到两端不再增长（对话框据此禁用「加一句」）',
      );
      expectContext(
        musicLyricContextLines(t, 0, prevCount: 0, nextCount: 0),
        <int>[],
        <int>[],
      );
    });

    test('锚越界 / 无时间歌词：两侧都为空', () {
      final LyricTimeline t = _timeline();
      expectContext(
        musicLyricContextLines(t, 9, prevCount: 1, nextCount: 1),
        <int>[],
        <int>[],
      );
      final LyricTimeline unsynced = LyricTimeline(
        format: 'txt',
        timingQuality: LyricTimingQuality.unsynced,
        lines: t.lines,
      );
      expectContext(
        musicLyricContextLines(unsynced, 1, prevCount: 1, nextCount: 1),
        <int>[],
        <int>[],
      );
    });

    test('合并窗口：换句子与起止，保留查词行号与翻译', () {
      final MusicLyricLineWindow w = musicLyricLineWindow(_timeline(), 0)!;
      final MusicLyricLineWindow merged = w.withContext(
        text: '夜に駆ける\n沈むように',
        startMs: 1000,
        endMs: 6000,
      );
      expect(merged.lineIndex, 0);
      expect(merged.text, '夜に駆ける\n沈むように');
      expect((merged.startMs, merged.endMs), (1000, 6000));
      expect(merged.translation, '在夜里奔跑');
      final MusicLyricLineWindow textOnly = w.withContext(text: 'x');
      expect((textOnly.startMs, textOnly.endMs), (w.startMs, w.endMs));
    });

    test('起止微调加在扩过留白的最终区间上，可越过行界，仍夹在 [0, 曲长]', () {
      final MusicLyricLineWindow w = musicLyricLineWindow(_timeline(), 1)!;
      // 行 [4 s, 6 s) → 留白后 [3.5 s, 6.5 s)。
      expect(w.clipInFile(startDeltaMs: -250, endDeltaMs: 1000), (
        startMs: 3250,
        endMs: 7500,
      ));
      expect(
        w.clipInFile(
          startDeltaMs: -10000,
          trackDurationMs: 7000,
          endDeltaMs: 5000,
        ),
        (startMs: 0, endMs: 7000),
      );
      expect(
        w.clipInFile(fileOffsetMs: 60000, startDeltaMs: 100, endDeltaMs: -100),
        (startMs: 63600, endMs: 66400),
        reason: '微调在曲目时间上做，再加 CUE 段首',
      );
      expect(
        w.clipInFile(startDeltaMs: 4000, endDeltaMs: -4000).endMs,
        w.clipInFile(startDeltaMs: 4000, endDeltaMs: -4000).startMs,
        reason: '终点不早于起点',
      );
    });
  });
}
