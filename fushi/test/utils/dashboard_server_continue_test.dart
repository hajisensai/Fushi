import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart'
    show audiobookshelfProgressKey;
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_images.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart';
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';

import '../pages/media_server/fake_media_server_browser.dart';

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

/// 按条目的图片旗子给 `<id>|<kind>` 地址的浏览器（没有那种图给 null）。
class _ArtBrowser extends FakeMediaServerBrowser {
  _ArtBrowser() : super(serverId: 'srv');

  @override
  String? coverUrl(
    MediaServerItem item, {
    int maxWidth = kMediaServerCoverMaxWidth,
    MediaServerImageKind kind = MediaServerImageKind.primary,
  }) {
    final bool has = switch (kind) {
      MediaServerImageKind.primary => item.hasCover,
      MediaServerImageKind.backdrop => item.hasBackdrop,
      MediaServerImageKind.thumb => item.hasThumb,
      MediaServerImageKind.logo => item.hasLogo,
    };
    return has ? '${item.id}|${kind.name}' : null;
  }
}

/// provider 实际会去取的地址（剥掉 [ResizeImage]）；null = 没有图。
String? _urlOf(ImageProvider? image) {
  final ImageProvider? inner = image is ResizeImage
      ? image.imageProvider
      : image;
  return inner is RemoteCoverImage ? inner.coverUrl : null;
}

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

    // BUG-5608：服务器条目要带上服务器自己的背景图 / logo，首页才能画系列色块。
    group('系列色块的图（BUG-5608）', () {
      final _ArtBrowser browser = _ArtBrowser();
      List<ServerContinueCandidate> run(List<MediaServerItem> resume) =>
          mediaServerContinueCandidates(
            serverId: 'srv',
            serverName: 'Home',
            resume: resume,
            nextUp: const <MediaServerItem>[],
            coverUrlOf: (MediaServerItem i) => browser.coverUrl(i.coverItem),
            coverFetcher: browser,
            backdropOf: (MediaServerItem i) =>
                mediaServerBackdropImage(browser, i),
            logoOf: (MediaServerItem i) => mediaServerLogoImage(browser, i),
            open: (_, __) async {},
          );

      test('集用所属剧的背景图与 logo，不用集自己的；年份 / 评分不当剧的', () {
        final ServerContinueCandidate ep = run(<MediaServerItem>[
          const MediaServerItem(
            id: 'ep1',
            name: 'Pilot',
            type: MediaServerItemType.episode,
            seriesId: 'show1',
            seriesName: 'Show',
            positionMs: 10,
            hasCover: true,
            // 集自己也报了背景图 / logo：系列色块仍要剧的那张。
            hasBackdrop: true,
            hasLogo: true,
            parentBackdropItemId: 'show1',
            parentLogoItemId: 'show1',
            seriesCoverItemId: 'show1',
            productionYear: 2021,
            communityRating: 7.5,
            genres: <String>['Drama'],
          ),
        ]).single;
        expect(_urlOf(ep.backdrop), 'show1|backdrop');
        expect(_urlOf(ep.logo), 'show1|logo');
        expect(ep.coverUrl, 'show1|primary');
        expect(ep.coverIsPoster, isTrue);
        expect(ep.isEpisode, isTrue);
        expect(ep.year, isNull);
        expect(ep.rating, isNull);
        expect(ep.genres, <String>['Drama']);
      });

      test('集的剧没报图：退回集自己的；都没有为 null；没有剧海报时封面不当海报', () {
        final List<ServerContinueCandidate> out = run(<MediaServerItem>[
          const MediaServerItem(
            id: 'ep1',
            name: 'Pilot',
            type: MediaServerItemType.episode,
            positionMs: 10,
            hasCover: true,
            hasBackdrop: true,
            hasLogo: true,
          ),
          const MediaServerItem(
            id: 'ep2',
            name: 'Two',
            type: MediaServerItemType.episode,
            positionMs: 10,
            hasCover: true,
          ),
        ]);
        expect(_urlOf(out[0].backdrop), 'ep1|backdrop');
        expect(_urlOf(out[0].logo), 'ep1|logo');
        expect(out[0].coverIsPoster, isFalse);
        expect(out[1].backdrop, isNull);
        expect(out[1].logo, isNull);
      });

      test('电影用自己的图，带年份 / 评分 / 类型', () {
        final ServerContinueCandidate movie = run(<MediaServerItem>[
          const MediaServerItem(
            id: 'm1',
            name: 'Film',
            type: MediaServerItemType.movie,
            positionMs: 10,
            hasCover: true,
            hasBackdrop: true,
            hasLogo: true,
            productionYear: 2019,
            communityRating: 8.1,
            genres: <String>['Action', 'Drama', 'Thriller'],
          ),
        ]).single;
        expect(_urlOf(movie.backdrop), 'm1|backdrop');
        expect(_urlOf(movie.logo), 'm1|logo');
        expect(movie.coverIsPoster, isTrue);
        expect(movie.year, 2019);
        expect(movie.rating, 8.1);
      });

      test('不传取图回调（旧调用方）：不带图', () {
        final ServerContinueCandidate c = _mediaServer(
          resume: <MediaServerItem>[_movie('a', positionMs: 10)],
        ).single;
        expect(c.backdrop, isNull);
        expect(c.logo, isNull);
      });
    });
  });

  group('serverContinueSeriesMeta（BUG-5608）', () {
    final ImageProvider backdrop = MemoryImage(Uint8List.fromList(<int>[1]));
    final ImageProvider logo = MemoryImage(Uint8List.fromList(<int>[2]));
    final ImageProvider cover = MemoryImage(Uint8List.fromList(<int>[3]));
    ServerContinueCandidate candidate({
      ServerContinueSource source = ServerContinueSource.mediaServer,
      ImageProvider? backdrop,
      ImageProvider? logo,
      bool coverIsPoster = true,
      bool isEpisode = false,
      int? year,
    }) => ServerContinueCandidate(
      source: source,
      serverId: 'srv',
      serverName: 'Home',
      itemId: 'x',
      title: 'X',
      recentMs: 0,
      open: (_) async {},
      backdrop: backdrop,
      logo: logo,
      coverIsPoster: coverIsPoster,
      isEpisode: isEpisode,
      genres: const <String>['Action', 'Drama', 'Thriller'],
      year: year,
      rating: 8.1,
    );

    test('带背景图的服务器条目：系列元数据带背景 / logo / 海报 / 概览 / chip', () {
      final FushiSeriesMeta? meta = serverContinueSeriesMeta(
        candidate(backdrop: backdrop, logo: logo, year: 2019),
        cover: cover,
      );
      expect(meta, isNotNull);
      expect(meta!.backdrop, same(backdrop));
      expect(meta.logo, same(logo));
      expect(meta.displayLogo, same(logo));
      expect(meta.poster, same(cover));
      expect(meta.year, 2019);
      expect(meta.overview, 'Action / Drama · ★ 8.1');
      expect(meta.chip, 'Movie · 2019');
    });

    test('集：chip 标剧集；封面不是海报时不进海报位', () {
      final FushiSeriesMeta? meta = serverContinueSeriesMeta(
        candidate(backdrop: backdrop, isEpisode: true, coverIsPoster: false),
        cover: cover,
      );
      expect(meta!.poster, isNull);
      expect(meta.chip, 'TV');
    });

    test('没有背景图也没有 logo、或是 ABS 条目：null（卡片照原摆法）', () {
      expect(serverContinueSeriesMeta(candidate(), cover: cover), isNull);
      expect(
        serverContinueSeriesMeta(
          candidate(
            source: ServerContinueSource.audiobookshelf,
            backdrop: backdrop,
            logo: logo,
          ),
          cover: cover,
        ),
        isNull,
      );
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
