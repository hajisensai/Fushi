import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_routes.dart';
import 'package:fushi_server/src/subscription_host.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// host 侧订阅：后端四元组 / 落地源由 host 覆写，provider 在场校验，启停/删除。
void main() {
  late FushiDatabase db;
  late VideoResourceRegistry registry;
  late VideoDownloadBackendTarget target;
  late ServerSubscriptionHost host;
  late VideoDownloadSubscriptionService service;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    registry = VideoResourceRegistry(<NyaaVideoResourceProvider>[
      NyaaVideoResourceProvider(
        client: NyaaClient(client: http.Client()),
        closesClient: true,
      ),
    ]);
    target = VideoDownloadBackendTarget(
      identity: buildVideoDownloadBackendIdentity(
        config: const QbConnectionConfig(
            backend: QbConnectionConfig.backendEmbedded),
        resolvedBackend: QbConnectionConfig.backendEmbedded,
        embeddedInstallationId: 'host-device-1',
      ),
      category: 'fushi',
    );
    service = VideoDownloadSubscriptionService(
      database: db,
      resourceRegistry: registry,
      enqueue: (_) async => throw StateError('not expected in this test'),
      workerId: 'test-worker',
    );
    host = ServerSubscriptionHost(
      db: db,
      registry: registry,
      backendTarget: () => target,
      targetSourceId: () => 7,
      backendName: 'embedded',
      service: service,
    );
  });

  tearDown(() async {
    await service.dispose();
    await db.close();
  });

  HostSubscriptionCreateRequest req(
          {String provider = 'nyaa:nyaa.si', String? id}) =>
      HostSubscriptionCreateRequest(
        title: 'Frieren',
        searchQuery: 'Frieren 1080p',
        mediaKind: 'tv',
        resourceProvider: provider,
        subscriptionId: id,
        identityJson: '{"providerId":"mal","mediaId":"52991"}',
        metadataProvider: 'mal',
        externalId: '52991',
        startAfterEpisode: 2,
        subtitlePolicy: 'required',
      );

  test('能力位：provider 清单 + 后端名', () async {
    final Map<String, Object?> cap = await host.capability();
    expect(cap['supported'], isTrue);
    expect(cap['backend'], 'embedded');
    expect(cap['providers'], <String>['nyaa']);
  });

  test('create：后端四元组与落地源用 host 自己的，客户端字段原样落库', () async {
    final VideoDownloadSubscriptionRow row =
        await host.create(req(id: 'video-discovery-abc'));
    expect(row.subscriptionId, 'video-discovery-abc');
    expect(row.backendKind, target.identity.kind);
    expect(row.backendProfileId, target.identity.profileId);
    expect(row.fingerprint, target.identity.fingerprint);
    expect(row.category, 'fushi');
    expect(row.targetSourceId, 7);
    expect(row.mode, 'ongoing');
    expect(row.startAfterEpisode, 2);
    expect(row.subtitlePolicy, 'required');
    expect(row.identityJson, contains('52991'));
    expect(row.enabled, isTrue);
    expect(row.nextCheckAt, isNotNull, reason: '创建即排期');

    // 同 id 再来一次 = upsert，不长第二行。
    await host.create(req(id: 'video-discovery-abc'));
    expect(await host.list(), hasLength(1));
  });

  test('create：没给 id 按内容派生稳定 id（同内容同一行）', () async {
    final VideoDownloadSubscriptionRow a = await host.create(req());
    final VideoDownloadSubscriptionRow b = await host.create(req());
    expect(a.subscriptionId, startsWith('host-sub-'));
    expect(b.subscriptionId, a.subscriptionId);
    expect(await host.list(), hasLength(1));
  });

  test('create：provider 不在 host 上 → provider_unavailable（列出可用的）', () async {
    expect(
      () => host.create(req(provider: 'torznab:jackett')),
      throwsA(isA<HostSubscriptionRejected>()
          .having((HostSubscriptionRejected e) => e.reason, 'reason',
              'provider_unavailable')
          .having((HostSubscriptionRejected e) => e.message, 'message',
              contains('nyaa'))),
    );
  });

  test('create：Torznab indexer 按 torznab:<id> 报可用', () async {
    final VideoResourceRegistry withTorznab = VideoResourceRegistry(<Object>[
      ...registry.providers,
      TorznabClient(
        indexers: <TorznabIndexerConfig>[
          TorznabIndexerConfig(
            id: 'jackett',
            name: 'Jackett',
            endpoint: Uri.parse('https://j/api'),
            apiKey: 'k',
          ),
        ],
        client: http.Client(),
      ),
    ].cast());
    final ServerSubscriptionHost h = ServerSubscriptionHost(
      db: db,
      registry: withTorznab,
      backendTarget: () => target,
      targetSourceId: () => 7,
      backendName: 'embedded',
      service: service,
    );
    expect((await h.capability())['providers'],
        <String>['nyaa', 'torznab:jackett']);
  });

  test('setEnabled / delete：未知 id 404；停用清租约、启用重排期', () async {
    final VideoDownloadSubscriptionRow row = await host.create(req(id: 's1'));
    await host.setEnabled('s1', false);
    VideoDownloadSubscriptionRow? after =
        await db.getVideoDownloadSubscription('s1');
    expect(after!.enabled, isFalse);
    expect(after.claimedBy, isNull);
    await host.setEnabled('s1', true);
    after = await db.getVideoDownloadSubscription('s1');
    expect(after!.enabled, isTrue);
    expect(after.nextCheckAt, greaterThanOrEqualTo(row.nextCheckAt!));
    expect(
      () => host.setEnabled('nope', true),
      throwsA(isA<HostSubscriptionRejected>()
          .having((HostSubscriptionRejected e) => e.status, 'status', 404)),
    );
    await host.delete('s1');
    expect(await host.list(), isEmpty);
    expect(
      () => host.delete('s1'),
      throwsA(isA<HostSubscriptionRejected>()
          .having((HostSubscriptionRejected e) => e.status, 'status', 404)),
    );
  });

  test('没有下载后端：能力位 supported=false，create / checkNow 拒 409', () async {
    final ServerSubscriptionHost off = ServerSubscriptionHost(
      db: db,
      registry: registry,
      backendTarget: () => target,
      targetSourceId: () => 7,
      backendName: 'none',
      service: null,
    );
    expect((await off.capability())['supported'], isFalse);
    expect(
      () => off.create(req()),
      throwsA(isA<HostSubscriptionRejected>().having(
          (HostSubscriptionRejected e) => e.reason, 'reason', 'unsupported')),
    );
    expect(
      () => off.checkNow(null),
      throwsA(isA<HostSubscriptionRejected>()
          .having((HostSubscriptionRejected e) => e.status, 'status', 409)),
    );
  });
}
