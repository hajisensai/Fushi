// BUG-5455：从媒体服务器「加入媒体库」的剧 / 电影要带上服务器自己的资料（简介 /
// 原名 / 评分 / 类型 / 背景 / 分集名与剧照）与观看状态，库里的合集详情页才和
// 服务器详情页看到同一份东西；用户 / 刮削写过别的身份后不再覆盖。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart';
import 'package:fushi/src/media/video/media_server/media_server_metadata.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_work_loader.dart'
    show lookupOfWork;
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:path/path.dart' as p;

import '../../../pages/media_server/fake_media_server_browser.dart';

/// 剧集带剧名合集归属；图片 URL 像 Jellyfin 一样带令牌，取图返回固定字节。
class _ArtBrowser extends FakeMediaServerBrowser {
  _ArtBrowser() : super(serverId: 'jellyfin:http://srv|u1');

  final List<String> fetched = <String>[];

  @override
  RemoteVideoInfo toRemoteVideoInfo(MediaServerItem item) => RemoteVideoInfo(
    id: item.id,
    title: mediaServerDisplayTitle(item),
    collection: mediaServerCollectionOf(item),
  );

  @override
  String? coverUrl(
    MediaServerItem item, {
    int maxWidth = kMediaServerCoverMaxWidth,
    MediaServerImageKind kind = MediaServerImageKind.primary,
  }) {
    final (bool has, String type) = switch (kind) {
      MediaServerImageKind.primary => (item.hasCover, 'Primary'),
      MediaServerImageKind.backdrop => (item.hasBackdrop, 'Backdrop'),
      MediaServerImageKind.thumb => (item.hasThumb, 'Thumb'),
      MediaServerImageKind.logo => (item.hasLogo, 'Logo'),
    };
    if (!has) return null;
    return 'http://srv/Items/${item.id}/Images/$type'
        '?maxWidth=$maxWidth&api_key=SECRET';
  }

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async {
    fetched.add(coverUrl);
    return Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, coverUrl.length % 256]);
  }
}

const MediaServerItem _series = MediaServerItem(
  id: 'show',
  name: 'Fangs of Fortune',
  type: MediaServerItemType.series,
  originalTitle: '大梦归离',
  productionYear: 2024,
  communityRating: 8.7,
  overview: 'During the Zhenyuan era…',
  genres: <String>['Fantasy', 'Drama'],
  providerIds: <String, String>{
    'tmdb': '233847',
    'imdb': 'tt3',
    'anilist': '99',
  },
  episodeCount: 3,
  hasCover: true,
  hasBackdrop: true,
  hasLogo: true,
);

MediaServerItem _episode(
  String id,
  int season,
  int number, {
  bool played = false,
  int positionMs = 0,
  int lastPlayedAtMs = 0,
}) => MediaServerItem(
  id: id,
  name: 'Episode $number',
  type: MediaServerItemType.episode,
  seriesId: 'show',
  seriesName: 'Fangs of Fortune',
  seasonNumber: season,
  episodeNumber: number,
  overview: 'Plot of $id',
  durationMs: 45 * 60 * 1000,
  played: played,
  positionMs: positionMs,
  lastPlayedAtMs: lastPlayedAtMs,
  hasCover: true,
);

void main() {
  late Directory root;
  late EnginePaths previousPaths;
  late FushiDatabase database;
  late VideoBookRepository repository;
  late MediaServerVideoLibrary library;
  late _ArtBrowser browser;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-ms-metadata-');
    previousPaths = enginePaths;
    enginePaths = FixedEnginePaths(
      documents: Directory(p.join(root.path, 'documents')),
      support: Directory(p.join(root.path, 'support')),
      temp: Directory(p.join(root.path, 'temp')),
    );
    VideoCoverMutationGate.debugResetForTesting();
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    repository = VideoBookRepository(database);
    library = MediaServerVideoLibrary(
      database: database,
      repository: repository,
    );
    browser = _ArtBrowser();
    browser.seasons['show'] = <MediaServerItem>[
      const MediaServerItem(
        id: 's1',
        name: 'Season 1',
        type: MediaServerItemType.season,
        seasonNumber: 1,
      ),
    ];
    browser.episodes['show|'] = <MediaServerItem>[
      _episode('e1', 1, 1, played: true, lastPlayedAtMs: 1700000000000),
      _episode('e2', 1, 2, positionMs: 600000, lastPlayedAtMs: 1700000500000),
      _episode('e3', 1, 3),
    ];
  });

  tearDown(() async {
    await database.close();
    enginePaths = previousPaths;
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<MediaCollectionRow> showCollection() async => (await database
      .getMediaCollectionByNaturalKey('Fangs of Fortune', 'playlist'))!;

  test('image identity URL drops access tokens and keeps the rest', () {
    expect(
      mediaServerImageIdentityUrl(
        'http://srv/Items/x/Images/Primary?maxWidth=720&api_key=SECRET',
      ),
      'http://srv/Items/x/Images/Primary?maxWidth=720',
    );
    expect(
      mediaServerImageIdentityUrl('http://plex/t?X-Plex-Token=SECRET'),
      'http://plex/t',
    );
    expect(mediaServerImageIdentityUrl('http://srv/a.jpg'), 'http://srv/a.jpg');
  });

  test('adding a series writes the server metadata the library page reads: '
      'work facts, cross references, bound episodes, local artwork', () async {
    expect(await library.addToLibrary(browser, _series), 3);

    final MediaCollectionRow collection = await showCollection();
    final VideoMetadataWorkRow work = (await database
        .resolveVideoMetadataWorkForCollection(collection.id))!;
    expect(work.title, 'Fangs of Fortune');
    expect(work.originalTitle, '大梦归离');
    expect(work.overview, 'During the Zhenyuan era…');
    expect(work.year, 2024);
    expect(work.rating, 8.7);
    expect(work.mediaType, 'tv');
    expect(
      <String>{
        for (final VideoMetadataTermRow term
            in await database.getVideoMetadataTermsForWork(work.id))
          if (term.kind == 'genre') term.name,
      },
      <String>{'Fantasy', 'Drama'},
    );

    // 主身份是服务器本身；TMDB / IMDb 只作非主交叉引用；已退役源（AniList）不落。
    final List<VideoMetadataProviderIdentityRow> ids = await database
        .getVideoMetadataProviderIdentities(workId: work.id);
    final Map<String, VideoMetadataProviderIdentityRow> byProvider =
        <String, VideoMetadataProviderIdentityRow>{
          for (final VideoMetadataProviderIdentityRow row in ids)
            row.provider: row,
        };
    expect(byProvider['mediaserver']!.isPrimary, isTrue);
    expect(byProvider['mediaserver']!.externalId, '${browser.serverId}/show');
    expect(byProvider['tmdb']!.isPrimary, isFalse);
    expect(byProvider['tmdb']!.externalId, '233847');
    expect(byProvider['imdb']!.isPrimary, isFalse);
    expect(byProvider.containsKey('anilist'), isFalse);
    // 服务器资料不是可续刮的身份：重刮入口不会拿它去问任何 provider。
    expect(await lookupOfWork(database, work.id), isNull);

    // 分集按服务器季集号绑到入库行，带分集名 / 简介 / 时长与剧照。
    final List<VideoMetadataSeasonRow> seasons = await database
        .getVideoMetadataSeasons(work.id);
    expect(seasons.single.seasonNumber, 1);
    expect(seasons.single.title, 'Season 1');
    final List<VideoMetadataEpisodeRow> episodes = await database
        .getVideoMetadataEpisodes(seasons.single.id);
    expect(
      <String?, String?>{
        for (final VideoMetadataEpisodeRow e in episodes) e.bookUid: e.title,
      },
      <String?, String?>{
        'e1': 'Episode 1',
        'e2': 'Episode 2',
        'e3': 'Episode 3',
      },
    );
    final VideoMetadataEpisodeRow e2 = episodes.firstWhere(
      (VideoMetadataEpisodeRow e) => e.bookUid == 'e2',
    );
    expect(e2.overview, 'Plot of e2');
    expect(e2.runtimeMinutes, 45);
    final List<VideoMetadataImageRow> still = await database
        .getVideoMetadataImages(episodeId: e2.id);
    expect(still.single.kind, VideoMetadataImageKind.thumb.name);
    expect(File(still.single.localPath!).existsSync(), isTrue);

    // 作品海报 / 背景 / logo 都落了本地文件；落库地址一律不带令牌。
    final List<VideoMetadataImageRow> art = await database
        .getVideoMetadataImages(workId: work.id);
    expect(art.map((VideoMetadataImageRow r) => r.kind).toSet(), <String>{
      VideoMetadataImageKind.cover.name,
      VideoMetadataImageKind.backdrop.name,
      VideoMetadataImageKind.logo.name,
    });
    for (final VideoMetadataImageRow row in <VideoMetadataImageRow>[
      ...art,
      ...still,
    ]) {
      expect(row.remoteUrl, isNot(contains('SECRET')));
      expect(File(row.localPath!).existsSync(), isTrue);
    }

    // 旧投影（合集资料行）同一份：首页 / 侧栏速览吃它。
    final CollectionScrapeMetaRow legacy = (await database
        .getCollectionScrapeMeta(collection.id))!;
    expect(legacy.source, 'mediaserver');
    expect(legacy.summary, 'During the Zhenyuan era…');
  });

  test('server watched state comes along: played → watched at the server '
      'time, newer server resume point is adopted', () async {
    await library.addToLibrary(browser, _series);

    final VideoBookRow e1 = (await repository.getByBookUid('e1'))!;
    expect(e1.completedAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(e1.lastPositionMs, 0);
    final VideoBookRow e2 = (await repository.getByBookUid('e2'))!;
    expect(e2.completedAt, isNull);
    expect(e2.lastPositionMs, 600000);
    expect(e2.lastPlayedAt, 1700000500000);
    expect((await repository.getByBookUid('e3'))!.completedAt, isNull);

    // 本机之后看得更新：服务器的旧断点不回灌。
    await database.updateVideoBookPosition(
      'e2',
      900000,
      playedAt: 1700000900000,
    );
    await library.addMissing(browser, _series);
    expect((await repository.getByBookUid('e2'))!.lastPositionMs, 900000);
  });

  test('refresh keeps metadata in sync, but a work identified by anything '
      'else (rescrape / manual identify) is never overwritten', () async {
    await library.addToLibrary(browser, _series);
    final MediaCollectionRow collection = await showCollection();

    // 服务器资料更新 → 后台补新集时跟着更新。
    browser.details['show'] = _series;
    await library.addMissing(
      browser,
      const MediaServerItem(
        id: 'show',
        name: 'Fangs of Fortune',
        type: MediaServerItemType.series,
        overview: 'Updated overview',
      ),
    );
    VideoMetadataWorkRow work = (await database
        .resolveVideoMetadataWorkForCollection(collection.id))!;
    expect(work.overview, 'Updated overview');

    // 改成 TMDB 主身份（刮削 / 手动识别的结果）之后，服务器资料不再覆盖。
    await database.replaceVideoMetadataProviderIdentities(
      workId: work.id,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:${work.id}:tmdb',
          provider: 'tmdb',
          externalId: '233847',
          isPrimary: const Value<bool>(true),
          updatedAt: 0,
        ),
      ],
    );
    await library.addMissing(browser, _series);
    work = (await database.resolveVideoMetadataWorkForCollection(
      collection.id,
    ))!;
    expect(work.overview, 'Updated overview');
  });

  test('a movie gets its own book-owned work; removing works deletes the '
      'downloaded artwork', () async {
    const MediaServerItem movie = MediaServerItem(
      id: 'mv',
      name: 'A Movie',
      type: MediaServerItemType.movie,
      overview: 'Movie plot',
      productionYear: 2020,
      durationMs: 7200000,
      hasCover: true,
      hasBackdrop: true,
    );
    expect(await library.addToLibrary(browser, movie), 1);
    final VideoMetadataWorkRow work = (await database
        .getVideoMetadataWorkByBook('mv'))!;
    expect(work.mediaType, 'movie');
    expect(work.overview, 'Movie plot');
    expect(work.runtimeMinutes, 120);

    await library.addToLibrary(browser, _series);
    final Directory imagesDir = await VideoStorage.mediaServerImagesDir();
    expect(imagesDir.listSync(), isNotEmpty);

    await library.removeWorks(<MediaServerLibraryWork>{
      (serverId: browser.serverId, workId: 'mv'),
      (serverId: browser.serverId, workId: 'show'),
    });
    expect(imagesDir.listSync(), isEmpty);
  });
}
