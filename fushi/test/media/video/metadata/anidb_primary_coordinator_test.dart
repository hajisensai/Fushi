// 2026-09-20 第六轮 b：AniDB 为默认主源（Shoko 形态）——哈希给出的 aid 直接就是
// 作品身份（不经 Fribb、一对多 MAL 映射不算歧义），anime XML 出核心资料与全集，
// TMDB 恒为补充（描述 / 图片 / 逐集链接），MAL 只是交叉引用；存量 MAL 身份不换源。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/anidb_ed2k.dart';
import 'package:fushi_engine/media/video/metadata/anidb_hash_identity_service.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  late Directory directory;
  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('anidb-primary-');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  VideoSourceScrapeCoordinator coordinator({
    required List<VideoMetadataProvider> providers,
    _HashService? hash,
  }) {
    if (hash != null) addTearDown(hash.close);
    final VideoSourceScrapeCoordinator runner = VideoSourceScrapeCoordinator(
      database: db,
      // 不传 primaryProvider：吃 `VideoSourceScrapeGlobalConfig` 默认 = AniDB。
      config: const VideoSourceScrapeGlobalConfig(),
      hashIdentityService: hash,
      registry: VideoMetadataProviderRegistry(providers),
    );
    addTearDown(runner.close);
    return runner;
  }

  Future<SourceScrapeReport> scrape(
          VideoSourceScrapeCoordinator runner, SourceLibraryRow source) =>
      runner.scrapeSource(source,
          cancellationToken: VideoSourceScrapeCancellationToken(),
          onProgress: (_) {});

  Future<List<String>> identities(String bookUid) async {
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByBook(bookUid))!;
    return (await db.getVideoMetadataProviderIdentities(workId: work.id))
        .map((VideoMetadataProviderIdentityRow id) =>
            '${id.provider}:${id.externalId}:${id.isPrimary}')
        .toList();
  }

  test('default primary is AniDB and hash aid is the work identity directly',
      () async {
    final SourceLibraryRow source = await _source(db, directory, count: 1);
    final _Provider anidb = _Provider(VideoMetadataProviderKind.anidb);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    // Fribb 把 aid 100 映到两个 MAL 条目：MAL 主源下这是「要人工选」的歧义，
    // AniDB 主源下作品身份已成立，MAL 不参与识别。
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      'Show.mkv': _matched(aid: 100, malIds: <int>{42, 43}),
    });
    final SourceScrapeReport report = await scrape(
        coordinator(
            providers: <VideoMetadataProvider>[anidb, mal, tmdb], hash: hash),
        source);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(report.pendingConfirmations, 0);
    expect(anidb.searchCalls, 0, reason: '哈希给了 aid，不做标题搜索');
    expect(anidb.fetchedIds, <String>['100']);
    expect(mal.searchCalls, 0);
    expect(mal.fetchedIds, isEmpty);
    expect(tmdb.searchCalls, greaterThan(0), reason: 'TMDB 恒为 AniDB 的补充');
    expect(await identities('book-0'), contains('anidb:100:true'));
    expect(await identities('book-0'), isNot(contains(startsWith('mal:'))),
        reason: 'Fribb 的一对多 MAL 映射不落成交叉引用（AniDB 自己的 XML 才算）');
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByBook('book-0'))!;
    expect(work.overview, 'anidb plot');
  });

  test('without hash the AniDB provider identifies by title, TMDB supplements',
      () async {
    final SourceLibraryRow source = await _source(db, directory, count: 1);
    final _Provider anidb = _Provider(VideoMetadataProviderKind.anidb);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report = await scrape(
        coordinator(
            providers: <VideoMetadataProvider>[anidb, mal, tmdb],
            hash: _HashService(const <String, AnidbHashIdentityResult>{},
                enabled: false)),
        source);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(anidb.searchCalls, greaterThan(0));
    expect(mal.searchCalls, 0, reason: 'MAL 不在 AniDB 主源的识别链上');
    expect(tmdb.searchCalls, greaterThan(0));
    expect(await identities('book-0'), contains('anidb:42:true'));
    expect(await identities('book-0'), contains('tmdb:42:false'));
  });

  test('an existing MAL primary is kept as-is under the AniDB default',
      () async {
    final SourceLibraryRow source = await _source(db, directory, count: 1);
    final VideoSourceScrapeWork local =
        (await VideoSourceWorkPlanner(db).plan(source)).single;
    await VideoMetadataDatabaseStore(db).apply(
        local,
        _Provider(VideoMetadataProviderKind.mal)
            ._work('777', VideoMetadataMediaKind.movie));
    final _Provider anidb = _Provider(VideoMetadataProviderKind.anidb);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report = await scrape(
        coordinator(
            providers: <VideoMetadataProvider>[anidb, mal, tmdb],
            hash: _HashService(const <String, AnidbHashIdentityResult>{},
                enabled: false)),
        source);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(anidb.searchCalls, 0, reason: '默认主源换成 AniDB 不能把存量 MAL 作品重识别');
    expect(mal.fetchedIds, <String>['777']);
    expect(await identities('book-0'), contains('mal:777:true'));
  });

  test('AniDB episodes decide TMDB (season, episode), not the file names',
      () async {
    // 文件名说 E01 / E02，AniDB 文件身份反过来说：book-0 是第 2 集、book-1 是第 1 集。
    final SourceLibraryRow source = await _source(db, directory, count: 2);
    final _EpisodeProvider anidb = _EpisodeProvider(
      VideoMetadataProviderKind.anidb,
      episodes: const <(int, String, String)>[
        (301, 'Alpha', '2024-01-05'),
        (302, 'Beta', '2024-01-12'),
      ],
    );
    final _EpisodeProvider tmdb = _EpisodeProvider(
      VideoMetadataProviderKind.tmdb,
      episodes: const <(int, String, String)>[
        (9001, 'Alpha', '2024-01-05'),
        (9002, 'Beta', '2024-01-12'),
      ],
    );
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      'Show S01E01.mkv': _matched(aid: 100, eid: 302, episodeNumber: '2'),
      'Show S01E02.mkv': _matched(aid: 100, eid: 301, episodeNumber: '1'),
    });
    final SourceScrapeReport report = await scrape(
        coordinator(
            providers: <VideoMetadataProvider>[anidb, tmdb], hash: hash),
        source);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final MediaCollectionRow collection =
        (await db.getMediaCollectionByNaturalKey('Show', 'playlist'))!;
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByCollection(collection.id))!;
    final Map<(int, int), (String?, int?, String?)> bound =
        <(int, int), (String?, int?, String?)>{};
    for (final VideoMetadataSeasonRow season
        in await db.getVideoMetadataSeasons(work.id)) {
      for (final VideoMetadataEpisodeRow episode
          in await db.getVideoMetadataEpisodes(season.id)) {
        bound[(season.seasonNumber, episode.episodeNumber)] = (
          episode.bookUid,
          episode.anidbEpisodeId,
          episode.anidbEpisodeNumber
        );
      }
    }
    expect(bound[(1, 1)], ('book-1', 301, '1'));
    expect(bound[(1, 2)], ('book-0', 302, '2'));
  });
}

Future<SourceLibraryRow> _source(FushiDatabase db, Directory root,
    {required int count}) async {
  final int sourceId = await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'Source', mediaKind: 'video', rootPath: root.path, createdAt: 1));
  final int? collectionId = count > 1
      ? await db.createMediaCollection('Show', collectionType: 'playlist')
      : null;
  for (int index = 0; index < count; index++) {
    final String name = count == 1 ? 'Show.mkv' : 'Show S01E0${index + 1}.mkv';
    final File file = File(p.join(root.path, name));
    await file.writeAsBytes(<int>[0]);
    await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>('book-$index'),
        title: const Value<String>('Show'),
        videoPath: Value<String>(file.path),
        sourceId: Value<int?>(sourceId)));
    if (collectionId != null) {
      await db.addToCollection(collectionId, MediaKind.video, 'book-$index');
    }
  }
  await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
          sourceId: Value<int>(sourceId),
          writeNfo: const Value<bool>(false),
          writeImages: const Value<bool>(false),
          fanartEnabled: const Value<bool>(false),
          updatedAt: 1));
  return (await db.getMediaSourceById(sourceId))!;
}

AnidbHashIdentityResult _matched({
  required int aid,
  int eid = 300,
  String episodeNumber = '1',
  Set<int> malIds = const <int>{},
}) =>
    AnidbHashIdentityResult(
      status: AnidbHashIdentityStatus.matched,
      hash: AnidbEd2kHash(
          ed2k: '0123456789abcdef0123456789abcdef',
          size: 1,
          modifiedAt: DateTime(2026),
          changedAt: DateTime(2026)),
      identity: AnidbFileIdentity(
          fileId: 200 + eid,
          animeId: aid,
          episodeId: eid,
          episodeNumber: episodeNumber,
          romajiTitle: 'Show',
          kanjiTitle: '',
          englishTitle: '',
          episodeTitle: '',
          episodeRomajiTitle: '',
          episodeKanjiTitle: '',
          animeType: 'TV Series'),
      mapping: AnimeIdentityMappingResult(anidbId: aid, malIds: malIds),
    );

class _HashService extends AnidbHashIdentityService {
  _HashService(this.results, {bool enabled = true})
      : super(
            enabled: enabled,
            config: const AnidbUdpConfig(
                username: 'user',
                password: 'test',
                clientName: 'testclient',
                clientVersion: 1));
  final Map<String, AnidbHashIdentityResult> results;
  @override
  bool get isConfigured => true;
  @override
  Future<AnidbHashIdentityResult> identifyFile(String path,
      {bool Function()? isCancelled,
      void Function(int, int)? onProgress}) async {
    onProgress?.call(1, 1);
    return results[p.basename(path)] ??
        const AnidbHashIdentityResult(status: AnidbHashIdentityStatus.notFound);
  }
}

class _Provider implements VideoMetadataProvider {
  _Provider(this.providerKind);
  @override
  final VideoMetadataProviderKind providerKind;
  int searchCalls = 0;
  final List<String> fetchedIds = <String>[];
  @override
  bool get isAvailable => true;

  VideoMetadataWork _work(String id, VideoMetadataMediaKind kind) =>
      VideoMetadataWork(
        provider: providerKind,
        kind: kind,
        title: 'Show',
        plot: '${providerKind.name} plot',
        ids: <VideoMetadataId>[
          VideoMetadataId(type: providerKind.name, value: id, isDefault: true)
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    searchCalls++;
    return <VideoMetadataWork>[_work('42', request.mediaKind)];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    fetchedIds.add(lookup.externalId);
    return _work(lookup.externalId, lookup.mediaKind);
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
          VideoMetadataLookup lookup) async =>
      <VideoMetadataSeason>[];
  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
          {required int seasonNumber}) async =>
      <VideoMetadataEpisode>[];
  @override
  void close() {}
}

/// 一季两集的剧：(id, 集名, 播出日)。
class _EpisodeProvider extends _Provider {
  _EpisodeProvider(super.providerKind, {required this.episodes});
  final List<(int, String, String)> episodes;

  List<VideoMetadataEpisode> _episodes() => <VideoMetadataEpisode>[
        for (int i = 0; i < episodes.length; i++)
          VideoMetadataEpisode(
            seasonNumber: 1,
            episodeNumber: i + 1,
            title: episodes[i].$2,
            airDate: episodes[i].$3,
            ids: <VideoMetadataId>[
              VideoMetadataId(
                  type: providerKind.name, value: '${episodes[i].$1}'),
            ],
          ),
      ];

  @override
  VideoMetadataWork _work(String id, VideoMetadataMediaKind kind) =>
      super._work(id, VideoMetadataMediaKind.tv).copyWith(
        episodeCount: episodes.length,
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
              seasonNumber: 1,
              title: 'Show',
              episodeCount: episodes.length,
              episodes: _episodes()),
        ],
      );

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
          VideoMetadataLookup lookup) async =>
      _work(lookup.externalId, lookup.mediaKind).seasons;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
          {required int seasonNumber}) async =>
      seasonNumber == 1 ? _episodes() : const <VideoMetadataEpisode>[];
}
