import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

enum SyncBackendType { googleDrive, webDav }

class SyncBackendError implements Exception {
  SyncBackendError(this.message, {this.isRetryable = false});
  final String message;
  final bool isRetryable;

  @override
  String toString() => 'SyncBackendError: $message';
}

class SyncAuthError implements Exception {
  SyncAuthError(this.message);
  final String message;

  @override
  String toString() => 'SyncAuthError: $message';
}

abstract class SyncBackend {
  // ── Auth ──────────────────────────────────────────────────────────

  Future<bool> get isAuthenticated;
  Future<String?> get currentEmail;
  Future<void> authenticate({required SyncRepository repo});
  Future<void> signOut({required SyncRepository repo});
  Future<bool> restoreAuth(SyncRepository repo);
  Future<void> refreshAuth();

  // ── Folder operations ─────────────────────────────────────────────

  Future<String> findOrCreateRootFolder();
  Future<List<DriveFile>> listBooks(String rootFolderId);
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  });

  // ── Metadata sync (JSON) ──────────────────────────────────────────

  Future<DriveSyncFiles> listSyncFiles(String folderId);
  Future<TtuProgress> getProgressFile(String fileId);
  Future<List<TtuStatistics>> getStatsFile(String fileId);
  Future<TtuAudioBook> getAudioBookFile(String fileId);
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  });
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  });
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  });

  // ── Content file sync ─────────────────────────────────────────────

  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  });
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  });
  Future<DriveFile?> findContentFile(String folderId, String fileName);

  // ── Cache ─────────────────────────────────────────────────────────

  void clearCache();
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  });
  String? get cachedRootFolderId;
  Map<String, String> get cachedFolderIds;
  void cacheBookFolderIds(List<DriveFile> folders);
}
