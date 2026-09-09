import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/scraper/scrape_identifier_words.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 设计稿 C 二期第一项：识别词在刮削链路上的两条端到端事实。
///
/// 1. 替换/屏蔽后的标题真的进了 provider 搜索，本来搜不到的作品能命中；
///    原候选仍保留在后，规则写错不至于把识别整条打死。
/// 2. 集偏移真的改变成员绑定的集号（经 `episodeOverrides` → `localEpisodeKeyFor`）。
void main() {
  late FushiDatabase db;
  late Directory directory;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('idwords-lib-');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<SourceScrapeReport> scrape(
    _MalProvider mal, {
    required String localTitle,
    required List<String> fileNames,
    String identifierWords = '',
  }) async {
    final SourceLibraryRow source =
        await _source(db, directory, localTitle, fileNames);
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: VideoSourceScrapeGlobalConfig(
        identifierWords:
            ScrapeIdentifierWords.parse(identifierWords).identifierWords,
      ),
      registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal]),
    );
    addTearDown(coordinator.close);
    return coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
  }

  Future<Map<(int, int), String?>> boundEpisodes(String localTitle) async {
    final MediaCollectionRow collection =
        (await db.getMediaCollectionByNaturalKey(localTitle, 'playlist'))!;
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

  test('without identifier words the mismatched local title finds nothing',
      () async {
    final _MalProvider mal = _MalProvider();
    final SourceScrapeReport report = await scrape(
      mal,
      localTitle: 'Kusuriya',
      fileNames: <String>['Kusuriya - 01.mkv'],
    );
    expect(report.succeededWorks, 0);
  });

  test('a replace word rewrites the candidate so the work matches', () async {
    final _MalProvider mal = _MalProvider();
    final SourceScrapeReport report = await scrape(
      mal,
      localTitle: 'Kusuriya',
      fileNames: <String>['Kusuriya - 01.mkv'],
      identifierWords: '# 把本地叫法改写成 provider 认识的标题\nKusuriya => Frieren',
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(mal.searchedTitles.first, 'Frieren', reason: '改写结果排在原候选之前');
    // 命中即止，所以原候选不会被真的搜一次；候选表本身必须保留它，
    // 规则写错时才还有按原标题搜的机会。
    expect(
      applyScrapeIdentifierWordsToCandidates(
        <String>['Kusuriya'],
        ScrapeIdentifierWords.parse('Kusuriya => Frieren').identifierWords,
      ),
      <String>['Frieren', 'Kusuriya'],
    );
  });

  test('a block word deletes the release group from the candidate', () async {
    final _MalProvider mal = _MalProvider();
    final SourceScrapeReport report = await scrape(
      mal,
      localTitle: 'Nekomoe kissaten Frieren',
      fileNames: <String>['Nekomoe kissaten Frieren - 01.mkv'],
      identifierWords: 'Nekomoe kissaten ',
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(mal.searchedTitles.first, 'Frieren');
  });

  test('an episode offset changes the episode a member binds to', () async {
    final _MalProvider mal = _MalProvider();
    final SourceScrapeReport report = await scrape(
      mal,
      localTitle: 'Frieren',
      fileNames: <String>['Frieren - 13.mkv', 'Frieren - 14.mkv'],
      identifierWords: '- <>  >> EP-12',
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), String?> bound = await boundEpisodes('Frieren');
    expect(bound[(1, 1)], 'book-0');
    expect(bound[(1, 2)], 'book-1');
  });

  test('without the offset the same members stay past the season', () async {
    final _MalProvider mal = _MalProvider();
    final SourceScrapeReport report = await scrape(
      mal,
      localTitle: 'Frieren',
      fileNames: <String>['Frieren - 13.mkv', 'Frieren - 14.mkv'],
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), String?> bound = await boundEpisodes('Frieren');
    expect(bound.values, isNot(contains('book-0')));
    expect(bound.values, isNot(contains('book-1')));
  });
}

Future<SourceLibraryRow> _source(
  FushiDatabase db,
  Directory root,
  String title,
  List<String> fileNames,
) async {
  final int sourceId = await db.insertMediaSource(MediaSourcesCompanion.insert(
    label: 'Source',
    mediaKind: 'video',
    rootPath: root.path,
    createdAt: 1,
  ));
  final int collectionId =
      await db.createMediaCollection(title, collectionType: 'playlist');
  for (int index = 0; index < fileNames.length; index++) {
    final File file = File(p.join(root.path, fileNames[index]));
    await file.writeAsBytes(<int>[0]);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value<String>('book-$index'),
      title: Value<String>(title),
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

/// MAL 假源：只认识 `Frieren`（12 集），并记录每次搜索用的标题。
class _MalProvider implements VideoMetadataProvider {
  final List<String> searchedTitles = <String>[];

  static const String _title = 'Frieren';
  static const int _episodeCount = 12;

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.mal;

  @override
  bool get isAvailable => true;

  VideoMetadataWork get _work => VideoMetadataWork(
        provider: VideoMetadataProviderKind.mal,
        kind: VideoMetadataMediaKind.tv,
        title: _title,
        episodeCount: _episodeCount,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'mal', value: '52991', isDefault: true),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    searchedTitles.add(request.title);
    return <VideoMetadataWork>[_work];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      _work;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
          VideoMetadataLookup lookup) async =>
      <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: _title,
          episodeCount: _episodeCount,
        ),
      ];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
      {required int seasonNumber}) async {
    if (seasonNumber != 1) return const <VideoMetadataEpisode>[];
    return <VideoMetadataEpisode>[
      for (int number = 1; number <= _episodeCount; number++)
        VideoMetadataEpisode(
          seasonNumber: 1,
          episodeNumber: number,
          absoluteNumber: number,
          title: '$_title #$number',
        ),
    ];
  }

  @override
  void close() {}
}
