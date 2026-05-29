import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

class FallbackSyncBackend extends SyncBackend {
  FallbackSyncBackend(this._backends) {
    if (_backends.isEmpty) {
      throw ArgumentError('At least one backend is required');
    }
  }

  final List<SyncBackend> _backends;
  int _activeIndex = 0;

  int get activeBackendIndex => _activeIndex;
  SyncBackend get activeBackend => _backends[_activeIndex];

  Future<T> _tryAll<T>(Future<T> Function(SyncBackend backend) action) async {
    SyncBackendError? lastError;
    for (var i = 0; i < _backends.length; i++) {
      try {
        final result = await action(_backends[i]);
        _activeIndex = i;
        return result;
      } on SyncAuthError {
        rethrow;
      } on SyncBackendError catch (e) {
        if (!e.isRetryable) rethrow;
        lastError = e;
        continue;
      }
    }
    throw lastError ?? SyncBackendError('All backends failed');
  }

  Future<void> _tryAllVoid(
      Future<void> Function(SyncBackend backend) action) async {
    SyncBackendError? lastError;
    for (var i = 0; i < _backends.length; i++) {
      try {
        await action(_backends[i]);
        _activeIndex = i;
        return;
      } on SyncAuthError {
        rethrow;
      } on SyncBackendError catch (e) {
        if (!e.isRetryable) rethrow;
        lastError = e;
        continue;
      }
    }
    throw lastError ?? SyncBackendError('All backends failed');
  }

  // ── Auth — delegates to active backend ──────────────────────────

  @override
  Future<bool> get isAuthenticated => activeBackend.isAuthenticated;
  @override
  Future<String?> get currentEmail => activeBackend.currentEmail;
  @override
  Future<void> authenticate({required SyncRepository repo}) =>
      activeBackend.authenticate(repo: repo);
  @override
  Future<void> signOut({required SyncRepository repo}) =>
      activeBackend.signOut(repo: repo);
  @override
  Future<bool> restoreAuth(SyncRepository repo) =>
      activeBackend.restoreAuth(repo);
  @override
  Future<void> refreshAuth() => activeBackend.refreshAuth();

  // ── Folder operations — fallback across backends ──────────────

  @override
  Future<String> findOrCreateRootFolder() =>
      _tryAll((b) => b.findOrCreateRootFolder());
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) =>
      _tryAll((b) => b.listBooks(rootFolderId));
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) =>
      _tryAll((b) => b.ensureBookFolder(
            bookTitle: bookTitle,
            rootFolderId: rootFolderId,
            coverData: coverData,
          ));

  // ── Metadata sync — fallback ──────────────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) =>
      _tryAll((b) => b.listSyncFiles(folderId));
  @override
  Future<TtuProgress> getProgressFile(String fileId) =>
      _tryAll((b) => b.getProgressFile(fileId));
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) =>
      _tryAll((b) => b.getStatsFile(fileId));
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) =>
      _tryAll((b) => b.getAudioBookFile(fileId));
  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) =>
      _tryAllVoid((b) => b.updateProgressFile(
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
      _tryAllVoid((b) => b.updateStatsFile(
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
      _tryAllVoid((b) => b.updateAudioBookFile(
            folderId: folderId,
            fileId: fileId,
            audioBook: audioBook,
          ));

  // ── Content file sync — fallback ──────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) =>
      _tryAllVoid((b) => b.uploadContentFile(
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
      _tryAllVoid((b) => b.downloadContentFile(
            fileId: fileId,
            destination: destination,
            onProgress: onProgress,
          ));
  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) =>
      _tryAll((b) => b.findContentFile(folderId, fileName));

  // ── Cache — delegates to active backend ───────────────────────

  @override
  void clearCache() => activeBackend.clearCache();
  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) =>
      activeBackend.restoreCache(
        rootFolderId: rootFolderId,
        titleToFolderId: titleToFolderId,
      );
  @override
  String? get cachedRootFolderId => activeBackend.cachedRootFolderId;
  @override
  Map<String, String> get cachedFolderIds => activeBackend.cachedFolderIds;
  @override
  void cacheBookFolderIds(List<DriveFile> folders) =>
      activeBackend.cacheBookFolderIds(folders);
}
