/// Kavita 协议层：HTTP 封装 + URL 构造（纯 Dart，无 Flutter / 插件）。
///
/// 协议事实（实测 Kavita 0.8.8.0）：
/// - 鉴权：`POST /api/Plugin/authenticate?apiKey&pluginName` → `{token(JWT),
///   refreshToken, apiKey}`。常规请求带 `Authorization: Bearer <JWT>`；JWT 过期（401）
///   时用 apiKey 重新鉴权一次再重放请求（比 refreshToken 轮换简单，没有共享实例风险）。
/// - `GET /api/Reader/image` 与 `/api/Image/*-cover` 是 AllowAnonymous、认 `apiKey`
///   查询参数，所以能直接交给 `Image.network` / 预取（没有头通道）。**这类 URL 带
///   长期密钥**——诊断日志 / 错误上报一律经 `redactCredentialsInText`（`apikey` 已登记）。
/// - 系列分页：`POST /api/Series/all-v2?PageNumber&PageSize`，body 是过滤器
///   （`{}` = 全部），分页信息在响应头 `Pagination`（JSON）。
/// - 下载：`GET /api/Download/chapter?chapterId` 单文件回原文件（EPUB 为
///   `application/epub+zip`，CBZ 可达数百 MB），文件名在 RFC 5987 `filename*`。
/// - 进度：`POST /api/Reader/progress`；`lastModifiedUtc` 由服务器盖章。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:fushi_engine/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/url_input_normalizer.dart';

/// Kavita 返回非 2xx。[path] 只含路径（不含查询串，避免带出 apiKey）。
class KavitaApiException implements Exception {
  const KavitaApiException(this.statusCode, this.path);

  final int statusCode;
  final String path;

  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;

  @override
  String toString() => 'KavitaApiException($statusCode, $path)';
}

/// 下载被取消。
class KavitaDownloadCancelled implements Exception {
  const KavitaDownloadCancelled();

  @override
  String toString() => 'KavitaDownloadCancelled';
}

/// 协作式取消令牌（下载逐块检查）。
class KavitaCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// 下载结果。
class KavitaDownloadResult {
  const KavitaDownloadResult({
    required this.file,
    required this.bytes,
    this.fileName,
    this.contentType,
  });

  final File file;
  final int bytes;

  /// 服务器给的文件名（`Content-Disposition`），可能缺。
  final String? fileName;
  final String? contentType;
}

class KavitaApi {
  KavitaApi({
    required this.serverUrl,
    required this.apiKey,
    this.pluginName = kPluginName,
    http.Client? client,
    KavitaAuthResult? initialAuth,
  }) : _client = client ?? createAppHttpIoClient(),
       _token = initialAuth?.token;

  /// 鉴权时报给服务器的插件名（Kavita 用它标注会话来源）。
  static const String kPluginName = 'Fushi';

  /// 单个小请求的响应超时。
  static const Duration kRequestTimeout = Duration(seconds: 20);

  /// 下载时两个数据块之间允许的最长停顿（stall 超时，整体不设限）。
  static const Duration kDownloadStallTimeout = Duration(seconds: 60);

  /// 归一化后的服务器根 URL（含 scheme、无尾斜杠）。
  final String serverUrl;

  /// 长期 API key（也用于图片 URL 的 `apiKey` 查询参数）。
  final String apiKey;
  final String pluginName;
  final http.Client _client;

  String? _token;
  Future<void>? _authInFlight;

  /// 归一化用户输入的服务器地址：折全角、补 scheme（缺省 http）、去尾斜杠。
  static String normalizeServerUrl(String raw) {
    String url = normalizeUrlInput(raw);
    if (url.isEmpty) return url;
    final RegExpMatch? scheme = RegExp(
      r'^(https?)://',
      caseSensitive: false,
    ).firstMatch(url);
    if (scheme == null) {
      url = 'http://$url';
    } else if (scheme.group(1) != scheme.group(1)!.toLowerCase()) {
      url = '${scheme.group(1)!.toLowerCase()}://${url.substring(scheme.end)}';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  void close() => _client.close();

  Uri uri(String path, [Map<String, String>? query]) {
    final Uri base = Uri.parse('$serverUrl$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(
      queryParameters: <String, String>{...base.queryParameters, ...query},
    );
  }

  // ---- URL 构造（带 apiKey，交给图片解码器 / 预取） ----

  /// 流式阅读的一页图片。`page` 为 0 起。
  String pageImageUrl(int chapterId, int page) =>
      uri('/api/Reader/image', <String, String>{
        'chapterId': '$chapterId',
        'page': '$page',
        'apiKey': apiKey,
        'extractPdf': 'true',
      }).toString();

  String seriesCoverUrl(int seriesId) => uri(
    '/api/Image/series-cover',
    <String, String>{'seriesId': '$seriesId', 'apiKey': apiKey},
  ).toString();

  String volumeCoverUrl(int volumeId) => uri(
    '/api/Image/volume-cover',
    <String, String>{'volumeId': '$volumeId', 'apiKey': apiKey},
  ).toString();

  String chapterCoverUrl(int chapterId) => uri(
    '/api/Image/chapter-cover',
    <String, String>{'chapterId': '$chapterId', 'apiKey': apiKey},
  ).toString();

  // ---- 鉴权 ----

  /// 用 apiKey 换 JWT。也作连接探测（401 → [KavitaApiException]）。
  Future<KavitaAuthResult> authenticate() async {
    final http.Response res = await _rawSend(
      'POST',
      '/api/Plugin/authenticate',
      query: <String, String>{'apiKey': apiKey, 'pluginName': pluginName},
      authorized: false,
    );
    final KavitaAuthResult auth = KavitaAuthResult.fromJson(_decodeMap(res));
    if (auth.token.isEmpty) {
      throw const FormatException('Kavita authenticate: empty token');
    }
    _token = auth.token;
    return auth;
  }

  Future<void> _ensureToken() async {
    if (_token != null) return;
    await _reauth();
  }

  Future<void> _reauth() {
    // 并发请求同时撞 401 只重鉴权一次。
    return _authInFlight ??= authenticate()
        .then<void>((_) {})
        .whenComplete(() => _authInFlight = null);
  }

  Map<String, String> get _baseHeaders => <String, String>{
    'Accept': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<http.Response> _rawSend(
    String method,
    String path, {
    Map<String, String>? query,
    Object? jsonBody,
    bool authorized = true,
  }) async {
    try {
      final http.Request req = http.Request(method, uri(path, query));
      req.headers.addAll(authorized ? _baseHeaders : _jsonAccept);
      if (jsonBody != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(jsonBody);
      }
      final http.StreamedResponse streamed = await _client
          .send(req)
          .timeout(kRequestTimeout);
      final http.Response res = await http.Response.fromStream(
        streamed,
      ).timeout(kRequestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw KavitaApiException(res.statusCode, path);
      }
      return res;
    } on http.ClientException catch (e) {
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  static const Map<String, String> _jsonAccept = <String, String>{
    'Accept': 'application/json',
  };

  /// 带 JWT 的请求；401 时重鉴权一次并重放。
  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? jsonBody,
  }) async {
    await _ensureToken();
    try {
      return await _rawSend(method, path, query: query, jsonBody: jsonBody);
    } on KavitaApiException catch (e) {
      if (!e.isUnauthorized) rethrow;
      _token = null;
      await _reauth();
      return _rawSend(method, path, query: query, jsonBody: jsonBody);
    }
  }

  Map<String, Object?> _decodeMap(http.Response res) {
    final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map) {
      throw const FormatException('Kavita: expected JSON object');
    }
    return decoded.cast<String, Object?>();
  }

  List<Object?> _decodeList(http.Response res) {
    final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! List) {
      throw const FormatException('Kavita: expected JSON array');
    }
    return decoded.cast<Object?>();
  }

  // ---- 浏览 ----

  Future<List<KavitaLibrary>> getLibraries() async {
    final http.Response res = await _send('GET', '/api/Library/libraries');
    return <KavitaLibrary>[
      for (final Object? e in _decodeList(res))
        if (e is Map) KavitaLibrary.fromJson(e.cast<String, Object?>()),
    ];
  }

  /// 系列分页。[libraryId] 非空时按库过滤。[pageNumber] 从 1 起（Kavita 口径）。
  Future<KavitaSeriesPage> getSeriesPage({
    int? libraryId,
    int pageNumber = 1,
    int pageSize = 50,
  }) async {
    final Map<String, Object?> filter = <String, Object?>{
      if (libraryId != null)
        'statements': <Map<String, Object?>>[
          // field 19 = Libraries, comparison 0 = Equal（FilterV2Dto）。
          <String, Object?>{
            'comparison': 0,
            'field': 19,
            'value': '$libraryId',
          },
        ],
      'combination': 1,
      'limitTo': 0,
      'sortOptions': <String, Object?>{'sortField': 1, 'isAscending': true},
    };
    final http.Response res = await _send(
      'POST',
      '/api/Series/all-v2',
      query: <String, String>{
        'PageNumber': '$pageNumber',
        'PageSize': '$pageSize',
      },
      jsonBody: filter,
    );
    final List<KavitaSeries> items = <KavitaSeries>[
      for (final Object? e in _decodeList(res))
        if (e is Map) KavitaSeries.fromJson(e.cast<String, Object?>()),
    ];
    return _pageFromHeader(res, items, pageNumber);
  }

  static KavitaSeriesPage _pageFromHeader(
    http.Response res,
    List<KavitaSeries> items,
    int requestedPage,
  ) {
    int current = requestedPage;
    int totalPages = requestedPage;
    int totalItems = items.length;
    final String? raw = res.headers['pagination'];
    if (raw != null && raw.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          current = kavitaTryInt(decoded['currentPage']) ?? current;
          totalPages = kavitaTryInt(decoded['totalPages']) ?? totalPages;
          totalItems = kavitaTryInt(decoded['totalItems']) ?? totalItems;
        }
      } on FormatException {
        // 分页头坏了：当作单页，不让浏览失败。
      }
    }
    return KavitaSeriesPage(
      items: items,
      pageNumber: current,
      totalPages: totalPages,
      totalItems: totalItems,
    );
  }

  Future<KavitaSeries> getSeries(int seriesId) async {
    final http.Response res = await _send('GET', '/api/Series/$seriesId');
    return KavitaSeries.fromJson(_decodeMap(res));
  }

  Future<KavitaSeriesDetail> getSeriesDetail(int seriesId) async {
    final http.Response res = await _send(
      'GET',
      '/api/Series/series-detail',
      query: <String, String>{'seriesId': '$seriesId'},
    );
    return KavitaSeriesDetail.fromJson(_decodeMap(res));
  }

  Future<KavitaChapterInfo> getChapterInfo(int chapterId) async {
    final http.Response res = await _send(
      'GET',
      '/api/Reader/chapter-info',
      query: <String, String>{'chapterId': '$chapterId'},
    );
    return KavitaChapterInfo.fromJson(_decodeMap(res));
  }

  /// 阅读器分页图片字节（带 apiKey，不依赖 JWT）。
  Future<Uint8List> fetchPageBytes(int chapterId, int page) async {
    try {
      final http.Response res = await _client
          .get(Uri.parse(pageImageUrl(chapterId, page)))
          .timeout(kRequestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw KavitaApiException(res.statusCode, '/api/Reader/image');
      }
      return res.bodyBytes;
    } on http.ClientException catch (e) {
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  Future<Uint8List> fetchSeriesCoverBytes(int seriesId) async {
    try {
      final http.Response res = await _client
          .get(Uri.parse(seriesCoverUrl(seriesId)))
          .timeout(kRequestTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw KavitaApiException(res.statusCode, '/api/Image/series-cover');
      }
      return res.bodyBytes;
    } on http.ClientException catch (e) {
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  /// EPUB 目录（脊柱页下标）。
  Future<List<KavitaBookTocItem>> getBookToc(int chapterId) async {
    final http.Response res = await _send(
      'GET',
      '/api/Book/$chapterId/chapters',
    );
    return <KavitaBookTocItem>[
      for (final Object? e in _decodeList(res))
        if (e is Map) KavitaBookTocItem.fromJson(e.cast<String, Object?>()),
    ];
  }

  // ---- 进度 ----

  /// 读章节进度。服务器没有记录时回 pageNum 0 的空进度（`lastModifiedUtc` 缺）。
  Future<KavitaProgress> getProgress(int chapterId) async {
    final http.Response res = await _send(
      'GET',
      '/api/Reader/get-progress',
      query: <String, String>{'chapterId': '$chapterId'},
    );
    return KavitaProgress.fromJson(_decodeMap(res));
  }

  Future<void> saveProgress(KavitaProgress progress) async {
    await _send(
      'POST',
      '/api/Reader/progress',
      jsonBody: progress.toRequestJson(),
    );
  }

  /// 把若干章节标已读（`mark-multiple-read`）。
  Future<void> markChaptersRead({
    required int seriesId,
    required List<int> chapterIds,
  }) async {
    await _send(
      'POST',
      '/api/Reader/mark-multiple-read',
      jsonBody: <String, Object?>{
        'seriesId': seriesId,
        'volumeIds': const <int>[],
        'chapterIds': chapterIds,
      },
    );
  }

  Future<void> markChaptersUnread({
    required int seriesId,
    required List<int> chapterIds,
  }) async {
    await _send(
      'POST',
      '/api/Reader/mark-multiple-unread',
      jsonBody: <String, Object?>{
        'seriesId': seriesId,
        'volumeIds': const <int>[],
        'chapterIds': chapterIds,
      },
    );
  }

  // ---- 下载 ----

  /// 章节文件体积（字节）。
  Future<int> getChapterDownloadSize(int chapterId) async {
    final http.Response res = await _send(
      'GET',
      '/api/Download/chapter-size',
      query: <String, String>{'chapterId': '$chapterId'},
    );
    final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return kavitaTryInt(decoded) ?? 0;
  }

  /// 把章节原文件流式写到 [destination]（先写 `.part`，成功后改名）。
  ///
  /// - 不整体读入内存（CBZ 可达数百 MB）；
  /// - 两块数据之间停顿超过 [kDownloadStallTimeout] 即失败；
  /// - JWT 在下载中途过期无影响：JWT 只在发起请求时校验，下载开始后连接不再鉴权；
  ///   发起时遇 401 会重鉴权一次再发；
  /// - [token] 被取消时抛 [KavitaDownloadCancelled] 并清理 `.part`。
  /// - 无断点续传：失败后重新从头下载（服务器的 Download 端点不保证 Range）。
  Future<KavitaDownloadResult> downloadChapter(
    int chapterId,
    File destination, {
    void Function(int received, int? total)? onProgress,
    KavitaCancelToken? token,
  }) async {
    await _ensureToken();
    http.StreamedResponse response = await _openDownload(chapterId);
    if (response.statusCode == 401) {
      await response.stream.drain<void>();
      _token = null;
      await _reauth();
      response = await _openDownload(chapterId);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw KavitaApiException(response.statusCode, '/api/Download/chapter');
    }

    final File part = File('${destination.path}.part');
    await part.parent.create(recursive: true);
    final IOSink sink = part.openWrite();
    int received = 0;
    final int? total = response.contentLength;
    try {
      await for (final List<int> chunk in response.stream.timeout(
        kDownloadStallTimeout,
      )) {
        if (token?.isCancelled ?? false) throw const KavitaDownloadCancelled();
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      if (total != null && total > 0 && received != total) {
        throw HttpException('Kavita download truncated ($received/$total)');
      }
      if (await destination.exists()) await destination.delete();
      await part.rename(destination.path);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
      rethrow;
    }
    return KavitaDownloadResult(
      file: destination,
      bytes: received,
      fileName: parseContentDispositionFileName(
        response.headers['content-disposition'],
      ),
      contentType: response.headers['content-type'],
    );
  }

  Future<http.StreamedResponse> _openDownload(int chapterId) async {
    try {
      final http.Request req = http.Request(
        'GET',
        uri('/api/Download/chapter', <String, String>{
          'chapterId': '$chapterId',
        }),
      );
      req.headers['Authorization'] = 'Bearer $_token';
      return await _client.send(req).timeout(kRequestTimeout);
    } on http.ClientException catch (e) {
      throw Exception(redactCredentialsInText(e.toString()));
    }
  }

  /// 解析 `Content-Disposition` 的文件名，`filename*`（RFC 5987）优先。
  static String? parseContentDispositionFileName(String? header) {
    if (header == null || header.isEmpty) return null;
    final RegExpMatch? star = RegExp(
      r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)",
      caseSensitive: false,
    ).firstMatch(header);
    if (star != null) {
      try {
        final String raw = star.group(2)!.trim();
        final String charset = star.group(1)!.trim().toLowerCase();
        if (charset.isEmpty || charset == 'utf-8') {
          return Uri.decodeComponent(raw);
        }
        return Uri.decodeComponent(raw);
      } on FormatException {
        // 落到普通 filename。
      }
    }
    final RegExpMatch? plain = RegExp(
      r'filename\s*=\s*"?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(header);
    final String? name = plain?.group(1)?.trim();
    return (name == null || name.isEmpty) ? null : name;
  }
}
