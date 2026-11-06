import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart'
    show audiobookshelfProgressKey;
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';

MediaServerItem _movie(
  String id, {
  int positionMs = 0,
  int lastPlayedAtMs = 0,
  int? durationMs,
  bool played = false,
}) => MediaServerItem(
  id: id,
  name: 'Movie $id',
  type: MediaServerItemType.movie,
  positionMs: positionMs,
  lastPlayedAtMs: lastPlayedAtMs,
  durationMs: durationMs,
  played: played,
);

MediaServerItem _episode(String id, {int lastPlayedAtMs = 0}) =>
    MediaServerItem(
      id: id,
      name: 'Pilot',
      type: MediaServerItemType.episode,
      seriesName: 'Show',
      seasonNumber: 1,
      episodeNumber: 2,
      lastPlayedAtMs: lastPlayedAtMs,
    );

List<ServerContinueCandidate> _mediaServer({
  List<MediaServerItem> resume = const <MediaServerItem>[],
  List<MediaServerItem> nextUp = const <MediaServerItem>[],
  String serverId = 's1',
}) => mediaServerContinueCandidates(
  serverId: serverId,
  serverName: 'Home',
  resume: resume,
  nextUp: nextUp,
  coverUrlOf: (MediaServerItem i) => 'http://x/${i.id}.jpg',
  open: (_, __) async {},
);

AudiobookshelfInProgressEntry _absEntry(
  String id, {
  String? episodeId,
  String? episodeTitle,
}) => AudiobookshelfInProgressEntry(
  item: AudiobookshelfItem(id: id, title: 'Book $id'),
  episodeId: episodeId,
  episodeTitle: episodeTitle,
);

AudiobookshelfMediaProgress _absProgress({
  double current = 30,
  double duration = 100,
  bool finished = false,
  int? lastUpdateMs,
  String? episodeId,
}) => AudiobookshelfMediaProgress(
  currentTimeSeconds: current,
  durationSeconds: duration,
  isFinished: finished,
  lastUpdateMs: lastUpdateMs,
  episodeId: episodeId,
);

void main() {
  group('mediaServerContinueCandidates', () {
    test('Resume 在前、NextUp 补后，同 id 去重，只收可播叶子', () {
      final List<ServerContinueCandidate> out = _mediaServer(
        resume: <MediaServerItem>[
          _movie('a', positionMs: 10, lastPlayedAtMs: 5),
        ],
        nextUp: <MediaServerItem>[
          _movie('a'),
          _episode('b'),
          const MediaServerItem(
            id: 'series',
            name: 'Series',
            type: MediaServerItemType.series,
          ),
        ],
      );
      expect(out.map((ServerContinueCandidate c) => c.itemId), <String>[
        'a',
        'b',
      ]);
      expect(out.first.recentMs, 5);
    });

    test('已看完的不收；进度 = 断点 / 时长，剧集用 SxxEyy 角标并以剧名分组', () {
      final List<ServerContinueCandidate> out = _mediaServer(
        resume: <MediaServerItem>[
          _movie('done', played: true),
          _movie('m', positionMs: 25, durationMs: 100),
        ],
        nextUp: <MediaServerItem>[_episode('e')],
      );
      expect(out, hasLength(2));
      final ServerContinueCandidate movie = out[0];
      expect(movie.progress, 0.25);
      expect(movie.badgeLabel, '25%');
      expect(movie.collectionName, isNull);
      final ServerContinueCandidate ep = out[1];
      expect(ep.collectionName, 'Show');
      expect(ep.title, 'S01E02 Pilot');
      expect(ep.badgeLabel, 'S01E02');
      expect(ep.progress, isNull);
      expect(ep.isVideo, isTrue);
      expect(ep.coverUrl, 'http://x/e.jpg');
    });
  });

  group('audiobookshelfContinueCandidates', () {
    List<ServerContinueCandidate> run(
      List<AudiobookshelfInProgressEntry> entries,
      Map<String, AudiobookshelfMediaProgress> progress,
    ) => audiobookshelfContinueCandidates(
      serverId: 'abs1',
      serverName: 'ABS',
      entries: entries,
      progressByKey: progress,
      coverUrlOf: (AudiobookshelfItem i) => 'http://abs/${i.id}',
      open: (_, __) async {},
    );

    test('排序时刻与进度取自服务器进度；已听完的丢弃；没有进度表照常出条目', () {
      final List<ServerContinueCandidate> out = run(
        <AudiobookshelfInProgressEntry>[
          _absEntry('a'),
          _absEntry('finished'),
          _absEntry('noprogress'),
        ],
        <String, AudiobookshelfMediaProgress>{
          audiobookshelfProgressKey('a', null): _absProgress(lastUpdateMs: 777),
          audiobookshelfProgressKey('finished', null): _absProgress(
            finished: true,
          ),
        },
      );
      expect(out.map((ServerContinueCandidate c) => c.itemId), <String>[
        'a',
        'noprogress',
      ]);
      expect(out[0].recentMs, 777);
      expect(out[0].progress, closeTo(0.3, 1e-9));
      expect(out[0].badgeLabel, '30%');
      expect(out[0].isVideo, isFalse);
      expect(out[1].recentMs, 0);
      expect(out[1].progress, isNull);
    });

    test('播客：最近收听的那一集作标题、播客名作分组，条目键带集 id', () {
      final List<ServerContinueCandidate> out = run(
        <AudiobookshelfInProgressEntry>[
          _absEntry('pod', episodeId: 'ep1', episodeTitle: 'Episode One'),
        ],
        <String, AudiobookshelfMediaProgress>{
          audiobookshelfProgressKey('pod', 'ep1'): _absProgress(
            episodeId: 'ep1',
            lastUpdateMs: 5,
          ),
        },
      );
      expect(out.single.title, 'Episode One');
      expect(out.single.collectionName, 'Book pod');
      expect(out.single.itemId, 'pod/ep1');
      expect(out.single.recentMs, 5);
    });
  });

  group('mergeServerContinue', () {
    test('按最近播放时刻倒序，同时刻保持输入顺序，跨来源混排', () {
      final List<ServerContinueCandidate> video = _mediaServer(
        resume: <MediaServerItem>[
          _movie('old', positionMs: 1, lastPlayedAtMs: 10),
          _movie('tieA', positionMs: 1, lastPlayedAtMs: 50),
          _movie('tieB', positionMs: 1, lastPlayedAtMs: 50),
        ],
      );
      final List<ServerContinueCandidate> abs =
          audiobookshelfContinueCandidates(
            serverId: 'abs1',
            serverName: 'ABS',
            entries: <AudiobookshelfInProgressEntry>[_absEntry('book')],
            progressByKey: <String, AudiobookshelfMediaProgress>{
              audiobookshelfProgressKey('book', null): _absProgress(
                lastUpdateMs: 99,
              ),
            },
            coverUrlOf: (_) => null,
            open: (_, __) async {},
          );
      final List<ServerContinueCandidate> merged = mergeServerContinue(
        <List<ServerContinueCandidate>>[video, abs],
      );
      expect(merged.map((ServerContinueCandidate c) => c.itemId), <String>[
        'book',
        'tieA',
        'tieB',
        'old',
      ]);
    });

    test('跨组同键去重；本机已入库的媒体服务器条目让位，但不误伤其它服务器 / ABS', () {
      final List<ServerContinueCandidate> s1 = _mediaServer(
        resume: <MediaServerItem>[
          _movie('m1', positionMs: 1, lastPlayedAtMs: 3),
          _movie('m2', positionMs: 1, lastPlayedAtMs: 2),
        ],
      );
      final List<ServerContinueCandidate> s2 = _mediaServer(
        serverId: 's2',
        resume: <MediaServerItem>[
          _movie('m1', positionMs: 1, lastPlayedAtMs: 1),
        ],
      );
      final List<ServerContinueCandidate> merged = mergeServerContinue(
        <List<ServerContinueCandidate>>[s1, s1, s2],
        localMediaServerItemKeys: <String>{mediaServerItemKey('s1', 'm1')},
      );
      expect(
        merged.map((ServerContinueCandidate c) => '${c.serverId}/${c.itemId}'),
        <String>['s1/m2', 's2/m1'],
      );
    });

    test('集的封面缓存键跟着剧海报走，不沿用集自己的 id（旧缓存里是 16:9 截图）', () {
      final List<ServerContinueCandidate> out = _mediaServer(
        resume: <MediaServerItem>[
          const MediaServerItem(
            id: 'ep1',
            name: 'Pilot',
            type: MediaServerItemType.episode,
            seriesName: 'Show',
            seriesCoverItemId: 'series1',
            hasCover: true,
            positionMs: 1000,
            durationMs: 100000,
          ),
        ],
      );
      expect(out.single.coverCacheKey, 'media-server:s1:series1');
    });

    test('空输入得空表', () {
      expect(
        mergeServerContinue(const <List<ServerContinueCandidate>>[]),
        isEmpty,
      );
    });
  });
}
