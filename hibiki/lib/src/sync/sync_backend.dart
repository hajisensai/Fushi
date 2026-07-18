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
import 'package:hibiki/src/sync/ttu_filename.dart';
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

/// The per-book sync folder name for [bookTitle] (its sanitized title), or throw
/// when that name would be empty.
///
/// `sanitizeTtuFilename('')` returns `''`, and every backend derives a per-book
/// folder as `<root>/<sanitized>/`. An empty sanitized name therefore collapses
/// that folder onto the sync root, scattering the book's `progress_*` /
/// `statistics_*` / `audioBook_*` JSON (and cover / epub / audiobook package)
/// directly into `hibiki-data/` next to real book folders (BUG-619, TODO-1329).
/// An empty title also has no unique `bookKey`, so such a row is not syncable —
/// refuse to resolve a folder for it instead of silently targeting the root.
/// The single guarded chokepoint every backend's [SyncBackend.ensureBookFolder]
/// funnels its title→folder-name derivation through.
String requireBookFolderName(String bookTitle) {
  final String name = sanitizeTtuFilename(bookTitle);
  if (name.isEmpty) {
    throw SyncBackendError(
      'refusing to resolve a book sync folder for an empty title: '
      'it would collapse onto the sync root',
    );
  }
  return name;
}

/// Path-style backends (WebDAV, Hibiki interconnect) use a book/namespace
/// folderId as a bare path PREFIX: a child is addressed as `folderId + name`
/// with NO separator inserted (see `WebDavOps.uploadJson`). The prefix therefore
/// MUST end with `/`, or `folderId + fileName` fuses the two into a sibling of
/// the folder — `<root>/<title>audioBook_1_6_….json` lands directly in the sync
/// root with the title glued to the file name instead of inside
/// `<root>/<title>/` (BUG-845, a re-report of BUG-619 / BUG-653's spill).
///
/// `ensureBookFolder` appends the slash when it CREATES a folder, but folder ids
/// also enter the cache from server PROPFIND hrefs
/// (`cacheBookFolderIds` / `restoreCache`), and some WebDAV servers (e.g.
/// Nutstore / 坚果云) return collection hrefs WITHOUT a trailing slash. Run every
/// such id through this before caching or returning it so the invariant "a
/// cached folderId ends with `/`" holds by construction — and any already
/// poisoned persisted cache self-heals the next time it is loaded.
String ensureFolderIdTrailingSlash(String folderId) =>
    folderId.endsWith('/') ? folderId : '$folderId/';

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

/// SyncAssetStore 默认委托（与 [SyncBackendFileTrioMixin]/[SyncFolderCache]
/// 同款模式：挂在具体后端的 `with` 列表，SyncBackend 接口零变化——测试 fake 用
/// `implements SyncBackend` 不受影响）。
mixin SyncAssetStoreDefaults on SyncBackend {
  //
  // findAsset/putAsset/getAsset were byte-identical across the ID-style backends
  // (ftp/sftp/dropbox/onedrive), each forwarding verbatim to the per-backend
  // content primitives, so they live here once instead of six copies. The
  // concrete findContentFile / uploadContentFile / downloadContentFile each
  // already take their own backend lock (_opLock / _guarded / WebDavOps), so
  // these defaults MUST NOT wrap them in another lock — re-acquiring a
  // non-reentrant mutex would deadlock (do not re-wrap).
  //
  // Path-style backends (WebDAV, Hibiki interconnect) probe existence with a
  // HEAD rather than findContentFile, so they still override findAsset; nothing
  // else diverges. The lone readiness difference — HibikiClientSyncBackend must
  // settle on a reachable host before any per-asset op — is funnelled through
  // the [ensureAssetReady] hook (default no-op) instead of duplicated call sites.

  /// Protected readiness hook awaited before the default [putAsset] / [getAsset]
  /// forward. Default no-op; a backend that must settle a session first
  /// (HibikiClientSyncBackend → resolve a reachable host) overrides it.
  Future<void> ensureAssetReady() async {}

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    // Delegates to the already-locking findContentFile; do not re-wrap.
    final DriveFile? file = await findContentFile(namespaceId, name);
    if (file == null) return null;
    return AssetEntry(id: file.id, name: file.name);
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    await ensureAssetReady();
    // Delegates to the already-locking uploadContentFile; do not re-wrap.
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
    await ensureAssetReady();
    // Delegates to the already-locking downloadContentFile; do not re-wrap.
    await downloadContentFile(
      fileId: assetId,
      destination: destination,
      onProgress: onProgress,
    );
  }
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
