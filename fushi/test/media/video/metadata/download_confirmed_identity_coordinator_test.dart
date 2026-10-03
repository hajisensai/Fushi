import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_media_reference_codec.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:path/path.dart' as p;

/// BUG-2796：下载任务确认过的身份是持久的。下载那一轮因资料源临时故障没刮成
/// 时，之后的补刮 / 整源刮削（调用方不传任何已确认身份）必须照这份身份直取，
/// 而不是按标题（俗称「fx外汇战士」）去搜；作品已有规范身份时不得被它覆盖。
void main() {
  late FushiDatabase db;
  late Directory directory;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('download-identity-');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  const String localTitle = 'fx外汇战士';

  Future<(SourceLibraryRow, int)> library() async {
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Source',
        mediaKind: 'video',
        rootPath: directory.path,
        createdAt: 1,
      ),
    );
    final int collectionId =
        await db.createMediaCollection(localTitle, collectionType: 'playlist');
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: 'job-1',
        resourceProvider: 'nyaa',
        selectedResourceId: 'release',
        metadataProvider: const Value<String?>('anilist'),
        externalId: const Value<String?>('206401'),
        identityJson: Value<String?>(
          encodeVideoMediaReference(
            VideoMediaReference(
              providerId: 'anilist',
              mediaId: '206401',
              mediaKind: VideoMetadataMediaKind.tv,
              discoveryCategory: VideoDiscoveryCategory.anime,
              title: 'FX戦士くるみちゃん',
              externalIds: const <String, String>{'mal': '63337'},
            ),
          ),
        ),
        mediaKind: VideoMetadataMediaKind.tv.name,
        title: 'FX戦士くるみちゃん',
        backendKind: 'embedded',
        fingerprint: 'fp',
        collectionId: Value<int?>(collectionId),
        lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
        createdAt: now,
        updatedAt: now,
      ),
    );
    for (int index = 0; index < 2; index++) {
      final File file =
          File(p.join(directory.path, '$localTitle - 0${index + 1}.mkv'));
      await file.writeAsBytes(<int>[0]);
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>('book-$index'),
          title: const Value<String>(localTitle),
          videoPath: Value<String>(file.path),
          sourceId: Value<int?>(sourceId),
        ),
      );
      await db.addToCollection(collectionId, MediaKind.video, 'book-$index');
      await db.upsertVideoDownloadJobFile(
        VideoDownloadJobFilesCompanion.insert(
          jobId: 'job-1',
          backendFileIndex: Value<int?>(index),
          originalRelativePath: p.basename(file.path),
          currentRelativePath: p.basename(file.path),
          finalAbsolutePath: Value<String?>(file.path),
          kind: const Value<String>('video'),
          status: const Value<String>(VideoDownloadJobFileStatus.imported),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(sourceId),
        writeNfo: const Value<bool>(false),
        writeImages: const Value<bool>(false),
        updatedAt: 1,
      ),
    );
    return ((await db.getMediaSourceById(sourceId))!, collectionId);
  }

  Future<SourceScrapeReport> scrape(
    SourceLibraryRow source,
    _MalProvider mal,
  ) {
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      primaryProvider: VideoMetadataProviderKind.mal,
      database: db,
      config: const VideoSourceScrapeGlobalConfig(),
      registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal]),
    );
    addTearDown(coordinator.close);
    return coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
  }

  test('没传已确认身份也照下载任务确认的身份直取，不按俗称搜索', () async {
    final (SourceLibraryRow source, int collectionId) = await library();
    final _MalProvider mal = _MalProvider();

    final SourceScrapeReport report = await scrape(source, mal);

    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(mal.fetchedIds, contains('63337'));
    expect(mal.searchedTitles, isEmpty);
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByCollection(collectionId))!;
    expect(work.title, 'FX戦士くるみちゃん');
  });

  test('作品已有规范身份（可能是用户手动改过的绑定）→ 不被下载身份覆盖', () async {
    final (SourceLibraryRow source, int collectionId) = await library();
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Manually bound',
        updatedAt: 1,
      ),
    );
    await db.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:mal',
          workId: Value<int?>(workId),
          provider: 'mal',
          externalId: '1',
          isPrimary: const Value<bool>(true),
          updatedAt: 1,
        ),
      ],
    );
    final _MalProvider mal = _MalProvider();

    await scrape(source, mal);

    expect(mal.fetchedIds, contains('1'), reason: '按已有规范身份刮过');
    expect(mal.fetchedIds, isNot(contains('63337')));
  });
}

/// MAL 假源：按标题搜不到任何东西（俗称），按 id 取资料恒能取到。
class _MalProvider implements VideoMetadataProvider {
  final List<String> searchedTitles = <String>[];
  final List<String> fetchedIds = <String>[];

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.mal;

  @override
  bool get isAvailable => true;

  VideoMetadataWork _work(String id) => VideoMetadataWork(
        provider: VideoMetadataProviderKind.mal,
        kind: VideoMetadataMediaKind.tv,
        title: id == '63337' ? 'FX戦士くるみちゃん' : 'Manually bound',
        episodeCount: 12,
        ids: <VideoMetadataId>[
          VideoMetadataId(type: 'mal', value: id, isDefault: true),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    searchedTitles.add(request.title);
    return const <VideoMetadataWork>[];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    fetchedIds.add(lookup.externalId);
    return _work(lookup.externalId);
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      <VideoMetadataSeason>[
        VideoMetadataSeason(seasonNumber: 1, title: 'S1', episodeCount: 12),
      ];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      <VideoMetadataEpisode>[
        for (int number = 1; number <= 12; number++)
          VideoMetadataEpisode(
            seasonNumber: 1,
            episodeNumber: number,
            absoluteNumber: number,
            title: '#$number',
          ),
      ];

  @override
  void close() {}
}
