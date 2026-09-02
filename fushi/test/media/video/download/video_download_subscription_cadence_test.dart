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
import 'package:fushi/src/media/video/download/subscription_check_schedule.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_download_subscription_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';

/// 周三 15:00 UTC——历史发布点。
final DateTime kRelease = DateTime.utc(2026, 9, 2, 15);

const SubscriptionCheckCadence kCadence = SubscriptionCheckCadence();

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
        createdAt: 1000,
      ),
    );

Future<void> _insertSubscription(
  FushiDatabase database, {
  required String id,
  required int sourceId,
  String mode = 'ongoing',
  bool enabled = true,
  int? nextCheckAt = 1000,
}) =>
    database.upsertVideoDownloadSubscription(
      VideoDownloadSubscriptionsCompanion.insert(
        subscriptionId: id,
        resourceProvider: 'torznab:indexer-a',
        metadataProvider: const Value<String?>('anilist'),
        externalId: Value<String?>('media-$id'),
        mediaKind: 'tv',
        discoveryCategory: const Value<String?>('anime'),
        title: 'Example Show',
        season: const Value<int?>(1),
        searchQuery: 'Example Show',
        filterJson: Value<String>(
          jsonEncode(<String, Object?>{'strict': true, 'quality': '1080p'}),
        ),
        mode: Value<String>(mode),
        backendKind: 'embedded',
        backendProfileId: const Value<String?>('embedded'),
        fingerprint: 'backend-fingerprint',
        category: const Value<String?>('fushi-video'),
        targetSourceId: Value<int?>(sourceId),
        enabled: Value<bool>(enabled),
        createdAt: 1000,
        updatedAt: 1000,
        nextCheckAt: Value<int?>(nextCheckAt),
      ),
    );

/// 预置若干「每周同一时刻发布」的历史条目。
Future<void> _insertWeeklyHistory(
  FushiDatabase database,
  String subscriptionId, {
  int weeks = 3,
}) async {
  for (int i = 0; i < weeks; i++) {
    final DateTime at = kRelease.subtract(Duration(days: 7 * i));
    await database.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: subscriptionId,
        logicalItemKey: 's1e${10 - i}',
        resourceProvider: 'torznab:indexer-a',
        selectedResourceId: 'release-$i',
        title: 'Example Show - ${10 - i}',
        season: const Value<int?>(1),
        episode: Value<int?>(10 - i),
        publishedAt: Value<int?>(at.millisecondsSinceEpoch),
        discoveredAt: at.millisecondsSinceEpoch,
        updatedAt: at.millisecondsSinceEpoch,
      ),
    );
  }
}

VideoDownloadSubscriptionService _service(
  FushiDatabase database, {
  required DateTime now,
}) {
  final VideoDownloadSubscriptionService service =
      VideoDownloadSubscriptionService(
    database: database,
    resourceRegistry: VideoResourceRegistry(<VideoResourceProvider>[
      _EmptyResourceProvider(),
    ]),
    // 本套件断言的是「下一次什么时候查」，不是入队；provider 恒返空候选，
    // 检查必定成功且不命中，nextCheckAt 就只由历史样本决定。
    enqueue: (VideoDownloadEnqueueRequest request) async =>
        fail('no candidate should be enqueued'),
    workerId: 'cadence-test-worker',
    now: () => now,
  );
  addTearDown(service.dispose);
  return service;
}

Future<int?> _checkAndReadNextCheckAt(
  FushiDatabase database,
  String subscriptionId, {
  required DateTime now,
}) async {
  await _service(database, now: now).checkNow();
  final VideoDownloadSubscriptionRow row =
      (await database.getVideoDownloadSubscription(subscriptionId))!;
  expect(row.lastCheckedAt, now.millisecondsSinceEpoch, reason: '这一轮检查应当真的跑到了');
  // 失败路径首次退避同样是 15 分钟，与「退回均匀间隔」肉眼无法区分——必须显式
  // 排除，否则一条抛异常的检查会被读成「节奏退化」而悄悄通过。
  expect(row.lastError, isNull, reason: '这一轮检查不该失败');
  expect(row.retryCount, 0);
  return row.nextCheckAt;
}

void main() {
  group('订阅检查节奏落到 nextCheckAt', () {
    test('连载订阅在冷窗里睡满冷窗封顶，而不是固定 15 分钟', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'weekly', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'weekly');

      // 预测点之后 3 天：深在冷窗里。
      final DateTime now = kRelease.add(const Duration(days: 3));
      final int? nextCheckAt = await _checkAndReadNextCheckAt(
        database,
        'weekly',
        now: now,
      );

      expect(
        nextCheckAt,
        now.millisecondsSinceEpoch + kCadence.coldInterval.inMilliseconds,
      );
    });

    test('连载订阅在热窗里加密到 5 分钟', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'weekly', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'weekly');

      // 预测点后 1 小时：字幕组滞后余温里。
      final DateTime now = kRelease.add(const Duration(hours: 1));
      final int? nextCheckAt = await _checkAndReadNextCheckAt(
        database,
        'weekly',
        now: now,
      );

      expect(
        nextCheckAt,
        now.millisecondsSinceEpoch + kCadence.hotInterval.inMilliseconds,
      );
    });

    test('历史样本不足时退回 15 分钟均匀间隔', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'fresh', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'fresh', weeks: 2);

      final DateTime now = kRelease.add(const Duration(days: 3));
      final int? nextCheckAt = await _checkAndReadNextCheckAt(
        database,
        'fresh',
        now: now,
      );

      expect(
        nextCheckAt,
        now.millisecondsSinceEpoch + kCadence.baseInterval.inMilliseconds,
      );
    });

    test('oneShot 订阅没有周期语义，始终用均匀间隔', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'once',
        sourceId: sourceId,
        mode: 'oneShot',
      );
      // 即便历史看着很像每周更新，一次性订阅也不该据此改节奏。
      await _insertWeeklyHistory(database, 'once');

      final DateTime now = kRelease.add(const Duration(days: 3));
      final int? nextCheckAt = await _checkAndReadNextCheckAt(
        database,
        'once',
        now: now,
      );

      expect(
        nextCheckAt,
        now.millisecondsSinceEpoch + kCadence.baseInterval.inMilliseconds,
      );
    });

    test('缺 publishedAt 的历史条目不参与相位判定', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'partial', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'partial', weeks: 2);
      // 第三条没有发布时刻（provider 没给 pubDate），样本仍然只有两条。
      await database.upsertVideoDownloadSubscriptionItem(
        VideoDownloadSubscriptionItemsCompanion.insert(
          subscriptionId: 'partial',
          logicalItemKey: 's1e7',
          resourceProvider: 'torznab:indexer-a',
          selectedResourceId: 'release-nodate',
          title: 'Example Show - 7',
          season: const Value<int?>(1),
          episode: const Value<int?>(7),
          discoveredAt: kRelease.millisecondsSinceEpoch,
          updatedAt: kRelease.millisecondsSinceEpoch,
        ),
      );

      final DateTime now = kRelease.add(const Duration(days: 3));
      final int? nextCheckAt = await _checkAndReadNextCheckAt(
        database,
        'partial',
        now: now,
      );

      expect(
        nextCheckAt,
        now.millisecondsSinceEpoch + kCadence.baseInterval.inMilliseconds,
      );
    });
  });

  group('getVideoDownloadSubscriptionPublishedAt', () {
    test('按发布时刻降序返回，并滤掉缺失值', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'weekly', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'weekly');

      final List<int> samples =
          await database.getVideoDownloadSubscriptionPublishedAt('weekly');
      expect(samples, <int>[
        kRelease.millisecondsSinceEpoch,
        kRelease.subtract(const Duration(days: 7)).millisecondsSinceEpoch,
        kRelease.subtract(const Duration(days: 14)).millisecondsSinceEpoch,
      ]);
    });

    test('limit 只取最近若干条', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(database, id: 'weekly', sourceId: sourceId);
      await _insertWeeklyHistory(database, 'weekly', weeks: 4);

      expect(
        (await database.getVideoDownloadSubscriptionPublishedAt(
          'weekly',
          limit: 2,
        ))
            .length,
        2,
      );
    });
  });

  group('nextVideoDownloadSubscriptionDueAt', () {
    test('没有订阅时返回 null', () async {
      final FushiDatabase database = await _openDatabase();
      expect(await database.nextVideoDownloadSubscriptionDueAt(), isNull);
    });

    test('取启用订阅中最早的到期时刻', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'late',
        sourceId: sourceId,
        nextCheckAt: 9000,
      );
      await _insertSubscription(
        database,
        id: 'early',
        sourceId: sourceId,
        nextCheckAt: 4000,
      );

      expect(await database.nextVideoDownloadSubscriptionDueAt(), 4000);
    });

    test('停用的订阅不参与调度', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'off',
        sourceId: sourceId,
        enabled: false,
        nextCheckAt: 1000,
      );
      await _insertSubscription(
        database,
        id: 'on',
        sourceId: sourceId,
        nextCheckAt: 7000,
      );

      expect(await database.nextVideoDownloadSubscriptionDueAt(), 7000);
    });

    test('nextCheckAt 为 NULL 的新订阅立即到期', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'brand-new',
        sourceId: sourceId,
        nextCheckAt: null,
      );

      expect(await database.nextVideoDownloadSubscriptionDueAt(), 0);
    });

    test('被别的 worker 占着的行要等 lease 过期才算到期', () async {
      final FushiDatabase database = await _openDatabase();
      final int sourceId = await _insertVideoSource(database);
      await _insertSubscription(
        database,
        id: 'claimed',
        sourceId: sourceId,
        nextCheckAt: 1000,
      );
      await database.claimNextVideoDownloadSubscription(
        workerId: 'other-worker',
        nowAt: 1000,
        leaseDurationMs: 5000,
      );

      // nextCheckAt 仍是 1000，但 lease 要到 6000 才过期。
      expect(await database.nextVideoDownloadSubscriptionDueAt(), 6000);
    });
  });
}

class _EmptyResourceProvider implements VideoResourceProvider {
  @override
  String get id => 'torznab';

  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};

  @override
  int get priority => 10;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async =>
      ProviderBatchResult<VideoResourceCandidate>.success(
        const <VideoResourceCandidate>[],
      );

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      fail('no candidate should be resolved');

  @override
  void close() {}
}
