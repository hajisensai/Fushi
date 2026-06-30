import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/tls/hibiki_pinning_http.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

class DavEntry {
  const DavEntry({
    required this.href,
    required this.displayName,
    required this.isCollection,
  });

  final String href;
  final String displayName;
  final bool isCollection;
}

class WebDavOps {
  WebDavOps({
    required String baseUrl,
    required String username,
    required String password,
    Duration connectionTimeout = const Duration(seconds: 60),
    String? pinnedFingerprint,
  })  : _baseUrl = baseUrl,
        _connectionTimeout = connectionTimeout,
        _pinnedFingerprint = pinnedFingerprint,
        _authHeader =
            'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  final String _baseUrl;
  final String _authHeader;
  final Duration _connectionTimeout;

  /// TODO-961 M1: https 端点的证书 SHA-256 钉扎指纹（aa:bb:.. 形式）。null = 明文
  /// http 老路径，用裸 [HttpClient]（行为零变化）；非 null = 用 pinned client，仅
  /// 接受指纹相等的自签证书。由数据（URL 是否带指纹）决定，不靠平台分支。
  final String? _pinnedFingerprint;
  HttpClient? _httpClient;

  String get baseUrl => _baseUrl;

  /// [force] aborts in-flight connections (used by short-timeout reachability
  /// probes so a hung connect doesn't linger; plain close only stops accepting
  /// new requests and won't cancel a socket stuck on connect).
  void close({bool force = false}) {
    _httpClient?.close(force: force);
    _httpClient = null;
  }

  HttpClient _client() {
    final HttpClient? existing = _httpClient;
    if (existing != null) return existing;
    final String? fp = _pinnedFingerprint;
    // 指纹非空 → pinned client（仅接受证书指纹相等的自签 https）；否则裸 client
    // （明文 http 老路径，字节不变）。连接超时只约束 connect，不约束正文传输。
    final HttpClient client = fp != null && fp.isNotEmpty
        ? createPinnedHttpClient(
            expectedFingerprint: fp,
            connectionTimeout: _connectionTimeout,
          )
        : (HttpClient()..connectionTimeout = _connectionTimeout);
    return _httpClient = client;
  }

  Future<HttpClientRequest> buildRequest(String method, String url) async {
    final request = await _client().openUrl(method, Uri.parse(url));
    request.followRedirects = false;
    request.headers.set('Authorization', _authHeader);
    return request;
  }

  Future<void> testConnection() async {
    try {
      final request = await buildRequest('PROPFIND', _baseUrl);
      request.headers.set('Depth', '0');
      request.headers.set('Content-Type', 'application/xml; charset=utf-8');
      request.add(utf8.encode(propfindBody));
      final response = await request.close();
      await response.drain<void>();

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw SyncAuthError('Authentication failed');
      }
      if (response.statusCode >= 400) {
        throw SyncBackendError('Server returned ${response.statusCode}');
      }
    } on SyncAuthError {
      rethrow;
    } on SyncBackendError {
      rethrow;
    } catch (e) {
      throw SyncBackendError('Connection failed: $e');
    }
  }

  Future<void> ensureCollection(String path) async {
    final checkReq = await buildRequest('PROPFIND', path);
    checkReq.headers.set('Depth', '0');
    checkReq.headers.set('Content-Type', 'application/xml; charset=utf-8');
    checkReq.add(utf8.encode(propfindBody));
    final checkResp = await checkReq.close();
    await checkResp.drain<void>();
    if (checkResp.statusCode == 207) return;

    final mkcolReq = await buildRequest('MKCOL', path);
    final mkcolResp = await mkcolReq.close();
    await mkcolResp.drain<void>();
    if (mkcolResp.statusCode >= 400 && mkcolResp.statusCode != 405) {
      throw SyncBackendError(
          'Failed to create folder: ${mkcolResp.statusCode}');
    }
  }

  Future<List<DavEntry>> propfindChildren(String path) async {
    final request = await buildRequest('PROPFIND', path);
    request.headers.set('Depth', '1');
    request.headers.set('Content-Type', 'application/xml; charset=utf-8');
    request.add(utf8.encode(propfindBody));
    final response = await request.close();

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw SyncAuthError('Authentication failed');
    }

    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 207) {
      throw SyncBackendError('PROPFIND failed: ${response.statusCode}',
          isRetryable: response.statusCode == 404);
    }
    return parsePropfindResponse(body, path);
  }

  List<DavEntry> parsePropfindResponse(String xml, String basePath) {
    final entries = <DavEntry>[];
    final responsePattern = RegExp(
        r'<(?:[a-zA-Z0-9]+:)?response[>\s](.*?)</(?:[a-zA-Z0-9]+:)?response>',
        dotAll: true);
    final hrefPattern =
        RegExp(r'<(?:[a-zA-Z0-9]+:)?href>(.*?)</(?:[a-zA-Z0-9]+:)?href>');
    final collectionPattern = RegExp(r'<(?:[a-zA-Z0-9]+:)?collection\s*/?>');
    final displayNamePattern = RegExp(
        r'<(?:[a-zA-Z0-9]+:)?displayname>(.*?)</(?:[a-zA-Z0-9]+:)?displayname>');

    for (final match in responsePattern.allMatches(xml)) {
      final block = match.group(1)!;
      final hrefMatch = hrefPattern.firstMatch(block);
      if (hrefMatch == null) continue;

      final href = Uri.decodeFull(hrefMatch.group(1)!.trim());
      final isCollection = collectionPattern.hasMatch(block);
      final displayMatch = displayNamePattern.firstMatch(block);

      String displayName;
      if (displayMatch != null && displayMatch.group(1)!.trim().isNotEmpty) {
        displayName = displayMatch.group(1)!.trim();
      } else {
        var cleaned = href;
        if (cleaned.endsWith('/')) {
          cleaned = cleaned.substring(0, cleaned.length - 1);
        }
        displayName = Uri.decodeFull(cleaned.split('/').last);
      }

      final resolvedHref = resolveHref(href, basePath);
      entries.add(DavEntry(
        href: resolvedHref,
        displayName: displayName,
        isCollection: isCollection,
      ));
    }
    return entries;
  }

  String resolveHref(String href, String basePath) {
    final baseUri = Uri.parse(basePath);
    if (href.startsWith('http://') || href.startsWith('https://')) {
      final hrefUri = Uri.parse(href);
      // Port is part of the origin: a server on :8080 that returns a
      // default-port (implicit :80) href must not be treated as same-origin,
      // else the reconstructed URL would target the wrong port (HBK-AUDIT-160).
      // Uri.port fills in the scheme default, so this compares effective ports.
      if (hrefUri.host != baseUri.host ||
          hrefUri.scheme != baseUri.scheme ||
          hrefUri.port != baseUri.port) {
        throw SyncBackendError('Server returned cross-origin href: $href');
      }
      return href;
    }
    final isDefaultPort = (baseUri.scheme == 'http' && baseUri.port == 80) ||
        (baseUri.scheme == 'https' && baseUri.port == 443);
    final portSuffix = isDefaultPort ? '' : ':${baseUri.port}';
    return '${baseUri.scheme}://${baseUri.host}$portSuffix$href';
  }

  // Metadata JSON files (progress/stats/audiobook) are tiny by spec; cap the
  // download so a hostile/buggy remote can't OOM the app by streaming a giant
  // body before jsonDecode. Mirrors GoogleDriveHandler._downloadJson.
  // HBK-AUDIT-139.
  static const int maxJsonDownloadSize = 10 * 1024 * 1024; // 10 MB

  Future<dynamic> downloadJson(String fileId) async {
    final request = await buildRequest('GET', fileId);
    final response = await request.close();
    checkStatus(response.statusCode, 'GET $fileId');
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      builder.add(chunk);
      if (builder.length > maxJsonDownloadSize) {
        throw SyncBackendError('GET $fileId failed: response too large');
      }
    }
    return jsonDecode(utf8.decode(builder.takeBytes()));
  }

  Future<void> uploadJson(
      String folderId, String fileName, dynamic data) async {
    final path = '$folderId${Uri.encodeComponent(fileName)}';
    final bytes = utf8.encode(jsonEncode(data));
    await putBytes(path, bytes, 'application/json');
  }

  Future<void> putBytes(
      String path, List<int> bytes, String contentType) async {
    final request = await buildRequest('PUT', path);
    request.headers.set('Content-Type', contentType);
    request.headers.set('Content-Length', '${bytes.length}');
    request.add(bytes);
    final response = await request.close();
    await response.drain<void>();
    checkStatus(response.statusCode, 'PUT $path');
  }

  Future<bool> headFile(String path) async {
    final request = await buildRequest('HEAD', path);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  Future<void> deleteFile(String path) async {
    final request = await buildRequest('DELETE', path);
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode >= 400 && response.statusCode != 404) {
      throw SyncBackendError('DELETE failed: ${response.statusCode}');
    }
  }

  void checkStatus(int statusCode, String context) {
    if (statusCode == 401 || statusCode == 403) {
      throw SyncAuthError('Authentication failed');
    }
    if (statusCode == 404) {
      throw SyncBackendError('Not found: $context', isRetryable: true);
    }
    if (statusCode >= 400) {
      throw SyncBackendError('$context failed: HTTP $statusCode');
    }
  }

  static const propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:">'
      '<d:prop>'
      '<d:resourcetype/>'
      '<d:displayname/>'
      '</d:prop>'
      '</d:propfind>';

  static String guessContentType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.epub')) return 'application/epub+zip';
    if (lower.endsWith('.m4b') || lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.flac')) return 'audio/flac';
    return 'application/octet-stream';
  }

  // HBK-AUDIT-085: delegate to the single canonical matcher in sync_utils so
  // file-matching semantics live in one place. Kept as a thin shim only for the
  // remaining external caller (webdav_sync_backend.dart).
  static DriveFile? findByPrefix(List<DriveFile> files, String prefix) =>
      findSyncFileByPrefix(files, prefix);

  static String normalizeUrl(String url) {
    var normalized = url.trim();
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    final scheme = Uri.parse(normalized).scheme;
    if (scheme != 'http' && scheme != 'https') {
      throw SyncBackendError('WebDAV URL must use http:// or https://');
    }
    return normalized;
  }
}
