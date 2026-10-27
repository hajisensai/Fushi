// 存量订阅的 provider 记的是旧内置源（`nyaa:nyaa.si` 等）：运行时解析到用户添加的
// 同格式 BT 站照常工作；没有可用站点就暂停（lastError 固定标记、均匀间隔重查），
// 用户添加站点后唤醒即恢复。provider 用引擎真装配（createBtSiteResourceProviders），
// 只把网络换成假 Nyaa 式搜索页。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_providers.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';

import '../../../torrent/nyaa_html_fixture.dart';

const int _nowAt = 1000;
const String _episode2Hash = '2222222222222222222222222222222222222222';

Future<FushiDatabase> _openDatabase() async {
  final FushiDatabase database = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (CommonDatabase raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(database.close);
  return database;
}

Future<int> _seed(FushiDatabase database, {String provider = 'nyaa:nyaa.si'}) async {
  final int sourceId = await database.insertMediaSource(
    MediaSourcesCompanion.insert(
      label: 'Managed videos',
      mediaKind: 'video',
      rootPath: r'D:\Videos',
      createdAt: _nowAt,
    ),
  );
  await database.upsertVideoDownloadSubscription(
    VideoDownloadSubscriptionsCompanion.insert(
      subscriptionId: 'legacy',
      resourceProvider: provider,
      metadataProvider: const Value<String?>('anilist'),
      externalId: const Value<String?>('media-legacy'),
      mediaKind: 'tv',
      discoveryCategory: const Value<String?>('anime'),
      title: 'Example Show',
      season: const Value<int?>(1),
      searchQuery: 'Example Show',
      filterJson: Value<String>(
        jsonEncode(<String, Object?>{
          'strict': true,
          'releaseGroup': 'SubsPlease',
          'resolution': '1080p',
          'trustedOnly': true,
        }),
      ),
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
  return sourceId;
}

BtSiteConfig _nyaaSite(String id, {bool enabled = true}) => BtSiteConfig(
      id: id,
      baseUrl: Uri.parse('https://$id.example'),
      format: BtSiteFormat.nyaa,
      domains: const <BtSiteDomain>{BtSiteDomain.anime},
      nyaaCategories: const <BtSiteDomain, String>{BtSiteDomain.anime: '1_0'},
      enabled: enabled,
    );

BtSiteConfig _jsonSite(String id) => BtSiteConfig(
      id: id,
      baseUrl: Uri.parse('https://$id.example'),
      format: BtSiteFormat.apibay,
      domains: const <BtSiteDomain>{BtSiteDomain.movie, BtSiteDomain.tv},
    );

/// 假站点：Nyaa 式搜索页回一条第 2 集的 trusted 发布。
http.Client _fakeNetwork() => MockClient((http.Request request) async {
      if (request.url.path == '/') {
        return http.Response.bytes(
          utf8.encode(
            nyaaSearchHtml(const <NyaaHtmlRow>[
              NyaaHtmlRow(
                title: '[SubsPlease] Example Show - 02 [1080p].mkv',
                infoHash: _episode2Hash,
                seeders: 20,
                trusted: true,
              ),
            ]),
          ),
          200,
        );
      }
      return http.Response('[]', 200);
    });

Future<VideoDownloadSubscriptionService> _service(
  FushiDatabase database,
  List<BtSiteConfig> sites,
  List<VideoDownloadEnqueueRequest> enqueued, {
  int nowAt = _nowAt,
}) async {
  final VideoResourceRegistry registry = VideoResourceRegistry(
    await createBtSiteResourceProviders(sites, () async => _fakeNetwork()),
  );
  addTearDown(registry.close);
  final VideoDownloadSubscriptionService service =
      VideoDownloadSubscriptionService(
    database: database,
    resourceRegistry: registry,
    enqueue: (VideoDownloadEnqueueRequest request) async {
      enqueued.add(request);
      final String jobId = 'job-${enqueued.length}';
      await database.upsertVideoDownloadJob(
        VideoDownloadJobsCompanion.insert(
          jobId: jobId,
          resourceProvider: persistedVideoResourceProviderId(request.resource),
          selectedResourceId: request.resource.remoteId,
          torrentHash: Value<String?>(request.resource.infoHash),
          metadataProvider: Value<String?>(request.media.providerId),
          externalId: Value<String?>(request.media.mediaId),
          mediaKind: request.media.mediaKind.name,
          discoveryCategory:
              Value<String?>(request.media.discoveryCategory.name),
          title: request.media.title,
          backendKind: request.backendTarget.kind,
          backendProfileId: Value<String?>(request.backendTarget.profileId),
          fingerprint: request.backendTarget.fingerprint,
          category: Value<String?>(request.backendTarget.category),
          targetSourceId: Value<int?>(request.targetSourceId),
          subtitlePolicy: Value<String>(request.subtitlePolicy.name),
          createdAt: nowAt,
          updatedAt: nowAt,
        ),
      );
      return jobId;
    },
    workerId: 'bt-site-test-worker',
    now: () => DateTime.fromMillisecondsSinceEpoch(nowAt),
  );
  addTearDown(service.dispose);
  return service;
}

void main() {
  test('旧内置 Nyaa 订阅 → 接上用户的 Nyaa 式站点（跳过别的格式的站）', () async {
    final FushiDatabase database = await _openDatabase();
    await _seed(database);
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    final VideoDownloadSubscriptionService service = await _service(
      database,
      <BtSiteConfig>[_jsonSite('jsonsite'), _nyaaSite('mysite')],
      enqueued,
    );

    await service.checkNow();

    expect(enqueued, hasLength(1));
    expect(
      persistedVideoResourceProviderId(enqueued.single.resource),
      'nyaa:mysite',
    );
    expect(enqueued.single.resource.remoteId, _episode2Hash);
    final VideoDownloadSubscriptionRow row =
        (await database.getVideoDownloadSubscription('legacy'))!;
    expect(row.lastError, isNull);
  });

  test('订阅条目上还是旧 provider id：同一个发布照常认领，不报「已不可用」', () async {
    final FushiDatabase database = await _openDatabase();
    await _seed(database);
    await database.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: 'legacy',
        logicalItemKey: 'S01E02',
        resourceProvider: 'nyaa:nyaa.si',
        selectedResourceId: _episode2Hash,
        torrentHash: const Value<String?>(_episode2Hash),
        title: '[SubsPlease] Example Show - 02 [1080p].mkv',
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        discoveredAt: _nowAt,
        updatedAt: _nowAt,
      ),
    );
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    final VideoDownloadSubscriptionService service = await _service(
      database,
      <BtSiteConfig>[_nyaaSite('mysite')],
      enqueued,
    );

    await service.checkNow();

    expect(enqueued.map((VideoDownloadEnqueueRequest r) => r.resource.remoteId),
        <String>[_episode2Hash]);
    expect(
      (await database.getVideoDownloadSubscription('legacy'))!.lastError,
      isNull,
    );
  });

  test('只有别的格式的站 → 暂停：固定标记 + 均匀间隔，不指数退避', () async {
    final FushiDatabase database = await _openDatabase();
    await _seed(database);
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    await (await _service(database, <BtSiteConfig>[_jsonSite('jsonsite')],
            enqueued))
        .checkNow();
    VideoDownloadSubscriptionRow row =
        (await database.getVideoDownloadSubscription('legacy'))!;
    expect(enqueued, isEmpty);
    expect(isVideoSubscriptionBtSiteMissingError(row.lastError), isTrue);
    expect(row.nextCheckAt, _nowAt + const Duration(minutes: 15).inMilliseconds);

    // 第二轮仍然没有站点：间隔不翻倍。
    final int later = row.nextCheckAt!;
    await (await _service(database, <BtSiteConfig>[_jsonSite('jsonsite')],
            enqueued, nowAt: later))
        .checkNow();
    row = (await database.getVideoDownloadSubscription('legacy'))!;
    expect(row.retryCount, 2);
    expect(row.nextCheckAt, later + const Duration(minutes: 15).inMilliseconds);
  });

  test('同格式站点停用 → 暂停', () async {
    final FushiDatabase database = await _openDatabase();
    await _seed(database);
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    await (await _service(
      database,
      <BtSiteConfig>[_nyaaSite('mysite', enabled: false)],
      enqueued,
    ))
        .checkNow();
    expect(enqueued, isEmpty);
    expect(
      isVideoSubscriptionBtSiteMissingError(
        (await database.getVideoDownloadSubscription('legacy'))!.lastError,
      ),
      isTrue,
    );
  });

  test('新增站点后唤醒 → 下一次检查恢复', () async {
    final FushiDatabase database = await _openDatabase();
    await _seed(database);
    final List<VideoDownloadEnqueueRequest> enqueued =
        <VideoDownloadEnqueueRequest>[];
    final VideoDownloadSubscriptionService before =
        await _service(database, const <BtSiteConfig>[], enqueued);
    await before.checkNow();
    await before.dispose();
    expect(
      isVideoSubscriptionBtSiteMissingError(
        (await database.getVideoDownloadSubscription('legacy'))!.lastError,
      ),
      isTrue,
    );

    // 用户加了站点：运行时按新配置重建，唤醒暂停的订阅（时钟没前进——不靠
    // 等节流间隔到期）。
    final VideoDownloadSubscriptionService after = await _service(
      database,
      <BtSiteConfig>[_nyaaSite('mysite')],
      enqueued,
      nowAt: _nowAt + 1,
    );
    await after.wakeBtSiteMissingSubscriptions();

    expect(enqueued, hasLength(1));
    expect(
      (await database.getVideoDownloadSubscription('legacy'))!.lastError,
      isNull,
    );
  });
}
