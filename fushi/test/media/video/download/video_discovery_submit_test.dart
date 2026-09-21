import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/download/video_discovery_submit.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_media_reference_codec.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

/// `video_discovery_submit.dart` 是从 `home_page.dart` 两处 `onSubmit` 逐字搬出
/// 的落库形状；这里钉的是搬迁后与原实现一致的字段口径（订阅 mode / 策略 /
/// 默认搜索词 / createdAt 保留 / 身份快照 / checkNow 触发，以及入队行的落点字段）。

const String _torrentHash = '0123456789abcdef0123456789abcdef01234567';
const int _firstAt = 1000;
const int _secondAt = 2000;

const VideoDownloadBackendIdentity _identity = VideoDownloadBackendIdentity(
  kind: 'embedded',
  profileId: 'embedded',
  fingerprint: 'installation-fingerprint',
);
const VideoDownloadBackendTarget _target = VideoDownloadBackendTarget(
  identity: _identity,
  category: 'fushi-video',
);

Future<FushiDatabase> _openDatabase() async {
  final FushiDatabase database = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (CommonDatabase raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(database.close);
  return database;
}

Future<MediaSourceRow> _insertVideoSource(
  FushiDatabase database, {
  String rootPath = r'D:\Videos',
}) async {
  final int id = await database.insertMediaSource(
    MediaSourcesCompanion.insert(
      label: 'Managed videos',
      mediaKind: 'video',
      rootPath: rootPath,
      createdAt: _firstAt,
    ),
  );
  return (await database.getMediaSourceById(id))!;
}

VideoMediaReference _reference({
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
  VideoDiscoveryCategory category = VideoDiscoveryCategory.anime,
}) =>
    VideoMediaReference(
      providerId: 'mal',
      mediaId: '100',
      mediaKind: kind,
      discoveryCategory: category,
      title: 'Show',
      originalTitle: 'ショー',
      aliases: const <String>['Show'],
      year: 2026,
      season: 1,
      tmdbId: 77,
    );

VideoDiscoveryItem _item(VideoMediaReference reference) => VideoDiscoveryItem(
      reference: reference,
      posterUrl: 'https://img.example/cover.jpg',
    );

VideoDiscoveryDownloadSelection _download({
  required VideoMediaReference media,
  required MediaSourceRow source,
  required VideoResourceCandidate resource,
  VideoDownloadSubtitlePolicy subtitlePolicy =
      VideoDownloadSubtitlePolicy.required,
}) =>
    VideoDiscoveryDownloadSelection(
      media: media,
      resource: resource,
      source: source,
      subtitlePolicy: subtitlePolicy,
    );

VideoDiscoverySubscriptionSelection _subscription({
  required VideoDiscoveryDownloadSelection download,
  int? startAfterEpisode,
  bool batchRelease = false,
}) =>
    VideoDiscoverySubscriptionSelection(
      download: download,
      filter: const StrictVideoSubscriptionFilter(
        json: '{"resolution":"1080p"}',
        releaseGroup: null,
        resolution: '1080p',
        summaryParts: <String>['1080p'],
      ),
      startAfterEpisode: startAfterEpisode,
      batchRelease: batchRelease,
    );

void main() {
  group('videoResourceSubscriptionSearchQuery', () {
    test('anime 走 Nyaa 首选搜索词', () {
      final VideoMediaReference reference = _reference();
      final List<String> preferred = preferredNyaaSearchQueries(
        VideoResourceSearchRequest(media: reference),
      );
      expect(preferred, isNotEmpty);
      expect(videoResourceSubscriptionSearchQuery(reference), preferred.first);
    });

    test('非 anime 直接用标题', () {
      final VideoMediaReference reference = _reference(
        category: VideoDiscoveryCategory.tv,
      );
      expect(videoResourceSubscriptionSearchQuery(reference), 'Show');
    });
  });

  group('createLocalVideoDownloadSubscription', () {
    test('movie → oneShot，落库字段与提交选择一致，checkNow 触发一次', () async {
      final FushiDatabase database = await _openDatabase();
      final MediaSourceRow source = await _insertVideoSource(database);
      final VideoMediaReference reference = _reference(
        kind: VideoMetadataMediaKind.movie,
      );
      final VideoDiscoveryItem item = _item(reference);
      int checkNowCalls = 0;

      await createLocalVideoDownloadSubscription(
        database: database,
        reference: item.reference,
        coverUrl: item.posterUrl,
        selection: _subscription(
          download: _download(
            media: reference,
            source: source,
            resource: _FakeResourceCandidate(),
            subtitlePolicy: VideoDownloadSubtitlePolicy.none,
          ),
          startAfterEpisode: 3,
        ),
        target: _target,
        checkNow: () async => checkNowCalls += 1,
        nowMs: _firstAt,
      );

      final VideoDownloadSubscriptionRow row =
          (await database.getVideoDownloadSubscription(
              videoDiscoverySubscriptionId(reference)))!;
      expect(checkNowCalls, 1);
      expect(row.mode, 'oneShot');
      expect(row.organizationPolicy, 'library');
      expect(row.subtitlePolicy, VideoDownloadSubtitlePolicy.none.name);
      expect(row.searchQuery, videoResourceSubscriptionSearchQuery(reference));
      expect(row.resourceProvider, 'nyaa:test-instance');
      expect(row.metadataProvider, 'mal');
      expect(row.externalId, '100');
      expect(row.mediaKind, 'movie');
      expect(row.discoveryCategory, 'anime');
      expect(row.coverUrl, 'https://img.example/cover.jpg');
      expect(row.filterJson, '{"resolution":"1080p"}');
      expect(row.startAfterEpisode, 3);
      expect(row.backendKind, _identity.kind);
      expect(row.backendProfileId, _identity.profileId);
      expect(row.fingerprint, _identity.fingerprint);
      expect(row.category, 'fushi-video');
      expect(row.targetSourceId, source.id);
      expect(row.enabled, isTrue);
      expect(row.nextCheckAt, _firstAt);
      expect(row.createdAt, _firstAt);
      expect(row.updatedAt, _firstAt);

      final VideoMediaReference decoded =
          decodeVideoMediaReference(row.identityJson)!;
      expect(decoded.title, reference.title);
      expect(decoded.mediaId, reference.mediaId);
      expect(decoded.providerId, reference.providerId);
      expect(decoded.tmdbId, 77);
    });

    test('整包 → oneShot（TV 也一样）：追更语义下整包永远不是「新的一集」', () async {
      // BUG-2619：判据从 HomePage 搬进这里时曾经只剩 mediaKind==movie，用户从 BD
      // 全集包建的订阅又变回 ongoing，展开永远是「还没有跟踪到任何发布」。这条漏了
      // 不会有任何别的测试变红，所以必须单独钉。
      final FushiDatabase database = await _openDatabase();
      final MediaSourceRow source = await _insertVideoSource(database);
      final VideoMediaReference reference = _reference(
        kind: VideoMetadataMediaKind.tv,
      );
      final VideoDiscoveryItem item = _item(reference);

      await createLocalVideoDownloadSubscription(
        database: database,
        reference: item.reference,
        coverUrl: item.posterUrl,
        selection: _subscription(
          batchRelease: true,
          download: _download(
            media: reference,
            source: source,
            resource: _FakeResourceCandidate(),
            subtitlePolicy: VideoDownloadSubtitlePolicy.none,
          ),
        ),
        target: _target,
      );

      final List<VideoDownloadSubscriptionRow> rows =
          await database.getVideoDownloadSubscriptions();
      expect(rows.single.mode, 'oneShot');
      await database.close();
    });

    test('tv → ongoing；显式 searchQuery 覆盖默认；二次提交保留 createdAt', () async {
      final FushiDatabase database = await _openDatabase();
      final MediaSourceRow source = await _insertVideoSource(database);
      final VideoMediaReference reference = _reference();
      final VideoDiscoveryItem item = _item(reference);
      final VideoDiscoverySubscriptionSelection selection = _subscription(
        download: _download(
          media: reference,
          source: source,
          resource: _FakeResourceCandidate(),
        ),
      );
      final String subscriptionId = videoDiscoverySubscriptionId(reference);

      await createLocalVideoDownloadSubscription(
        database: database,
        reference: item.reference,
        coverUrl: item.posterUrl,
        selection: selection,
        target: _target,
        nowMs: _firstAt,
      );
      final VideoDownloadSubscriptionRow first =
          (await database.getVideoDownloadSubscription(subscriptionId))!;
      expect(first.mode, 'ongoing');
      expect(first.subtitlePolicy, VideoDownloadSubtitlePolicy.required.name);
      expect(first.startAfterEpisode, isNull);
      expect(first.createdAt, _firstAt);
      expect(first.updatedAt, _firstAt);

      await createLocalVideoDownloadSubscription(
        database: database,
        reference: item.reference,
        coverUrl: item.posterUrl,
        selection: selection,
        target: _target,
        searchQuery: 'custom query',
        nowMs: _secondAt,
      );
      final VideoDownloadSubscriptionRow second =
          (await database.getVideoDownloadSubscription(subscriptionId))!;
      expect(second.searchQuery, 'custom query');
      expect(second.createdAt, _firstAt);
      expect(second.updatedAt, _secondAt);
      expect(second.nextCheckAt, _secondAt);
      expect(
        (await database.getVideoDownloadSubscriptions()).length,
        1,
        reason: '同一作品同一稳定 id，二次提交只 upsert',
      );
    });
  });

  group('enqueueLocalVideoDownload', () {
    test('入队行带落点来源 / 封面 / 字幕策略', () async {
      final FushiDatabase database = await _openDatabase();
      final Directory root =
          await Directory.systemTemp.createTemp('fushi-discovery-submit-');
      addTearDown(() => root.delete(recursive: true));
      final MediaSourceRow source =
          await _insertVideoSource(database, rootPath: root.path);
      final _FakeResourceCandidate resource = _FakeResourceCandidate();
      final VideoResourceRegistry resourceRegistry = VideoResourceRegistry(
        <VideoResourceProvider>[_FakeResourceProvider(resource)],
      );
      addTearDown(resourceRegistry.close);
      final VideoMetadataProviderRegistry metadataRegistry =
          VideoMetadataProviderRegistry(const <VideoMetadataProvider>[]);
      addTearDown(metadataRegistry.close);
      final VideoSourceScrapeCoordinator scrapeCoordinator =
          VideoSourceScrapeCoordinator(
        database: database,
        config: const VideoSourceScrapeGlobalConfig(),
        registry: metadataRegistry,
      );
      addTearDown(scrapeCoordinator.close);
      // 后端未装配：入队只落库，wake 后的处理轮以 action-required 收场，
      // 不影响这里断言的落点字段。
      final VideoDownloadPipelineService pipeline =
          VideoDownloadPipelineService(
        database: database,
        resourceRegistry: resourceRegistry,
        backendResolver: (_) async => null,
        scrapeCoordinator: scrapeCoordinator,
        workerId: 'discovery-submit-test-worker',
        pollInterval: const Duration(hours: 1),
        videoCoversDirectory: Directory('${root.path}/covers'),
      );
      addTearDown(pipeline.dispose);
      final VideoMediaReference reference = _reference();
      final VideoDiscoveryItem item = _item(reference);

      final String jobId = await enqueueLocalVideoDownload(
        pipeline: pipeline,
        coverUrl: item.posterUrl,
        selection: _download(
          media: reference,
          source: source,
          resource: resource,
          subtitlePolicy: VideoDownloadSubtitlePolicy.bestEffort,
        ),
        target: _target,
      );

      final VideoDownloadJobRow job =
          (await database.getVideoDownloadJob(jobId))!;
      expect(job.targetSourceId, source.id);
      expect(job.coverUrl, 'https://img.example/cover.jpg');
      expect(job.subtitlePolicy, VideoDownloadSubtitlePolicy.bestEffort.name);
      expect(job.resourceProvider, 'nyaa:test-instance');
      expect(job.selectedResourceId, 'release-1');
      expect(job.torrentHash, _torrentHash);
      expect(job.metadataProvider, 'mal');
      expect(job.externalId, '100');
      expect(job.fingerprint, _identity.fingerprint);
      expect(job.category, 'fushi-video');
      expect(job.organizationPolicy, 'library');
      expect(
        decodeVideoMediaReference(job.identityJson)!.title,
        reference.title,
      );
    });
  });
}

class _FakeResourceCandidate extends VideoResourceCandidate {
  _FakeResourceCandidate()
      : super(
          providerId: 'nyaa',
          providerInstanceId: 'test-instance',
          remoteId: 'release-1',
          title: 'Show S01E01',
          providerPriority: 0,
          infoHash: _torrentHash,
        );
}

class _FakeResourceProvider implements VideoResourceProvider {
  _FakeResourceProvider(this.candidate);

  final VideoResourceCandidate candidate;

  @override
  String get id => 'nyaa';

  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async =>
      ProviderBatchResult<VideoResourceCandidate>.success(
        <VideoResourceCandidate>[candidate],
      );

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      const TorrentMagnetPayload(
        magnetUri: 'magnet:?xt=urn:btih:$_torrentHash',
        torrentId: _torrentHash,
      );

  @override
  void close() {}
}
