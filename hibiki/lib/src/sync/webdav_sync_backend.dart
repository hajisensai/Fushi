import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_backend_file_trio_mixin.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/ttu_models.dart';
import 'package:fushi/src/sync/webdav_ops.dart';

class WebDavSyncBackend extends SyncBackend
    with SyncFolderCache, SyncBackendFileTrioMixin, SyncAssetStoreDefaults {
  WebDavSyncBackend._();
  static final WebDavSyncBackend instance = WebDavSyncBackend._();

  WebDavOps? _ops;
  String? _username;

  // 路径式后端：folderId 是裸路径前缀，必须以 `/` 结尾（BUG-845）。
  @override
  String normalizeFolderId(String id) => ensureFolderIdTrailingSlash(id);

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
    if (rootFolderIdCache != null) return rootFolderIdCache!;

    final path = '${_ops!.baseUrl}/$kSyncRootFolderName/';
    await _ops!.ensureCollection(path);
    rootFolderIdCache = path;
    return path;
  }

  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async {
    final entries = await _ops!.propfindChildren(rootFolderId);
    return entries
        .where((e) => e.isCollection && e.href != rootFolderId)
        .map((e) => SyncFileRef(id: e.href, name: e.displayName))
        .toList();
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async {
    final sanitized = requireBookFolderName(bookTitle);

    if (folderIdCache.containsKey(sanitized)) {
      // A cached id may have entered slash-less from a server PROPFIND href
      // (some WebDAV servers omit the trailing slash on collection hrefs).
      // Normalize on return so `folderId + fileName` never fuses the file into
      // the root as `<title>audioBook_…` (BUG-845).
      return ensureFolderIdTrailingSlash(folderIdCache[sanitized]!);
    }

    final path = '$rootFolderId${Uri.encodeComponent(sanitized)}/';
    await _ops!.ensureCollection(path);
    folderIdCache[sanitized] = path;

    final Uint8List? coverData = await readCoverData?.call();
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
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    final entries = await _ops!.propfindChildren(folderId);
    final files = entries
        .where((e) => !e.isCollection && e.href != folderId)
        .map((e) => SyncFileRef(id: e.href, name: e.displayName))
        .toList();

    return SyncFileTrio(
      progress: WebDavOps.findByPrefix(files, 'progress_'),
      statistics: WebDavOps.findByPrefix(files, 'statistics_'),
      audioBook: WebDavOps.findByPrefix(files, 'audioBook_'),
    );
  }

  // get{Progress,Stats,AudioBook}File 三件套由 SyncBackendFileTrioMixin 提供；
  // 这里只给出 WebDAV 的下载原语（size-capped GET + jsonDecode，见 WebDavOps）。
  @override
  Future<Object?> readJsonById(String fileId) => _ops!.downloadJson(fileId);

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

    await writeSyncStreamToFile(
      source: response,
      destination: destination,
      totalBytes: response.contentLength,
      onProgress: onProgress,
      onCleanupError: (e) =>
          debugPrint('[webdav] failed to clean up temp file: $e'),
    );
  }

  @override
  Future<SyncFileRef?> findContentFile(String folderId, String fileName) async {
    final path = '$folderId${Uri.encodeComponent(fileName)}';
    final exists = await _ops!.headFile(path);
    if (!exists) return null;
    return SyncFileRef(id: path, name: fileName);
  }

  // ── Cache ─────────────────────────────────────────────────────────
  //
  // 缓存字段 + clearCache / restoreCache / cachedRootFolderId / cachedFolderIds
  // / cacheBookFolderIds / evictFolderId 六方法收敛进 [SyncFolderCache] mixin；
  // 本后端仅覆写 [normalizeFolderId] 保持尾斜杠规范化（BUG-845，见类顶部）。

  // ── SyncAssetStore ────────────────────────────────────────────────

  @override
  Future<String> ensureNamespace(String name) async {
    final root = '${_ops!.baseUrl}/$kSyncRootFolderName/';
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
