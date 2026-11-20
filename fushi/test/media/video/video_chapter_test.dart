import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';

void main() {
  group('parseChapterListJson (TODO-424 / c32 video-36a)', () {
    test('整份 JSON → 升序 VideoChapter 列表（秒 → 毫秒）', () {
      // libmpv 把 node 数组序列化成的形状（mkv 5 章）。
      const String raw =
          '[{"title":"Chapter 01","time":0.000000},'
          '{"title":"Chapter 02","time":300.500000},'
          '{"title":"Chapter 03","time":600},'
          '{"title":"Chapter 04","time":900.25},'
          '{"title":"Chapter 05","time":1200.0}]';
      final List<VideoChapter> chapters = parseChapterListJson(raw);
      expect(chapters.length, 5);
      expect(
        chapters[0],
        const VideoChapter(index: 0, title: 'Chapter 01', start: Duration.zero),
      );
      expect(chapters[1].title, 'Chapter 02');
      expect(chapters[1].start, const Duration(milliseconds: 300500));
      expect(chapters[2].start, const Duration(seconds: 600));
      expect(chapters[3].start, const Duration(milliseconds: 900250));
      expect(chapters[4].start, const Duration(seconds: 1200));
      expect(chapters[4].index, 4);
    });

    test('读不到 / 不是 JSON 数组 / 空数组 => 空列表（无章节）', () {
      expect(parseChapterListJson(''), isEmpty);
      expect(parseChapterListJson('   '), isEmpty);
      expect(parseChapterListJson('[]'), isEmpty);
      expect(parseChapterListJson('{"title":"x"}'), isEmpty);
      expect(parseChapterListJson('not json'), isEmpty);
    });

    test('缺 title 记空串；负值 / 缺失 / 非数字 time clamp 到 0', () {
      final List<VideoChapter> chapters = parseChapterListJson(
        '[{"time":-5},{"title":"Named"},{"title":"S","time":"12"}]',
      );
      expect(chapters[0].title, '');
      expect(chapters[0].start, Duration.zero);
      expect(chapters[1].title, 'Named');
      expect(chapters[1].start, Duration.zero);
      expect(chapters[2].start, Duration.zero);
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
    test(
      'chapters getter empty by default; debug inject + position highlight',
      () {
        final VideoPlayerController c = VideoPlayerController();
        addTearDown(c.dispose);
        expect(c.chapters, isEmpty);
        expect(c.chapterIndexForPosition(123), -1);

        c.debugSetChaptersForTesting(<VideoChapter>[
          const VideoChapter(
            index: 0,
            title: 'Chapter 01',
            start: Duration.zero,
          ),
          const VideoChapter(
            index: 1,
            title: 'Chapter 02',
            start: Duration(seconds: 300),
          ),
        ]);
        expect(c.chapters.length, 2);
        expect(c.chapterIndexForPosition(0), 0);
        expect(c.chapterIndexForPosition(300000), 1);
        expect(c.chapterIndexForPosition(450000), 1);
      },
    );

    test(
      'seekToChapter / next / previous are no-op-safe without a Player',
      () async {
        final VideoPlayerController c = VideoPlayerController();
        addTearDown(c.dispose);
        c.debugSetChaptersForTesting(<VideoChapter>[
          const VideoChapter(index: 0, title: 'A', start: Duration.zero),
          const VideoChapter(
            index: 1,
            title: 'B',
            start: Duration(seconds: 300),
          ),
        ]);
        // 无 Player：这些只是不抛（seekMs / getProperty 都 no-op 安全）。
        await c.seekToChapter(0);
        await c.seekToChapter(5); // 越界 no-op
        await c.seekToChapter(-1); // 负 no-op
        await c.nextChapter();
        await c.previousChapter();
      },
    );
  });

  group('chapter first-load readiness guards (TODO-521)', () {
    final String src = File(
      'lib/src/media/video/video_player_controller.dart',
    ).readAsStringSync();

    test('load waits for real duration readiness instead of fixed delay', () {
      final int loadStart = src.indexOf('Future<void> load({');
      expect(loadStart, greaterThanOrEqualTo(0));
      final int loadEnd = src.indexOf(
        'void _handleCompletedChanged',
        loadStart,
      );
      expect(loadEnd, greaterThan(loadStart));
      final String loadBody = src.substring(loadStart, loadEnd);

      expect(
        loadBody,
        contains('_refreshChaptersWhenDurationReady(player, loadToken)'),
      );
      expect(
        loadBody,
        isNot(contains('unawaited(refreshChapters())')),
        reason: 'open() 后立刻读 chapter-list 会复现首次读空竞态',
      );
      expect(
        loadBody,
        isNot(contains('Future.delayed')),
        reason: '章节就绪必须由 duration 信号驱动，不能靠固定延迟掩盖竞态',
      );
    });

    test(
      'duration subscription has initial-state path and lifecycle cancellation',
      () {
        expect(
          src,
          contains('StreamSubscription<Duration>? _durationReadySub'),
        );
        expect(src, contains('player.state.duration'));
        expect(src, contains('player.stream.duration.listen'));
        expect(
          src,
          contains('await _durationReadySub?.cancel()'),
          reason: '换片 load 前必须取消上一片 duration 订阅',
        );
        expect(
          src,
          contains('unawaited(_durationReadySub?.cancel())'),
          reason: 'dispose 必须取消 duration 订阅',
        );
      },
    );

    test(
      'chapter refresh results are guarded by player identity and load token',
      () {
        expect(src, contains('int _loadToken = 0'));
        expect(src, contains('final int loadToken = ++_loadToken'));
        expect(
          src,
          contains('bool _isCurrentLoad(Player player, int loadToken)'),
        );
        expect(src, contains('_refreshChaptersForLoad(player, loadToken)'));
        expect(
          src,
          contains('if (!_isCurrentLoad(player, loadToken)) return;'),
        );
      },
    );

    test('new loads clear stale chapters before opening the next media', () {
      expect(src, contains('_clearChaptersForNewLoad();'));
      expect(src, contains('_chapters = const <VideoChapter>[];'));
      expect(src, contains('notifyListeners();'));
    });
  });
}
