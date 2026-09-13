import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/media/video/video_subscription_updates.dart';
import 'package:fushi_core/fushi_core.dart';

/// 视频首页「已更新未看」行的纯函数门：订阅→合集解析（两套订阅链路四条路径）
/// 与合集内未看目标集选取（Next-Up 口径）。
void main() {
  const int now = 1_800_000_000_000;

  VideoDownloadSubscriptionRow sub(
    String id, {
    int? collectionId,
    String? metadataProvider,
    String? externalId,
  }) =>
      VideoDownloadSubscriptionRow(
        subscriptionId: id,
        resourceProvider: 'nyaa',
        metadataProvider: metadataProvider,
        externalId: externalId,
        mediaKind: 'tv',
        title: 'Show $id',
        searchQuery: 'Show $id',
        filterJson: '{}',
        mode: 'ongoing',
        backendKind: 'embedded',
        fingerprint: 'fp-$id',
        collectionId: collectionId,
        organizationPolicy: 'library',
        subtitlePolicy: 'bestEffort',
        enabled: true,
        retryCount: 0,
        createdAt: now,
        updatedAt: now,
      );

  VideoDownloadSubscriptionItemRow item(
    String subscriptionId,
    String key, {
    String? jobId,
  }) =>
      VideoDownloadSubscriptionItemRow(
        id: key.hashCode,
        subscriptionId: subscriptionId,
        logicalItemKey: key,
        resourceProvider: 'nyaa',
        selectedResourceId: 'r-$key',
        title: key,
        jobId: jobId,
        status: 'processed',
        discoveredAt: now,
        updatedAt: now,
      );

  VideoDownloadJobRow job(
    String id, {
    int? collectionId,
    String? metadataProvider,
    String? externalId,
  }) =>
      VideoDownloadJobRow(
        jobId: id,
        resourceProvider: 'nyaa',
        selectedResourceId: 'r-$id',
        metadataProvider: metadataProvider,
        externalId: externalId,
        mediaKind: 'tv',
        title: 'Job $id',
        backendKind: 'embedded',
        fingerprint: 'fp-$id',
        collectionId: collectionId,
        organizationPolicy: 'library',
        subtitlePolicy: 'bestEffort',
        lifecycle: 'completed',
        stage: 'complete',
        stageProgress: 1,
        priority: 0,
        attemptCount: 0,
        maxAttempts: 3,
        createdAt: now,
        updatedAt: now,
      );

  MediaCollectionRow collection(int id, {int? anilistId}) => MediaCollectionRow(
        id: id,
        name: 'C$id',
        collectionType: 'collection',
        sortOrder: 0,
        createdAt: now,
        orderUpdatedAt: 0,
        anilistId: anilistId,
      );

  group('subscribedVideoCollectionIds', () {
    test('五条路径取并集：直绑 / 条目→任务 / 身份→任务 / 身份→作品 / 旧 anilistId', () {
      final Set<int> ids = subscribedVideoCollectionIds(
        subscriptions: <VideoDownloadSubscriptionRow>[
          sub('direct', collectionId: 1),
          sub('via-job'),
          sub('via-work', metadataProvider: 'anidb', externalId: '77'),
          sub('via-job-identity', metadataProvider: 'anidb', externalId: '88'),
        ],
        itemsBySubscription: <String, List<VideoDownloadSubscriptionItemRow>>{
          'via-job': <VideoDownloadSubscriptionItemRow>[
            item('via-job', 'e1', jobId: 'j1'),
            item('via-job', 'e2'),
          ],
        },
        jobs: <VideoDownloadJobRow>[
          job('j1', collectionId: 2),
          job('j-none'),
          // 条目 jobId 已 setNull，但任务与订阅同元数据身份 → 仍能找回合集。
          job(
            'j-identity',
            collectionId: 6,
            metadataProvider: 'anidb',
            externalId: '88',
          ),
          // 同身份但没入库的任务、与别的身份的任务都不算。
          job('j-identity-nocol', metadataProvider: 'anidb', externalId: '88'),
          job(
            'j-other',
            collectionId: 7,
            metadataProvider: 'anidb',
            externalId: '99',
          ),
        ],
        collectionIdByProviderIdentity: <String, int>{
          providerIdentityKey('anidb', '77'): 3,
        },
        legacyAnilistIds: <int>[500],
        collections: <MediaCollectionRow>[
          collection(1),
          collection(2),
          collection(3),
          collection(4, anilistId: 500),
          collection(5, anilistId: 999),
          collection(6),
          collection(7),
        ],
      );
      expect(ids, <int>{1, 2, 3, 4, 6});
    });

    test('没有订阅 → 空集（首页整行隐藏的前置条件）', () {
      expect(
        subscribedVideoCollectionIds(
          subscriptions: const <VideoDownloadSubscriptionRow>[],
          itemsBySubscription: const <String,
              List<VideoDownloadSubscriptionItemRow>>{},
          jobs: const <VideoDownloadJobRow>[],
          collectionIdByProviderIdentity: const <String, int>{},
          legacyAnilistIds: const <int>[],
          collections: <MediaCollectionRow>[collection(1, anilistId: 500)],
        ),
        isEmpty,
      );
    });
  });

  group('selectVideoSubscriptionUpdate', () {
    VideoSeriesPlaybackState unwatched() => const VideoSeriesPlaybackState(
          lastWatchedAtMs: 0,
          positionMs: 0,
          completed: false,
        );
    VideoSeriesPlaybackState completed(int at) => VideoSeriesPlaybackState(
          lastWatchedAtMs: at,
          positionMs: 0,
          completed: true,
        );
    VideoSeriesPlaybackState watching(int at) => VideoSeriesPlaybackState(
          lastWatchedAtMs: at,
          positionMs: 60_000,
          completed: false,
        );

    test('全看完 → null（不占行）', () {
      expect(
        selectVideoSubscriptionUpdate(
          <VideoSeriesPlaybackState>[completed(1), completed(2)],
          <int?>[now, now],
        ),
        isNull,
      );
    });

    test('从没播过 → 目标是第 1 集未看，未看数 = 全部', () {
      final VideoSubscriptionUpdate? u = selectVideoSubscriptionUpdate(
        <VideoSeriesPlaybackState>[unwatched(), unwatched(), unwatched()],
        <int?>[now - 3, now - 1, now - 2],
      );
      expect(u!.targetIndex, 0);
      expect(u.unwatchedCount, 3);
      expect(u.latestUnwatchedImportedAtMs, now - 1);
    });

    test('Next-Up：目标是最近播放那集之后的第一集未看，跳过的旧集不回塞', () {
      // 第 1 集没看（跳过），第 2 集看完，第 3 集在看，第 4、5 集未看。
      final VideoSubscriptionUpdate? u = selectVideoSubscriptionUpdate(
        <VideoSeriesPlaybackState>[
          unwatched(),
          completed(10),
          watching(20),
          unwatched(),
          unwatched(),
        ],
        <int?>[1, 2, 3, 4, null],
      );
      expect(u!.targetIndex, 3);
      expect(u.unwatchedCount, 3, reason: '跳过的第 1 集仍计入未看数');
      expect(u.latestUnwatchedImportedAtMs, 4, reason: 'null 入库时刻按 0 计');
    });

    test('最近播放之后没有未看 → 回落合集里第一集未看', () {
      final VideoSubscriptionUpdate? u = selectVideoSubscriptionUpdate(
        <VideoSeriesPlaybackState>[unwatched(), completed(10), completed(20)],
        <int?>[1, 2, 3],
      );
      expect(u!.targetIndex, 0);
      expect(u.unwatchedCount, 1);
    });
  });
}
