import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/anidb_title_catalog.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/anime_offline_identity_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// 设计稿 A2：离线标题索引阶段在协调器里的行为。
void main() {
  late FushiDatabase db;
  late Directory directory;
  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    directory =
        await Directory.systemTemp.createTemp('offline-identity-coordinator-');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<SourceScrapeReport> scrape(
    VideoSourceScrapeCoordinator coordinator,
    SourceLibraryRow source,
  ) {
    addTearDown(coordinator.close);
    return coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
  }

  test('Chinese folder name resolves offline and fetches MAL by id only',
      () async {
    final SourceLibraryRow source =
        await _source(db, directory, title: '葬送的芙莉莲');
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report = await scrape(
      VideoSourceScrapeCoordinator(
        // 本用例测的是 MAL 主源形态（2026-09-20 起默认主源是 AniDB，MAL 仍可选）。
        primaryProvider: VideoMetadataProviderKind.mal,
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
        registry:
            VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
        offlineIdentityResolver: _offline(<String, int>{'葬送的芙莉莲': 17617}),
      ),
      source,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(mal.searchCalls, 0, reason: '离线命中后不得再发标题搜索');
    expect(mal.fetchedIds, contains('52991'));
    expect(tmdb.searchCalls, 0, reason: 'TMDB 补充经 id 接力，不搜标题');
    expect(tmdb.fetchedIds, contains('209867'));
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByBook('book-0'))!;
    final List<VideoMetadataProviderIdentityRow> ids =
        await db.getVideoMetadataProviderIdentities(workId: work.id);
    expect(
      ids
          .singleWhere((VideoMetadataProviderIdentityRow id) => id.isPrimary)
          .provider,
      'mal',
    );
    expect(
      ids.map((VideoMetadataProviderIdentityRow id) => id.provider).toSet(),
      containsAll(<String>['mal', 'tmdb', 'anidb']),
    );
  });

  test('offline identity falls over to the TMDB id when MAL is down', () async {
    final SourceLibraryRow source =
        await _source(db, directory, title: '葬送的芙莉莲');
    final _Provider mal = _Provider(
      VideoMetadataProviderKind.mal,
      failure: const VideoMetadataNetworkException('504', statusCode: 504),
    );
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report = await scrape(
      VideoSourceScrapeCoordinator(
        // 本用例测的是 MAL 主源形态（2026-09-20 起默认主源是 AniDB，MAL 仍可选）。
        primaryProvider: VideoMetadataProviderKind.mal,
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
        registry:
            VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
        offlineIdentityResolver: _offline(<String, int>{'葬送的芙莉莲': 17617}),
      ),
      source,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(mal.fetchedIds, contains('52991'));
    expect(tmdb.fetchedIds, contains('209867'));
    expect(tmdb.searchCalls, 0);
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByBook('book-0'))!;
    final List<VideoMetadataProviderIdentityRow> ids =
        await db.getVideoMetadataProviderIdentities(workId: work.id);
    expect(
      ids
          .singleWhere((VideoMetadataProviderIdentityRow id) => id.isPrimary)
          .provider,
      'tmdb',
    );
  });

  test('ambiguous offline hit is reported and falls back to title search',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final SourceScrapeReport report = await scrape(
      VideoSourceScrapeCoordinator(
        // 本用例测的是 MAL 主源形态（2026-09-20 起默认主源是 AniDB，MAL 仍可选）。
        primaryProvider: VideoMetadataProviderKind.mal,
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal]),
        offlineIdentityResolver: AnimeOfflineIdentityResolver.custom(
          search: (String query) async => <AniDbTitleSearchResult>[
            _hit(1, query),
            _hit(2, query),
          ],
          entryForAnidb: (int anidbId) async => null,
        ),
      ),
      source,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(mal.searchCalls, greaterThan(0));
    expect(
      report.warnings
          .any((SourceScrapeIssue issue) => issue.message.contains('多个同名候选')),
      isTrue,
    );
  });

  test('MAL identity found by search relays a TMDB id through the mapping',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report = await scrape(
      VideoSourceScrapeCoordinator(
        // 本用例测的是 MAL 主源形态（2026-09-20 起默认主源是 AniDB，MAL 仍可选）。
        primaryProvider: VideoMetadataProviderKind.mal,
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
        registry:
            VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
        identityMapping: _mapping(
          '[{"anidb_id":5,"mal_id":42,"themoviedb_id":{"tv":777},"type":"TV"}]',
        ),
      ),
      source,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(mal.searchCalls, greaterThan(0));
    expect(tmdb.searchCalls, 0, reason: '有映射就按 id 直拉，不再按标题搜');
    expect(tmdb.fetchedIds, contains('777'));
  });

  // BUG-2828：TMDB 常把剧场版收成所属剧的第 0 季，Fribb 于是给出
  // `type: MOVIE` + `{tv: N}`。按形态把 tv id 当 /movie/N 拉，会命中同号的
  // 无关电影（真机：リズと青い鳥 → tv 62564 → 挪威片 Turn Me On, Dammit!）。
  test('movie whose mapping row is a TMDB show id never fetches /movie/<tv id>',
      () async {
    // 本地标题与假 MAL 源返回的 'Show' 一致，才能经标题搜索唯一命中。
    final SourceLibraryRow source =
        await _source(db, directory, fileName: 'Show (2018).mkv');
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report = await scrape(
      VideoSourceScrapeCoordinator(
        primaryProvider: VideoMetadataProviderKind.mal,
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
        registry:
            VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
        identityMapping: _mapping(
          '[{"anidb_id":13491,"mal_id":42,"themoviedb_id":{"tv":62564},'
          '"season":{"tmdb":0},"type":"MOVIE"}]',
        ),
      ),
      source,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(tmdb.fetchedKinds, isNotEmpty, reason: 'TMDB 补充仍然要做');
    expect(
      tmdb.fetchedKinds,
      everyElement(VideoMetadataMediaKind.movie),
      reason: '电影只该按 /movie 补',
    );
    expect(tmdb.fetchedIds, isNot(contains('62564')),
        reason: 'tv 空间的 id 不能当电影 id 拉');
    expect(tmdb.searchCalls, greaterThan(0),
        reason: '映射没有电影空间的 TMDB id，回退标题补充');
    expect(tmdb.searchYears.first, 2018,
        reason: '主源没给年份时用本地目录年份做年份门，不能只凭标题判精确命中');
  });

  // BUG-3071：BUG-2828 修复前绑错的存量（identity 表只存 TMDB id、读回来按作品
  // 形态还原成 movie lookup）重刮时排在映射前面复用，照样拉 /movie/62564——修复版
  // 里重刮也救不回。第一轮用「映射说 62564 是电影」造出这份存量，第二轮换成真实
  // 映射（`{tv: 62564}`）重刮。
  test(
      'rescrape drops a stored TMDB id that the mapping places in the other '
      'namespace (BUG-3071)', () async {
    final SourceLibraryRow source =
        await _source(db, directory, fileName: 'Show (2018).mkv');
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider staleTmdb = _Provider(VideoMetadataProviderKind.tmdb);
    await scrape(
      VideoSourceScrapeCoordinator(
        primaryProvider: VideoMetadataProviderKind.mal,
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
        registry: VideoMetadataProviderRegistry(
            <VideoMetadataProvider>[mal, staleTmdb]),
        identityMapping: _mapping(
          '[{"anidb_id":13491,"mal_id":42,"themoviedb_id":{"movie":[62564]},'
          '"type":"MOVIE"}]',
        ),
      ),
      source,
    );
    expect(staleTmdb.fetchedIds, contains('62564'), reason: '造出绑错的存量');

    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report = await scrape(
      VideoSourceScrapeCoordinator(
        primaryProvider: VideoMetadataProviderKind.mal,
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
        registry:
            VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
        identityMapping: _mapping(
          '[{"anidb_id":13491,"mal_id":42,"themoviedb_id":{"tv":62564},'
          '"season":{"tmdb":0},"type":"MOVIE"}]',
        ),
      ),
      source,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(tmdb.fetchedIds, isNot(contains('62564')),
        reason: '映射说 62564 在 tv 空间，存量里的 movie 62564 不能再拉');
    final List<String> storedTmdb = <String>[
      for (final VideoMetadataProviderIdentityRow row
          in await db.select(db.videoMetadataProviderIdentities).get())
        if (row.provider == 'tmdb' &&
            row.seasonId == null &&
            row.episodeId == null &&
            row.personKey == null &&
            row.characterKey == null)
          row.externalId,
    ];
    expect(storedTmdb, isNot(contains('62564')), reason: '绑错的交叉引用不再写回');
  });

  // 本地年份是「这一季」的，TMDB 剧的年份是第一季首播：续作季拿本地年份当门
  // 会把正确的剧挡在 ±1 年外（审查发现，与 Shoko 的无年份查询变体同理）。
  test('sequel season does not gate the TMDB show search on its local year',
      () async {
    final SourceLibraryRow source =
        await _source(db, directory, fileName: 'Show S02E01 (2019).mkv');
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    await scrape(
      VideoSourceScrapeCoordinator(
        primaryProvider: VideoMetadataProviderKind.mal,
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
        registry:
            VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
        identityMapping: _mapping('[]'),
      ),
      source,
    );
    expect(tmdb.searchCalls, greaterThan(0), reason: '没有映射，标题补充');
    expect(tmdb.searchYears, everyElement(isNull));
  });

  test('offline identity of a movie filed under a TMDB show skips the tv id',
      () async {
    final SourceLibraryRow source = await _source(db, directory,
        title: 'リズと青い鳥', fileName: 'リズと青い鳥 (2018).mkv');
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report = await scrape(
      VideoSourceScrapeCoordinator(
        primaryProvider: VideoMetadataProviderKind.mal,
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
        registry:
            VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
        offlineIdentityResolver: AnimeOfflineIdentityResolver.custom(
          search: (String query) async => <AniDbTitleSearchResult>[
            if (query == 'リズと青い鳥') _hit(13491, query),
          ],
          entryForAnidb: (int anidbId) async => AnimeIdentityEntry(
            anidbId: anidbId,
            malIds: const <int>{35677},
            tmdbId: 62564,
            tmdbSeason: 0,
            type: 'MOVIE',
          ),
        ),
      ),
      source,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(mal.fetchedIds, contains('35677'));
    expect(tmdb.fetchedIds, isNot(contains('62564')));
    expect(tmdb.fetchedKinds, everyElement(VideoMetadataMediaKind.movie));
  });
}

AnimeOfflineIdentityResolver _offline(Map<String, int> exactByTitle) =>
    AnimeOfflineIdentityResolver.custom(
      search: (String query) async => <AniDbTitleSearchResult>[
        if (exactByTitle[query] case final int animeId) _hit(animeId, query),
      ],
      entryForAnidb: (int anidbId) async => anidbId == 17617
          ? AnimeIdentityEntry(
              anidbId: 17617,
              malIds: const <int>{52991},
              tmdbId: 209867,
              tmdbSeason: 1,
              type: 'TV',
            )
          : null,
    );

AniDbTitleSearchResult _hit(int animeId, String title) {
  final AniDbTitle matched =
      AniDbTitle(value: title, type: 'official', language: 'zh-Hans');
  return AniDbTitleSearchResult(
    record: AniDbTitleRecord(animeId: animeId, titles: <AniDbTitle>[matched]),
    matchedTitle: matched,
    kind: AniDbTitleMatchKind.exact,
    similarity: 1,
  );
}

AnimeIdentityMapping _mapping(String body) => AnimeIdentityMapping(
      httpClient: VideoMetadataHttpClient(
        client: MockClient((_) async => http.Response(body, 200)),
      ),
    );

Future<SourceLibraryRow> _source(
  FushiDatabase db,
  Directory root, {
  String title = 'Show',
  String? fileName,
}) async {
  final int sourceId = await db.insertMediaSource(MediaSourcesCompanion.insert(
    label: 'Source',
    mediaKind: 'video',
    rootPath: root.path,
    createdAt: 1,
  ));
  // 带集号 → 剧集形态（离线阶段的类型闸门按 TV 过滤）。
  final File file = File(p.join(root.path, fileName ?? '$title - 01.mkv'));
  await file.writeAsBytes(<int>[0]);
  await db.upsertVideoBook(VideoBooksCompanion(
    bookUid: const Value<String>('book-0'),
    title: Value<String>(title),
    videoPath: Value<String>(file.path),
    sourceId: Value<int?>(sourceId),
  ));
  await db.upsertVideoSourceScrapeSettings(
    VideoSourceScrapeSettingsCompanion.insert(
      sourceId: Value<int>(sourceId),
      writeNfo: const Value<bool>(false),
      writeImages: const Value<bool>(false),
      updatedAt: 1,
    ),
  );
  return (await db.getMediaSourceById(sourceId))!;
}

class _Provider implements VideoMetadataProvider {
  _Provider(this.providerKind, {this.failure});

  @override
  final VideoMetadataProviderKind providerKind;
  final Exception? failure;
  int searchCalls = 0;
  final List<String> fetchedIds = <String>[];
  final List<VideoMetadataMediaKind> fetchedKinds = <VideoMetadataMediaKind>[];
  final List<int?> searchYears = <int?>[];

  @override
  bool get isAvailable => true;

  VideoMetadataWork _work(String id, VideoMetadataMediaKind kind) =>
      VideoMetadataWork(
        provider: providerKind,
        kind: kind,
        title: 'Show',
        plot: '${providerKind.name} plot',
        ids: <VideoMetadataId>[
          VideoMetadataId(type: providerKind.name, value: id, isDefault: true),
        ],
        images: <VideoMetadataImage>[
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: 'https://example.com/poster.jpg',
            provider: providerKind,
          ),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    searchCalls++;
    searchYears.add(request.year);
    if (failure != null) throw failure!;
    return <VideoMetadataWork>[_work('42', request.mediaKind)];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    fetchedIds.add(lookup.externalId);
    fetchedKinds.add(lookup.mediaKind);
    if (failure != null) throw failure!;
    return _work(lookup.externalId, lookup.mediaKind);
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
          VideoMetadataLookup lookup) async =>
      const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
          {required int seasonNumber}) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}
