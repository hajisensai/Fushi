/// 挂在本进程下载管线上的内容订阅 host：订阅行落在 host 自己的
/// `video_download_subscriptions`，由同进程的 `VideoDownloadSubscriptionService`
/// 抢租约、搜资源、投进 host 的下载管线。
///
/// 无头服务端（`ServerDownloadHost`）与 app 当 host（`AppDownloadHost`）共用这一份；
/// 两边只差「registry / service / 后端落点从哪来」，全部经构造参数注入。
///
/// 后端绑定四元组与落地源由 host 覆写（见 `host_subscription_host.dart` 库注释），
/// 客户端只提供内容身份。
library;

import 'dart:async' show FutureOr;
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_routes.dart'
    show HostSubscriptionRejected;

class PipelineSubscriptionHost implements HostSubscriptionHost {
  PipelineSubscriptionHost({
    required this.db,
    required this.registry,
    required this.backendTarget,
    required this.targetSourceId,
    required this.backendName,
    this.service,
  });

  final FushiDatabase db;
  final VideoResourceRegistry registry;

  /// host 当下的下载后端落点（kind / profileId / fingerprint / category）。
  /// app 侧解析落点要先落一次安装 id，所以允许异步。
  final FutureOr<VideoDownloadBackendTarget> Function() backendTarget;

  /// host 的受管视频源行 id（服务端固定 `<documents>/downloads`；app 是用户选的
  /// 默认受管来源）。
  final FutureOr<int> Function() targetSourceId;

  /// 能力位里报给客户端看的后端名（`embedded` / `qbittorrent`）。
  final String backendName;

  /// 周期检查服务；null = 下载后端没起来（能力位报 supported=false）。
  final VideoDownloadSubscriptionService? service;

  bool get _supported => service != null;

  /// 已注册（且未停用）的 provider id。内置源报裸 id（`nyaa` / `apibay` / `knaben`，
  /// 订阅服务的在场校验也只看 `resourceProvider` 冒号前的裸 id）；Torznab 一个对象带
  /// 多个 indexer，按 `torznab:<indexerId>` 逐个报，客户端据此判断能不能把自己那台
  /// 机器上搜到的资源交给 host 订阅。
  List<String> get availableProviderIds => <String>[
        for (final VideoResourceProvider p in registry.providers)
          if (!registry.disabledProviderIds.contains(p.id))
            if (p is TorznabClient)
              for (final TorznabIndexerConfig cfg in p.indexers)
                '${p.id}:${cfg.id}'
            else
              p.id,
      ];

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
        'supported': _supported,
        'backend': _supported ? backendName : 'none',
        'providers': availableProviderIds,
      };

  @override
  Future<List<VideoDownloadSubscriptionRow>> list() =>
      db.getVideoDownloadSubscriptions();

  @override
  Future<Map<String, Map<String, int>>> itemCounts() =>
      db.getVideoDownloadSubscriptionItemStatusCounts();

  @override
  Future<VideoDownloadSubscriptionRow> create(
      HostSubscriptionCreateRequest request) async {
    if (!_supported) {
      throw const HostSubscriptionRejected(
          409, 'unsupported', 'no torrent backend on this host');
    }
    final String providerBase = request.resourceProvider.split(':').first;
    final bool providerPresent = registry.providers.any(
      (VideoResourceProvider p) =>
          p.id == providerBase && !registry.disabledProviderIds.contains(p.id),
    );
    if (!providerPresent) {
      throw HostSubscriptionRejected(
        400,
        'provider_unavailable',
        'resource provider "${request.resourceProvider}" is not configured on this host; '
            'available: ${availableProviderIds.join(', ')}',
      );
    }
    final VideoDownloadBackendTarget target = await backendTarget();
    final int sourceId = await targetSourceId();
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String id = request.subscriptionId ?? _deriveSubscriptionId(request);
    final VideoDownloadSubscriptionRow? previous =
        await db.getVideoDownloadSubscription(id);
    await db.upsertVideoDownloadSubscription(
      VideoDownloadSubscriptionsCompanion.insert(
        subscriptionId: id,
        resourceProvider: request.resourceProvider,
        metadataProvider: Value<String?>(request.metadataProvider),
        externalId: Value<String?>(request.externalId),
        mediaKind: request.mediaKind,
        discoveryCategory: Value<String?>(request.discoveryCategory),
        title: request.title,
        year: Value<int?>(request.year),
        season: Value<int?>(request.season),
        coverUrl: Value<String?>(request.coverUrl),
        identityJson: Value<String?>(request.identityJson),
        searchQuery: request.searchQuery,
        filterJson: Value<String>(request.filterJson),
        mode: Value<String>(request.effectiveMode),
        startAfterEpisode: Value<int?>(request.startAfterEpisode),
        // 后端绑定与落地源：host 自己的，永远不信客户端。
        backendKind: target.identity.kind,
        backendProfileId: Value<String?>(target.identity.profileId),
        fingerprint: target.identity.fingerprint,
        category: Value<String?>(target.category),
        targetSourceId: Value<int?>(sourceId),
        organizationPolicy: const Value<String>('library'),
        subtitlePolicy: Value<String>(request.subtitlePolicy),
        enabled: const Value<bool>(true),
        nextCheckAt: Value<int?>(now),
        claimedBy: const Value<String?>(null),
        claimExpiresAt: const Value<int?>(null),
        retryCount: const Value<int>(0),
        fulfilledAt: const Value<int?>(null),
        lastError: const Value<String?>(null),
        createdAt: previous?.createdAt ?? now,
        updatedAt: now,
      ),
    );
    await service!.checkNow();
    return (await db.getVideoDownloadSubscription(id))!;
  }

  /// 客户端没给稳定 id 时按内容身份派生（同 provider + 同搜索词 + 同身份 → 同一行）。
  static String _deriveSubscriptionId(HostSubscriptionCreateRequest request) {
    final String seed = <String>[
      request.resourceProvider,
      request.searchQuery,
      request.mediaKind,
      request.identityJson ?? '',
    ].join('\u0000');
    return 'host-sub-${sha256.convert(utf8.encode(seed)).toString().substring(0, 24)}';
  }

  @override
  Future<void> setEnabled(String subscriptionId, bool enabled) async {
    final VideoDownloadSubscriptionRow? row =
        await db.getVideoDownloadSubscription(subscriptionId);
    if (row == null) {
      throw const HostSubscriptionRejected(
          404, 'not_found', 'unknown subscription');
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.updateVideoDownloadSubscription(
      subscriptionId,
      VideoDownloadSubscriptionsCompanion(
        enabled: Value<bool>(enabled),
        // 重新启用立刻排期；停用清掉租约免得挂一条永远不会续的 claim。
        nextCheckAt: Value<int?>(enabled ? now : row.nextCheckAt),
        claimedBy: const Value<String?>(null),
        claimExpiresAt: const Value<int?>(null),
        updatedAt: Value<int>(now),
      ),
    );
    if (enabled) await service?.checkNow();
  }

  @override
  Future<void> checkNow(String? subscriptionId) async {
    final VideoDownloadSubscriptionService? svc = service;
    if (svc == null) {
      throw const HostSubscriptionRejected(
          409, 'unsupported', 'no torrent backend on this host');
    }
    if (subscriptionId != null) {
      final VideoDownloadSubscriptionRow? row =
          await db.getVideoDownloadSubscription(subscriptionId);
      if (row == null) {
        throw const HostSubscriptionRejected(
            404, 'not_found', 'unknown subscription');
      }
      await db.updateVideoDownloadSubscription(
        subscriptionId,
        VideoDownloadSubscriptionsCompanion(
          nextCheckAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
          claimedBy: const Value<String?>(null),
          claimExpiresAt: const Value<int?>(null),
        ),
      );
    }
    await svc.checkNow();
  }

  @override
  Future<void> delete(String subscriptionId) async {
    final int n = await db.deleteVideoDownloadSubscription(subscriptionId);
    if (n == 0) {
      throw const HostSubscriptionRejected(
          404, 'not_found', 'unknown subscription');
    }
  }
}
