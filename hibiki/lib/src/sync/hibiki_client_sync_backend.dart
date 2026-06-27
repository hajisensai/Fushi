import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_book_client.dart';
import 'package:hibiki/src/sync/remote_cover_headers.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:hibiki/src/utils/misc/resumable_downloader.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';

/// Probes whether a single Hibiki server URL is reachable with [token].
/// Returns true if reachable, false on connectivity failure/timeout, and
/// throws [SyncAuthError] if the server rejects the token.
typedef HibikiProbe = Future<bool> Function(String url, String token);

/// Picks the first reachable URL from [candidates] (in order, skipping
/// disabled ones). A [SyncAuthError] from a probe propagates immediately —
/// every candidate shares one token, so one rejection means all fail. Throws
/// a retryable [SyncBackendError] when no enabled candidate is reachable.
Future<String> resolveReachableHibikiUrl(
  List<HibikiClientUrl> candidates,
  String token,
  HibikiProbe probe,
) async {
  for (final HibikiClientUrl candidate in candidates) {
    if (!candidate.enabled) continue;
    if (await probe(candidate.url, token)) return candidate.url;
  }
  throw SyncBackendError(
    'No reachable Hibiki server address',
    isRetryable: true,
  );
}

/// Default probe: a short-timeout WebDAV connection test. Connectivity
/// failures and timeouts map to `false` (unreachable); a rejected token
/// surfaces as [SyncAuthError] so the resolver stops trying other addresses.
Future<bool> _defaultHibikiProbe(String url, String token) async {
  WebDavOps? ops;
  try {
    ops = WebDavOps(
      baseUrl: WebDavOps.normalizeUrl(url),
      username: 'hibiki',
      password: token,
      // Bound the socket connect itself (WebDavOps defaults to 60s); the outer
      // .timeout only bounds the awaited future, not the underlying connect.
      connectionTimeout: HibikiClientSyncBackend.probeTimeout,
    );
    await ops.testConnection().timeout(HibikiClientSyncBackend.probeTimeout);
    return true;
  } on SyncAuthError {
    rethrow;
  } catch (e) {
    // Unreachable, timed out, or the server returned an error — skip this
    // address, but log why so a running-but-erroring server is distinguishable
    // from "down" (HBK-AUDIT-166).
    debugPrint('[hibiki-client] probe failed for $url: $e');
    return false;
  } finally {
    // force: abort any connect still in flight when we timed out, so an
    // unreachable address never leaks a socket lingering up to 60s.
    ops?.close(force: true);
  }
}

/// Sync backend for connecting to another Hibiki instance's embedded server.
///
/// Uses the WebDAV protocol (same as [WebDavSyncBackend]) but stores
/// credentials in dedicated keys to avoid collision with the user's
/// standalone WebDAV config.
class HibikiClientSyncBackend extends SyncBackend
    implements RemoteBookClient, RemoteVideoClient, RemoteCoverHeadersProvider {
  HibikiClientSyncBackend._({HibikiProbe? probe})
      : _probe = probe ?? _defaultHibikiProbe;
  static final HibikiClientSyncBackend instance = HibikiClientSyncBackend._();

  /// Test seam: inject a fake reachability probe.
  @visibleForTesting
  HibikiClientSyncBackend.withProbe(HibikiProbe probe) : _probe = probe;

  /// How long to wait for a single address probe before treating it as
  /// unreachable and trying the next candidate. Short so LAN-first failover
  /// to WAN is quick when you are away from home.
  static const Duration probeTimeout = Duration(seconds: 2);

  final HibikiProbe _probe;
  List<HibikiClientUrl> _candidates = const <HibikiClientUrl>[];
  String? _token;
  bool _sessionResolved = false;

  WebDavOps? _ops;
  String? _rootFolderId;
  final Map<String, String> _titleToFolderId = {};

  /// Test seam: force address resolution without performing a folder op.
  @visibleForTesting
  Future<void> ensureResolved() => _ensureResolved();

  /// Test seam: the base URL the session has settled on.
  @visibleForTesting
  String? get activeBaseUrl => _ops?.baseUrl;

  // ── Auth ──────────────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated async => _ops != null;

  @override
  Future<String?> get currentEmail async => 'hibiki';

  Future<void> _loadConfig(SyncRepository repo) async {
    _candidates = (await repo.getHibikiClientUrls())
        .where((HibikiClientUrl u) => u.enabled)
        .toList();
    _token = await repo.getHibikiClientToken();
    _sessionResolved = false;
  }

  /// Builds a provisional [WebDavOps] on the first well-formed candidate so
  /// [isAuthenticated] reflects "configured". The actually-reachable address
  /// is chosen later by [_ensureResolved] on the first network operation.
  void _buildProvisionalOps() {
    _ops?.close();
    _ops = null;
    if (_token == null) return;
    for (final HibikiClientUrl candidate in _candidates) {
      try {
        _ops = WebDavOps(
          baseUrl: WebDavOps.normalizeUrl(candidate.url),
          username: 'hibiki',
          password: _token!,
        );
        return;
      } on SyncBackendError {
        continue; // malformed URL — keep looking for a usable handle
      }
    }
  }

  /// Probes the candidate addresses (in order) and settles the session on the
  /// first reachable one. Switching addresses rebuilds [_ops] and clears the
  /// folder cache, whose paths embed the previous base URL.
  Future<void> _ensureResolved() async {
    if (_sessionResolved) return;
    final String? token = _token;
    if (token == null) {
      throw SyncAuthError('Hibiki server credentials not configured');
    }
    final String chosen =
        await resolveReachableHibikiUrl(_candidates, token, _probe);
    final String normalized = WebDavOps.normalizeUrl(chosen);
    if (_ops == null || _ops!.baseUrl != normalized) {
      _ops?.close();
      _ops =
          WebDavOps(baseUrl: normalized, username: 'hibiki', password: token);
      clearCache();
    }
    _sessionResolved = true;
  }

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    await _loadConfig(repo);
    if (_candidates.isEmpty || _token == null) {
      throw SyncAuthError('Hibiki server credentials not configured');
    }
    // Probes + selects a reachable address (or throws), confirming the token
    // is accepted by the server.
    await _ensureResolved();
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    _ops?.close();
    _ops = null;
    _candidates = const <HibikiClientUrl>[];
    _token = null;
    _sessionResolved = false;
    await repo.setHibikiClientUrls(const <HibikiClientUrl>[]);
    // Also wipe the legacy single-url key, else getHibikiClientUrls would
    // migrate it back on the next read.
    // ignore: deprecated_member_use_from_same_package
    await repo.setHibikiClientUrl(null);
    await repo.setHibikiClientToken(null);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    await _loadConfig(repo);
    if (_candidates.isEmpty || _token == null) {
      _ops?.close();
      _ops = null;
      return false;
    }
    _buildProvisionalOps();
    return _ops != null;
  }

  @override
  Future<void> refreshAuth() async {}

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() async {
    await _ensureResolved();
    if (_rootFolderId != null) return _rootFolderId!;

    final path = '${_ops!.baseUrl}/$kSyncRootFolderName/';
    await _ops!.ensureCollection(path);
    _rootFolderId = path;
    return path;
  }

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async {
    final entries = await _ops!.propfindChildren(rootFolderId);
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
    await _ops!.ensureCollection(path);
    _titleToFolderId[sanitized] = path;

    if (coverData != null) {
      try {
        final format = detectCoverFormat(coverData);
        final coverPath = '${path}cover_1_6.${format.extension}';
        final existing = await _ops!.headFile(coverPath);
        if (!existing) {
          await _ops!.putBytes(coverPath, coverData, format.mimeType);
        }
      } catch (e) {
        debugPrint('[hibiki-client] cover upload failed: $e');
      }
    }

    return path;
  }

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final entries = await _ops!.propfindChildren(folderId);
    final files = entries
        .where((e) => !e.isCollection && e.href != folderId)
        .map((e) => DriveFile(id: e.href, name: e.displayName))
        .toList();

    // HBK-AUDIT-085: route through the single canonical matcher in sync_utils.
    return DriveSyncFiles(
      progress: findSyncFileByPrefix(files, 'progress_'),
      statistics: findSyncFileByPrefix(files, 'statistics_'),
      audioBook: findSyncFileByPrefix(files, 'audioBook_'),
    );
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    final json = await _ops!.downloadJson(fileId);
    return TtuProgress.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async {
    final json = await _ops!.downloadJson(fileId);
    return (json as List)
        .cast<Map<String, dynamic>>()
        .map(TtuStatistics.fromJson)
        .toList();
  }

  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async {
    final json = await _ops!.downloadJson(fileId);
    return TtuAudioBook.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    if (fileId != null) await _ops!.deleteFile(fileId);
    final fileName =
        progressFileName(progress.lastBookmarkModified, progress.progress);
    await _ops!.uploadJson(folderId, fileName, progress.toJson());
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    if (fileId != null) await _ops!.deleteFile(fileId);
    final fileName = statisticsFileName(stats);
    await _ops!
        .uploadJson(folderId, fileName, stats.map((s) => s.toJson()).toList());
  }

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    if (fileId != null) await _ops!.deleteFile(fileId);
    final fileName = audioBookFileName(
        audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
    await _ops!.uploadJson(folderId, fileName, audioBook.toJson());
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
    final request = await _ops!.buildRequest('PUT', path);
    request.headers.set('Content-Type', WebDavOps.guessContentType(fileName));
    request.headers.set('Content-Length', '$length');
    int bytesUploaded = 0;
    await request.addStream(file.openRead().map((chunk) {
      bytesUploaded += chunk.length;
      onProgress?.call(length > 0 ? bytesUploaded / length : 0);
      return chunk;
    }));
    final response = await request.close();
    await response.drain<void>();
    _ops!.checkStatus(response.statusCode, 'PUT $path');
  }

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {
    final request = await _ops!.buildRequest('GET', fileId);
    final response = await request.close();
    _ops!.checkStatus(response.statusCode, 'GET $fileId');

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
        } catch (e) {
          debugPrint('[hibiki-client] failed to clean up temp file: $e');
        }
      }
    }
  }

  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async {
    final path = '$folderId${Uri.encodeComponent(fileName)}';
    final exists = await _ops!.headFile(path);
    if (!exists) return null;
    return DriveFile(id: path, name: fileName);
  }

  // ── Cache ─────────────────────────────────────────────────────────

  @override
  void clearCache() {
    _rootFolderId = null;
    _titleToFolderId.clear();
    // Re-probe the candidate addresses on the next op. SyncManager calls
    // clearCache() before retrying a retryable failure; if the resolved
    // address just went down, the retry must be free to fail over to the next
    // one (HBK-AUDIT-157). The folder cache is cleared here too, so switching
    // addresses is safe — no stale base-URL-coupled paths survive.
    _sessionResolved = false;
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

  @override
  void evictFolderId(String folderId) {
    // 按值反查逐出书名→folderId 缓存里指向 [folderId] 的条目，消除删书后陈旧态
    // （BUG-202）。路径式后端的 folderId 是按名派生的路径，逐出仍是廉价正确性。
    _titleToFolderId.removeWhere((_, id) => id == folderId);
  }

  // ── SyncAssetStore ────────────────────────────────────────────────

  @override
  Future<String> ensureNamespace(String name) async {
    await _ensureResolved();
    final root = '${_ops!.baseUrl}/$kSyncRootFolderName/';
    final path = '$root${Uri.encodeComponent(name)}/';
    await _ops!.ensureCollection(path);
    return path;
  }

  @override
  Future<String> ensureFolder(String parentId, String name) async {
    await _ensureResolved();
    final path = '$parentId${Uri.encodeComponent(name)}/';
    await _ops!.ensureCollection(path);
    return path;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    await _ensureResolved();
    final entries = await _ops!.propfindChildren(namespaceId);
    return entries
        .where((e) => e.href != namespaceId)
        .map((e) => AssetEntry(
              id: e.href,
              name: _stripTrailingSlash(e.displayName),
              isFolder: e.isCollection,
            ))
        .toList();
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    await _ensureResolved();
    final path = '$namespaceId${Uri.encodeComponent(name)}';
    if (!await _ops!.headFile(path)) return null;
    return AssetEntry(id: path, name: name);
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    await uploadContentFile(
      folderId: namespaceId,
      fileName: name,
      file: file,
      onProgress: onProgress,
    );
  }

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    await downloadContentFile(
      fileId: assetId,
      destination: destination,
      onProgress: onProgress,
    );
  }

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    await _ensureResolved();
    return _ops!.downloadJson(assetId);
  }

  @override
  Future<void> putJsonAsset(
      String namespaceId, String name, Object? json) async {
    await _ensureResolved();
    await _ops!.uploadJson(namespaceId, name, json);
  }

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    await _ensureResolved();
    // 服务端 _handleDelete 对目录 recursive 删、对文件单删；同一原语。
    // WebDavOps.deleteFile 已把服务端 404/已删除当作成功（幂等）；其它错误
    // （网络/权限/协议）必须自然抛出，否则 UI 会把真实失败误报为「已删除」。
    await _ops!.deleteFile(id);
  }

  static String _stripTrailingSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  // ── Live library (interconnect-only) ──────────────────────────────
  // host 升级为「库感知」后，client 直读对端实时词典，彻底不经 __dictionaries__。
  // 无旧设备，互联恒走 live（无能力探测）；分流由 orchestrator 按后端类型判定。

  /// host 根 origin（folder 路径是 `${_apiBase}/$kSyncRootFolderName/`，
  /// 故 /api 端点在 `${_apiBase}/api/...`）。
  String get _apiBase => _ops!.baseUrl;

  @override
  Map<String, String> get remoteCoverHeaders {
    final String? token = _token;
    if (token == null || token.isEmpty) return const <String, String>{};
    return <String, String>{
      'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    };
  }

  /// 列出对端 host 当前实时词典清单（直打 `/api/library/dictionaries`）。
  Future<List<RemoteDictionaryInfo>> listRemoteDictionaries() async {
    await _ensureResolved();
    final HttpClientRequest req =
        await _ops!.buildRequest('GET', '$_apiBase/api/library/dictionaries');
    final HttpClientResponse res = await req.close();
    _ops!.checkStatus(res.statusCode, 'GET /api/library/dictionaries');
    final String body = await res.transform(utf8.decoder).join();
    final List<dynamic> arr = jsonDecode(body) as List<dynamic>;
    return <RemoteDictionaryInfo>[
      for (final dynamic e in arr)
        RemoteDictionaryInfo.fromJson((e as Map).cast<String, Object?>()),
    ];
  }

  /// 从对端 host 下载名为 [name] 的词典包到 [destination] 文件。
  Future<void> getRemoteDictionary(
    String name,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    await downloadContentFile(
      fileId: '$_apiBase/api/library/dictionaries/${Uri.encodeComponent(name)}',
      destination: destination,
      onProgress: onProgress,
    );
  }

  /// 把本地 [file]（.hibikidict 包）推送到对端 host，导入名为 [name] 的词典。
  Future<void> putRemoteDictionary(
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/dictionaries/${Uri.encodeComponent(name)}',
    );
    final int length = await file.length();
    req.headers.set('Content-Type', 'application/octet-stream');
    req.headers.set('Content-Length', '$length');
    int sent = 0;
    await req.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      onProgress?.call(length > 0 ? sent / length : 0);
      return chunk;
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/dictionaries/$name');
  }

  /// 通知对端 host 删除名为 [name] 的词典。
  Future<void> deleteRemoteDictionary(String name) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'DELETE',
      '$_apiBase/api/library/dictionaries/${Uri.encodeComponent(name)}',
    );
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'DELETE /api/library/dictionaries/$name');
  }

  // ── Live books (interconnect-only) ────────────────────────────────
  // 与 live dictionaries 对称：直打 /api/library/books，不经 WebDAV 暂存。

  /// 列出对端 host 当前书库清单（直打 `/api/library/books`）。
  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async {
    await _ensureResolved();
    final HttpClientRequest req =
        await _ops!.buildRequest('GET', '$_apiBase/api/library/books');
    final HttpClientResponse res = await req.close();
    _ops!.checkStatus(res.statusCode, 'GET /api/library/books');
    final String body = await res.transform(utf8.decoder).join();
    final List<dynamic> arr = jsonDecode(body) as List<dynamic>;
    return <RemoteBookInfo>[
      for (final dynamic e in arr)
        RemoteBookInfo.fromJson((e as Map).cast<String, Object?>()),
    ];
  }

  /// 从对端 host 下载书名为 [title] 的 EPUB 到 [destination] 文件。
  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    await downloadContentFile(
      fileId: '$_apiBase/api/library/books/${Uri.encodeComponent(title)}',
      destination: destination,
      onProgress: onProgress,
    );
  }

  /// 把本地 [file]（.epub）推送到对端 host，导入书名为 [title] 的书。
  Future<void> putRemoteBook(
    String title,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/books/${Uri.encodeComponent(title)}',
    );
    final int length = await file.length();
    req.headers.set('Content-Type', 'application/epub+zip');
    req.headers.set('Content-Length', '$length');
    int sent = 0;
    await req.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      onProgress?.call(length > 0 ? sent / length : 0);
      return chunk;
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/books/$title');
  }

  /// 通知对端 host 删除书名为 [title] 的书。
  Future<void> deleteRemoteBook(String title) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'DELETE',
      '$_apiBase/api/library/books/${Uri.encodeComponent(title)}',
    );
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'DELETE /api/library/books/$title');
  }

  /// 读 host 端书 [bookKey] 的阅读进度（TODO-767）。host 返回 404（该书无记录）或
  /// 网络异常时返回 [RemoteBookProgress.empty]，让调用方退回本地 `reader_positions`
  /// （离线 / 旧 host 无端点不致崩溃）。
  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/books/${Uri.encodeComponent(bookKey)}/progress',
    );
    final HttpClientResponse res = await req.close();
    if (res.statusCode == 404) {
      await res.drain<void>();
      return RemoteBookProgress.empty;
    }
    _ops!.checkStatus(
        res.statusCode, 'GET /api/library/books/$bookKey/progress');
    final String body = await res.transform(utf8.decoder).join();
    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    return RemoteBookProgress.fromJson(json.cast<String, Object?>());
  }

  /// 向 host 上报书 [bookKey] 的本端阅读进度（TODO-767）。host 端取较新时间戳决定
  /// 是否覆盖（落 host 自己的 reader_positions）。
  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/books/${Uri.encodeComponent(bookKey)}/progress',
    );
    req.headers.set('Content-Type', 'application/json');
    req.write(jsonEncode(progress.toJson()));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(
        res.statusCode, 'PUT /api/library/books/$bookKey/progress');
  }

  // ── Live local audio (interconnect-only) ──────────────────────────
  // 与 live books 对称：直打 /api/library/localaudio，不经 WebDAV 暂存。

  /// 列出对端 host 当前本地音频来源清单（直打 `/api/library/localaudio`）。
  Future<List<RemoteLocalAudioInfo>> listRemoteLocalAudio() async {
    await _ensureResolved();
    final HttpClientRequest req =
        await _ops!.buildRequest('GET', '$_apiBase/api/library/localaudio');
    final HttpClientResponse res = await req.close();
    _ops!.checkStatus(res.statusCode, 'GET /api/library/localaudio');
    final String body = await res.transform(utf8.decoder).join();
    final List<dynamic> arr = jsonDecode(body) as List<dynamic>;
    return <RemoteLocalAudioInfo>[
      for (final dynamic e in arr)
        RemoteLocalAudioInfo.fromJson((e as Map).cast<String, Object?>()),
    ];
  }

  /// 从对端 host 下载 displayName 为 [displayName] 的本地音频库到 [dest] 文件。
  Future<void> getRemoteLocalAudio(
    String displayName,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    await downloadContentFile(
      fileId:
          '$_apiBase/api/library/localaudio/${Uri.encodeComponent(displayName)}',
      destination: dest,
      onProgress: onProgress,
    );
  }

  /// 把本地 [file] 推送到对端 host，导入 displayName 为 [displayName] 的本地音频来源。
  Future<void> putRemoteLocalAudio(
    String displayName,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/localaudio/${Uri.encodeComponent(displayName)}',
    );
    final int length = await file.length();
    req.headers.set('Content-Type', 'application/octet-stream');
    req.headers.set('Content-Length', '$length');
    int sent = 0;
    await req.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      onProgress?.call(length > 0 ? sent / length : 0);
      return chunk;
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(
        res.statusCode, 'PUT /api/library/localaudio/$displayName');
  }

  /// 通知对端 host 删除 displayName 为 [displayName] 的本地音频来源。
  Future<void> deleteRemoteLocalAudio(String displayName) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'DELETE',
      '$_apiBase/api/library/localaudio/${Uri.encodeComponent(displayName)}',
    );
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(
        res.statusCode, 'DELETE /api/library/localaudio/$displayName');
  }

  // ── Live audiobooks (interconnect-only) ───────────────────────────
  // 与 live books 对称：直打 /api/library/audiobooks，不经 WebDAV 暂存。

  /// 列出对端 host 当前有声书清单（直打 `/api/library/audiobooks`）。
  Future<List<RemoteAudiobookInfo>> listRemoteAudiobooks() async {
    await _ensureResolved();
    final HttpClientRequest req =
        await _ops!.buildRequest('GET', '$_apiBase/api/library/audiobooks');
    final HttpClientResponse res = await req.close();
    _ops!.checkStatus(res.statusCode, 'GET /api/library/audiobooks');
    final String body = await res.transform(utf8.decoder).join();
    final List<dynamic> arr = jsonDecode(body) as List<dynamic>;
    return <RemoteAudiobookInfo>[
      for (final dynamic e in arr)
        RemoteAudiobookInfo.fromJson((e as Map).cast<String, Object?>()),
    ];
  }

  /// 从对端 host 下载 bookKey 为 [bookKey] 的有声书到 [dest] 文件。
  Future<void> getRemoteAudiobook(
    String bookKey,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    await downloadContentFile(
      fileId:
          '$_apiBase/api/library/audiobooks/${Uri.encodeComponent(bookKey)}',
      destination: dest,
      onProgress: onProgress,
    );
  }

  /// 把本地 [file] 推送到对端 host，导入 bookKey 为 [bookKey] 的有声书。
  Future<void> putRemoteAudiobook(
    String bookKey,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/audiobooks/${Uri.encodeComponent(bookKey)}',
    );
    final int length = await file.length();
    req.headers.set('Content-Type', 'application/octet-stream');
    req.headers.set('Content-Length', '$length');
    int sent = 0;
    await req.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      onProgress?.call(length > 0 ? sent / length : 0);
      return chunk;
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/audiobooks/$bookKey');
  }

  /// 通知对端 host 删除 bookKey 为 [bookKey] 的有声书。
  Future<void> deleteRemoteAudiobook(String bookKey) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest(
      'DELETE',
      '$_apiBase/api/library/audiobooks/${Uri.encodeComponent(bookKey)}',
    );
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!
        .checkStatus(res.statusCode, 'DELETE /api/library/audiobooks/$bookKey');
  }

  // ── Remote videos (interconnect-only, read-only) ─────────────────────────
  // 视频只远程观看/可选下载，不参与双向同步。Host 的 /stream 端点使用短时
  // token URL，media_kit 可直接播放，不依赖自定义 HTTP header。

  /// 列出对端 host 当前视频清单（直打 `/api/library/videos`）。
  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    await _ensureResolved();
    final HttpClientRequest req =
        await _ops!.buildRequest('GET', '$_apiBase/api/library/videos');
    final HttpClientResponse res = await req.close();
    _ops!.checkStatus(res.statusCode, 'GET /api/library/videos');
    final String body = await res.transform(utf8.decoder).join();
    final List<dynamic> arr = jsonDecode(body) as List<dynamic>;
    return <RemoteVideoInfo>[
      for (final dynamic e in arr)
        RemoteVideoInfo.fromJson((e as Map).cast<String, Object?>()),
    ];
  }

  /// 向 host 换取可直接播放的视频 stream URL。
  ///
  /// 返回的 [RemoteVideoStreamUrls.streamUrl] 已携带短时 token；播放器不需要
  /// Authorization 头。字幕 URL（若存在）仍是普通受 Basic 鉴权的 API URL，UI
  /// 可先用 [getRemoteVideoSubtitle] 下载到本地后交给现有字幕加载逻辑。
  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async {
    await _ensureResolved();
    final String encodedId = _encodeVideoId(id);
    final String query = episodeIndex > 0 ? '?episode=$episodeIndex' : '';
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/videos/$encodedId/streamurl$query',
    );
    final HttpClientResponse res = await req.close();
    _ops!.checkStatus(res.statusCode, 'GET /api/library/videos/$id/streamurl');
    final String body = await res.transform(utf8.decoder).join();
    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    return RemoteVideoStreamUrls.fromJson(json);
  }

  /// media_kit 兼容接口：当前协议走 token URL，因此无需额外 HTTP headers。
  Map<String, String> remoteVideoAuthHeaders() => const <String, String>{};

  /// 下载对端视频外挂字幕到 [dest]。
  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {
    await _ensureResolved();
    final Map<String, String> query = <String, String>{
      if (embeddedStreamIndex != null)
        'embeddedStreamIndex': '$embeddedStreamIndex',
      if (episodeIndex > 0) 'episode': '$episodeIndex',
    };
    final Uri uri = Uri.parse(
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}/subtitle',
    ).replace(queryParameters: query.isEmpty ? null : query);
    await downloadContentFile(
      fileId: uri.toString(),
      destination: dest,
      onProgress: onProgress,
    );
  }

  /// 整段下载对端视频到 [dest]（用于 UI 的「下载到本机」）。
  ///
  /// 下载走 host 签发的 token stream URL，避免依赖播放器/header 兼容性；失败时
  /// 复用 [downloadContentFile] 同款清理语义，不留下截断文件。
  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    final RemoteVideoStreamUrls urls = await remoteVideoStreamUrls(id);
    // 根因修复（TODO-819）：旧实现是裸 GET 无 Range，中断即整包删、
    // 下次从 0。host /stream 已支持 Range（serveFileWithRange → 206），故改走通用
    // ResumableDownloader：Range + 同目录 .part + 中断保留 part 可续传。LAN 单源
    // 不分片（单连接 Range 已足够，避免共享出口限流）。
    final File partFile = File('${dest.path}.part');
    await dest.parent.create(recursive: true);
    final HttpClient client = HttpClient();
    try {
      final ResumableDownloader downloader = ResumableDownloader(
        url: urls.streamUrl,
        destination: dest,
        partFile: partFile,
        open: (Uri uri, Map<String, String> headers) =>
            _openResumableRequest(client, uri, headers),
        onProgress: (int received, int? total) {
          if (total != null && total > 0) {
            onProgress?.call(received / total);
          }
        },
      );
      await downloader.download();
    } finally {
      client.close(force: true);
    }
  }

  /// ResumableDownloader 的注入缝：用 [client] 发一次带 [headers]（含 Range/If-Range）
  /// 的 GET，包成 [ResumableDownloadResponse]。token stream URL 自带鉴权，无需额外头。
  Future<ResumableDownloadResponse> _openResumableRequest(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final HttpClientRequest request = await client.openUrl('GET', uri);
    for (final MapEntry<String, String> entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final HttpClientResponse response = await request.close();
    final Map<String, String> responseHeaders = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      if (values.isNotEmpty) responseHeaders[name] = values.join(',');
    });
    return ResumableDownloadResponse(
      statusCode: response.statusCode,
      headers: responseHeaders,
      stream: response,
    );
  }

  /// 读 host 端视频 [id] 的播放断点（TODO-653）。host 返回 404（视频不存在）或网络
  /// 异常时返回 (0, 0)，让调用方退回本地 prefs（离线/旧 host 不致崩溃）。
  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async {
    await _ensureResolved();
    final String query = episodeIndex > 0 ? '?episode=$episodeIndex' : '';
    final HttpClientRequest req = await _ops!.buildRequest(
      'GET',
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}/position$query',
    );
    final HttpClientResponse res = await req.close();
    if (res.statusCode == 404) {
      await res.drain<void>();
      return (positionMs: 0, updatedAtMs: 0);
    }
    _ops!.checkStatus(res.statusCode, 'GET /api/library/videos/$id/position');
    final String body = await res.transform(utf8.decoder).join();
    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    return (
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['positionUpdatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// 向 host 上报视频 [id] 的本端播放断点（TODO-653）。host 端取较新时间戳决定覆盖。
  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    await _ensureResolved();
    final String query = episodeIndex > 0 ? '?episode=$episodeIndex' : '';
    final HttpClientRequest req = await _ops!.buildRequest(
      'PUT',
      '$_apiBase/api/library/videos/${_encodeVideoId(id)}/position$query',
    );
    req.headers.set('Content-Type', 'application/json');
    req.write(jsonEncode(<String, Object?>{
      'positionMs': positionMs,
      'positionUpdatedAtMs': updatedAtMs,
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/videos/$id/position');
  }

  static String _encodeVideoId(String id) =>
      id.split('/').map(Uri.encodeComponent).join('/');

  // ── Test connection ───────────────────────────────────────────────

  Future<void> testConnection({
    required String url,
    required String token,
  }) async {
    final ops = WebDavOps(
      baseUrl: WebDavOps.normalizeUrl(url),
      username: 'hibiki',
      password: token,
    );
    try {
      await ops.testConnection();
    } finally {
      ops.close();
    }
  }
}
