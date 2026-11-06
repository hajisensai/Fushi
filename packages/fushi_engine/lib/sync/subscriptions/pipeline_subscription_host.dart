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
    this.releaseSeedsOutsideTarget,
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

  /// 改目标来源后摘掉旧来源里已完成集的种子（下载管线的
  /// `releaseSubscriptionSeedsOutsideTarget`，BUG-2776）；null = 没有管线，跳过。
  final Future<int> Function(String subscriptionId)? releaseSeedsOutsideTarget;

  bool get _supported => service != null;

  /// 已注册的 provider id。用户 BT 站报**格式名**（`nyaa` / `apibay` / `knaben`）：
  /// 客户端搜到的资源记的是它自己那台设备上的站点 id（`nyaa:<客户端 siteId>`），
  /// host 上没有同 id 的站点，按格式解析到 host 自己的同格式站点
  /// （`VideoResourceRegistry.resolveProvider`），所以能力位只需说「有这种格式」。
  /// Torznab 一个对象带多个 indexer，按 `torznab:<indexerId>` 逐个报，客户端据此
  /// 判断能不能把自己那台机器上搜到的资源交给 host 订阅。
  List<String> get availableProviderIds => <String>{
    for (final VideoResourceProvider p in registry.providers)
      if (isBtSiteProviderId(p.id))
        p.id.split(':').first
      else if (p is TorznabClient)
        // 停用的索引器不参与搜索，公布出去也订阅不到（BUG-2818）。过滤
        // 写在迭代源上：这里再嵌一层 collection-if 会吃掉下面的 else。
        for (final TorznabIndexerConfig cfg in p.indexers.where(
          (TorznabIndexerConfig c) => c.enabled,
        ))
          '${p.id}:${cfg.id}'
      else
        p.id,
  }.toList();

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
    HostSubscriptionCreateRequest request,
  ) async {
    if (!_supported) {
      throw const HostSubscriptionRejected(
        409,
        'unsupported',
        'no torrent backend on this host',
      );
    }
    final bool providerPresent =
        registry.resolveProvider(request.resourceProvider) != null;
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
    final VideoDownloadSubscriptionRow? previous = await db
        .getVideoDownloadSubscription(id);
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
    await _requireRow(subscriptionId);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.updateVideoDownloadSubscription(
      subscriptionId,
      VideoDownloadSubscriptionsCompanion(
        enabled: Value<bool>(enabled),
        // 重新启用立刻排期；停用不动排期。
        nextCheckAt: enabled ? Value<int?>(now) : const Value<int?>.absent(),
        // oneShot 完成位只在停用态合法（表级 CHECK）：重新启用必须同时清掉，
        // 否则写入直接被约束拒绝。
        fulfilledAt: enabled
            ? const Value<int?>(null)
            : const Value<int?>.absent(),
        // 清掉租约，免得挂一条永远不会续的 claim。
        claimedBy: const Value<String?>(null),
        claimExpiresAt: const Value<int?>(null),
        updatedAt: Value<int>(now),
      ),
    );
    if (enabled) await service?.checkNow();
  }

  /// [subscriptionId] 为 null = 「全部检查」：所有启用的订阅立即到期，再跑一轮。
  @override
  Future<void> checkNow(String? subscriptionId) async {
    final VideoDownloadSubscriptionService? svc = service;
    if (svc == null) {
      throw const HostSubscriptionRejected(
        409,
        'unsupported',
        'no torrent backend on this host',
      );
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (subscriptionId != null) {
      final VideoDownloadSubscriptionRow row = await _requireRow(
        subscriptionId,
      );
      if (!row.enabled) {
        throw const HostSubscriptionRejected(
          409,
          'disabled',
          'subscription is disabled; enable it first',
        );
      }
      await db.updateVideoDownloadSubscription(
        subscriptionId,
        VideoDownloadSubscriptionsCompanion(
          nextCheckAt: Value<int?>(now),
          claimedBy: const Value<String?>(null),
          claimExpiresAt: const Value<int?>(null),
          updatedAt: Value<int>(now),
        ),
      );
    } else {
      for (final VideoDownloadSubscriptionRow row
          in await db.getVideoDownloadSubscriptions()) {
        if (!row.enabled) continue;
        await db.updateVideoDownloadSubscription(
          row.subscriptionId,
          VideoDownloadSubscriptionsCompanion(
            nextCheckAt: Value<int?>(now),
            updatedAt: Value<int>(now),
          ),
        );
      }
    }
    await svc.checkNow();
  }

  /// 一条订阅的逐集历史（季 / 集 / 发现时刻序）。本机管理面用，不在互联 wire 上。
  Future<List<VideoDownloadSubscriptionItemRow>> items(
    String subscriptionId,
  ) async {
    await _requireRow(subscriptionId);
    return db.getVideoDownloadSubscriptionItems(subscriptionId);
  }

  /// 编辑订阅规则（窄合并）：只写 [edit] 里给出的白名单列，外加 `nextCheckAt=now`
  /// 让新规则尽快跑一轮、清 `lastError`；items 历史与其余调度状态一概不动。
  /// 改了目标来源时，已派出、还没进整理的任务一起改过去（BUG-2755），旧来源里
  /// 已完成集的种子一并摘掉（BUG-2776）。
  ///
  /// 只给本机主人用（订阅页「编辑」与桌面控制通道）：互联 wire 上目标来源由 host
  /// 自己决定，见库注释，所以它不在 [HostSubscriptionHost] 接口上。
  Future<VideoDownloadSubscriptionRow> update(
    String subscriptionId,
    VideoDownloadSubscriptionRuleEdit edit,
  ) async {
    await _requireRow(subscriptionId);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.updateVideoDownloadSubscriptionRetargetingJobs(
      subscriptionId,
      VideoDownloadSubscriptionsCompanion(
        searchQuery: edit.searchQuery,
        startAfterEpisode: edit.startAfterEpisode,
        subtitlePolicy: edit.subtitlePolicy,
        targetSourceId: edit.targetSourceId,
        filterJson: edit.filterJson,
        nextCheckAt: Value<int?>(now),
        lastError: const Value<String?>(null),
        updatedAt: Value<int>(now),
      ),
      nowAt: now,
    );
    if (edit.targetSourceId.present) {
      await releaseSeedsOutsideTarget?.call(subscriptionId);
    }
    await service?.checkNow();
    return _requireRow(subscriptionId);
  }

  Future<VideoDownloadSubscriptionRow> _requireRow(
    String subscriptionId,
  ) async {
    final VideoDownloadSubscriptionRow? row = await db
        .getVideoDownloadSubscription(subscriptionId);
    if (row == null) {
      throw const HostSubscriptionRejected(
        404,
        'not_found',
        'unknown subscription',
      );
    }
    return row;
  }

  @override
  Future<void> delete(String subscriptionId) async {
    final int n = await db.deleteVideoDownloadSubscription(subscriptionId);
    if (n == 0) {
      throw const HostSubscriptionRejected(
        404,
        'not_found',
        'unknown subscription',
      );
    }
  }
}

/// 编辑订阅的白名单列（[PipelineSubscriptionHost.update]）。每列 `absent` = 不动；
/// 构造时校验取值，非法直接抛 [FormatException]。
class VideoDownloadSubscriptionRuleEdit {
  VideoDownloadSubscriptionRuleEdit({
    this.searchQuery = const Value<String>.absent(),
    this.startAfterEpisode = const Value<int?>.absent(),
    this.subtitlePolicy = const Value<String>.absent(),
    this.targetSourceId = const Value<int?>.absent(),
    this.filterJson = const Value<String>.absent(),
  }) {
    if (searchQuery.present && searchQuery.value.trim().isEmpty) {
      throw const FormatException('searchQuery must not be empty');
    }
    final int? start = startAfterEpisode.present
        ? startAfterEpisode.value
        : null;
    if (start != null && start < 0) {
      throw const FormatException('startAfterEpisode must be >= 0');
    }
    if (subtitlePolicy.present &&
        !kVideoDownloadSubscriptionSubtitlePolicies.contains(
          subtitlePolicy.value,
        )) {
      throw const FormatException(
        'subtitlePolicy must be none / bestEffort / required',
      );
    }
    if (filterJson.present && jsonDecode(filterJson.value) is! Map) {
      throw const FormatException('filterJson must be a JSON object');
    }
  }

  final Value<String> searchQuery;
  final Value<int?> startAfterEpisode;
  final Value<String> subtitlePolicy;
  final Value<int?> targetSourceId;
  final Value<String> filterJson;

  bool get isEmpty =>
      !searchQuery.present &&
      !startAfterEpisode.present &&
      !subtitlePolicy.present &&
      !targetSourceId.present &&
      !filterJson.present;
}

/// 订阅字幕策略的合法取值（与表列 / 创建请求同一组）。
const Set<String> kVideoDownloadSubscriptionSubtitlePolicies = <String>{
  'none',
  'bestEffort',
  'required',
};
