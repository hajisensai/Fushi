// 内置 BT 搜索站移除后的订阅规则：
// - 存量 provider=nyaa/apibay/knaben 的订阅不迁移，检查时报「来源已移除」（配置错误
//   的一种），不崩、不打网络、重试间隔直接取上限而不是 15 分钟一刷；
// - RSS 搜索站订阅至少要一条严格版本规则（与 Torznab 同门槛）；
// - 绑定的 RSS 站在本机不存在 / 已停用：明确配置错误，不静默「成功 0 条」。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/rss_search_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const int _nowAt = 1000000;

void main() {
  late FushiDatabase db;
  late int sourceId;
  late List<Uri> requests;
  late VideoDownloadSubscriptionService service;

  Future<void> insert({
    required String id,
    required String provider,
    Map<String, Object?> filters = const <String, Object?>{
      'strict': true,
      'releaseGroup': 'SubsPlease',
    },
    String? discoveryCategory = 'anime',
  }) => db.upsertVideoDownloadSubscription(
    VideoDownloadSubscriptionsCompanion.insert(
      subscriptionId: id,
      resourceProvider: provider,
      mediaKind: 'tv',
      discoveryCategory: Value<String?>(discoveryCategory),
      title: 'Example Show',
      searchQuery: 'Example Show',
      filterJson: Value<String>(jsonEncode(filters)),
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

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Managed videos',
        mediaKind: 'video',
        rootPath: '/videos',
        createdAt: _nowAt,
      ),
    );
    requests = <Uri>[];
    service = VideoDownloadSubscriptionService(
      database: db,
      resourceRegistry: VideoResourceRegistry(<VideoResourceProvider>[
        RssSearchProvider(
          sites: <RssSearchSiteConfig>[
            RssSearchSiteConfig(
              id: 'nyaa-rss',
              name: 'Nyaa',
              urlTemplate: 'https://nyaa.si/?page=rss&q={query}',
              domains: const <RssSearchDomain>[RssSearchDomain.anime],
            ),
            RssSearchSiteConfig(
              id: 'off',
              name: 'Off',
              urlTemplate: 'https://off.example/rss?q={query}',
              enabled: false,
              domains: const <RssSearchDomain>[RssSearchDomain.anime],
            ),
          ],
          client: MockClient((http.Request request) async {
            requests.add(request.url);
            return http.Response(
              '<?xml version="1.0"?><rss version="2.0"><channel></channel></rss>',
              200,
            );
          }),
        ),
      ]),
      enqueue: (_) async => throw StateError('nothing should be enqueued'),
      workerId: 'rss-rules-worker',
      now: () => DateTime.fromMillisecondsSinceEpoch(_nowAt),
    );
  });

  tearDown(() async {
    await service.dispose();
    await db.close();
  });

  Future<VideoDownloadSubscriptionRow> row(String id) async =>
      (await db.getVideoDownloadSubscription(id))!;

  test('存量 nyaa / apibay / knaben 订阅：报「来源已移除」，零网络请求，重试隔 6 小时', () async {
    // 旧行常缺 discoveryCategory（旧版靠 provider=nyaa 推成 anime）：
    // 也要先报「来源已移除」而不是别的次要错误。
    await insert(
      id: 'old-nyaa',
      provider: 'nyaa:nyaa.si',
      discoveryCategory: null,
    );
    await insert(id: 'old-apibay', provider: 'apibay');
    await insert(id: 'old-knaben', provider: 'knaben:knaben.org');

    await service.checkNow();

    expect(requests, isEmpty, reason: '已移除的来源不发任何请求');
    for (final String id in <String>['old-nyaa', 'old-apibay', 'old-knaben']) {
      final VideoDownloadSubscriptionRow r = await row(id);
      expect(
        r.lastError,
        kVideoDownloadSubscriptionProviderRemovedMessage,
        reason: id,
      );
      expect(r.enabled, isTrue, reason: '不自动删 / 停用，留给用户改选 RSS 站');
      expect(r.claimedBy, isNull, reason: '租约已释放');
      expect(r.retryCount, 1);
      expect(
        r.nextCheckAt,
        _nowAt + const Duration(hours: 6).inMilliseconds,
        reason: '永远不会自愈：不按 15 分钟指数退避反复改写同一条错误',
      );
      expect(isRemovedBuiltinVideoResourceProvider(r.resourceProvider), isTrue);
    }

    // 下一轮未到期：不会再领取、不会刷新错误。
    await service.checkNow();
    expect((await row('old-nyaa')).retryCount, 1);
  });

  test('RSS 订阅没有任何严格版本规则：配置错误，不搜', () async {
    await insert(
      id: 'loose',
      provider: 'rss:nyaa-rss',
      filters: const <String, Object?>{
        'strict': true,
        'titleInclude': <String>['Example'],
      },
    );
    await service.checkNow();
    expect(requests, isEmpty);
    expect(
      (await row('loose')).lastError,
      'RSS and Torznab subscriptions require at least one strict version rule',
    );
  });

  test('绑定的 RSS 站不存在 / 已停用：配置错误，而不是「成功 0 条」', () async {
    await insert(id: 'gone', provider: 'rss:deleted-site');
    await insert(id: 'disabled', provider: 'rss:off');
    await service.checkNow();
    expect(requests, isEmpty);
    for (final String id in <String>['gone', 'disabled']) {
      expect(
        (await row(id)).lastError,
        'The selected RSS search site is not configured on this device',
        reason: id,
      );
    }
  });

  test('合法的 RSS 订阅：只打绑定的那个站，查到 0 条照常结账', () async {
    await insert(id: 'ok', provider: 'rss:nyaa-rss');
    await service.checkNow();
    expect(requests, isNotEmpty);
    expect(requests.every((Uri u) => u.host == 'nyaa.si'), isTrue);
    final VideoDownloadSubscriptionRow r = await row('ok');
    expect(r.lastError, isNull);
    expect(r.retryCount, 0);
  });

  test('已移除来源也是一种配置错误（UI 既有的配置错误呈现照常生效）', () {
    const Object error = VideoDownloadSubscriptionProviderRemovedError();
    expect(error, isA<VideoDownloadSubscriptionConfigurationError>());
    expect(error.toString(), kVideoDownloadSubscriptionProviderRemovedMessage);
  });
}
