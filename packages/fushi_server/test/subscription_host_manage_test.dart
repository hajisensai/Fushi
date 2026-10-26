import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_routes.dart';
import 'package:fushi_engine/sync/subscriptions/pipeline_subscription_host.dart';
import 'package:test/test.dart';

/// 订阅管理面（订阅页按钮与桌面控制通道共用的那一份）：启停 / 检查 / 编辑 / 逐集历史。
void main() {
  late FushiDatabase db;
  late VideoResourceRegistry registry;
  late VideoDownloadSubscriptionService service;
  late List<String> released;
  late PipelineSubscriptionHost host;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    registry = VideoResourceRegistry(<VideoResourceProvider>[
      _EmptyResources(),
    ]);
    service = VideoDownloadSubscriptionService(
      database: db,
      resourceRegistry: registry,
      enqueue: (_) async => throw StateError('not expected in this test'),
      workerId: 'test-worker',
    );
    released = <String>[];
    host = PipelineSubscriptionHost(
      db: db,
      registry: registry,
      backendTarget: () => VideoDownloadBackendTarget(
        identity: buildVideoDownloadBackendIdentity(
          config: const QbConnectionConfig(
            backend: QbConnectionConfig.backendEmbedded,
          ),
          resolvedBackend: QbConnectionConfig.backendEmbedded,
          embeddedInstallationId: 'host-device-1',
        ),
        category: 'fushi',
      ),
      targetSourceId: () => 7,
      backendName: 'embedded',
      service: service,
      releaseSeedsOutsideTarget: (String id) async {
        released.add(id);
        return 0;
      },
    );
  });

  tearDown(() async {
    await service.dispose();
    await db.close();
  });

  Future<VideoDownloadSubscriptionRow> create(
    String id, {
    String mode = 'ongoing',
  }) => host.create(
    HostSubscriptionCreateRequest(
      title: 'Show $id',
      searchQuery: 'Show $id 1080p',
      mediaKind: mode == 'oneShot' ? 'movie' : 'tv',
      resourceProvider: 'fake',
      subscriptionId: id,
      mode: mode,
      filterJson:
          '{"strict":true,"releaseGroup":"SubsPlease","resolution":"1080p","trusted":true}',
      startAfterEpisode: 2,
    ),
  );

  test('重新启用已完成的 oneShot：同时清 fulfilledAt（表级 CHECK 只许停用态带完成位）', () async {
    await create('movie', mode: 'oneShot');
    await db.updateVideoDownloadSubscription(
      'movie',
      const VideoDownloadSubscriptionsCompanion(
        enabled: Value<bool>(false),
        fulfilledAt: Value<int?>(123),
      ),
    );
    await host.setEnabled('movie', true);
    final VideoDownloadSubscriptionRow row = (await db
        .getVideoDownloadSubscription('movie'))!;
    expect(row.enabled, isTrue);
    expect(row.fulfilledAt, isNull);
  });

  test('停用不动排期与完成位', () async {
    await create('movie', mode: 'oneShot');
    await db.updateVideoDownloadSubscription(
      'movie',
      const VideoDownloadSubscriptionsCompanion(
        enabled: Value<bool>(false),
        fulfilledAt: Value<int?>(123),
        nextCheckAt: Value<int?>(456),
      ),
    );
    await host.setEnabled('movie', false);
    final VideoDownloadSubscriptionRow row = (await db
        .getVideoDownloadSubscription('movie'))!;
    expect(row.fulfilledAt, 123);
    expect(row.nextCheckAt, 456);
  });

  test('checkNow(null) = 全部检查：启用的都跑一轮，停用的不碰', () async {
    await create('a');
    await create('b');
    await host.setEnabled('b', false);
    // 把两条都推到很远的将来：只有「全部检查」把启用的拉回到期，它才会被检查。
    for (final String id in <String>['a', 'b']) {
      await db.updateVideoDownloadSubscription(
        id,
        const VideoDownloadSubscriptionsCompanion(
          nextCheckAt: Value<int?>(9999999999999),
          lastCheckedAt: Value<int?>(null),
        ),
      );
    }
    await host.checkNow(null);
    expect(
      (await db.getVideoDownloadSubscription('a'))!.lastCheckedAt,
      isNotNull,
    );
    final VideoDownloadSubscriptionRow b = (await db
        .getVideoDownloadSubscription('b'))!;
    expect(b.lastCheckedAt, isNull);
    expect(b.nextCheckAt, 9999999999999);
  });

  test('checkNow(id)：未知 404，停用 409', () async {
    await create('a');
    await host.setEnabled('a', false);
    await expectLater(
      host.checkNow('a'),
      throwsA(
        isA<HostSubscriptionRejected>().having(
          (HostSubscriptionRejected e) => e.status,
          'status',
          409,
        ),
      ),
    );
    await expectLater(
      host.checkNow('nope'),
      throwsA(
        isA<HostSubscriptionRejected>().having(
          (HostSubscriptionRejected e) => e.status,
          'status',
          404,
        ),
      ),
    );
  });

  test('update：只写给出的列，重排期、清 lastError；没改来源不摘种子', () async {
    await create('a');
    await db.updateVideoDownloadSubscription(
      'a',
      const VideoDownloadSubscriptionsCompanion(
        lastError: Value<String?>('boom'),
        nextCheckAt: Value<int?>(9999999999999),
      ),
    );
    final VideoDownloadSubscriptionRow row = await host.update(
      'a',
      VideoDownloadSubscriptionRuleEdit(
        searchQuery: const Value<String>('Show a 720p'),
        subtitlePolicy: const Value<String>('required'),
      ),
    );
    expect(row.searchQuery, 'Show a 720p');
    expect(row.subtitlePolicy, 'required');
    expect(row.startAfterEpisode, 2, reason: '没给就不动');
    expect(
      row.filterJson,
      '{"strict":true,"releaseGroup":"SubsPlease","resolution":"1080p","trusted":true}',
    );
    expect(row.targetSourceId, 7);
    expect(row.lastError, isNull);
    expect(released, isEmpty);
  });

  test('update：改目标来源 → 摘旧来源种子；startAfterEpisode 可清空', () async {
    await create('a');
    final VideoDownloadSubscriptionRow row = await host.update(
      'a',
      VideoDownloadSubscriptionRuleEdit(
        targetSourceId: const Value<int?>(9),
        startAfterEpisode: const Value<int?>(null),
      ),
    );
    expect(row.targetSourceId, 9);
    expect(row.startAfterEpisode, isNull);
    expect(released, <String>['a']);
  });

  test('update / items：未知 id 404', () async {
    await expectLater(
      host.update(
        'nope',
        VideoDownloadSubscriptionRuleEdit(searchQuery: const Value('x')),
      ),
      throwsA(
        isA<HostSubscriptionRejected>().having(
          (HostSubscriptionRejected e) => e.status,
          'status',
          404,
        ),
      ),
    );
    await expectLater(
      host.items('nope'),
      throwsA(
        isA<HostSubscriptionRejected>().having(
          (HostSubscriptionRejected e) => e.status,
          'status',
          404,
        ),
      ),
    );
    await create('a');
    expect(await host.items('a'), isEmpty);
  });

  test('VideoDownloadSubscriptionRuleEdit 校验取值', () {
    expect(
      () => VideoDownloadSubscriptionRuleEdit(searchQuery: const Value(' ')),
      throwsFormatException,
    );
    expect(
      () => VideoDownloadSubscriptionRuleEdit(
        startAfterEpisode: const Value<int?>(-1),
      ),
      throwsFormatException,
    );
    expect(
      () => VideoDownloadSubscriptionRuleEdit(
        subtitlePolicy: const Value('sometimes'),
      ),
      throwsFormatException,
    );
    expect(
      () => VideoDownloadSubscriptionRuleEdit(filterJson: const Value('[]')),
      throwsFormatException,
    );
    expect(VideoDownloadSubscriptionRuleEdit().isEmpty, isTrue);
    // 换源只开放「改选 RSS 站」一条路（已移除内置源的旧订阅靠它恢复）。
    for (final String bad in <String>['rss', 'rss:', 'torznab:x', 'nyaa']) {
      expect(
        () => VideoDownloadSubscriptionRuleEdit(
          resourceProvider: Value<String>(bad),
        ),
        throwsFormatException,
        reason: bad,
      );
    }
    expect(
      VideoDownloadSubscriptionRuleEdit(
        resourceProvider: const Value<String>('rss:site1'),
      ).isEmpty,
      isFalse,
    );
  });

  test('update：改选 RSS 站写 resourceProvider，其余来源身份不动', () async {
    await create('a');
    final VideoDownloadSubscriptionRow before = (await db
        .getVideoDownloadSubscription('a'))!;
    final VideoDownloadSubscriptionRow row = await host.update(
      'a',
      VideoDownloadSubscriptionRuleEdit(
        resourceProvider: const Value<String>('rss:site1'),
      ),
    );
    expect(row.resourceProvider, 'rss:site1');
    expect(row.fingerprint, before.fingerprint);
    expect(row.searchQuery, before.searchQuery);
  });
}

/// 永远搜不到资源的 provider：让订阅服务真跑一轮检查、又不联网。
class _EmptyResources implements VideoResourceProvider {
  @override
  String get id => 'fake';
  @override
  int get priority => 100;
  @override
  Set<VideoDiscoveryCategory> get categories =>
      VideoDiscoveryCategory.values.toSet();
  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async => ProviderBatchResult<VideoResourceCandidate>.success(
    const <VideoResourceCandidate>[],
  );
  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) =>
      throw UnimplementedError();
  @override
  void close() {}
}
