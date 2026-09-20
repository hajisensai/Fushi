import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
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

/// Shoko `TmdbSearchService`：映射表没收录的作品，TMDB 补充源只能按标题搜——
/// 沿 MAL Prequel 链回溯到根作品的标题（cour 标题搜不到整部剧）、去年份再搜
/// （多季剧 first_air_date 早于本季年份）、仍歧义按「集数最接近的季 + 首播
/// ±3 天」打分。
void main() {
  late FushiDatabase db;
  late Directory directory;
  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('hxh-lib-');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
      'prequel-chain root title, no-year retry and season scoring pick the '
      'right TMDB show', () async {
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    final SourceLibraryRow source =
        await _source(db, directory, <String>['HxH Chimera S01E01.mkv']);
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      // 本用例测的是 MAL 主源形态（2026-09-20 起默认主源是 AniDB，MAL 仍可选）。
      primaryProvider: VideoMetadataProviderKind.mal,
      database: db,
      config: const VideoSourceScrapeGlobalConfig(),
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
      identityMapping: AnimeIdentityMapping(
        httpClient: VideoMetadataHttpClient(
          client: MockClient((_) async => http.Response('[]', 200)),
        ),
      ),
    );
    addTearDown(coordinator.close);
    final SourceScrapeReport report = await coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
    expect(report.succeededWorks, 1,
        reason:
            '${report.errors.map((SourceScrapeIssue i) => i.message)} ${report.warnings.map((SourceScrapeIssue i) => i.message)}');
    expect(mal.prequelLookups, <String>['99', '11'],
        reason: '沿 Prequel 链走到根（11 没有前传即停）');
    expect(tmdb.searches, contains('Hunter x Hunter'), reason: '用根作品标题搜');
    expect(tmdb.searchYears['Hunter x Hunter'], contains(null),
        reason: '续作不带年份搜（MAL 2020 与剧首播 2011 差太远，年份门会挡掉）');
    final MediaCollectionRow collection =
        (await db.getMediaCollectionByNaturalKey('HxH Chimera', 'playlist'))!;
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByCollection(collection.id) ??
            await db.getVideoMetadataWorkByBook('book-0'))!;
    final List<VideoMetadataProviderIdentityRow> ids =
        await db.getVideoMetadataProviderIdentities(workId: work.id);
    expect(
      ids
          .where((VideoMetadataProviderIdentityRow id) => id.provider == 'tmdb')
          .map((VideoMetadataProviderIdentityRow id) => id.externalId),
      <String>['46298'],
      reason: 'S1 148 集与 MAL 148 集最接近的那部',
    );
    expect(
      report.warnings.any((SourceScrapeIssue issue) =>
          issue.message.contains('按集数最接近的季与首播日选了')),
      isTrue,
      reason: '${report.warnings.map((SourceScrapeIssue i) => i.message)}',
    );
  });
}

Future<SourceLibraryRow> _source(
  FushiDatabase db,
  Directory root,
  List<String> fileNames,
) async {
  final int sourceId = await db.insertMediaSource(MediaSourcesCompanion.insert(
    label: 'Source',
    mediaKind: 'video',
    rootPath: root.path,
    createdAt: 1,
  ));
  final int collectionId =
      await db.createMediaCollection('HxH Chimera', collectionType: 'playlist');
  for (int index = 0; index < fileNames.length; index++) {
    final File file = File(p.join(root.path, fileNames[index]));
    await file.writeAsBytes(<int>[0]);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value<String>('book-$index'),
      title: const Value<String>('HxH Chimera'),
      videoPath: Value<String>(file.path),
      sourceId: Value<int?>(sourceId),
    ));
    await db.addToCollection(collectionId, MediaKind.video, 'book-$index');
  }
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

/// MAL 假源：99 = 「HxH Part 2」（2020，148 集，前传 11）；11 = 「Hunter x Hunter」
/// （根，无前传）。
class _MalProvider
    implements VideoMetadataProvider, VideoMetadataRelationsProvider {
  final List<String> prequelLookups = <String>[];

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.mal;
  @override
  bool get isAvailable => true;

  VideoMetadataWork? _work(String id) => switch (id) {
        '99' => VideoMetadataWork(
            provider: providerKind,
            kind: VideoMetadataMediaKind.tv,
            title: 'Hunter x Hunter: Chimera Ant Arc',
            aliases: const <String>['HxH Chimera'],
            year: 2020,
            premiered: '2020-04-05',
            episodeCount: 148,
            ids: const <VideoMetadataId>[
              VideoMetadataId(type: 'mal', value: '99', isDefault: true),
            ],
          ),
        '11' => VideoMetadataWork(
            provider: providerKind,
            kind: VideoMetadataMediaKind.tv,
            title: 'Hunter x Hunter',
            year: 2011,
            episodeCount: 148,
            ids: const <VideoMetadataId>[
              VideoMetadataId(type: 'mal', value: '11', isDefault: true),
            ],
          ),
        _ => null,
      };

  @override
  Future<List<VideoMetadataWork>> search(
          VideoMetadataSearchRequest request) async =>
      <VideoMetadataWork>[_work('99')!];

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      _work(lookup.externalId);

  @override
  Future<List<VideoMetadataLookup>> fetchPrequels(
      VideoMetadataLookup lookup) async {
    prequelLookups.add(lookup.externalId);
    return lookup.externalId == '99'
        ? const <VideoMetadataLookup>[
            VideoMetadataLookup(
                provider: VideoMetadataProviderKind.mal,
                externalId: '11',
                mediaKind: VideoMetadataMediaKind.tv),
          ]
        : const <VideoMetadataLookup>[];
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
      VideoMetadataLookup lookup) async {
    final VideoMetadataWork? work = _work(lookup.externalId);
    if (work == null) return const <VideoMetadataSeason>[];
    return <VideoMetadataSeason>[
      VideoMetadataSeason(
          seasonNumber: 1, title: work.title, episodeCount: work.episodeCount),
    ];
  }

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
          {required int seasonNumber}) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}

/// TMDB 假源：只有 "Hunter x Hunter" 搜得到，两部同名（2011 版 S1 148 集 /
/// 2013 版 S1 62 集），年份都过不了 ±1（MAL 2020）→ 去年份再搜 → 歧义 → 打分。
class _TmdbProvider implements VideoMetadataProvider {
  final List<String> searches = <String>[];
  final Map<String, List<int?>> searchYears = <String, List<int?>>{};

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;
  @override
  bool get isAvailable => true;

  VideoMetadataWork _show(String id, int year, int episodes, String aired) =>
      VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.tv,
        title: 'Hunter x Hunter',
        year: year,
        ids: <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: id, isDefault: true),
        ],
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
              seasonNumber: 1,
              title: 'Season 1',
              episodeCount: episodes,
              airDate: aired),
        ],
      );

  VideoMetadataWork? _byId(String id) => switch (id) {
        '46298' => _show('46298', 2011, 148, '2011-10-02'),
        '1234' => _show('1234', 2013, 62, '2013-01-01'),
        _ => null,
      };

  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    searches.add(request.title);
    (searchYears[request.title] ??= <int?>[]).add(request.year);
    if (request.title != 'Hunter x Hunter') return const <VideoMetadataWork>[];
    return <VideoMetadataWork>[_byId('46298')!, _byId('1234')!];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      _byId(lookup.externalId);

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
          VideoMetadataLookup lookup) async =>
      _byId(lookup.externalId)?.seasons ?? const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
          {required int seasonNumber}) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}
