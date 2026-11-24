import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/netflix_metadata.dart'
    show WebVideoCoverFetcher;
import 'package:fushi/src/media/video/stream_book_episodes.dart';
import 'package:fushi/src/media/video/video_episode_rail.dart'
    show VideoEpisodeEntry;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/youtube_playlist.dart';

/// 拍板台 zGXhhMAglH：YouTube 播放列表 / 流媒体书合集进播放器选集面板的数据层。
void main() {
  YoutubePlaylistEntry entry(String id, String title, {int? durationMs}) =>
      YoutubePlaylistEntry(videoId: id, title: title, durationMs: durationMs);

  VideoBookRow row(
    String uid, {
    int lastPositionMs = 0,
    DateTime? completedAt,
    String? coverPath,
  }) => VideoBookRow(
    bookUid: uid,
    title: 't',
    videoPath: 'https://www.youtube.com/watch?v=x',
    delayMs: 0,
    currentEpisode: 0,
    lastPositionMs: lastPositionMs,
    completedAt: completedAt,
    coverPath: coverPath,
    importedAt: 0,
  );

  group('youtubePlaylistBookEpisodes', () {
    test('每条是一本以视频 id 定身份的流媒体书，集号取列表顺位、全列表同一栏', () {
      final List<StreamBookEpisode> eps =
          youtubePlaylistBookEpisodes(<YoutubePlaylistEntry>[
            entry('AAAAAAAAAAA', '【まいご！】第12話 #shorts'),
            entry('BBBBBBBBBBB', 'MyGO!!!!! 2024 S02 特典'),
          ]);
      expect(eps.map((StreamBookEpisode e) => e.bookUid), <String>[
        'video/stream/yt:AAAAAAAAAAA',
        'video/stream/yt:BBBBBBBBBBB',
      ]);
      expect(
        eps.first.url,
        'https://www.youtube.com/watch?v=AAAAAAAAAAA',
        reason: '规范观看页：与浏览器交接 / 落书同一身份',
      );
      expect(eps.map((StreamBookEpisode e) => e.episodeNumber), <int>[
        1,
        2,
      ], reason: '标题里的「第12話」「2024」「S02」都不是这份列表里的集号');
      expect(
        eps.map((StreamBookEpisode e) => e.sectionKey).toSet(),
        hasLength(1),
      );
      expect(
        eps.first.coverUrl,
        'https://i.ytimg.com/vi/AAAAAAAAAAA/mqdefault.jpg',
      );
    });

    test('已落书的集带进度角标与本机封面（本机封面优先于缩略图）', () {
      final List<StreamBookEpisode> eps = youtubePlaylistBookEpisodes(
        <YoutubePlaylistEntry>[
          entry('AAAAAAAAAAA', 'a', durationMs: 100000),
          entry('BBBBBBBBBBB', 'b'),
        ],
        rows: <String, VideoBookRow>{
          'video/stream/yt:AAAAAAAAAAA': row(
            'video/stream/yt:AAAAAAAAAAA',
            lastPositionMs: 25000,
            coverPath: '/covers/a.jpg',
          ),
          'video/stream/yt:BBBBBBBBBBB': row(
            'video/stream/yt:BBBBBBBBBBB',
            completedAt: DateTime(2026, 11, 24),
          ),
        },
      );
      expect(eps[0].started, isTrue);
      expect(eps[0].progress, closeTo(0.25, 1e-9));
      expect(eps[0].coverPath, '/covers/a.jpg');
      expect(eps[0].coverUrl, isNull);
      expect(eps[1].completed, isTrue);
      expect(eps[1].started, isFalse);
      expect(eps[1].coverUrl, isNotNull);
    });
  });

  test('面板卡片保留显式集号与分栏，不按标题重新解析', () {
    final List<VideoEpisodeEntry> entries = streamBookEpisodePanelEntries(
      youtubePlaylistBookEpisodes(<YoutubePlaylistEntry>[
        entry('AAAAAAAAAAA', 'Season 3 Episode 9'),
        entry('BBBBBBBBBBB', 'PV'),
        entry('CCCCCCCCCCC', 'S02E05'),
      ]),
      coverFetcher: const WebVideoCoverFetcher(),
    );
    expect(entries.map((VideoEpisodeEntry e) => e.episodeNumber), <int>[
      1,
      2,
      3,
    ]);
    expect(
      entries.map((VideoEpisodeEntry e) => e.groupKey).toSet(),
      hasLength(1),
      reason: '一份播放列表不拆成季 chip',
    );
    expect(entries.every((VideoEpisodeEntry e) => e.cover != null), isTrue);
  });

  group('YoutubePlaylistEpisodes', () {
    tearDown(YoutubePlaylistEpisodes.debugReset);

    test('首批先亮、拉完再整份换上；同一列表 id 进程内共享、不重拉', () async {
      final StreamController<YoutubePlaylistEntry> source =
          StreamController<YoutubePlaylistEntry>();
      int loads = 0;
      YoutubePlaylistEpisodes.loader = (String id) {
        loads++;
        expect(id, 'PL123');
        return source.stream;
      };
      final YoutubePlaylistEpisodes list = YoutubePlaylistEpisodes.forPlaylist(
        'PL123',
      );
      final List<int> seen = <int>[];
      list.addListener(() => seen.add(list.entries.length));
      for (int i = 0; i < 30; i++) {
        source.add(entry('v${i.toString().padLeft(10, '0')}', 'e$i'));
      }
      await pumpEventQueue();
      expect(seen, <int>[25], reason: '首批 25 条先通知，面板不用等整份列表');
      await source.close();
      await pumpEventQueue();
      expect(seen, <int>[25, 30]);
      expect(list.indexOfVideo('v0000000029'), 29);
      expect(list.indexOfVideo('nope'), -1);

      expect(
        identical(YoutubePlaylistEpisodes.forPlaylist('PL123'), list),
        isTrue,
        reason: '换页后新页拿到同一份',
      );
      expect(loads, 1, reason: '没过期不重拉');
    });

    test('过期后重拉：旧列表留着，新列表拉完整才换上', () async {
      DateTime now = DateTime(2026, 11, 24, 12);
      YoutubePlaylistEpisodes.clock = () => now;
      StreamController<YoutubePlaylistEntry> source =
          StreamController<YoutubePlaylistEntry>();
      YoutubePlaylistEpisodes.loader = (String _) => source.stream;
      final YoutubePlaylistEpisodes list = YoutubePlaylistEpisodes.forPlaylist(
        'PL1',
      );
      for (int i = 0; i < 40; i++) {
        source.add(entry('a${i.toString().padLeft(10, '0')}', 'a$i'));
      }
      await source.close();
      await pumpEventQueue();
      expect(list.entries, hasLength(40));

      now = now.add(const Duration(hours: 1));
      source = StreamController<YoutubePlaylistEntry>();
      YoutubePlaylistEpisodes.forPlaylist('PL1');
      for (int i = 0; i < 30; i++) {
        source.add(entry('b${i.toString().padLeft(10, '0')}', 'b$i'));
      }
      await pumpEventQueue();
      expect(list.entries, hasLength(40), reason: '刷新途中不先缩成首批 25 条');
      await source.close();
      await pumpEventQueue();
      expect(list.entries, hasLength(30));
      expect(list.entries.first.videoId, 'b0000000000');
    });

    test('拉到一半失败：已到的照样能用，记下错误', () async {
      final StreamController<YoutubePlaylistEntry> source =
          StreamController<YoutubePlaylistEntry>();
      YoutubePlaylistEpisodes.loader = (String _) => source.stream;
      final YoutubePlaylistEpisodes list = YoutubePlaylistEpisodes.forPlaylist(
        'PLerr',
      );
      source
        ..add(entry('AAAAAAAAAAA', 'a'))
        ..add(entry('BBBBBBBBBBB', 'b'))
        ..addError(StateError('network'));
      await source.close();
      await pumpEventQueue();
      expect(list.entries, hasLength(2));
      expect(list.error, isA<StateError>());
      expect(list.loading, isFalse);
    });
  });
}
