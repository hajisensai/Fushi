import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:hibiki/src/sync/google_drive_auth.dart';
import 'package:hibiki/src/sync/google_drive_handler.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

class GoogleDriveSyncBackend extends SyncBackend {
  GoogleDriveSyncBackend._();
  static final GoogleDriveSyncBackend instance = GoogleDriveSyncBackend._();

  final GoogleDriveHandler _drive = GoogleDriveHandler.instance;
  final GoogleDriveAuth _auth = GoogleDriveAuth.instance;

  /// Maps a [GoogleDriveError] to the sync-layer exception type. A 403
  /// insufficient_scope is NOT a retryable backend failure (TODO-836): the old
  /// drive.file grant no longer covers drive.appdata, so the session must be
  /// re-consented — it becomes a [SyncAuthError] that the manual-sync catch turns
  /// into a sign-out + re-login prompt, instead of a [SyncBackendError] that
  /// dead-ends at a generic toast. Extracted as a single source of truth so
  /// both wraps stay symmetric and the classification is unit-testable.
  @visibleForTesting
  static Exception mapDriveError(GoogleDriveError e) {
    if (e.statusCode == 403 &&
        e.message.toLowerCase().contains('insufficient_scope')) {
      return SyncAuthError(e.message);
    }
    return SyncBackendError(e.message, isRetryable: e.isStaleCacheError);
  }

  Future<T> _wrapErrors<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on GoogleDriveError catch (e) {
      throw mapDriveError(e);
    } on GoogleDriveAuthError catch (e) {
      throw SyncAuthError(e.message);
    }
  }

  Future<void> _wrapVoidErrors(Future<void> Function() fn) async {
    try {
      await fn();
    } on GoogleDriveError catch (e) {
      throw mapDriveError(e);
    } on GoogleDriveAuthError catch (e) {
      throw SyncAuthError(e.message);
    }
  }

  // ── Auth ──────────────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated => _auth.isAuthenticated;

  @override
  Future<String?> get currentEmail => _auth.currentEmail;

  @override
  Future<void> authenticate({required SyncRepository repo}) =>
      _wrapVoidErrors(() => _auth.authenticate(repo: repo));

  @override
  Future<void> signOut({required SyncRepository repo}) =>
      _wrapVoidErrors(() => _auth.signOut(repo: repo));

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    // Mobile: rehydrate the google_sign_in session via signInSilently() instead
    // of the old no-op `return false`, which left the account row showing
    // "未登录"/no email and blocked auto-sync's isAuthenticated gate after a
    // restart (BUG-047).
    if (GoogleDriveAuth.useMobileAuth) return _auth.restoreMobileAuth();
    if (await _auth.isAuthenticated) return true;
    return _auth.restoreDesktopAuth(repo);
  }

  @override
  Future<void> refreshAuth() => _auth.refreshAuth();

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() =>
      _wrapErrors(() => _drive.findOrCreateRootFolder());

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) =>
      _wrapErrors(() => _drive.listBooks(rootFolderId));

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) =>
      _wrapErrors(() => _drive.ensureBookFolder(
            bookTitle: bookTitle,
            rootFolder: rootFolderId,
            coverData: coverData,
          ));

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) =>
      _wrapErrors(() => _drive.listSyncFiles(folderId));

  @override
  Future<TtuProgress> getProgressFile(String fileId) =>
      _wrapErrors(() => _drive.getProgressFile(fileId));

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) =>
      _wrapErrors(() => _drive.getStatsFile(fileId));

  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) =>
      _wrapErrors(() => _drive.getAudioBookFile(fileId));

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) =>
      _wrapVoidErrors(() => _drive.updateProgressFile(
            folderId: folderId,
            fileId: fileId,
            progress: progress,
          ));

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) =>
      _wrapVoidErrors(() => _drive.updateStatsFile(
            folderId: folderId,
            fileId: fileId,
            stats: stats,
          ));

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) =>
      _wrapVoidErrors(() => _drive.updateAudioBookFile(
            folderId: folderId,
            fileId: fileId,
            audioBook: audioBook,
          ));

  // ── Content file sync ──────────────────────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) =>
      _wrapVoidErrors(() => _drive.uploadContentFile(
            folderId: folderId,
            fileName: fileName,
            file: file,
            onProgress: onProgress,
          ));

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) =>
      _wrapVoidErrors(() => _drive.downloadContentFile(
            fileId: fileId,
            destination: destination,
            onProgress: onProgress,
          ));

  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) =>
      _wrapErrors(() => _drive.findContentFile(folderId, fileName));

  // ── Cache ─────────────────────────────────────────────────────────

  @override
  void clearCache() => _drive.clearCache();

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) =>
      _drive.restoreCache(
        rootFolderId: rootFolderId,
        titleToFolderId: titleToFolderId,
      );

  @override
  String? get cachedRootFolderId => _drive.cachedRootFolderId;

  @override
  Map<String, String> get cachedFolderIds => _drive.cachedFolderIds;

  @override
  void cacheBookFolderIds(List<DriveFile> folders) =>
      _drive.cacheBookFolderIds(folders);

  @override
  void evictFolderId(String folderId) => _drive.evictFolderId(folderId);

  // ── SyncAssetStore ─────────────────────────────────────────────────

  @override
  Future<String> ensureNamespace(String name) => _wrapErrors(() async {
        final root = await _drive.findOrCreateRootFolder();
        return _drive.ensureChildFolder(root, name);
      });

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _wrapErrors(() => _drive.ensureChildFolder(parentId, name));

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _wrapErrors(() => _drive.listChildrenRaw(namespaceId));

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) =>
      _wrapErrors(() async {
        final f = await _drive.findContentFile(namespaceId, name);
        if (f == null) return null;
        return AssetEntry(id: f.id, name: f.name);
      });

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) =>
      _wrapVoidErrors(() => _drive.uploadContentFile(
            folderId: namespaceId,
            fileName: name,
            file: file,
            onProgress: onProgress,
          ));

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) =>
      _wrapVoidErrors(() => _drive.downloadContentFile(
            fileId: assetId,
            destination: destination,
            onProgress: onProgress,
          ));

  @override
  Future<Object?> getJsonAsset(String assetId) =>
      _wrapErrors(() => _drive.downloadJsonById(assetId));

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _wrapVoidErrors(() => _drive.uploadJsonInFolder(namespaceId, name, json));

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _wrapVoidErrors(() async {
        // Drive 删文件夹即递归删内容，文件/文件夹同一 API；isFolder 无需分支。
        try {
          await _drive.deleteFile(id);
        } on GoogleDriveError catch (e) {
          if (e.isStaleCacheError) return; // 幂等：404 已不存在视为成功。
          rethrow;
        }
      });
}
