import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_download_path_mapping.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

const String _torrentHash = '0123456789abcdef0123456789abcdef01234567';
const VideoDownloadBackendIdentity _backendIdentity =
    VideoDownloadBackendIdentity(
  kind: 'embedded',
  profileId: 'embedded',
  fingerprint: 'integration-installation',
  category: 'hibiki-video',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerVideoDiscoveryDownloadPipelineTests();
}

void registerVideoDiscoveryDownloadPipelineTests() {
  test('发现资源完整进入下载、整理、字幕、导入和精确刮削闭环', () async {
    final Directory sandbox =
        await Directory.systemTemp.createTemp('hibiki-video-pipeline-itest-');
    final Directory incoming = Directory(p.join(sandbox.path, 'incoming'));
    final Directory library = Directory(p.join(sandbox.path, 'library'));
    await incoming.create(recursive: true);
    await library.create(recursive: true);
    final File downloaded1 = File(p.join(incoming.path, 'Show.S01E01.mkv'));
    final File downloaded2 = File(p.join(incoming.path, 'Show.S01E02.mkv'));
    await downloaded1.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
    await downloaded2.writeAsBytes(<int>[5, 6, 7, 8], flush: true);

    final _TrackingDatabase database =
        _TrackingDatabase(NativeDatabase.memory());
    final _ResourceProvider resourceProvider = _ResourceProvider();
    final VideoResourceRegistry resourceRegistry =
        VideoResourceRegistry(<VideoResourceProvider>[resourceProvider]);
    final _SubtitleProvider subtitleProvider = _SubtitleProvider();
    final VideoSubtitleRegistry subtitleRegistry =
        VideoSubtitleRegistry(<VideoSubtitleProvider>[subtitleProvider]);
    final _MetadataProvider metadataProvider = _MetadataProvider();
    final VideoMetadataProviderRegistry metadataRegistry =
        VideoMetadataProviderRegistry(<VideoMetadataProvider>[
      metadataProvider,
    ]);
    final _NoImages noImages = _NoImages();
    late final VideoSourceScrapeCoordinator scrapeCoordinator;
    late final VideoDownloadPipelineService pipeline;
    try {
      final int sourceId = await database.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Managed videos',
          mediaKind: 'video',
          rootPath: library.path,
          createdAt: 1,
        ),
      );
      await database.upsertVideoSourceScrapeSettings(
        VideoSourceScrapeSettingsCompanion.insert(
          sourceId: Value<int>(sourceId),
          providerOverride: const Value<String?>('anilist'),
          writeNfo: const Value<bool>(true),
          writeImages: const Value<bool>(false),
          fanartEnabled: const Value<bool>(false),
          updatedAt: 1,
        ),
      );
      scrapeCoordinator = VideoSourceScrapeCoordinator(
        database: database,
        config: const VideoSourceScrapeGlobalConfig(
          primaryProvider: VideoMetadataProviderKind.anilist,
        ),
        registry: metadataRegistry,
        fanartProvider: noImages,
      );
      final _MovingTorrentBackend backend = _MovingTorrentBackend(
        incomingRoot: incoming,
        libraryRoot: library,
      );
      pipeline = VideoDownloadPipelineService(
        database: database,
        resourceRegistry: resourceRegistry,
        subtitleRegistry: subtitleRegistry,
        backendResolver: (_) async => VideoDownloadBackendBinding(
          backend: backend,
          identity: _backendIdentity,
          pathMappings: <VideoDownloadPathMapping>[
            VideoDownloadPathMapping(
              remoteRoot: '/downloads',
              localRoot: incoming.path,
            ),
            VideoDownloadPathMapping(
              remoteRoot: '/media',
              localRoot: library.path,
            ),
          ],
        ),
        scrapeCoordinator: scrapeCoordinator,
        preferredSubtitleLanguages: const <String>['zh-cn'],
        workerId: 'video-pipeline-itest',
        pollInterval: const Duration(milliseconds: 20),
      );

      final String jobId = await pipeline.enqueue(
        VideoDownloadEnqueueRequest(
          media: VideoMediaReference(
            providerId: 'anilist',
            mediaId: '100',
            mediaKind: VideoMetadataMediaKind.tv,
            discoveryCategory: VideoDiscoveryCategory.anime,
            title: 'Show',
            year: 2026,
            season: 1,
            anilistId: 100,
          ),
          resource: resourceProvider.candidate,
          backendIdentity: _backendIdentity,
          targetSourceId: sourceId,
          subtitlePolicy: VideoDownloadSubtitlePolicy.required,
        ),
      );
      final VideoDownloadJobRow completed = await _waitForJob(
        database,
        jobId,
        (VideoDownloadJobRow row) =>
            row.lifecycle == VideoDownloadJobLifecycle.completed,
      );

      expect(completed.stage, VideoDownloadJobStage.scrape);
      expect(completed.targetSourceId, sourceId);
      expect(backend.addCalls, 1);
      expect(backend.renameCalls, 2);
      expect(backend.moveCalls, 1);
      expect(resourceProvider.searchCalls, 1);
      expect(resourceProvider.resolveCalls, 1);
      expect(subtitleProvider.searchCalls, 2);
      expect(subtitleProvider.downloadCalls, 2);
      expect(metadataProvider.searchCalls, 0,
          reason: '发现页身份必须走 confirmed lookup，禁止标题搜索');
      expect(metadataProvider.fetchCalls, 1);
      expect(database.videoLibraryRefreshCalls, 2,
          reason: '导入后与元数据应用后各刷新一次当前视频库');

      final File video = File(p.join(
        library.path,
        'Show (2026)',
        'Season 01',
        'Show (2026) - S01E01.mkv',
      ));
      final File subtitle = File(p.setExtension(video.path, '.zh-cn.srt'));
      expect(await downloaded1.exists(), isFalse);
      expect(await downloaded2.exists(), isFalse);
      expect(await video.readAsBytes(), <int>[1, 2, 3, 4]);
      expect(await subtitle.readAsString(),
          '1\n00:00:00,000 --> 00:00:01,000\n字幕\n');

      final List<VideoBookRow> books = await database.allVideoBooks();
      expect(books, hasLength(2));
      final VideoBookRow firstBook = books.firstWhere(
        (VideoBookRow row) => row.videoPath == video.path,
      );
      expect(
          books.every((VideoBookRow row) => row.sourceId == sourceId), isTrue);
      expect(firstBook.subtitleSource, subtitle.path);
      final List<VideoDownloadJobFileRow> jobFiles =
          await database.getVideoDownloadJobFiles(jobId);
      expect(jobFiles, hasLength(2));
      expect(
        jobFiles.every(
          (VideoDownloadJobFileRow row) =>
              row.status == VideoDownloadJobFileStatus.imported,
        ),
        isTrue,
      );
      expect(
        jobFiles.map((VideoDownloadJobFileRow row) => row.finalAbsolutePath),
        contains(video.path),
      );
      final List<VideoDownloadJobSubtitleRow> subtitles =
          await database.getVideoDownloadJobSubtitles(jobId);
      expect(subtitles, hasLength(2));
      expect(
        subtitles.every(
          (VideoDownloadJobSubtitleRow row) =>
              row.status == VideoDownloadJobSubtitleStatus.placed,
        ),
        isTrue,
      );
      expect(
        subtitles.map((VideoDownloadJobSubtitleRow row) => row.finalPath),
        contains(subtitle.path),
      );

      final File showNfo =
          File(p.join(library.path, 'Show (2026)', 'tvshow.nfo'));
      final File seasonNfo = File(p.join(
        library.path,
        'Show (2026)',
        'Season 01',
        'season.nfo',
      ));
      final File episodeNfo = File(p.setExtension(video.path, '.nfo'));
      expect(await showNfo.exists(), isTrue);
      expect(await seasonNfo.exists(), isTrue);
      expect(await episodeNfo.exists(), isTrue);
      expect(await episodeNfo.readAsString(), contains('<title>Pilot</title>'));
      final VideoMetadataWorkRow? metadata =
          await database.getVideoMetadataWorkByCollection(
        completed.collectionId!,
      );
      expect(metadata?.title, 'Show');
      final List<VideoMetadataProviderIdentityRow> identities =
          await database.getVideoMetadataProviderIdentities(
        workId: metadata!.id,
      );
      expect(identities.single.provider, 'anilist');
      expect(identities.single.externalId, '100');
      final List<VideoSourceScrapeRunRow> scrapeRuns =
          await database.getVideoSourceScrapeRuns(sourceId: sourceId);
      expect(scrapeRuns.single.scope, 'work');
      expect(scrapeRuns.single.status, 'completed');
    } finally {
      if (pipeline case final VideoDownloadPipelineService service) {
        await service.dispose();
      }
      if (scrapeCoordinator case final VideoSourceScrapeCoordinator value) {
        value.close();
      }
      resourceRegistry.close();
      subtitleRegistry.close();
      metadataRegistry.close();
      noImages.close();
      await database.close();
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    }
  });
}

Future<VideoDownloadJobRow> _waitForJob(
  FushiDatabase database,
  String jobId,
  bool Function(VideoDownloadJobRow row) predicate,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final VideoDownloadJobRow? row = await database.getVideoDownloadJob(jobId);
    if (row != null && predicate(row)) return row;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException(
    'job did not complete: ${await database.getVideoDownloadJob(jobId)}',
  );
}

class _TrackingDatabase extends FushiDatabase {
  _TrackingDatabase(super.executor) : super.forTesting();

  int videoLibraryRefreshCalls = 0;

  @override
  void notifyVideoLibraryChanged() {
    videoLibraryRefreshCalls += 1;
    super.notifyVideoLibraryChanged();
  }
}

class _ResourceCandidate extends VideoResourceCandidate {
  _ResourceCandidate()
      : super(
          providerId: 'nyaa',
          providerInstanceId: 'integration',
          remoteId: 'release-1',
          title: 'Show S01E01',
          providerPriority: 0,
          infoHash: _torrentHash,
          trusted: true,
        );
}

class _ResourceProvider implements VideoResourceProvider {
  final _ResourceCandidate candidate = _ResourceCandidate();
  int searchCalls = 0;
  int resolveCalls = 0;

  @override
  String get id => 'nyaa';

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    searchCalls += 1;
    return ProviderBatchResult<VideoResourceCandidate>.success(
      <VideoResourceCandidate>[candidate],
    );
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async {
    resolveCalls += 1;
    return const TorrentMagnetPayload(
      magnetUri: 'magnet:?xt=urn:btih:$_torrentHash',
      torrentId: _torrentHash,
    );
  }

  @override
  void close() {}
}

class _SubtitleCandidate extends VideoSubtitleCandidate {
  _SubtitleCandidate(int episode)
      : super(
          providerId: 'jimaku',
          remoteId: 'subtitle-$episode',
          fileName: 'Show.S01E${episode.toString().padLeft(2, '0')}.zh-cn.srt',
          language: 'zh-cn',
          providerPriority: 0,
          season: 1,
          episode: episode,
        );
}

class _SubtitleProvider implements VideoSubtitleProvider {
  int searchCalls = 0;
  int downloadCalls = 0;

  @override
  String get id => 'jimaku';

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    searchCalls += 1;
    return ProviderBatchResult<VideoSubtitleCandidate>.success(
      <VideoSubtitleCandidate>[_SubtitleCandidate(request.effectiveEpisode!)],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    downloadCalls += 1;
    return VideoSubtitleDownload(
      bytes: Uint8List.fromList(
        utf8.encode('1\n00:00:00,000 --> 00:00:01,000\n字幕\n'),
      ),
      fileName: candidate.fileName,
      language: candidate.language,
    );
  }

  @override
  void close() {}
}

class _MovingTorrentBackend implements TorrentBackend {
  _MovingTorrentBackend({
    required this.incomingRoot,
    required this.libraryRoot,
  });

  final Directory incomingRoot;
  final Directory libraryRoot;
  final Map<int, String> originalRelativePaths = <int, String>{
    0: 'Show.S01E01.mkv',
    1: 'Show.S01E02.mkv',
  };
  final Map<int, String> currentRelativePaths = <int, String>{
    0: 'Show.S01E01.mkv',
    1: 'Show.S01E02.mkv',
  };
  int addCalls = 0;
  int renameCalls = 0;
  int moveCalls = 0;

  @override
  Future<String?> probeConnection() async => 'integration';

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    addCalls += 1;
    return true;
  }

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      const <TorrentSnapshot>[
        TorrentSnapshot(
          hash: _torrentHash,
          name: 'Show',
          progress: 1,
          state: 'uploading',
          savePath: '/downloads',
          contentPath: '/downloads/Show.S01E01.mkv',
          amountLeft: 0,
        ),
      ];

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      currentRelativePaths.entries
          .map(
            (MapEntry<int, String> entry) => TorrentFileEntry(
              name: entry.value,
              size: 4,
              progress: 1,
              index: entry.key,
            ),
          )
          .toList(growable: false);

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async {
    renameCalls += 1;
    currentRelativePaths[fileIndex] = newPath;
    return TorrentStorageResult(ok: true, path: newPath);
  }

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async {
    moveCalls += 1;
    if (newSavePath != '/media') {
      return const TorrentStorageResult.failure('unexpected save path');
    }
    for (final MapEntry<int, String> entry in originalRelativePaths.entries) {
      final File source = File(p.join(incomingRoot.path, entry.value));
      final File target = File(p.joinAll(<String>[
        libraryRoot.path,
        ...currentRelativePaths[entry.key]!.split('/'),
      ]));
      await target.parent.create(recursive: true);
      await source.rename(target.path);
    }
    return TorrentStorageResult(ok: true, path: newSavePath);
  }

  @override
  void close() {}
}

class _MetadataProvider implements VideoMetadataProvider {
  int searchCalls = 0;
  int fetchCalls = 0;

  VideoMetadataWork get work => VideoMetadataWork(
        provider: VideoMetadataProviderKind.anilist,
        kind: VideoMetadataMediaKind.tv,
        title: 'Show',
        year: 2026,
        seasonCount: 1,
        episodeCount: 2,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'anilist', value: '100', isDefault: true),
        ],
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
            seasonNumber: 1,
            title: 'Season 1',
            episodeCount: 2,
          ),
        ],
      );

  @override
  VideoMetadataProviderKind get providerKind =>
      VideoMetadataProviderKind.anilist;

  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    searchCalls += 1;
    return <VideoMetadataWork>[work];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    fetchCalls += 1;
    return lookup.externalId == '100' ? work : null;
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      work.seasons;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      <VideoMetadataEpisode>[
        VideoMetadataEpisode(
          seasonNumber: 1,
          episodeNumber: 1,
          title: 'Pilot',
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'anilist', value: '100-1'),
          ],
        ),
        VideoMetadataEpisode(
          seasonNumber: 1,
          episodeNumber: 2,
          title: 'Second',
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'anilist', value: '100-2'),
          ],
        ),
      ];

  @override
  void close() {}
}

class _NoImages implements VideoMetadataImageProvider {
  @override
  bool get isAvailable => false;

  @override
  Future<List<VideoMetadataImage>> fetchImages(VideoMetadataWork work) async =>
      const <VideoMetadataImage>[];

  @override
  void close() {}
}
