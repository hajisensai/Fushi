import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend_file_trio_mixin.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';

/// 两个「路径式」WebDAV 后端（WebDavSyncBackend / HibikiClientSyncBackend）共享
/// 的五个只读/建目录方法：findOrCreateRootFolder / listBooks / ensureBookFolder /
/// listSyncFiles / readJsonById。二者原本各持一份逐字（或仅注释/日志前缀有别）的
/// 副本，唯一真实分叉是 hibiki_client 在首个网络操作前要先做多候选地址解析
/// （`_ensureResolved`），抽成 [ensureReady] 钩子。
///
/// [ensureReady] 时机与原实现逐点对照：五方法中**只有** [findOrCreateRootFolder]
/// 在原 hibiki_client 实现里调用 `_ensureResolved()`（且在缓存检查之前）；其余四个
/// 原本就直接用 `_ops!`（readJsonById 明确「读取不经 _ensureResolved」——它只在
/// listSyncFiles 之后被 SyncBackendFileTrioMixin 的 get*File 调用，届时地址已解析）。
/// 因此本 mixin 只在 [findOrCreateRootFolder] 首行 `await ensureReady()`，别处一律
/// 不调，不得增删。
///
/// 写入侧（updateProgressFile 等）上传/删除次序在两后端真实分叉
/// （upload-then-delete vs delete-then-upload，见 SyncBackendFileTrioMixin 顶注），
/// 保留各自 override，不在此合并。
mixin WebDavPathBackendMixin
    on SyncBackend, SyncFolderCache, SyncBackendFileTrioMixin {
  /// 底层 WebDAV 传输原语。两后端都实现为 `_ops!`——保持原来的 null-assert 语义：
  /// 未 authenticate/restoreAuth 就调用时抛错，而不是静默空转。
  @protected
  WebDavOps get webDavOps;

  /// debugPrint 前缀（'[webdav]' / '[hibiki-client]'）。
  @protected
  String get logTag;

  /// 首个网络操作前的就绪钩子：WebDAV 空实现（authenticate/restoreAuth 后即就绪）；
  /// hibiki_client 转 `_ensureResolved()` 完成多候选 host 解析。时机见类顶注。
  @protected
  Future<void> ensureReady();

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() async {
    await ensureReady();
    if (rootFolderIdCache != null) return rootFolderIdCache!;

    final path = '${webDavOps.baseUrl}/$kSyncRootFolderName/';
    await webDavOps.ensureCollection(path);
    rootFolderIdCache = path;
    return path;
  }

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async {
    final entries = await webDavOps.propfindChildren(rootFolderId);
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
    final sanitized = requireBookFolderName(bookTitle);

    if (folderIdCache.containsKey(sanitized)) {
      // A cached id may have entered slash-less from a server PROPFIND href
      // (some WebDAV servers omit the trailing slash on collection hrefs).
      // Normalize on return so `folderId + fileName` never fuses the file into
      // the root as `<title>audioBook_…` (BUG-845).
      return ensureFolderIdTrailingSlash(folderIdCache[sanitized]!);
    }

    final path = '$rootFolderId${Uri.encodeComponent(sanitized)}/';
    await webDavOps.ensureCollection(path);
    folderIdCache[sanitized] = path;

    if (coverData != null) {
      try {
        final format = detectCoverFormat(coverData);
        final coverPath = '${path}cover_1_6.${format.extension}';
        final existing = await webDavOps.headFile(coverPath);
        if (!existing) {
          await webDavOps.putBytes(coverPath, coverData, format.mimeType);
        }
      } catch (e) {
        debugPrint('$logTag cover upload failed: $e');
      }
    }

    return path;
  }

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final entries = await webDavOps.propfindChildren(folderId);
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

  // get{Progress,Stats,AudioBook}File 三件套由 SyncBackendFileTrioMixin 提供；
  // 这里只给出路径式后端的下载原语（size-capped GET + jsonDecode，见
  // WebDavOps.downloadJson）。读取不经 ensureReady（沿用原实现，直接用 ops）。
  @override
  Future<Object?> readJsonById(String fileId) => webDavOps.downloadJson(fileId);
}
