import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

class WebDavSyncBackend extends SyncBackend {
  WebDavSyncBackend._();
  static final WebDavSyncBackend instance = WebDavSyncBackend._();

  String? _baseUrl;
  String? _username;
  String? _password;
  String? _rootFolderId;
  final Map<String, String> _titleToFolderId = {};
  HttpClient? _httpClient;

  // ── Auth ──────────────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated async =>
      _baseUrl != null && _username != null && _password != null;

  @override
  Future<String?> get currentEmail async => _username;

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    final url = await repo.getWebDavUrl();
    final user = await repo.getWebDavUsername();
    final pass = await repo.getWebDavPassword();

    if (url == null || user == null || pass == null) {
      throw SyncAuthError('WebDAV credentials not configured');
    }

    _baseUrl = _normalizeUrl(url);
    _username = user;
    _password = pass;

    await _testConnection();
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    _baseUrl = null;
    _username = null;
    _password = null;
    _closeClient();
    await repo.setWebDavUrl(null);
    await repo.setWebDavUsername(null);
    await repo.setWebDavPassword(null);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    final url = await repo.getWebDavUrl();
    final user = await repo.getWebDavUsername();
    final pass = await repo.getWebDavPassword();

    if (url == null || user == null || pass == null) return false;

    _baseUrl = _normalizeUrl(url);
    _username = user;
    _password = pass;
    return true;
  }

  @override
  Future<void> refreshAuth() async {}

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() async {
    if (_rootFolderId != null) return _rootFolderId!;

    final path = '$_baseUrl/ttu-reader-data/';
    await _ensureCollection(path);
    _rootFolderId = path;
    return path;
  }

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async {
    final entries = await _propfindChildren(rootFolderId);
    return entries
        .where((e) => e.isCollection && e.href != rootFolderId)
        .map((e) => DriveFile(id: e.href, name: e.displayName))
        .toList();
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async {
    final sanitized = sanitizeTtuFilename(bookTitle);

    if (_titleToFolderId.containsKey(sanitized)) {
      return _titleToFolderId[sanitized]!;
    }

    final path = '$rootFolderId${Uri.encodeComponent(sanitized)}/';
    await _ensureCollection(path);
    _titleToFolderId[sanitized] = path;

    if (coverData != null) {
      try {
        final format = detectCoverFormat(coverData);
        final coverPath = '${path}cover_1_6.${format.extension}';
        final existing = await _headFile(coverPath);
        if (!existing) {
          await _putBytes(coverPath, coverData, format.mimeType);
        }
      } catch (_) {}
    }

    return path;
  }

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final entries = await _propfindChildren(folderId);
    final files = entries
        .where((e) => !e.isCollection && e.href != folderId)
        .map((e) => DriveFile(id: e.href, name: e.displayName))
        .toList();

    return DriveSyncFiles(
      progress: _findByPrefix(files, 'progress_'),
      statistics: _findByPrefix(files, 'statistics_'),
      audioBook: _findByPrefix(files, 'audioBook_'),
    );
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    final json = await _downloadJson(fileId);
    return TtuProgress.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async {
    final json = await _downloadJson(fileId);
    return (json as List)
        .cast<Map<String, dynamic>>()
        .map(TtuStatistics.fromJson)
        .toList();
  }

  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async {
    final json = await _downloadJson(fileId);
    return TtuAudioBook.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    if (fileId != null) await _deleteFile(fileId);
    final fileName =
        progressFileName(progress.lastBookmarkModified, progress.progress);
    await _uploadJson(folderId, fileName, progress.toJson());
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    if (fileId != null) await _deleteFile(fileId);
    final fileName = statisticsFileName(stats);
    await _uploadJson(folderId, fileName, stats.map((s) => s.toJson()).toList());
  }

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    if (fileId != null) await _deleteFile(fileId);
    final fileName = audioBookFileName(
        audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
    await _uploadJson(folderId, fileName, audioBook.toJson());
  }

  // ── Content file sync ─────────────────────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    final path = '$folderId${Uri.encodeComponent(fileName)}';
    final length = await file.length();
    final request = await _buildRequest('PUT', path);
    request.headers.set('Content-Type', _guessContentType(fileName));
    request.headers.set('Content-Length', '$length');
    int bytesUploaded = 0;
    await request.addStream(file.openRead().map((chunk) {
      bytesUploaded += chunk.length;
      onProgress?.call(length > 0 ? bytesUploaded / length : 0);
      return chunk;
    }));
    final response = await request.close();
    await response.drain<void>();
    _checkStatus(response.statusCode, 'PUT $path');
  }

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {
    final request = await _buildRequest('GET', fileId);
    final response = await request.close();
    _checkStatus(response.statusCode, 'GET $fileId');

    final contentLength = response.contentLength;
    final sink = destination.openWrite();
    int bytesReceived = 0;
    bool success = false;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (contentLength > 0) {
          onProgress?.call(bytesReceived / contentLength);
        }
      }
      success = true;
    } finally {
      await sink.close();
      if (!success) {
        try {
          destination.deleteSync();
        } catch (_) {}
      }
    }
  }

  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async {
    final path = '$folderId${Uri.encodeComponent(fileName)}';
    final exists = await _headFile(path);
    if (!exists) return null;
    return DriveFile(id: path, name: fileName);
  }

  // ── Cache ─────────────────────────────────────────────────────────

  @override
  void clearCache() {
    _rootFolderId = null;
    _titleToFolderId.clear();
  }

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    _rootFolderId = rootFolderId;
    if (titleToFolderId != null) {
      _titleToFolderId.addAll(titleToFolderId);
    }
  }

  @override
  String? get cachedRootFolderId => _rootFolderId;

  @override
  Map<String, String> get cachedFolderIds => Map.unmodifiable(_titleToFolderId);

  @override
  void cacheBookFolderIds(List<DriveFile> folders) {
    for (final f in folders) {
      _titleToFolderId[f.name] = f.id;
    }
  }

  // ── Test connection ───────────────────────────────────────────────

  Future<void> testConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    final normalizedUrl = _normalizeUrl(url);
    final client = HttpClient();
    try {
      final request =
          await client.openUrl('PROPFIND', Uri.parse(normalizedUrl));
      request.followRedirects = false;
      request.headers.set('Authorization',
          'Basic ${base64Encode(utf8.encode('$username:$password'))}');
      request.headers.set('Depth', '0');
      request.headers.set('Content-Type', 'application/xml; charset=utf-8');
      request.add(utf8.encode(_propfindBody));
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw SyncAuthError('Authentication failed');
      }
      if (response.statusCode >= 400) {
        throw SyncBackendError(
            'Server returned ${response.statusCode}');
      }
    } on SyncAuthError {
      rethrow;
    } on SyncBackendError {
      rethrow;
    } catch (e) {
      throw SyncBackendError('Connection failed: $e');
    } finally {
      client.close();
    }
  }

  // ── Private helpers ───────────────────────────────────────────────

  HttpClient _client() => _httpClient ??= HttpClient();

  void _closeClient() {
    _httpClient?.close();
    _httpClient = null;
  }

  String _normalizeUrl(String url) {
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

  String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$_username:$_password'))}';

  Future<HttpClientRequest> _buildRequest(String method, String url) async {
    final request = await _client().openUrl(method, Uri.parse(url));
    request.followRedirects = false;
    request.headers.set('Authorization', _authHeader);
    return request;
  }

  Future<void> _testConnection() async {
    try {
      final request = await _buildRequest('PROPFIND', _baseUrl!);
      request.headers.set('Depth', '0');
      request.headers.set('Content-Type', 'application/xml; charset=utf-8');
      request.add(utf8.encode(_propfindBody));
      final response = await request.close();
      await response.drain<void>();

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw SyncAuthError('Authentication failed');
      }
      if (response.statusCode >= 400) {
        throw SyncBackendError(
            'Server returned ${response.statusCode}');
      }
    } on SyncAuthError {
      rethrow;
    } on SyncBackendError {
      rethrow;
    } catch (e) {
      throw SyncBackendError('Connection failed: $e');
    }
  }

  Future<void> _ensureCollection(String path) async {
    final checkReq = await _buildRequest('PROPFIND', path);
    checkReq.headers.set('Depth', '0');
    checkReq.headers.set('Content-Type', 'application/xml; charset=utf-8');
    checkReq.add(utf8.encode(_propfindBody));
    final checkResp = await checkReq.close();
    await checkResp.drain<void>();
    if (checkResp.statusCode == 207) return;

    final mkcolReq = await _buildRequest('MKCOL', path);
    final mkcolResp = await mkcolReq.close();
    await mkcolResp.drain<void>();
    if (mkcolResp.statusCode >= 400 && mkcolResp.statusCode != 405) {
      throw SyncBackendError(
          'Failed to create folder: ${mkcolResp.statusCode}');
    }
  }

  static const _propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:">'
      '<d:prop>'
      '<d:resourcetype/>'
      '<d:displayname/>'
      '</d:prop>'
      '</d:propfind>';

  Future<List<_DavEntry>> _propfindChildren(String path) async {
    final request = await _buildRequest('PROPFIND', path);
    request.headers.set('Depth', '1');
    request.headers.set('Content-Type', 'application/xml; charset=utf-8');
    request.add(utf8.encode(_propfindBody));
    final response = await request.close();

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw SyncAuthError('Authentication failed');
    }

    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 207) {
      throw SyncBackendError(
          'PROPFIND failed: ${response.statusCode}',
          isRetryable: response.statusCode == 404);
    }
    return _parsePropfindResponse(body, path);
  }

  List<_DavEntry> _parsePropfindResponse(String xml, String basePath) {
    final entries = <_DavEntry>[];
    final responsePattern =
        RegExp(r'<(?:[a-zA-Z0-9]+:)?response[>\s](.*?)</(?:[a-zA-Z0-9]+:)?response>',
            dotAll: true);
    final hrefPattern =
        RegExp(r'<(?:[a-zA-Z0-9]+:)?href>(.*?)</(?:[a-zA-Z0-9]+:)?href>');
    final collectionPattern =
        RegExp(r'<(?:[a-zA-Z0-9]+:)?collection\s*/?>');
    final displayNamePattern =
        RegExp(r'<(?:[a-zA-Z0-9]+:)?displayname>(.*?)</(?:[a-zA-Z0-9]+:)?displayname>');

    for (final match in responsePattern.allMatches(xml)) {
      final block = match.group(1)!;
      final hrefMatch = hrefPattern.firstMatch(block);
      if (hrefMatch == null) continue;

      var href = Uri.decodeFull(hrefMatch.group(1)!.trim());
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

      final resolvedHref = _resolveHref(href, basePath);
      entries.add(_DavEntry(
        href: resolvedHref,
        displayName: displayName,
        isCollection: isCollection,
      ));
    }
    return entries;
  }

  String _resolveHref(String href, String basePath) {
    final baseUri = Uri.parse(basePath);
    if (href.startsWith('http://') || href.startsWith('https://')) {
      final hrefUri = Uri.parse(href);
      if (hrefUri.host != baseUri.host || hrefUri.scheme != baseUri.scheme) {
        throw SyncBackendError('Server returned cross-origin href: $href');
      }
      return href;
    }
    final isDefaultPort =
        (baseUri.scheme == 'http' && baseUri.port == 80) ||
        (baseUri.scheme == 'https' && baseUri.port == 443);
    final portSuffix = isDefaultPort ? '' : ':${baseUri.port}';
    return '${baseUri.scheme}://${baseUri.host}$portSuffix$href';
  }

  Future<dynamic> _downloadJson(String fileId) async {
    final request = await _buildRequest('GET', fileId);
    final response = await request.close();
    _checkStatus(response.statusCode, 'GET $fileId');

    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body);
  }

  Future<void> _uploadJson(
      String folderId, String fileName, dynamic data) async {
    final path = '$folderId${Uri.encodeComponent(fileName)}';
    final bytes = utf8.encode(jsonEncode(data));
    await _putBytes(path, bytes, 'application/json');
  }

  Future<void> _putBytes(
      String path, List<int> bytes, String contentType) async {
    final request = await _buildRequest('PUT', path);
    request.headers.set('Content-Type', contentType);
    request.headers.set('Content-Length', '${bytes.length}');
    request.add(bytes);
    final response = await request.close();
    await response.drain<void>();
    _checkStatus(response.statusCode, 'PUT $path');
  }

  Future<bool> _headFile(String path) async {
    final request = await _buildRequest('HEAD', path);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  Future<void> _deleteFile(String path) async {
    final request = await _buildRequest('DELETE', path);
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode >= 400 && response.statusCode != 404) {
      throw SyncBackendError('DELETE failed: ${response.statusCode}');
    }
  }

  void _checkStatus(int statusCode, String context) {
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

  static String _guessContentType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.epub')) return 'application/epub+zip';
    if (lower.endsWith('.m4b') || lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.flac')) return 'audio/flac';
    return 'application/octet-stream';
  }

  static DriveFile? _findByPrefix(List<DriveFile> files, String prefix) {
    for (final f in files) {
      if (f.name.startsWith(prefix)) return f;
    }
    return null;
  }
}

class _DavEntry {
  const _DavEntry({
    required this.href,
    required this.displayName,
    required this.isCollection,
  });

  final String href;
  final String displayName;
  final bool isCollection;
}
