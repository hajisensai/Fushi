/// 互联「内容订阅」客户端（`/api/subscriptions`）：订阅在已配对 host 上创建并由
/// host 自己周期跑（搜资源 → 投 host 的下载管线）；本机只做浏览/启停/删除。
///
/// 与 `InterconnectDownloadClient` 同一形状：传输层（选路、凭据、钉扎、整段超时、
/// client 生命周期、错误分型）全部走 [InterconnectHostChannel]。
library;

import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:http/http.dart' as http;

class HostSubscriptionTarget {
  const HostSubscriptionTarget({
    required this.baseUrl,
    required this.deviceName,
    required this.backend,
    required this.providers,
    this.fingerprintSha256,
    this.host,
  });

  /// 这台 host 的身份（client 产出的 target 一律带上）。null = 调用方直接构造的
  /// 老形状 target，按 [baseUrl] 认（见 [hostRef]）。
  final InterconnectHostRef? host;

  /// 请求按它选路 / 取凭据 / 钉扎，而不是按 [baseUrl] 那一条地址。
  InterconnectHostRef get hostRef =>
      host ?? InterconnectHostRef.legacyUrl(interconnectPersistedUrl(baseUrl));

  /// 这台 host 的持久代表地址（`p2p://` 而非本次的本地转发口）。
  final String baseUrl;
  final String? deviceName;

  /// `qbittorrent` / `embedded`。
  final String backend;

  /// host 上已注册的资源 provider id（内置源裸 id；Torznab 为 `torznab:<indexerId>`）。
  final List<String> providers;
  final String? fingerprintSha256;

  String get label => deviceName ?? baseUrl;

  /// 客户端搜到的资源（持久化 id `<providerId>:<instanceId>`）能不能交给这台 host 订阅。
  bool supportsResourceProvider(String persistedProviderId) {
    final String base = persistedProviderId.split(':').first;
    return providers.any(
      (String id) => id == base || id == persistedProviderId,
    );
  }
}

/// host 上的一条订阅（`videoDownloadSubscriptionToWire` 的镜像）。
class HostSubscription {
  const HostSubscription({
    required this.subscriptionId,
    required this.title,
    required this.searchQuery,
    required this.mediaKind,
    required this.mode,
    required this.resourceProvider,
    required this.enabled,
    required this.updatedAt,
    this.coverUrl,
    this.lastCheckedAt,
    this.lastMatchedAt,
    this.lastError,
    this.itemCounts = const <String, int>{},
  });

  factory HostSubscription.fromJson(Map<String, dynamic> json) {
    final Object? counts = json['itemCounts'];
    return HostSubscription(
      subscriptionId: json['subscriptionId'].toString(),
      title: (json['title'] ?? '').toString(),
      searchQuery: (json['searchQuery'] ?? '').toString(),
      mediaKind: (json['mediaKind'] ?? '').toString(),
      mode: (json['mode'] ?? '').toString(),
      resourceProvider: (json['resourceProvider'] ?? '').toString(),
      enabled: json['enabled'] == true,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      coverUrl: json['coverUrl']?.toString(),
      lastCheckedAt: (json['lastCheckedAt'] as num?)?.toInt(),
      lastMatchedAt: (json['lastMatchedAt'] as num?)?.toInt(),
      lastError: json['lastError']?.toString(),
      itemCounts: counts is Map
          ? <String, int>{
              for (final MapEntry<dynamic, dynamic> e in counts.entries)
                e.key.toString(): (e.value as num?)?.toInt() ?? 0,
            }
          : const <String, int>{},
    );
  }

  final String subscriptionId;
  final String title;
  final String searchQuery;
  final String mediaKind;
  final String mode;
  final String resourceProvider;
  final bool enabled;
  final int updatedAt;
  final String? coverUrl;
  final int? lastCheckedAt;
  final int? lastMatchedAt;
  final String? lastError;
  final Map<String, int> itemCounts;
}

/// 创建请求（wire 字段与引擎 `HostSubscriptionCreateRequest.fromJson` 一一对应）。
class HostSubscriptionCreate {
  const HostSubscriptionCreate({
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
    this.filterJson,
    this.startAfterEpisode,
    this.subtitlePolicy,
  });

  final String title;
  final String searchQuery;
  final String mediaKind;
  final String resourceProvider;
  final String? subscriptionId;
  final String? mode;
  final String? identityJson;
  final String? metadataProvider;
  final String? externalId;
  final String? discoveryCategory;
  final int? year;
  final int? season;
  final String? coverUrl;
  final String? filterJson;
  final int? startAfterEpisode;
  final String? subtitlePolicy;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'searchQuery': searchQuery,
    'mediaKind': mediaKind,
    'resourceProvider': resourceProvider,
    if (subscriptionId != null) 'subscriptionId': subscriptionId,
    if (mode != null) 'mode': mode,
    if (identityJson != null) 'identityJson': identityJson,
    if (metadataProvider != null) 'metadataProvider': metadataProvider,
    if (externalId != null) 'externalId': externalId,
    if (discoveryCategory != null) 'discoveryCategory': discoveryCategory,
    if (year != null) 'year': year,
    if (season != null) 'season': season,
    if (coverUrl != null) 'coverUrl': coverUrl,
    if (filterJson != null) 'filterJson': filterJson,
    if (startAfterEpisode != null) 'startAfterEpisode': startAfterEpisode,
    if (subtitlePolicy != null) 'subtitlePolicy': subtitlePolicy,
  };
}

class HostSubscriptionException implements Exception {
  const HostSubscriptionException(this.code, [this.detail, this.reason]);
  final String code;
  final String? detail;

  /// host 的结构化原因（`provider_unavailable` / `unsupported` / `not_found`）。
  final String? reason;

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

/// 内容订阅 client。每台 host 一条 [InterconnectHostChannel]，复用到 [close]。
class InterconnectSubscriptionClient {
  InterconnectSubscriptionClient({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration probeTimeout = const Duration(seconds: 4),
    Duration requestTimeout = const Duration(seconds: 30),
  }) : _repo = repo,
       _borrowedPlain = httpClient,
       _pinnedClientFactory = pinnedClientFactory,
       _probeTimeout = probeTimeout,
       _requestTimeout = requestTimeout;

  final SyncRepository _repo;

  /// 借用的明文 client（测试缝 / 调用方共享）：本 client 不关它。
  final http.Client? _borrowedPlain;

  /// 没借到时自建、各通道共用，[close] 时关。
  http.Client? _ownedPlain;
  final http.Client Function(String expectedFingerprint)? _pinnedClientFactory;
  final Duration _probeTimeout;
  final Duration _requestTimeout;
  final Map<String, InterconnectHostChannel> _channels =
      <String, InterconnectHostChannel>{};
  bool _closed = false;

  InterconnectHostChannel _channel(InterconnectHostRef host) {
    if (_closed) {
      throw const InterconnectChannelException(
        InterconnectChannelFailure.cancelled,
      );
    }
    return _channels.putIfAbsent(
      host.key,
      () => InterconnectHostChannel(
        repo: _repo,
        host: host,
        plainClient: _borrowedPlain ?? (_ownedPlain ??= http.Client()),
        pinnedClientFactory: _pinnedClientFactory,
      ),
    );
  }

  /// 关掉全部通道与自建的明文 client；在途与之后的请求抛
  /// `HostSubscriptionException('cancelled')`。
  void close() {
    if (_closed) return;
    _closed = true;
    for (final InterconnectHostChannel c in _channels.values) {
      c.close();
    }
    _channels.clear();
    _ownedPlain?.close();
    _ownedPlain = null;
  }

  /// 所有宣告 `subscriptions.supported` 的已配对 host（一个用户可能配多台）。
  /// 每台 host 只产出一个目标；探不到的原因见 [probeAllOutcomes]。
  Future<List<HostSubscriptionTarget>> probeAll() async =>
      <HostSubscriptionTarget>[
        for (final InterconnectCapabilityOutcome<HostSubscriptionTarget> o
            in await probeAllOutcomes())
          if (o is InterconnectCapabilityAvailable<HostSubscriptionTarget>)
            o.target,
      ];

  /// 每台已启用 host 的探测结局（含失败原因），并发探、按配对清单的组序返回。
  Future<List<InterconnectCapabilityOutcome<HostSubscriptionTarget>>>
  probeAllOutcomes() async {
    final List<InterconnectHostRef> hosts = interconnectPairedHostRefs(
      await _repo.getFushiClientUrls(),
    );
    return Future.wait(
      <Future<InterconnectCapabilityOutcome<HostSubscriptionTarget>>>[
        for (final InterconnectHostRef h in hosts) probeHost(h),
      ],
    );
  }

  /// 探一台 host 的订阅能力（`subscriptions.supported`）。
  Future<InterconnectCapabilityOutcome<HostSubscriptionTarget>> probeHost(
    InterconnectHostRef host,
  ) async {
    final List<FushiClientUrl> rows = await _repo.getFushiClientUrls();
    String? pin;
    String? rawName;
    for (final FushiClientUrl u in rows) {
      if (!host.matches(u)) continue;
      final String? fp = u.fingerprintSha256;
      if (pin == null && fp != null && fp.isNotEmpty) pin = fp;
      final String? name = u.deviceName;
      if (rawName == null && name != null && name.isNotEmpty) rawName = name;
    }
    final String? groupPin = pin;
    final String? groupName = rawName;
    return probeInterconnectCapability<HostSubscriptionTarget>(
      _channel(host),
      label: interconnectHostLabel(rows, host),
      timeout: _probeTimeout,
      parse: (Map<String, dynamic> caps, FushiClientUrl via) {
        final Object? subs = caps['subscriptions'];
        if (subs is! Map || subs['supported'] != true) return null;
        final Object? providers = subs['providers'];
        return HostSubscriptionTarget(
          host: host,
          baseUrl: host.anchorUrl,
          deviceName: via.deviceName ?? groupName,
          backend: (subs['backend'] ?? '').toString(),
          providers: providers is List
              ? providers
                    .map((Object? e) => e.toString())
                    .toList(growable: false)
              : const <String>[],
          fingerprintSha256: groupPin,
        );
      },
    );
  }

  Future<HostSubscription> create(
    HostSubscriptionTarget target,
    HostSubscriptionCreate request,
  ) async {
    final Map<String, dynamic> body = await _call(
      target,
      'POST',
      '/api/subscriptions',
      jsonBody: request.toJson(),
    );
    final Object? sub = body['subscription'];
    if (sub is! Map) throw const HostSubscriptionException('bad_response');
    return HostSubscription.fromJson(Map<String, dynamic>.from(sub));
  }

  Future<List<HostSubscription>> list(HostSubscriptionTarget target) async {
    final Map<String, dynamic> body = await _call(
      target,
      'GET',
      '/api/subscriptions',
    );
    final List<dynamic> rows =
        body['subscriptions'] as List<dynamic>? ?? const <dynamic>[];
    return rows
        .whereType<Map>()
        .map((Map e) => HostSubscription.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  Future<void> setEnabled(
    HostSubscriptionTarget target,
    String subscriptionId,
    bool enabled,
  ) => _call(
    target,
    'POST',
    '/api/subscriptions/${Uri.encodeComponent(subscriptionId)}/enable',
    jsonBody: <String, Object?>{'enabled': enabled},
  );

  Future<void> checkNow(
    HostSubscriptionTarget target,
    String? subscriptionId,
  ) => _call(
    target,
    'POST',
    subscriptionId == null
        ? '/api/subscriptions/check'
        : '/api/subscriptions/${Uri.encodeComponent(subscriptionId)}/check',
  );

  Future<void> delete(HostSubscriptionTarget target, String subscriptionId) =>
      _call(
        target,
        'DELETE',
        '/api/subscriptions/${Uri.encodeComponent(subscriptionId)}',
      );

  Future<Map<String, dynamic>> _call(
    HostSubscriptionTarget target,
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
  }) async {
    final InterconnectChannelResponse r;
    try {
      r = await _channel(await _hostOf(target)).send(
        method,
        path,
        body: jsonBody == null ? null : InterconnectRequestBody.json(jsonBody),
        timeout: _requestTimeout,
      );
    } on InterconnectChannelException catch (e) {
      throw HostSubscriptionException(e.code);
    }
    if (r.statusCode >= 400) {
      // 错误体按本路由原来的字段取（`{message, reason}`），非 JSON 原样带回。
      throw HostSubscriptionException(
        'http_${r.statusCode}',
        r.jsonString('message') ?? r.text,
        r.jsonString('reason'),
      );
    }
    return r.jsonObject ?? <String, dynamic>{};
  }

  /// client 产出的 target 自带 host 身份；调用方直接构造的老形状 target 按它的
  /// 地址在配对清单里认那台 host（行带 hostId 时按 hostId 选路），清单里没有才
  /// 退回按 URL 认。
  Future<InterconnectHostRef> _hostOf(HostSubscriptionTarget target) async =>
      target.host ??
      interconnectHostRefForUrl(
        await _repo.getFushiClientUrls(),
        target.baseUrl,
      ) ??
      target.hostRef;
}
