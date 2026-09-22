/// 互联「代下载」客户端（`/api/downloads`，设计 §3.3）：把磁链交给已配对 host，
/// 由 host 下到它自己的库里；之后经既有远程库路径流播。
library;

import 'dart:convert';

import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:http/http.dart' as http;

class HostDownloadTarget {
  const HostDownloadTarget({
    required this.baseUrl,
    required this.deviceName,
    required this.backend,
    this.kinds = const <String>['video'],
    this.fingerprintSha256,
  });

  final String baseUrl;
  final String? deviceName;

  /// `qbittorrent` / `embedded`。
  final String backend;

  /// host 宣告能收的内容域：`video` 加上它能按域入库的发现页域（`novel` /
  /// `manga` / `audiobook` / `game`）。老 host 不带这个字段 = 只收视频。
  final List<String> kinds;
  final String? fingerprintSha256;

  String get label => deviceName ?? baseUrl;

  /// [discoveryKind] = `DiscoveryMediaKind.name`；null 表示视频。
  bool supportsKind(String? discoveryKind) =>
      discoveryKind == null || kinds.contains(discoveryKind);
}

/// host 上的一条下载任务（`videoDownloadJobToWire` 的镜像）。
class HostDownloadJob {
  const HostDownloadJob({
    required this.jobId,
    required this.title,
    required this.lifecycle,
    required this.stage,
    required this.stageProgress,
    required this.updatedAt,
    this.lastError,
  });

  factory HostDownloadJob.fromJson(Map<String, dynamic> json) =>
      HostDownloadJob(
        jobId: json['jobId'].toString(),
        title: (json['title'] ?? '').toString(),
        lifecycle: (json['lifecycle'] ?? '').toString(),
        stage: (json['stage'] ?? '').toString(),
        stageProgress: (json['stageProgress'] as num?)?.toDouble() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
        lastError: json['lastError']?.toString(),
      );

  final String jobId;
  final String title;
  final String lifecycle;
  final String stage;
  final double stageProgress;
  final int updatedAt;
  final String? lastError;
}

class HostDownloadException implements Exception {
  const HostDownloadException(this.code, [this.detail]);
  final String code;
  final String? detail;

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

class InterconnectDownloadClient {
  InterconnectDownloadClient({
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

  /// 第一台宣告 `downloads.supported` 的已配对 host。
  Future<HostDownloadTarget?> probe() async {
    for (final FushiClientUrl candidate in await _enabledCandidates()) {
      final HostDownloadTarget? target = await _probeCandidate(candidate);
      if (target != null) return target;
    }
    return null;
  }

  /// 只探这一台（用户在「下载执行设备」里选定的那台）；不在配对清单里 / 没宣告
  /// 能力 / 探不到 → null，**不**退而求其次换别的 host——用户点名的设备连不上要
  /// 如实告诉他，而不是悄悄下到另一台机器上。
  Future<HostDownloadTarget?> probeUrl(String baseUrl) async {
    for (final FushiClientUrl candidate in await _enabledCandidates()) {
      if (candidate.url == baseUrl) return _probeCandidate(candidate);
    }
    return null;
  }

  /// 全部宣告能力的已配对 host（资源搜索页的「下载到」下拉要列出来让用户挑）。
  Future<List<HostDownloadTarget>> probeAll() async {
    final List<HostDownloadTarget> targets = <HostDownloadTarget>[];
    for (final FushiClientUrl candidate in await _enabledCandidates()) {
      final HostDownloadTarget? target = await _probeCandidate(candidate);
      if (target != null) targets.add(target);
    }
    return targets;
  }

  Future<List<FushiClientUrl>> _enabledCandidates() async =>
      (await _repo.getFushiClientUrls())
          .where((FushiClientUrl u) => u.enabled)
          .toList(growable: false);

  Future<HostDownloadTarget?> _probeCandidate(FushiClientUrl candidate) async {
    final Uri? uri = _uri(candidate.url, '/api/capabilities');
    final String? token =
        interconnectTokenFor(candidate, await _repo.getFushiClientToken());
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
      final Object? downloads = decoded['downloads'];
      if (downloads is! Map || downloads['supported'] != true) return null;
      final Object? kinds = downloads['kinds'];
      return HostDownloadTarget(
        baseUrl: candidate.url,
        deviceName: candidate.deviceName,
        backend: (downloads['backend'] ?? '').toString(),
        kinds: kinds is List
            ? kinds.map((Object? k) => k.toString()).toList(growable: false)
            : const <String>['video'],
        fingerprintSha256: candidate.fingerprintSha256,
      );
    } catch (_) {
      return null;
    } finally {
      if (closeAfter) client.close();
    }
  }

  /// [discoveryKind] = `DiscoveryMediaKind.name`（非视频域，host 按域入库）；
  /// null = 视频，此时 [mediaKind] 才有意义。
  Future<String> addMagnet(
    HostDownloadTarget target, {
    required String magnetUri,
    required String title,
    String mediaKind = 'movie',
    String? discoveryKind,
  }) async {
    final Map<String, dynamic> body = await _call(
      target,
      'POST',
      '/api/downloads',
      jsonBody: <String, Object?>{
        'magnet': magnetUri,
        'title': title,
        'mediaKind': mediaKind,
        if (discoveryKind != null) 'discoveryKind': discoveryKind,
      },
    );
    return body['jobId'].toString();
  }

  Future<List<HostDownloadJob>> listJobs(HostDownloadTarget target) async {
    final Map<String, dynamic> body = await _call(
      target,
      'GET',
      '/api/downloads',
    );
    final List<dynamic> jobs =
        body['jobs'] as List<dynamic>? ?? const <dynamic>[];
    return jobs
        .whereType<Map>()
        .map((Map e) => HostDownloadJob.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  Future<void> cancel(HostDownloadTarget target, String jobId) => _call(
        target,
        'POST',
        '/api/downloads/${Uri.encodeComponent(jobId)}/cancel',
      );

  Future<void> retry(HostDownloadTarget target, String jobId) => _call(
        target,
        'POST',
        '/api/downloads/${Uri.encodeComponent(jobId)}/retry',
      );

  Future<void> delete(HostDownloadTarget target, String jobId) =>
      _call(target, 'DELETE', '/api/downloads/${Uri.encodeComponent(jobId)}');

  Future<Map<String, dynamic>> _call(
    HostDownloadTarget target,
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
  }) async {
    final String? token = await _tokenForBaseUrl(target.baseUrl);
    if (token == null || token.isEmpty) {
      throw const HostDownloadException('no_host');
    }
    final Uri? uri = _uri(target.baseUrl, path);
    if (uri == null) throw const HostDownloadException('http', 'bad host url');
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
        try {
          final dynamic decoded = jsonDecode(text);
          if (decoded is Map && decoded['message'] != null) {
            detail = decoded['message'].toString();
          }
        } catch (_) {
          // 非 JSON 错误体原样带回。
        }
        throw HostDownloadException('http_${response.statusCode}', detail);
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
