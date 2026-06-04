import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';

class WebDavSyncBackend extends SyncBackend {
  WebDavSyncBackend._();
  static final WebDavSyncBackend instance = WebDavSyncBackend._();

  WebDavOps? _ops;
  String? _username;
  String? _rootFolderId;
  final Map<String, String> _titleToFolderId = {};

  // ── Auth ──────────────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated async => _ops != null;

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

    final normalized = WebDavOps.normalizeUrl(url);
    _ops = WebDavOps(baseUrl: normalized, username: user, password: pass);
    _username = user;
    // The URL may have changed; drop folder ids cached against the old base
    // URL so we never target the previous server (HBK-AUDIT-158).
    clearCache();

    await _ops!.testConnection();
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    _ops?.close();
    _ops = null;
    _username = null;
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

    final normalized = WebDavOps.normalizeUrl(url);
    _ops = WebDavOps(baseUrl: normalized, username: user, password: pass);
    _username = user;
    return true;
  }

  @override
  Future<void> refreshAuth() async {}

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() async {
    if (_rootFolderId != null) return _rootFolderId!;

    final path = '${_ops!.baseUrl}/ttu-reader-data/';
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
        debugPrint('[webdav] cover upload failed: $e');
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

    return DriveSyncFiles(
      progress: WebDavOps.findByPrefix(files, 'progress_'),
      statistics: WebDavOps.findByPrefix(files, 'statistics_'),
      audioBook: WebDavOps.findByPrefix(files, 'audioBook_'),
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
    final fileName =
        progressFileName(progress.lastBookmarkModified, progress.progress);
    await _ops!.uploadJson(folderId, fileName, progress.toJson());
    // Upload-then-delete: remove the old file only after the new one is safely
    // uploaded, so a failed upload never destroys the only copy (HBK-AUDIT-048).
    if (fileId != null) await _ops!.deleteFile(fileId);
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    final fileName = statisticsFileName(stats);
    await _ops!
        .uploadJson(folderId, fileName, stats.map((s) => s.toJson()).toList());
    // Upload-then-delete (HBK-AUDIT-048).
    if (fileId != null) await _ops!.deleteFile(fileId);
  }

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    final fileName = audioBookFileName(
        audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
    await _ops!.uploadJson(folderId, fileName, audioBook.toJson());
    // Upload-then-delete (HBK-AUDIT-048).
    if (fileId != null) await _ops!.deleteFile(fileId);
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
          debugPrint('[webdav] failed to clean up temp file: $e');
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

  // ── SyncAssetStore ────────────────────────────────────────────────

  @override
  Future<String> ensureNamespace(String name) async {
    final root = '${_ops!.baseUrl}/ttu-reader-data/';
    final path = '$root${Uri.encodeComponent(name)}/';
    await _ops!.ensureCollection(path);
    return path;
  }

  @override
  Future<String> ensureFolder(String parentId, String name) async {
    final path = '$parentId${Uri.encodeComponent(name)}/';
    await _ops!.ensureCollection(path);
    return path;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
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
  }) {
    return uploadContentFile(
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
  }) {
    return downloadContentFile(
      fileId: assetId,
      destination: destination,
      onProgress: onProgress,
    );
  }

  @override
  Future<Object?> getJsonAsset(String assetId) => _ops!.downloadJson(assetId);

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _ops!.uploadJson(namespaceId, name, json);

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    // WebDAV DELETE 对 collection（文件夹）递归删除，对文件单删；同一原语。
    // WebDavOps.deleteFile 已把 404/已删除当作成功（幂等）；其它错误（网络/权限/
    // 协议）必须自然抛出，否则 UI 会把真实失败误报为「已删除」。
    await _ops!.deleteFile(id);
  }

  static String _stripTrailingSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  // ── Test connection ───────────────────────────────────────────────

  Future<void> testConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    final ops = WebDavOps(
      baseUrl: WebDavOps.normalizeUrl(url),
      username: username,
      password: password,
    );
    try {
      await ops.testConnection();
    } finally {
      ops.close();
    }
  }
}
