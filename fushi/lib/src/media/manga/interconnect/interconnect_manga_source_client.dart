/// 互联「对端扩展源代理浏览」的客户端：探测每台已配对对端的 `mangaSources` 能力位、
/// 取它的已启用源清单，再把热门 / 最新 / 搜索 / 详情 / 页表 / 页图 / 封面逐个打到
/// **提供该源的那台对端**上（`/api/manga-sources/**`）。
///
/// 为什么不走 [InterconnectSyncBackend]：它是「一个会话 = 第一台可达对端」模型，
/// 而扩展源分散在各台对端上（桌面装了 Mihon、Mac 装了 Aidoku），每个源必须定向打
/// 自己所在的那台。传输契约与 `InterconnectMangaOcrClient` 同构：候选地址来自
/// [SyncRepository.getFushiClientUrls]、`Basic base64(hibiki:token)`、https 带指纹
/// 走钉扎 client。老 host 的 capabilities 无 `mangaSources` → 该对端不列源。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/manga_sources/host_manga_source_host.dart';
import 'package:fushi_engine/sync/manga_sources/host_manga_source_routes.dart'
    show kMangaSourcesApiPrefix;
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';

/// 一台透出了扩展源的已配对对端（探测命中的候选地址 + 凭据 + 它的源清单）。
class InterconnectMangaSourcePeer {
  const InterconnectMangaSourcePeer({
    required this.baseUrl,
    required this.token,
    required this.sources,
    this.fingerprintSha256,
    this.deviceName,
  });

  final String baseUrl;
  final String token;
  final List<RemoteMangaSourceInfo> sources;

  /// https 端点的证书指纹（TOFU 钉扎）；http 老路径为 null。
  final String? fingerprintSha256;
  final String? deviceName;

  /// 展示名：对端自报名优先，回落主机名。
  String get displayName {
    final String? name = deviceName;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return Uri.tryParse(baseUrl)?.host ?? baseUrl;
  }
}

/// 一个可浏览的对端源 = 源信息 + 提供它的对端。
///
/// 同一个源 id 出现在多台对端上时注册表只保留第一台（源身份不含设备），所以
/// 这里的 [peer] 只是「此刻经谁走」，不进任何持久化身份。
class InterconnectRemoteSource {
  const InterconnectRemoteSource({required this.info, required this.peer});

  final RemoteMangaSourceInfo info;
  final InterconnectMangaSourcePeer peer;

  String get id => info.id;
  String get name => info.name;
  String get language => info.language;
}

/// 代理源请求失败：机器可读 [code] + 人类可读 [message]。
///
/// code：`http`（网络 / 非 2xx）/ `auth`（token 被拒）/ `source_not_found`（对端
/// 已把该源停用或卸载）/ `cloudflare`（对端被挑战页拦下，只能在对端解）/
/// `runtime`（对端扩展运行时报错）/ `unavailable`（没有对端提供该源）。
class InterconnectMangaSourceException implements Exception {
  const InterconnectMangaSourceException(this.code, this.message);

  static const String codeHttp = 'http';
  static const String codeAuth = 'auth';
  static const String codeUnavailable = 'unavailable';

  final String code;
  final String message;

  bool get isCloudflare => code == HostMangaSourceException.codeCloudflare;
  bool get isSourceNotFound =>
      code == HostMangaSourceException.codeSourceNotFound;

  @override
  String toString() => 'InterconnectMangaSourceException($code): $message';
}

/// 窄接口（注册表 / 适配器 / 浏览页依赖它，测试注 fake）。
abstract class InterconnectMangaSourceTransport {
  /// 并发探测全部已启用对端，返回带 `mangaSources` 能力位且源清单非空的那些。
  Future<List<InterconnectMangaSourcePeer>> probe();

  Future<List<Map<String, Object?>>> filters(
    InterconnectMangaSourcePeer peer,
    String sourceId,
  );

  Future<RemoteMangaBrowsePage> browse(
    InterconnectMangaSourcePeer peer,
    String sourceId, {
    required RemoteMangaBrowseMode mode,
    required int page,
    String query = '',
    List<Map<String, Object?>> filters = const <Map<String, Object?>>[],
  });

  Future<RemoteMangaSeriesDetail> details(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    Map<String, Object?> series,
  );

  Future<List<Map<String, Object?>>> pages(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
  );

  Future<Uint8List> pageImage(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
    Map<String, Object?> page,
  );

  Future<Uint8List> coverImage(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    String url,
  );
}

/// 生产实现。
class InterconnectMangaSourceClient
    implements InterconnectMangaSourceTransport {
  InterconnectMangaSourceClient({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration probeTimeout = const Duration(seconds: 4),
    Duration requestTimeout = const Duration(seconds: 60),
  }) : _repo = repo,
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

  @override
  Future<List<InterconnectMangaSourcePeer>> probe() async {
    final List<FushiClientUrl> candidates = (await _repo.getFushiClientUrls())
        .where((FushiClientUrl u) => u.enabled)
        .toList(growable: false);
    if (candidates.isEmpty) return const <InterconnectMangaSourcePeer>[];
    final String? fallbackToken = await _repo.getFushiClientToken();
    final List<InterconnectMangaSourcePeer?> probed = await Future.wait(
      <Future<InterconnectMangaSourcePeer?>>[
        for (final FushiClientUrl candidate in candidates)
          _probeOne(candidate, interconnectTokenFor(candidate, fallbackToken)),
      ],
    );
    return <InterconnectMangaSourcePeer>[
      for (final InterconnectMangaSourcePeer? peer in probed)
        if (peer != null && peer.sources.isNotEmpty) peer,
    ];
  }

  Future<InterconnectMangaSourcePeer?> _probeOne(
    FushiClientUrl candidate,
    String? token,
  ) async {
    if (token == null) return null;
    final Uri? capabilities = _uri(candidate.url, '/api/capabilities');
    if (capabilities == null) return null;
    final (http.Client client, bool closeAfter) = _clientFor(
      candidate.url,
      fingerprint: candidate.fingerprintSha256,
    );
    try {
      final http.Response response = await client
          .get(capabilities, headers: _headers(token))
          .timeout(_probeTimeout);
      if (response.statusCode != 200) return null;
      final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
      // 老 host / 无头服务端 / iOS 对端：没有 `mangaSources` 键 → 不列它的源。
      if (decoded is! Map || decoded['mangaSources'] is! Map) return null;
      final http.Response list = await client
          .get(
            _uri(candidate.url, kMangaSourcesApiPrefix)!,
            headers: _headers(token),
          )
          .timeout(_probeTimeout);
      if (list.statusCode != 200) return null;
      final Object? listJson = jsonDecode(utf8.decode(list.bodyBytes));
      final List<RemoteMangaSourceInfo> sources = <RemoteMangaSourceInfo>[
        for (final Map<String, Object?> json in jsonMapList(
          listJson is Map ? listJson['sources'] : null,
        ))
          if (RemoteMangaSourceInfo.fromJson(json)
              case final RemoteMangaSourceInfo info)
            info,
      ];
      return InterconnectMangaSourcePeer(
        baseUrl: candidate.url,
        token: token,
        sources: sources,
        fingerprintSha256: candidate.fingerprintSha256,
        deviceName: candidate.deviceName,
      );
    } catch (_) {
      return null;
    } finally {
      if (closeAfter) client.close();
    }
  }

  @override
  Future<List<Map<String, Object?>>> filters(
    InterconnectMangaSourcePeer peer,
    String sourceId,
  ) async {
    final Map<String, Object?> json = await _getJson(
      peer,
      _sourcePath(sourceId, 'filters'),
    );
    return jsonMapList(json['filters']);
  }

  @override
  Future<RemoteMangaBrowsePage> browse(
    InterconnectMangaSourcePeer peer,
    String sourceId, {
    required RemoteMangaBrowseMode mode,
    required int page,
    String query = '',
    List<Map<String, Object?>> filters = const <Map<String, Object?>>[],
  }) async => RemoteMangaBrowsePage.fromJson(
    await _postJson(peer, _sourcePath(sourceId, 'browse'), <String, Object?>{
      'mode': mode.name,
      'page': page,
      'query': query,
      'filters': filters,
    }),
  );

  @override
  Future<RemoteMangaSeriesDetail> details(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    Map<String, Object?> series,
  ) async => RemoteMangaSeriesDetail.fromJson(
    await _postJson(peer, _sourcePath(sourceId, 'details'), <String, Object?>{
      'series': series,
    }),
  );

  @override
  Future<List<Map<String, Object?>>> pages(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
  ) async {
    final Map<String, Object?> json = await _postJson(
      peer,
      _sourcePath(sourceId, 'pages'),
      <String, Object?>{'series': series, 'chapter': chapter},
    );
    return jsonMapList(json['pages']);
  }

  @override
  Future<Uint8List> pageImage(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
    Map<String, Object?> page,
  ) => _postBytes(peer, _sourcePath(sourceId, 'page-image'), <String, Object?>{
    'series': series,
    'chapter': chapter,
    'page': page,
  });

  @override
  Future<Uint8List> coverImage(
    InterconnectMangaSourcePeer peer,
    String sourceId,
    String url,
  ) => _postBytes(peer, _sourcePath(sourceId, 'cover'), <String, Object?>{
    'url': url,
  });

  // ── HTTP 内部 ─────────────────────────────────────────────────

  static String _sourcePath(String sourceId, String action) =>
      '$kMangaSourcesApiPrefix/${Uri.encodeComponent(sourceId)}/$action';

  Map<String, String> _headers(String token, {bool json = false}) =>
      <String, String>{
        'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        if (json) 'Content-Type': 'application/json',
      };

  static Uri? _uri(String baseUrl, String path) {
    final Uri? base = Uri.tryParse(baseUrl.trim());
    if (base == null || base.host.isEmpty) return null;
    return base.replace(path: path, query: null, fragment: null);
  }

  /// https + 指纹 → 新建钉扎 client（调用方负责 close）；否则复用共享明文 client。
  (http.Client, bool) _clientFor(String baseUrl, {String? fingerprint}) {
    final Uri? base = Uri.tryParse(baseUrl);
    final bool usePinned =
        base != null &&
        base.isScheme('https') &&
        fingerprint != null &&
        fingerprint.isNotEmpty;
    if (usePinned) return (_pinnedClientFactory(fingerprint), true);
    return (_httpClient, false);
  }

  Future<http.Response> _send(
    InterconnectMangaSourcePeer peer,
    String method,
    String path, {
    Object? body,
  }) async {
    final Uri? uri = _uri(peer.baseUrl, path);
    if (uri == null) {
      throw InterconnectMangaSourceException(
        InterconnectMangaSourceException.codeHttp,
        'Bad peer URL: ${peer.baseUrl}',
      );
    }
    final (http.Client client, bool closeAfter) = _clientFor(
      peer.baseUrl,
      fingerprint: peer.fingerprintSha256,
    );
    try {
      final http.Response response = switch (method) {
        'GET' =>
          await client
              .get(uri, headers: _headers(peer.token))
              .timeout(_requestTimeout),
        _ =>
          await client
              .post(
                uri,
                headers: _headers(peer.token, json: true),
                body: jsonEncode(body),
              )
              .timeout(_requestTimeout),
      };
      _checkStatus(response);
      return response;
    } on InterconnectMangaSourceException {
      rethrow;
    } catch (error) {
      throw InterconnectMangaSourceException(
        InterconnectMangaSourceException.codeHttp,
        '$error',
      );
    } finally {
      if (closeAfter) client.close();
    }
  }

  void _checkStatus(http.Response response) {
    final int status = response.statusCode;
    if (status >= 200 && status < 300) return;
    if (status == 401 || status == 403) {
      throw InterconnectMangaSourceException(
        InterconnectMangaSourceException.codeAuth,
        'HTTP $status',
      );
    }
    // host 路由把运行时失败编码成 `{error: {code, message}}`（404 = 源已不在）。
    try {
      final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map && decoded['error'] is Map) {
        final Map<Object?, Object?> error =
            decoded['error'] as Map<Object?, Object?>;
        throw InterconnectMangaSourceException(
          error['code']?.toString() ?? HostMangaSourceException.codeRuntime,
          error['message']?.toString() ?? 'HTTP $status',
        );
      }
    } on FormatException {
      // 非 JSON 错误体：落到下面的通用 http 错误。
    }
    throw InterconnectMangaSourceException(
      status == 404
          ? HostMangaSourceException.codeSourceNotFound
          : InterconnectMangaSourceException.codeHttp,
      'HTTP $status',
    );
  }

  Future<Map<String, Object?>> _getJson(
    InterconnectMangaSourcePeer peer,
    String path,
  ) async => jsonMap(
    jsonDecode(utf8.decode((await _send(peer, 'GET', path)).bodyBytes)),
  );

  Future<Map<String, Object?>> _postJson(
    InterconnectMangaSourcePeer peer,
    String path,
    Map<String, Object?> body,
  ) async => jsonMap(
    jsonDecode(
      utf8.decode((await _send(peer, 'POST', path, body: body)).bodyBytes),
    ),
  );

  Future<Uint8List> _postBytes(
    InterconnectMangaSourcePeer peer,
    String path,
    Map<String, Object?> body,
  ) async => (await _send(peer, 'POST', path, body: body)).bodyBytes;
}
