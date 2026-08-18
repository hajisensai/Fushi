import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_download_subscription_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';

const int _nowAt = 1000;

Future<FushiDatabase> _openDatabase() async {
  final FushiDatabase database = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (CommonDatabase raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(database.close);
  return database;
}

Future<int> _insertVideoSource(FushiDatabase database) =>
    database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Managed videos',
        mediaKind: 'video',
        rootPath: r'D:\Videos',
        createdAt: _nowAt,
      ),
    );

Future<void> _insertSubscription(
  FushiDatabase database, {
  required String id,
  required int sourceId,
  required String resourceProvider,
  required String mediaKind,
  required String discoveryCategory,
  required Map<String, Object?> filters,
  String mode = 'ongoing',
  int? startAfterEpisode,
  int? season,
}) =>
    database.upsertVideoDownloadSubscription(
      VideoDownloadSubscriptionsCompanion.insert(
        subscriptionId: id,
        resourceProvider: resourceProvider,
        metadataProvider: const Value<String?>('anilist'),
        externalId: Value<String?>('media-$id'),
        mediaKind: mediaKind,
        discoveryCategory: Value<String?>(discoveryCategory),
        title: 'Example Show',
        season: Value<int?>(season),
        searchQuery: 'Example Show',
        filterJson: Value<String>(jsonEncode(filters)),
        mode: Value<String>(mode),
        startAfterEpisode: Value<int?>(startAfterEpisode),
        backendKind: 'embedded',
        backendProfileId: const Value<String?>('embedded'),
        fingerprint: 'backend-fingerprint',
        category: const Value<String?>('fushi-video'),
        targetSourceId: Value<int?>(sourceId),
        createdAt: _nowAt,
        updatedAt: _nowAt,
        nextCheckAt: const Value<int?>(_nowAt),
      ),
    );

Future<String> _persistFakeJob(
  FushiDatabase database,
  VideoDownloadEnqueueRequest request,
  String jobId,
) async {
  await database.upsertVideoDownloadJob(
    VideoDownloadJobsCompanion.insert(
      jobId: jobId,
      resourceProvider: persistedVideoResourceProviderId(request.resource),
      selectedResourceId: request.resource.remoteId,
      resourceTitle: Value<String?>(request.resource.title),
      torrentHash: Value<String?>(request.resource.infoHash),
      metadataProvider: Value<String?>(request.media.providerId),
      externalId: Value<String?>(request.media.mediaId),
      mediaKind: request.media.mediaKind.name,
      discoveryCategory: Value<String?>(request.media.discoveryCategory.name),
      title: request.media.title,
      season: Value<int?>(request.media.season),
      backendKind: request.backendIdentity.kind,
      backendProfileId: Value<String?>(request.backendIdentity.profileId),
      fingerprint: request.backendIdentity.fingerprint,
      category: Value<String?>(request.backendIdentity.category),
      targetSourceId: Value<int?>(request.targetSourceId),
      subtitlePolicy: Value<String>(request.subtitlePolicy.name),
      createdAt: _nowAt,
      updatedAt: _nowAt,
    ),
  );
  return jobId;
}

VideoDownloadSubscriptionService _service({
  required FushiDatabase database,
  required VideoResourceProvider provider,
  required VideoDownloadSubscriptionEnqueue enqueue,
  Duration checkInterval = const Duration(minutes: 15),
  Duration leaseDuration = const Duration(minutes: 2),
  DateTime Function()? now,
}) {
  final VideoDownloadSubscriptionService service =
      VideoDownloadSubscriptionService(
    database: database,
    resourceRegistry: VideoResourceRegistry(<VideoResourceProvider>[provider]),
    enqueue: enqueue,
    workerId: 'subscription-test-worker',
    checkInterval: checkInterval,
    leaseDuration: leaseDuration,
    now: now ?? () => DateTime.fromMillisecondsSinceEpoch(_nowAt),
  );
  addTearDown(service.dispose);
  return service;
}

void main() {
  test(
      'Nyaa strict rules include the selected first episode and persist outbox',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'anime',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      season: 1,
      startAfterEpisode: 1,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'SubsPlease',
        'resolution': '1080p',
        'trustedOnly': true,
        'nyaaCategory': '1_2',
      },
    );
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'nyaa',
      candidates: <VideoResourceCandidate>[
        _candidate(remoteId: 'old', episode: 1),
        _candidate(remoteId: 'wrong-group', episode: 2, group: 'Other'),
        _candidate(
            remoteId: 'wrong-resolution', episode: 2, resolution: '720p'),
        _candidate(remoteId: 'untrusted', episode: 2, trusted: false),
        _candidate(remoteId: 'episode-2-low', episode: 2, seeders: 2),
        _candidate(remoteId: 'episode-2-best', episode: 2, seeders: 20),
        _candidate(remoteId: 'episode-3', episode: 3, seeders: 5),
      ],
    );
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) async {
        final List<VideoDownloadSubscriptionItemRow> outbox =
            await database.getVideoDownloadSubscriptionItems('anime');
        expect(
          outbox.any(
            (VideoDownloadSubscriptionItemRow item) =>
                item.selectedResourceId == request.resource.remoteId &&
                item.status == VideoDownloadSubscriptionItemStatus.discovered,
          ),
          isTrue,
          reason: 'enqueue 外部动作前必须先持久化逻辑集选择',
        );
        enqueued.add(request);
        return _persistFakeJob(
          database,
          request,
          'job-${enqueued.length}',
        );
      },
    );

    await service.checkNow();

    expect(service.checkInterval, const Duration(minutes: 15));
    expect(
      enqueued
          .map((VideoDownloadEnqueueRequest value) => value.resource.remoteId),
      <String>['old', 'episode-2-best', 'episode-3'],
    );
    final List<VideoDownloadSubscriptionItemRow> items =
        await database.getVideoDownloadSubscriptionItems('anime');
    expect(
      items.map(
          (VideoDownloadSubscriptionItemRow value) => value.logicalItemKey),
      <String>['S01E01', 'S01E02', 'S01E03'],
    );
    expect(
      items.every(
        (VideoDownloadSubscriptionItemRow item) =>
            item.status == VideoDownloadSubscriptionItemStatus.queued &&
            item.jobId != null,
      ),
      isTrue,
    );
    final VideoDownloadSubscriptionRow row =
        (await database.getVideoDownloadSubscription('anime'))!;
    expect(
        row.nextCheckAt, _nowAt + const Duration(minutes: 15).inMilliseconds);
    expect(row.retryCount, 0);
    expect(row.lastError, isNull);
  });

  test('anime roman numeral title uses the canonical third-season key',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'mushoku-iii',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      startAfterEpisode: 1,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'Erai-raws',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'nyaa',
        candidates: <VideoResourceCandidate>[
          _candidate(
            remoteId: 'mushoku-iii-02',
            mediaTitle: '[Erai-raws] Mushoku Tensei III: '
                'Isekai Ittara Honki Dasu - 02 [1080p]',
            group: 'Erai-raws',
          ),
        ],
      ),
      enqueue: (VideoDownloadEnqueueRequest request) async {
        enqueued.add(request);
        return _persistFakeJob(database, request, 'mushoku-iii-job');
      },
    );

    await service.checkNow();

    expect(enqueued, hasLength(1));
    expect(enqueued.single.media.season, 3);
    expect(enqueued.single.media.episode, 2);
    final VideoDownloadSubscriptionItemRow item =
        (await database.getVideoDownloadSubscriptionItems('mushoku-iii'))
            .single;
    expect(item.logicalItemKey, 'S03E02');
    expect(item.season, 3);
    expect(item.episode, 2);
  });

  test('confirmed local episode is skipped before another release is enqueued',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'local-episode',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      startAfterEpisode: 1,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'Erai-raws',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final int collectionId = await database.createMediaCollection(
      'Mushoku Tensei III',
      collectionType: 'playlist',
    );
    await database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/mushoku-iii-s03e02'),
        title: const Value<String>('Mushoku Tensei III - S03E02'),
        videoPath: const Value<String>(r'D:\Videos\Mushoku.S03E02.mkv'),
        sourceId: Value<int?>(sourceId),
      ),
    );
    await database.addToCollection(
      collectionId,
      MediaKind.video,
      'video/mushoku-iii-s03e02',
    );
    final int workId = await database.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Mushoku Tensei III',
        updatedAt: _nowAt,
      ),
    );
    await database.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:anilist',
          provider: 'anilist',
          externalId: 'media-local-episode',
          isPrimary: const Value<bool>(true),
          updatedAt: _nowAt,
        ),
      ],
    );
    int enqueueCount = 0;
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'nyaa',
        candidates: <VideoResourceCandidate>[
          _candidate(
            remoteId: 'duplicate-s03e02',
            mediaTitle: '[Erai-raws] Mushoku Tensei III: '
                'Isekai Ittara Honki Dasu - 02 [1080p]',
            group: 'Erai-raws',
          ),
        ],
      ),
      enqueue: (VideoDownloadEnqueueRequest _) async {
        enqueueCount++;
        return 'unexpected-job';
      },
    );

    await service.checkNow();

    expect(enqueueCount, 0);
    final VideoDownloadSubscriptionItemRow item =
        (await database.getVideoDownloadSubscriptionItems('local-episode'))
            .single;
    expect(item.logicalItemKey, 'S03E02');
    expect(item.status, VideoDownloadSubscriptionItemStatus.skipped);
    expect(item.jobId, isNull);
  });

  test('explicit Nyaa backfill traverses beyond 100 releases continuously',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'anime-backfill',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      season: 1,
      startAfterEpisode: 70,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'SubsPlease',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final List<VideoResourceCandidate> firstPage = <VideoResourceCandidate>[
      _candidate(remoteId: 'p1-100-low', episode: 100, seeders: 1),
      ...List<VideoResourceCandidate>.generate(
        74,
        (int index) {
          final int episode = 127 + index;
          return _candidate(
            remoteId: 'p1-$episode',
            episode: episode,
            seeders: episode,
          );
        },
      ),
    ];
    final List<VideoResourceCandidate> secondPage = <VideoResourceCandidate>[
      ...List<VideoResourceCandidate>.generate(
        56,
        (int index) {
          final int episode = 71 + index;
          return _candidate(
            remoteId: 'p2-$episode',
            episode: episode,
            seeders: episode == 100 ? 500 : episode,
          );
        },
      ),
      _candidate(
        remoteId: 'p2-101-wrong-group',
        episode: 101,
        group: 'Other',
        seeders: 9999,
      ),
    ];
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'nyaa',
      resultsByPage: <int, ProviderBatchResult<VideoResourceCandidate>>{
        1: ProviderBatchResult<VideoResourceCandidate>.success(firstPage),
        2: ProviderBatchResult<VideoResourceCandidate>.success(secondPage),
      },
    );
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) async {
        enqueued.add(request);
        return _persistFakeJob(
          database,
          request,
          'backfill-job-${enqueued.length}',
        );
      },
    );

    await service.checkNow();

    expect(provider.requestedPages, <int>[1, 2]);
    expect(provider.requestedLimits, everyElement(75));
    expect(enqueued, hasLength(130));
    final List<int> episodes = enqueued
        .map((VideoDownloadEnqueueRequest request) => request.media.episode!)
        .toList()
      ..sort();
    expect(episodes, List<int>.generate(130, (int index) => index + 71));
    expect(
      enqueued
          .singleWhere(
            (VideoDownloadEnqueueRequest request) =>
                request.media.episode == 100,
          )
          .resource
          .remoteId,
      'p2-100',
      reason: '同一 SxxExx 必须跨页选严格规则内的最佳版本且只入队一次',
    );
    expect(
      enqueued
          .singleWhere(
            (VideoDownloadEnqueueRequest request) =>
                request.media.episode == 101,
          )
          .resource
          .remoteId,
      'p2-101',
      reason: '后续页的高做种错误发布组不能绕过严格版本锁定',
    );
    final List<VideoDownloadSubscriptionItemRow> items =
        await database.getVideoDownloadSubscriptionItems('anime-backfill');
    expect(items, hasLength(130));
    expect(
      items
          .map((VideoDownloadSubscriptionItemRow item) => item.logicalItemKey)
          .toSet(),
      hasLength(130),
    );
  });

  test('a repeated full provider page stops pagination without duplicate jobs',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'anime-repeat-page',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      season: 1,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'SubsPlease',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final List<VideoResourceCandidate> repeated =
        List<VideoResourceCandidate>.generate(
      75,
      (int index) => _candidate(
        remoteId: 'repeat-${index + 1}',
        episode: index + 1,
      ),
    );
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'nyaa',
      resultsByPage: <int, ProviderBatchResult<VideoResourceCandidate>>{
        1: ProviderBatchResult<VideoResourceCandidate>.success(repeated),
        2: ProviderBatchResult<VideoResourceCandidate>.success(repeated),
      },
    );
    int enqueueCount = 0;
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) async {
        enqueueCount++;
        return _persistFakeJob(database, request, 'repeat-job-$enqueueCount');
      },
    );

    await service.checkNow();

    expect(provider.requestedPages, <int>[1, 2]);
    expect(enqueueCount, 75);
    expect(
      await database.getVideoDownloadSubscriptionItems('anime-repeat-page'),
      hasLength(75),
    );
  });

  test('full changing pages stop at the bounded per-check safety limit',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'anime-page-cap',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      season: 1,
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'SubsPlease',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final Map<int, ProviderBatchResult<VideoResourceCandidate>> pages =
        <int, ProviderBatchResult<VideoResourceCandidate>>{};
    for (int page = 1; page <= 20; page++) {
      pages[page] = ProviderBatchResult<VideoResourceCandidate>.success(
        List<VideoResourceCandidate>.generate(75, (int index) {
          final int release = page * 100 + index;
          return _FakeResourceCandidate(
            providerId: 'nyaa',
            instanceId: 'nyaa.si',
            remoteId: 'page-$page-release-$index',
            title: '[SubsPlease] Example Show - 1 [1080p]',
            infoHash: release.toRadixString(16).padLeft(40, '0'),
            releaseGroup: 'SubsPlease',
            resolution: '1080p',
            trusted: true,
            seeders: release,
            category: '1_2',
          );
        }),
      );
    }
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'nyaa',
      resultsByPage: pages,
    );
    int enqueueCount = 0;
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) async {
        enqueueCount++;
        return _persistFakeJob(database, request, 'page-cap-job');
      },
    );

    await service.checkNow();

    expect(provider.requestedPages, List<int>.generate(20, (int i) => i + 1));
    expect(enqueueCount, 1, reason: '1,500 个版本仍只能生成一个 S01E01 逻辑项');
  });

  test(
      'oneShot reconciles a persisted job after crash and never enqueues twice',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'movie',
      sourceId: sourceId,
      resourceProvider: 'torznab:indexer-a',
      mediaKind: 'movie',
      discoveryCategory: 'movie',
      mode: 'oneShot',
      filters: <String, Object?>{
        'strict': true,
        'quality': '1080p',
        'source': 'WEB-DL',
        'codec': 'HEVC',
        'language': 'Dual Audio',
      },
    );
    final VideoResourceCandidate candidate = _candidate(
      providerId: 'torznab',
      instanceId: 'indexer-a',
      remoteId: 'movie-release',
      mediaTitle: 'Example Movie 1080p WEB-DL x265 Dual-Audio',
      episode: null,
      group: null,
      resolution: null,
      category: 'movies',
    );
    await database.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: 'movie',
        logicalItemKey: 'movie',
        resourceProvider: 'torznab:indexer-a',
        selectedResourceId: candidate.remoteId,
        torrentHash: Value<String?>(candidate.infoHash),
        title: candidate.title,
        discoveredAt: _nowAt,
        updatedAt: _nowAt,
      ),
    );
    await database.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: 'persisted-job',
        resourceProvider: 'torznab:indexer-a',
        selectedResourceId: candidate.remoteId,
        torrentHash: Value<String?>(candidate.infoHash),
        metadataProvider: const Value<String?>('anilist'),
        externalId: const Value<String?>('media-movie'),
        mediaKind: 'movie',
        discoveryCategory: const Value<String?>('movie'),
        title: 'Example Movie',
        backendKind: 'embedded',
        backendProfileId: const Value<String?>('embedded'),
        fingerprint: 'backend-fingerprint',
        category: const Value<String?>('fushi-video'),
        targetSourceId: Value<int?>(sourceId),
        createdAt: _nowAt,
        updatedAt: _nowAt,
      ),
    );
    int enqueueCount = 0;
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'torznab',
        candidates: <VideoResourceCandidate>[candidate],
      ),
      enqueue: (VideoDownloadEnqueueRequest _) async {
        enqueueCount++;
        return 'unexpected-job';
      },
    );

    await service.checkNow();

    expect(enqueueCount, 0);
    final VideoDownloadSubscriptionItemRow item =
        (await database.getVideoDownloadSubscriptionItems('movie')).single;
    expect(item.jobId, 'persisted-job');
    expect(item.status, VideoDownloadSubscriptionItemStatus.queued);
    final VideoDownloadSubscriptionRow subscription =
        (await database.getVideoDownloadSubscription('movie'))!;
    expect(subscription.enabled, isFalse);
    expect(subscription.fulfilledAt, _nowAt);
  });

  test('Torznab selected codec and language never silently downgrade',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'strict-tv',
      sourceId: sourceId,
      resourceProvider: 'torznab:indexer-a',
      mediaKind: 'tv',
      discoveryCategory: 'tv',
      season: 1,
      filters: <String, Object?>{
        'strict': true,
        'quality': '1080p',
        'source': 'WEB-DL',
        'codec': 'HEVC',
        'language': 'Dual Audio',
      },
    );
    int enqueueCount = 0;
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'torznab',
        candidates: <VideoResourceCandidate>[
          _candidate(
            providerId: 'torznab',
            instanceId: 'indexer-a',
            remoteId: 'downgraded',
            mediaTitle: 'Example Show S01E02 1080p WEB-DL AVC Japanese',
            episode: null,
            group: null,
            resolution: null,
          ),
        ],
      ),
      enqueue: (VideoDownloadEnqueueRequest _) async {
        enqueueCount++;
        return 'unexpected-job';
      },
    );

    await service.checkNow();

    expect(enqueueCount, 0);
    expect(
      await database.getVideoDownloadSubscriptionItems('strict-tv'),
      isEmpty,
    );
  });

  test('provider errors use exponential retry and redact credential URLs',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'retry',
      sourceId: sourceId,
      resourceProvider: 'nyaa',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      filters: <String, Object?>{
        'strict': true,
        'releaseGroup': 'SubsPlease',
        'resolution': '1080p',
        'trustedOnly': true,
      },
    );
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'nyaa',
        result: ProviderBatchResult<VideoResourceCandidate>.failure(
          const ExternalProviderFailure(
            providerId: 'nyaa',
            operation: 'search',
            kind: ExternalProviderFailureKind.network,
            message: 'request failed https://example.test/?apikey=top-secret',
            retryable: true,
          ),
        ),
      ),
      enqueue: (VideoDownloadEnqueueRequest _) async => 'unused',
    );

    await service.checkNow();

    final VideoDownloadSubscriptionRow first =
        (await database.getVideoDownloadSubscription('retry'))!;
    expect(first.retryCount, 1);
    expect(
        first.nextCheckAt, _nowAt + const Duration(minutes: 15).inMilliseconds);
    expect(first.lastError, contains('<redacted>'));
    expect(first.lastError, isNot(contains('top-secret')));
    expect(first.claimedBy, isNull);
  });

  test('start triggers an immediate due check', () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'startup',
      sourceId: sourceId,
      resourceProvider: 'torznab:indexer-a',
      mediaKind: 'movie',
      discoveryCategory: 'movie',
      mode: 'oneShot',
      filters: <String, Object?>{'strict': true, 'quality': '1080p'},
    );
    final VideoResourceCandidate candidate = _candidate(
      providerId: 'torznab',
      instanceId: 'indexer-a',
      remoteId: 'startup-release',
      mediaTitle: 'Example Movie 1080p',
      episode: null,
      group: null,
      resolution: null,
    );
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: _FakeResourceProvider(
        id: 'torznab',
        candidates: <VideoResourceCandidate>[candidate],
      ),
      enqueue: (VideoDownloadEnqueueRequest request) =>
          _persistFakeJob(database, request, 'startup-job'),
    );

    service.start();
    for (int attempt = 0; attempt < 20; attempt++) {
      final VideoDownloadSubscriptionRow row =
          (await database.getVideoDownloadSubscription('startup'))!;
      if (row.fulfilledAt != null) break;
      await pumpEventQueue();
    }

    final VideoDownloadSubscriptionRow row =
        (await database.getVideoDownloadSubscription('startup'))!;
    expect(row.fulfilledAt, _nowAt);
    expect(row.enabled, isFalse);
  });

  test('long provider search renews the subscription lease', () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'lease-heartbeat',
      sourceId: sourceId,
      resourceProvider: 'torznab:indexer-a',
      mediaKind: 'movie',
      discoveryCategory: 'movie',
      mode: 'oneShot',
      filters: <String, Object?>{'strict': true, 'quality': '1080p'},
    );
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'torznab',
      pauseSearch: true,
      candidates: <VideoResourceCandidate>[
        _candidate(
          providerId: 'torznab',
          instanceId: 'indexer-a',
          remoteId: 'lease-release',
          mediaTitle: 'Example Movie 1080p',
          episode: null,
          group: null,
          resolution: null,
        ),
      ],
    );
    addTearDown(provider.releaseSearch);
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) =>
          _persistFakeJob(database, request, 'lease-job'),
      leaseDuration: const Duration(milliseconds: 90),
      now: DateTime.now,
    );

    final Future<void> check = service.checkNow();
    await provider.searchEntered.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 240));

    final VideoDownloadSubscriptionRow held =
        (await database.getVideoDownloadSubscription('lease-heartbeat'))!;
    expect(held.claimedBy, 'subscription-test-worker');
    expect(
      held.claimExpiresAt,
      greaterThan(DateTime.now().millisecondsSinceEpoch),
    );
    final VideoDownloadSubscriptionRow? stolen =
        await database.claimNextVideoDownloadSubscription(
      workerId: 'competing-subscription-worker',
      nowAt: DateTime.now().millisecondsSinceEpoch,
      leaseDurationMs: 1000,
    );
    expect(stolen, isNull);

    provider.releaseSearch();
    await check;
    final VideoDownloadSubscriptionRow completed =
        (await database.getVideoDownloadSubscription('lease-heartbeat'))!;
    expect(completed.claimedBy, isNull);
    expect(completed.enabled, isFalse);
    expect(completed.fulfilledAt, isNotNull);
  });

  test('a failed completion CAS does not overwrite the new lease owner',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    await _insertSubscription(
      database,
      id: 'lost-subscription-lease',
      sourceId: sourceId,
      resourceProvider: 'torznab:indexer-a',
      mediaKind: 'movie',
      discoveryCategory: 'movie',
      mode: 'oneShot',
      filters: <String, Object?>{'strict': true, 'quality': '1080p'},
    );
    final _FakeResourceProvider provider = _FakeResourceProvider(
      id: 'torznab',
      pauseSearch: true,
      candidates: <VideoResourceCandidate>[
        _candidate(
          providerId: 'torznab',
          instanceId: 'indexer-a',
          remoteId: 'lost-lease-release',
          mediaTitle: 'Example Movie 1080p',
          episode: null,
          group: null,
          resolution: null,
        ),
      ],
    );
    addTearDown(provider.releaseSearch);
    final VideoDownloadSubscriptionService service = _service(
      database: database,
      provider: provider,
      enqueue: (VideoDownloadEnqueueRequest request) =>
          _persistFakeJob(database, request, 'lost-lease-job'),
    );

    final Future<void> check = service.checkNow();
    await provider.searchEntered.future.timeout(const Duration(seconds: 2));
    await database.updateVideoDownloadSubscription(
      'lost-subscription-lease',
      const VideoDownloadSubscriptionsCompanion(
        claimedBy: Value<String?>('competing-subscription-worker'),
        claimExpiresAt: Value<int?>(_nowAt + 60000),
        updatedAt: Value<int>(_nowAt),
      ),
    );
    provider.releaseSearch();
    await check;

    final VideoDownloadSubscriptionRow row = (await database
        .getVideoDownloadSubscription('lost-subscription-lease'))!;
    expect(row.claimedBy, 'competing-subscription-worker');
    expect(row.enabled, isTrue);
    expect(row.retryCount, 0);
    expect(row.lastError, isNull);
  });
}

VideoResourceCandidate _candidate({
  String providerId = 'nyaa',
  String instanceId = 'nyaa.si',
  required String remoteId,
  int? episode,
  String? mediaTitle,
  String? group = 'SubsPlease',
  String? resolution = '1080p',
  bool trusted = true,
  int seeders = 10,
  String category = '1_2',
}) =>
    _FakeResourceCandidate(
      providerId: providerId,
      instanceId: instanceId,
      remoteId: remoteId,
      title: mediaTitle ?? '[SubsPlease] Example Show - $episode [1080p]',
      infoHash: remoteId.hashCode
          .abs()
          .toRadixString(16)
          .padLeft(40, '0')
          .substring(0, 40),
      releaseGroup: group,
      resolution: resolution,
      trusted: trusted,
      seeders: seeders,
      category: category,
    );

class _FakeResourceCandidate extends VideoResourceCandidate {
  _FakeResourceCandidate({
    required String providerId,
    required String instanceId,
    required String remoteId,
    required String title,
    required String infoHash,
    required String? releaseGroup,
    required String? resolution,
    required bool trusted,
    required int seeders,
    required String category,
  }) : super(
          providerId: providerId,
          providerInstanceId: instanceId,
          remoteId: remoteId,
          title: title,
          providerPriority: 10,
          infoHash: infoHash,
          releaseGroup: releaseGroup,
          resolution: resolution,
          trusted: trusted,
          seeders: seeders,
          category: category,
        );
}

class _FakeResourceProvider implements VideoResourceProvider {
  _FakeResourceProvider({
    required this.id,
    List<VideoResourceCandidate> candidates = const <VideoResourceCandidate>[],
    ProviderBatchResult<VideoResourceCandidate>? result,
    Map<int, ProviderBatchResult<VideoResourceCandidate>> resultsByPage =
        const <int, ProviderBatchResult<VideoResourceCandidate>>{},
    bool pauseSearch = false,
  })  : _result = result ??
            ProviderBatchResult<VideoResourceCandidate>.success(candidates),
        _resultsByPage = resultsByPage,
        _searchGate = pauseSearch ? Completer<void>() : null;

  @override
  final String id;

  /// 测试替身不限域：本套件断言的是订阅调度，不该再依赖「id 恰好叫 torznab」
  /// 这种间接门控。
  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};

  final ProviderBatchResult<VideoResourceCandidate> _result;
  final Map<int, ProviderBatchResult<VideoResourceCandidate>> _resultsByPage;
  final Completer<void>? _searchGate;
  final Completer<void> searchEntered = Completer<void>();
  final List<int> requestedPages = <int>[];
  final List<int> requestedLimits = <int>[];

  void releaseSearch() {
    final Completer<void>? gate = _searchGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  int get priority => 10;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    requestedPages.add(request.page);
    requestedLimits.add(request.limit);
    if (!searchEntered.isCompleted) searchEntered.complete();
    await _searchGate?.future;
    return _resultsByPage[request.page] ?? _result;
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      TorrentMagnetPayload(
        magnetUri: 'magnet:?xt=urn:btih:${candidate.infoHash}',
        torrentId: candidate.infoHash,
      );

  @override
  void close() {}
}
