import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/anime_episode_relations.dart';
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

/// 设计稿 B：多季一张卡。一个本地合集含多季（季目录 / 绝对集号）时，用 Fribb
/// 同一 TMDB 剧的季条目序列把各季映射到各自 MAL id 逐季抓分集，绝对集号经
/// anime-relations 重定向；卡片仍是这一个合集。
///
/// 数据形状照 Frieren 真实条目：S1 = MAL 52991 / anidb 17617（28 集），
/// S2 = MAL 59978 / anidb 18886（tmdb 同剧 209867，offset 28）；
/// anime-relations：`52991:29-38 -> 59978:1-10!`。
const String _fribb = '['
    '{"anidb_id":17617,"mal_id":52991,"themoviedb_id":{"tv":209867},'
    '"season":{"tvdb":1,"tmdb":1},"type":"TV"},'
    '{"anidb_id":18886,"mal_id":59978,"themoviedb_id":{"tv":209867},'
    '"season":{"tvdb":2,"tmdb":1},"episode_offset":{"tmdb":28},"type":"TV"}'
    ']';
const String _relations = '::meta\n- version: 1\n\n::rules\n'
    '- 52991|46474|154587:29-38 -> 59978|49240|182255:1-10!\n';

void main() {
  late FushiDatabase db;
  late Directory directory;
  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    // 目录名里不能带 season 字样：parseVideoPath 会从父目录名回落季号。
    directory = await Directory.systemTemp.createTemp('frieren-lib-');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<SourceScrapeReport> scrape(
    _MalProvider mal, {
    required List<String> fileNames,
    bool withRelations = true,
  }) async {
    final SourceLibraryRow source = await _source(db, directory, fileNames);
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(),
      registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal]),
      identityMapping: AnimeIdentityMapping(
        httpClient: VideoMetadataHttpClient(
          client: MockClient((_) async => http.Response(_fribb, 200)),
        ),
      ),
      episodeRelations: withRelations
          ? AnimeEpisodeRelationsCatalog(
              httpClient: VideoMetadataHttpClient(
                client: MockClient((_) async => http.Response(_relations, 200)),
              ),
            )
          : null,
    );
    addTearDown(coordinator.close);
    return coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
  }

  Future<Map<(int, int), String?>> boundEpisodes() async {
    final MediaCollectionRow collection =
        (await db.getMediaCollectionByNaturalKey('Frieren', 'playlist'))!;
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByCollection(collection.id))!;
    final Map<(int, int), String?> result = <(int, int), String?>{};
    for (final VideoMetadataSeasonRow season
        in await db.getVideoMetadataSeasons(work.id)) {
      for (final VideoMetadataEpisodeRow episode
          in await db.getVideoMetadataEpisodes(season.id)) {
        result[(season.seasonNumber, episode.episodeNumber)] = episode.bookUid;
      }
    }
    return result;
  }

  test('season folders fetch each season from its own MAL entry', () async {
    final _MalProvider mal = _MalProvider();
    final SourceScrapeReport report = await scrape(mal, fileNames: <String>[
      'Frieren S01E01.mkv',
      'Frieren S02E01.mkv',
      'Frieren S02E02.mkv',
    ]);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(mal.fetchedIds, containsAll(<String>['52991', '59978']));
    final Map<(int, int), String?> bound = await boundEpisodes();
    expect(bound[(1, 1)], 'book-0');
    expect(bound[(2, 1)], 'book-1');
    expect(bound[(2, 2)], 'book-2');
    expect(bound.keys.where(((int, int) key) => key.$1 == 2), hasLength(10));
  });

  test('absolute numbering is redirected through anime-relations', () async {
    final _MalProvider mal = _MalProvider();
    final SourceScrapeReport report = await scrape(mal, fileNames: <String>[
      '[Sub] Frieren - 01.mkv',
      '[Sub] Frieren - 28.mkv',
      '[Sub] Frieren - 29.mkv',
      '[Sub] Frieren - 30.mkv',
    ]);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), String?> bound = await boundEpisodes();
    expect(bound[(1, 1)], 'book-0');
    expect(bound[(1, 28)], 'book-1');
    expect(bound[(2, 1)], 'book-2', reason: '29 → S2E1（anime-relations）');
    expect(bound[(2, 2)], 'book-3');
    expect(bound[(1, 29)], isNull);
  });

  test('without a relation rule the season episode counts decide', () async {
    final _MalProvider mal = _MalProvider();
    final SourceScrapeReport report = await scrape(
      mal,
      fileNames: <String>['[Sub] Frieren - 01.mkv', '[Sub] Frieren - 30.mkv'],
      withRelations: false,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), String?> bound = await boundEpisodes();
    expect(bound[(2, 2)], 'book-1', reason: '30 − 28 = S2E2（按季集数累加）');
  });

  test('an absolute number past every known season stays unverified', () async {
    final _MalProvider mal = _MalProvider();
    final SourceScrapeReport report = await scrape(
      mal,
      fileNames: <String>['[Sub] Frieren - 01.mkv', '[Sub] Frieren - 99.mkv'],
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), String?> bound = await boundEpisodes();
    expect(bound.values, isNot(contains('book-1')));
    expect(
      report.warnings
          .any((SourceScrapeIssue issue) => issue.message.contains('绝对集号 99')),
      isTrue,
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
      await db.createMediaCollection('Frieren', collectionType: 'playlist');
  for (int index = 0; index < fileNames.length; index++) {
    final File file = File(p.join(root.path, fileNames[index]));
    await file.writeAsBytes(<int>[0]);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value<String>('book-$index'),
      title: const Value<String>('Frieren'),
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

/// MAL 假源：52991 = 第一季 28 集、59978 = 第二季 10 集；标题搜索只回第一季。
class _MalProvider implements VideoMetadataProvider {
  final List<String> fetchedIds = <String>[];
  int searchCalls = 0;

  static const Map<String, (String, int)> _entries = <String, (String, int)>{
    '52991': ('Sousou no Frieren', 28),
    '59978': ('Sousou no Frieren 2nd Season', 10),
  };

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.mal;

  @override
  bool get isAvailable => true;

  VideoMetadataWork? _work(String id) {
    final (String, int)? entry = _entries[id];
    if (entry == null) return null;
    return VideoMetadataWork(
      provider: providerKind,
      kind: VideoMetadataMediaKind.tv,
      title: entry.$1,
      aliases: const <String>['Frieren'],
      episodeCount: entry.$2,
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'mal', value: id, isDefault: true),
      ],
    );
  }

  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    searchCalls++;
    return <VideoMetadataWork>[_work('52991')!];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    fetchedIds.add(lookup.externalId);
    return _work(lookup.externalId);
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
      VideoMetadataLookup lookup) async {
    final VideoMetadataWork? work = _work(lookup.externalId);
    if (work == null) return const <VideoMetadataSeason>[];
    return <VideoMetadataSeason>[
      VideoMetadataSeason(
        seasonNumber: 1,
        title: work.title,
        episodeCount: work.episodeCount,
        ids: work.ids,
      ),
    ];
  }

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
      {required int seasonNumber}) async {
    final (String, int)? entry = _entries[lookup.externalId];
    if (entry == null || seasonNumber != 1) {
      return const <VideoMetadataEpisode>[];
    }
    return <VideoMetadataEpisode>[
      for (int number = 1; number <= entry.$2; number++)
        VideoMetadataEpisode(
          seasonNumber: 1,
          episodeNumber: number,
          absoluteNumber: number,
          title: '${entry.$1} #$number',
        ),
    ];
  }

  @override
  void close() {}
}
