import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';

void main() {
  group('parseChapterList (TODO-424)', () {
    test('parses count + per-index title/time into升序 VideoChapter list', () {
      // 模拟 mkv 5 章 Chapter 01..05，time 为秒（浮点字符串）。
      const Map<int, String> titles = <int, String>{
        0: 'Chapter 01',
        1: 'Chapter 02',
        2: 'Chapter 03',
        3: 'Chapter 04',
        4: 'Chapter 05',
      };
      const Map<int, String> times = <int, String>{
        0: '0.000',
        1: '300.500',
        2: '600',
        3: '900.250',
        4: '1200.0',
      };
      final List<VideoChapter> chapters = parseChapterList(
        count: '5',
        titleAt: (int i) => titles[i]!,
        timeAt: (int i) => times[i]!,
      );
      expect(chapters.length, 5);
      expect(
          chapters[0],
          const VideoChapter(
              index: 0, title: 'Chapter 01', start: Duration.zero));
      expect(chapters[1].title, 'Chapter 02');
      expect(chapters[1].start, const Duration(milliseconds: 300500));
      expect(chapters[2].start, const Duration(seconds: 600));
      expect(chapters[3].start, const Duration(milliseconds: 900250));
      expect(chapters[4].start, const Duration(seconds: 1200));
    });

    test('empty / zero / non-numeric count => empty list (无章节)', () {
      String t(int i) => '';
      String s(int i) => '0';
      expect(parseChapterList(count: '', titleAt: t, timeAt: s), isEmpty);
      expect(parseChapterList(count: '0', titleAt: t, timeAt: s), isEmpty);
      expect(parseChapterList(count: 'NaN', titleAt: t, timeAt: s), isEmpty);
      expect(parseChapterList(count: '-3', titleAt: t, timeAt: s), isEmpty);
    });

    test('blank title kept as empty string; negative/invalid time clamps to 0',
        () {
      final List<VideoChapter> chapters = parseChapterList(
        count: '2',
        titleAt: (int i) => i == 0 ? '' : 'Named',
        timeAt: (int i) => i == 0 ? '-5' : 'oops',
      );
      expect(chapters[0].title, '');
      expect(chapters[0].start, Duration.zero); // -5s clamp 到 0
      expect(chapters[1].title, 'Named');
      expect(chapters[1].start, Duration.zero); // 非法 time => 0
    });
  });

  group('adjacentChapterIndex (TODO-424)', () {
    test('forward: next chapter, null at last chapter', () {
      expect(
        adjacentChapterIndex(chapterCount: 5, currentIndex: 0, forward: true),
        1,
      );
      expect(
        adjacentChapterIndex(chapterCount: 5, currentIndex: 3, forward: true),
        4,
      );
      // 已在末章：no next。
      expect(
        adjacentChapterIndex(chapterCount: 5, currentIndex: 4, forward: true),
        isNull,
      );
    });

    test('forward: currentIndex < 0 (首章之前) => 落首章 0', () {
      expect(
        adjacentChapterIndex(chapterCount: 5, currentIndex: -1, forward: true),
        0,
      );
    });

    test('backward: previous chapter, null at first chapter / 首章之前', () {
      expect(
        adjacentChapterIndex(chapterCount: 5, currentIndex: 3, forward: false),
        2,
      );
      expect(
        adjacentChapterIndex(chapterCount: 5, currentIndex: 1, forward: false),
        0,
      );
      // 已在首章：no prev。
      expect(
        adjacentChapterIndex(chapterCount: 5, currentIndex: 0, forward: false),
        isNull,
      );
      // 首章之前（-1）：后退仍 no-op。
      expect(
        adjacentChapterIndex(chapterCount: 5, currentIndex: -1, forward: false),
        isNull,
      );
    });

    test('no chapters => null both directions', () {
      expect(
        adjacentChapterIndex(chapterCount: 0, currentIndex: 0, forward: true),
        isNull,
      );
      expect(
        adjacentChapterIndex(chapterCount: 0, currentIndex: 0, forward: false),
        isNull,
      );
    });
  });

  group('chapterIndexForPositionIn (TODO-424)', () {
    final List<VideoChapter> chapters = <VideoChapter>[
      const VideoChapter(index: 0, title: 'A', start: Duration.zero),
      const VideoChapter(index: 1, title: 'B', start: Duration(seconds: 300)),
      const VideoChapter(index: 2, title: 'C', start: Duration(seconds: 600)),
    ];

    test('returns last chapter whose start <= position', () {
      expect(chapterIndexForPositionIn(chapters, 0), 0);
      expect(chapterIndexForPositionIn(chapters, 100), 0);
      expect(chapterIndexForPositionIn(chapters, 300000), 1);
      expect(chapterIndexForPositionIn(chapters, 450000), 1);
      expect(chapterIndexForPositionIn(chapters, 600000), 2);
      expect(chapterIndexForPositionIn(chapters, 999000), 2);
    });

    test('empty list => -1; position before first start (>0 first) => -1', () {
      expect(chapterIndexForPositionIn(const <VideoChapter>[], 1000), -1);
      final List<VideoChapter> later = <VideoChapter>[
        const VideoChapter(index: 0, title: 'X', start: Duration(seconds: 10)),
      ];
      expect(chapterIndexForPositionIn(later, 5000), -1);
      expect(chapterIndexForPositionIn(later, 10000), 0);
    });
  });

  group('VideoPlayerController chapter API without libmpv (TODO-424)', () {
    test('chapters getter empty by default; debug inject + position highlight',
        () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      expect(c.chapters, isEmpty);
      expect(c.chapterIndexForPosition(123), -1);

      c.debugSetChaptersForTesting(<VideoChapter>[
        const VideoChapter(index: 0, title: 'Chapter 01', start: Duration.zero),
        const VideoChapter(
            index: 1, title: 'Chapter 02', start: Duration(seconds: 300)),
      ]);
      expect(c.chapters.length, 2);
      expect(c.chapterIndexForPosition(0), 0);
      expect(c.chapterIndexForPosition(300000), 1);
      expect(c.chapterIndexForPosition(450000), 1);
    });

    test('seekToChapter / next / previous are no-op-safe without a Player',
        () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugSetChaptersForTesting(<VideoChapter>[
        const VideoChapter(index: 0, title: 'A', start: Duration.zero),
        const VideoChapter(index: 1, title: 'B', start: Duration(seconds: 300)),
      ]);
      // 无 Player：这些只是不抛（seekMs / getProperty 都 no-op 安全）。
      await c.seekToChapter(0);
      await c.seekToChapter(5); // 越界 no-op
      await c.seekToChapter(-1); // 负 no-op
      await c.nextChapter();
      await c.previousChapter();
    });
  });
}
