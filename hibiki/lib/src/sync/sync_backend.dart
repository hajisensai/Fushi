import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/sync/dropbox_sync_backend.dart';
import 'package:hibiki/src/sync/ftp_sync_backend.dart';
import 'package:hibiki/src/sync/google_drive_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/obfuscating_sync_backend.dart';
import 'package:hibiki/src/sync/onedrive_sync_backend.dart';
import 'package:hibiki/src/sync/sftp_sync_backend.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/src/sync/webdav_sync_backend.dart';

enum SyncBackendType {
  googleDrive,
  hibikiServer,
  webDav,
  oneDrive,
  dropbox,
  ftp,
  sftp,
}

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

abstract class SyncBackend implements SyncAssetStore {
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

  /// 删除某本书的远端文件夹（[folderId] = `ensureBookFolder` 返回的定位符）后，
  /// 把它从书名→folderId 缓存里逐出（按值反查，删所有指向 [folderId] 的条目）。
  ///
  /// 不逐出会留下「书名仍映射到已删/已 trash 的 folderId」的陈旧态：Google Drive
  /// 的 folderId 是不可变 ID，删后进回收站仍能被缓存命中，`ensureBookFolder` 命中
  /// 即返回 trashed folderId，后续上传打向 trashed 文件夹（其 `files.list` 返回空而
  /// 非 404，绕过 404 自愈）→ 复传石沉（BUG-202）。调用方逐出内存后须再
  /// `SyncRepository.setFolderCache(cachedFolderIds)` 重写持久化缓存。
  void evictFolderId(String folderId);
}

// HBK-AUDIT-091: resolver lives next to SyncBackendType (its switch subject)
// instead of inside the concrete GoogleDrive backend, so no single concrete
// backend is forced to import all of its siblings.
SyncBackend resolveSyncBackend(SyncBackendType type) {
  final SyncBackend raw;
  switch (type) {
    case SyncBackendType.googleDrive:
      raw = GoogleDriveSyncBackend.instance;
    case SyncBackendType.webDav:
      raw = WebDavSyncBackend.instance;
    case SyncBackendType.hibikiServer:
      // 局域网双端（hibiki 自有 server）不是「防扫盘」场景：两端都是用户自己的
      // 设备/服务，混淆只会徒增开销并破坏 hibiki client/server 的字节协议契约，
      // 所以 hibikiServer 直接返回裸后端，不包 ObfuscatingSyncBackend（TODO-623 A1）。
      return HibikiClientSyncBackend.instance;
    case SyncBackendType.oneDrive:
      raw = OneDriveSyncBackend.instance;
    case SyncBackendType.dropbox:
      raw = DropboxSyncBackend.instance;
    case SyncBackendType.ftp:
      raw = FtpSyncBackend.instance;
    case SyncBackendType.sftp:
      raw = SftpSyncBackend.instance;
  }
  // 其余均为云端/第三方存储：包一层字节混淆装饰器防扫盘看到明文内容（TODO-623 A1）。
  return ObfuscatingSyncBackend(raw);
}
