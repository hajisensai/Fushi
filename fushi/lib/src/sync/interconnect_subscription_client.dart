/// 互联「内容订阅」客户端（`/api/subscriptions`）：订阅在已配对 host 上创建并由
/// host 自己周期跑（搜资源 → 投 host 的下载管线）；本机只做浏览/启停/删除。
///
/// 与 `InterconnectDownloadClient` 同一形状（探测能力位 → pinned client 打请求）。
library;

import 'dart:convert';

import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:http/http.dart' as http;

class HostSubscriptionTarget {
  const HostSubscriptionTarget({
    required this.baseUrl,
    required this.deviceName,
    required this.backend,
    required this.providers,
    this.fingerprintSha256,
  });

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

class InterconnectSubscriptionClient {
  InterconnectSubscriptionClient({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration probeTimeout = const Duration(seconds: 4),
    Duration requestTimeout = const Duration(seconds: 30),
  })  : _repo = repo,
        _httpClient = httpClient ?? http.Client(),
        _pinnedClientFactory = pinnedClientFactory ?? _defaultPinnedClient,
        _probeTimeout = probeTimeout,
        _requestTimeout = requestTimeout;

  final SyncRepository _repo;
  final http.Client _httpClient;
  final http.Client Function(String expectedFingerprint) _pinnedClientFactory;
  final Duration _probeTimeout;
  final Duration _requestTimeout;

  static http.Client _defaultPinnedClient(String expectedFingerprint) =>
      createPinnedHttpPackageClient(expectedFingerprint: expectedFingerprint);

  /// 所有宣告 `subscriptions.supported` 的已配对 host（一个用户可能配多台）。
  Future<List<HostSubscriptionTarget>> probeAll() async {
    final List<FushiClientUrl> candidates = (await _repo.getFushiClientUrls())
        .where((FushiClientUrl u) => u.enabled)
        .toList(growable: false);
    final String? fallbackToken = await _repo.getFushiClientToken();
    final List<HostSubscriptionTarget> targets = <HostSubscriptionTarget>[];
    for (final FushiClientUrl candidate in candidates) {
      final Uri? uri = _uri(candidate.url, '/api/capabilities');
      final String? token = interconnectTokenFor(candidate, fallbackToken);
      if (uri == null || token == null) continue;
      final (http.Client client, bool closeAfter) = _clientFor(
        candidate.url,
        fingerprint: candidate.fingerprintSha256,
      );
      try {
        final http.Response response = await client
            .get(uri, headers: _headers(token))
            .timeout(_probeTimeout);
        if (response.statusCode != 200) continue;
        final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map) continue;
        final Object? subs = decoded['subscriptions'];
        if (subs is! Map || subs['supported'] != true) continue;
        final Object? providers = subs['providers'];
        targets.add(HostSubscriptionTarget(
          baseUrl: candidate.url,
          deviceName: candidate.deviceName,
          backend: (subs['backend'] ?? '').toString(),
          providers: providers is List
              ? providers
                  .map((dynamic e) => e.toString())
                  .toList(growable: false)
              : const <String>[],
          fingerprintSha256: candidate.fingerprintSha256,
        ));
      } catch (_) {
        continue;
      } finally {
        if (closeAfter) client.close();
      }
    }
    return targets;
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
    final Map<String, dynamic> body =
        await _call(target, 'GET', '/api/subscriptions');
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
  ) =>
      _call(
        target,
        'POST',
        '/api/subscriptions/${Uri.encodeComponent(subscriptionId)}/enable',
        jsonBody: <String, Object?>{'enabled': enabled},
      );

  Future<void> checkNow(
          HostSubscriptionTarget target, String? subscriptionId) =>
      _call(
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
    final String? token = await _tokenForBaseUrl(target.baseUrl);
    if (token == null || token.isEmpty) {
      throw const HostSubscriptionException('no_host');
    }
    final Uri? uri = _uri(target.baseUrl, path);
    if (uri == null) {
      throw const HostSubscriptionException('http', 'bad host url');
    }
    final (http.Client client, bool closeAfter) = _clientFor(
      target.baseUrl,
      fingerprint: target.fingerprintSha256,
    );
    try {
      final http.Request req = http.Request(method, uri)
        ..headers.addAll(_headers(token));
      if (jsonBody != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(jsonBody);
      }
      final http.Response response = await http.Response.fromStream(
        await client.send(req).timeout(_requestTimeout),
      );
      final String text = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (response.statusCode >= 400) {
        String detail = text;
        String? reason;
        try {
          final dynamic decoded = jsonDecode(text);
          if (decoded is Map) {
            if (decoded['message'] != null)
              detail = decoded['message'].toString();
            reason = decoded['reason']?.toString();
          }
        } catch (_) {
          // 非 JSON 错误体原样带回。
        }
        throw HostSubscriptionException(
          'http_${response.statusCode}',
          detail,
          reason,
        );
      }
      final dynamic decoded =
          text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
      if (decoded is! Map) return <String, dynamic>{};
      return Map<String, dynamic>.from(decoded);
    } finally {
      if (closeAfter) client.close();
    }
  }

  Future<String?> _tokenForBaseUrl(String baseUrl) async {
    final String? fallbackToken = await _repo.getFushiClientToken();
    for (final FushiClientUrl u in await _repo.getFushiClientUrls()) {
      if (u.url == baseUrl) return interconnectTokenFor(u, fallbackToken);
    }
    return (fallbackToken != null && fallbackToken.isNotEmpty)
        ? fallbackToken
        : null;
  }

  Map<String, String> _headers(String token) => <String, String>{
        'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      };

  (http.Client, bool) _clientFor(String baseUrl, {String? fingerprint}) {
    final Uri? base = _parse(baseUrl);
    final bool usePinned = base != null &&
        base.isScheme('https') &&
        fingerprint != null &&
        fingerprint.isNotEmpty;
    if (usePinned) return (_pinnedClientFactory(fingerprint), true);
    return (_httpClient, false);
  }

  static Uri? _parse(String baseUrl) {
    try {
      return Uri.parse(WebDavOps.normalizeUrl(baseUrl));
    } catch (_) {
      return null;
    }
  }

  Uri? _uri(String baseUrl, String path) {
    final Uri? base = _parse(baseUrl);
    if (base == null) return null;
    return base.replace(path: path, queryParameters: const <String, String>{});
  }
}
