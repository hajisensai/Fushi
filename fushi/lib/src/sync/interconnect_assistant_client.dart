/// 互联「AI 助手会话」客户端（`/api/assistant`）：手机把一句话交给已配对的电脑，
/// 由电脑的 AI 与下载管线去办；手机只收快照、发动作。
library;

import 'dart:convert';

import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:http/http.dart' as http;

/// 一台已配对 host 的助手能力。
class HostAssistantTarget {
  const HostAssistantTarget({
    required this.baseUrl,
    required this.deviceName,
    required this.features,
    this.reason,
    this.fingerprintSha256,
  });

  final String baseUrl;
  final String? deviceName;

  /// 当前能开的会话种类（[kHostAssistantFeatureVideoAcquire] …）。
  final List<String> features;

  /// 开不了时 host 给的短码（`no_provider` / `not_ready` / `disabled`）；老 host 根本
  /// 没有 `assistant` 能力位时是 [kHostAssistantReasonUnsupported]。
  final String? reason;
  final String? fingerprintSha256;

  String get label => deviceName ?? baseUrl;

  bool supports(String feature) => features.contains(feature);
}

/// 老 host（没有 `assistant` 能力位）的本地短码。
const String kHostAssistantReasonUnsupported = 'unsupported';

/// host 回的一份会话信封。
class HostAssistantEnvelope {
  const HostAssistantEnvelope({
    required this.id,
    required this.revision,
    required this.view,
  });

  factory HostAssistantEnvelope.fromJson(Map<String, dynamic> json) {
    final Object? view = json['view'];
    return HostAssistantEnvelope(
      id: '${json['id'] ?? ''}',
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      view: view is Map
          ? view.map(
              (Object? key, Object? value) =>
                  MapEntry<String, Object?>('$key', value),
            )
          : const <String, Object?>{},
    );
  }

  final String id;
  final int revision;
  final Map<String, Object?> view;
}

class HostAssistantException implements Exception {
  const HostAssistantException(this.code, [this.detail]);

  /// `http_<status>` / `no_host`；409 时 [detail] 是 host 给的 reason 短码。
  final String code;
  final String? detail;

  bool get sessionGone => code == 'http_404';

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

class InterconnectAssistantClient {
  InterconnectAssistantClient({
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

  /// 长轮询一次等多久（host 侧另有 25 秒上限）。
  static const Duration longPollWait = Duration(seconds: 20);

  static http.Client _defaultPinnedClient(String expectedFingerprint) =>
      createPinnedHttpPackageClient(expectedFingerprint: expectedFingerprint);

  /// 只探这一台（「下载执行设备」点名的那台）。不在配对清单里 / 连不上 → null；
  /// 连得上但老 host 没有助手能力位 → reason = [kHostAssistantReasonUnsupported]。
  Future<HostAssistantTarget?> probeUrl(String baseUrl) async {
    final String? fallbackToken = await _repo.getFushiClientToken();
    for (final FushiClientUrl candidate in await _repo.getFushiClientUrls()) {
      if (!candidate.enabled || candidate.url != baseUrl) continue;
      final Uri? uri = _uri(candidate.url, '/api/capabilities');
      final String? token = interconnectTokenFor(candidate, fallbackToken);
      if (uri == null || token == null) return null;
      final (http.Client client, bool closeAfter) = _clientFor(
        candidate.url,
        fingerprint: candidate.fingerprintSha256,
      );
      try {
        final http.Response response = await client
            .get(uri, headers: _headers(token))
            .timeout(_probeTimeout);
        if (response.statusCode != 200) return null;
        final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map) return null;
        final Object? assistant = decoded['assistant'];
        if (assistant is! Map) {
          return HostAssistantTarget(
            baseUrl: candidate.url,
            deviceName: candidate.deviceName,
            features: const <String>[],
            reason: kHostAssistantReasonUnsupported,
            fingerprintSha256: candidate.fingerprintSha256,
          );
        }
        final Object? features = assistant['features'];
        return HostAssistantTarget(
          baseUrl: candidate.url,
          deviceName: candidate.deviceName,
          features: assistant['supported'] == true && features is List
              ? features.map((Object? f) => '$f').toList(growable: false)
              : const <String>[],
          reason: assistant['reason']?.toString(),
          fingerprintSha256: candidate.fingerprintSha256,
        );
      } catch (_) {
        return null;
      } finally {
        if (closeAfter) client.close();
      }
    }
    return null;
  }

  Future<HostAssistantEnvelope> open(
    HostAssistantTarget target, {
    required String feature,
    required String locale,
  }) async =>
      HostAssistantEnvelope.fromJson(
        await _call(
          target,
          'POST',
          '/api/assistant/sessions',
          jsonBody: <String, Object?>{'feature': feature, 'locale': locale},
        ),
      );

  /// 长轮询：快照越过 [after] 或等满 [wait] 就返回。
  Future<HostAssistantEnvelope> read(
    HostAssistantTarget target,
    String id, {
    int? after,
    Duration wait = Duration.zero,
  }) async =>
      HostAssistantEnvelope.fromJson(
        await _call(
          target,
          'GET',
          '/api/assistant/sessions/${Uri.encodeComponent(id)}',
          query: <String, String>{
            if (after != null) 'after': '$after',
            if (wait > Duration.zero) 'wait': '${wait.inSeconds}',
          },
          timeout: _requestTimeout + wait,
        ),
      );

  Future<HostAssistantEnvelope> act(
    HostAssistantTarget target,
    String id,
    Map<String, Object?> action,
  ) async =>
      HostAssistantEnvelope.fromJson(
        await _call(
          target,
          'POST',
          '/api/assistant/sessions/${Uri.encodeComponent(id)}/actions',
          jsonBody: action,
        ),
      );

  Future<void> close(HostAssistantTarget target, String id) => _call(
        target,
        'DELETE',
        '/api/assistant/sessions/${Uri.encodeComponent(id)}',
      );

  Future<Map<String, dynamic>> _call(
    HostAssistantTarget target,
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
    Map<String, String> query = const <String, String>{},
    Duration? timeout,
  }) async {
    final String? token = await _tokenForBaseUrl(target.baseUrl);
    if (token == null || token.isEmpty) {
      throw const HostAssistantException('no_host');
    }
    final Uri? uri = _uri(target.baseUrl, path, query: query);
    if (uri == null) throw const HostAssistantException('http', 'bad host url');
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
        await client.send(req).timeout(timeout ?? _requestTimeout),
      );
      final String text = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (response.statusCode >= 400) {
        String detail = text;
        try {
          final dynamic decoded = jsonDecode(text);
          if (decoded is Map && decoded['reason'] != null) {
            detail = decoded['reason'].toString();
          }
        } catch (_) {
          // 非 JSON 错误体原样带回。
        }
        throw HostAssistantException('http_${response.statusCode}', detail);
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

  Uri? _uri(
    String baseUrl,
    String path, {
    Map<String, String> query = const <String, String>{},
  }) {
    final Uri? base = _parse(baseUrl);
    if (base == null) return null;
    return base.replace(path: path, queryParameters: query);
  }
}
