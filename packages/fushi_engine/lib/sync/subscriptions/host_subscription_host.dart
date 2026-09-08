/// 互联 host 的「内容订阅」面（`/api/subscriptions`）：订阅在 host 上创建、由 host
/// 自己的 `VideoDownloadSubscriptionService` 周期检查并投进 host 的下载管线。
///
/// 与 `/api/downloads` 同一决策：wire 只带**内容身份**（标题 / 搜索词 / 资源 provider /
/// 发现页身份快照），**后端绑定四元组**（backendKind / backendProfileId / fingerprint /
/// category）与落地源 `targetSourceId` 一律由 host 用自己的身份覆写——客户端传来的
/// 指纹是它自己那台机器的下载后端，写进 host 的订阅行只会让 host 管线在
/// `_validateBackendBinding` 把每条任务打进 needsAttention。
library;

import 'package:fushi_core/fushi_core.dart';

/// 创建请求（POST body）。必填四项；其余可空，`identityJson` 是发现页身份快照
/// （`encodeVideoMediaReference`），有则订阅检查用它做原名/别名/交叉 ID 匹配。
class HostSubscriptionCreateRequest {
  const HostSubscriptionCreateRequest({
    required this.title,
    required this.searchQuery,
    required this.mediaKind,
    required this.resourceProvider,
    this.subscriptionId,
    this.mode,
    this.identityJson,
    this.metadataProvider,
    this.externalId,
    this.discoveryCategory,
    this.year,
    this.season,
    this.coverUrl,
    this.filterJson = '{}',
    this.startAfterEpisode,
    this.subtitlePolicy = 'bestEffort',
  });

  factory HostSubscriptionCreateRequest.fromJson(Map<String, dynamic> json) {
    String str(String key) => (json[key] ?? '').toString().trim();
    String? opt(String key) {
      final String v = str(key);
      return v.isEmpty ? null : v;
    }

    int? intOf(String key) {
      final Object? v = json[key];
      if (v is num) return v.toInt();
      return int.tryParse('${v ?? ''}');
    }

    final String title = str('title');
    final String searchQuery = str('searchQuery');
    final String mediaKind = str('mediaKind');
    final String resourceProvider = str('resourceProvider');
    if (title.isEmpty) throw const FormatException('title required');
    if (searchQuery.isEmpty)
      throw const FormatException('searchQuery required');
    if (mediaKind != 'movie' && mediaKind != 'tv') {
      throw const FormatException('mediaKind must be movie or tv');
    }
    if (resourceProvider.isEmpty) {
      throw const FormatException('resourceProvider required');
    }
    final String? mode = opt('mode');
    if (mode != null && mode != 'oneShot' && mode != 'ongoing') {
      throw const FormatException('mode must be oneShot or ongoing');
    }
    final String subtitlePolicy = opt('subtitlePolicy') ?? 'bestEffort';
    if (!const <String>{'none', 'bestEffort', 'required'}
        .contains(subtitlePolicy)) {
      throw const FormatException(
          'subtitlePolicy must be none / bestEffort / required');
    }
    final String? metadataProvider = opt('metadataProvider');
    final String? externalId = opt('externalId');
    // 表级 CHECK：两者同为 NULL 或同非 NULL。
    if ((metadataProvider == null) != (externalId == null)) {
      throw const FormatException(
          'metadataProvider and externalId must be given together');
    }
    final Object? filter = json['filterJson'];
    return HostSubscriptionCreateRequest(
      title: title,
      searchQuery: searchQuery,
      mediaKind: mediaKind,
      resourceProvider: resourceProvider,
      subscriptionId: opt('subscriptionId'),
      mode: mode,
      identityJson: opt('identityJson'),
      metadataProvider: metadataProvider,
      externalId: externalId,
      discoveryCategory: opt('discoveryCategory'),
      year: intOf('year'),
      season: intOf('season'),
      coverUrl: opt('coverUrl'),
      filterJson: filter is String && filter.trim().isNotEmpty ? filter : '{}',
      startAfterEpisode: intOf('startAfterEpisode'),
      subtitlePolicy: subtitlePolicy,
    );
  }

  final String title;
  final String searchQuery;

  /// `movie` | `tv`。
  final String mediaKind;

  /// 持久化 provider id（`<providerId>:<instanceId>`，见 `persistedVideoResourceProviderId`）。
  final String resourceProvider;

  /// 客户端可传发现页派生的稳定 id（幂等：同一作品重复订阅只 upsert 一行）；缺省 host 生成。
  final String? subscriptionId;

  /// `oneShot` | `ongoing`；缺省 movie → oneShot，其余 ongoing。
  final String? mode;
  final String? identityJson;
  final String? metadataProvider;
  final String? externalId;
  final String? discoveryCategory;
  final int? year;
  final int? season;
  final String? coverUrl;
  final String filterJson;
  final int? startAfterEpisode;
  final String subtitlePolicy;

  String get effectiveMode =>
      mode ?? (mediaKind == 'movie' ? 'oneShot' : 'ongoing');
}

/// host 侧实现（服务端 `ServerSubscriptionHost`）。
abstract interface class HostSubscriptionHost {
  /// 能力位：`{supported, providers: [ids], backend}`；未接线/无下载后端 → supported=false。
  Future<Map<String, Object?>> capability();

  Future<List<VideoDownloadSubscriptionRow>> list();

  /// 每条订阅的 item 状态计数（`{subscriptionId: {status: count}}`）。
  Future<Map<String, Map<String, int>>> itemCounts();

  Future<VideoDownloadSubscriptionRow> create(
      HostSubscriptionCreateRequest request);

  Future<void> setEnabled(String subscriptionId, bool enabled);

  /// [subscriptionId] 为 null = 立刻检查所有到期/全部订阅。
  Future<void> checkNow(String? subscriptionId);

  Future<void> delete(String subscriptionId);
}

/// wire 编码（客户端 `HostSubscription.fromJson` 的镜像；只挑 UI 要的列，
/// 后端四元组不出 wire——它是 host 内部事）。
Map<String, Object?> videoDownloadSubscriptionToWire(
  VideoDownloadSubscriptionRow row, {
  Map<String, int>? itemCounts,
}) =>
    <String, Object?>{
      'subscriptionId': row.subscriptionId,
      'title': row.title,
      'searchQuery': row.searchQuery,
      'mediaKind': row.mediaKind,
      'mode': row.mode,
      'resourceProvider': row.resourceProvider,
      'metadataProvider': row.metadataProvider,
      'externalId': row.externalId,
      'discoveryCategory': row.discoveryCategory,
      'year': row.year,
      'season': row.season,
      'coverUrl': row.coverUrl,
      'startAfterEpisode': row.startAfterEpisode,
      'subtitlePolicy': row.subtitlePolicy,
      'enabled': row.enabled,
      'nextCheckAt': row.nextCheckAt,
      'lastCheckedAt': row.lastCheckedAt,
      'lastMatchedAt': row.lastMatchedAt,
      'fulfilledAt': row.fulfilledAt,
      'retryCount': row.retryCount,
      'lastError': row.lastError,
      'createdAt': row.createdAt,
      'updatedAt': row.updatedAt,
      if (itemCounts != null) 'itemCounts': itemCounts,
    };
