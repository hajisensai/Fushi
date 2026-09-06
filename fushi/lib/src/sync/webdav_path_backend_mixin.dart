import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, protected;
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/sync/webdav_ops.dart';

/// 走 [WebDavOps] 的路径式后端（WebDAV / 互联 client）共用的三件套：
/// 列书目录、确保书目录（含封面上传）、列书目录下的同步文件。
///
/// 两个后端原本各写一份逐字相同的实现（2026-07-24 审查 §三-2）。它们的
/// `findOrCreateRootFolder` **有真实差异**（WebDAV 走 Fushi 改名迁移三段、互联
/// 没有），故不进这里；SFTP / FTP 原语不同（`listdir` vs `changeDirectory`+
/// `listDirectoryContent`+连接锁），也不进——硬合是拿 6 个抽象方法换 80 行。
///
/// folderId 是以 `/` 结尾的 href 前缀（BUG-845）；[SyncFolderCache.folderIdCache]
/// 里可能存着服务器 PROPFIND 回来的无尾斜杠 href，命中缓存时统一补斜杠再返回。
mixin WebDavPathBackendMixin on SyncBackend, SyncFolderCache {
  /// 当前会话的 WebDAV 原语；未建立会话时抛出（与原先 `_ops!` 同义）。
  @protected
  WebDavOps get davOps;

  /// 封面上传失败时 debugPrint 的前缀（`[webdav]` / `[fushi-client]`）。
  @protected
  String get davLogTag;

  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async {
    final List<DavEntry> entries = await davOps.propfindChildren(rootFolderId);
    return entries
        .where((DavEntry e) => e.isCollection && e.href != rootFolderId)
        .map((DavEntry e) => SyncFileRef(id: e.href, name: e.displayName))
        .toList();
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async {
    final String sanitized = requireBookFolderName(bookTitle);

    if (folderIdCache.containsKey(sanitized)) {
      // A cached id may have entered slash-less from a server PROPFIND href
      // (some WebDAV servers omit the trailing slash on collection hrefs).
      // Normalize on return so `folderId + fileName` never fuses the file into
      // the root as `<title>audioBook_…` (BUG-845).
      return ensureFolderIdTrailingSlash(folderIdCache[sanitized]!);
    }

    final String path = '$rootFolderId${Uri.encodeComponent(sanitized)}/';
    await davOps.ensureCollection(path);
    folderIdCache[sanitized] = path;

    final Uint8List? coverData = await readCoverData?.call();
    if (coverData != null) {
      try {
        final ({String mimeType, String extension}) format =
            detectCoverFormat(coverData);
        final String coverPath = '${path}cover_1_6.${format.extension}';
        final bool existing = await davOps.headFile(coverPath);
        if (!existing) {
          await davOps.putBytes(coverPath, coverData, format.mimeType);
        }
      } catch (e) {
        debugPrint('$davLogTag cover upload failed: $e');
      }
    }

    return path;
  }

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    final List<DavEntry> entries = await davOps.propfindChildren(folderId);
    final List<SyncFileRef> files = entries
        .where((DavEntry e) => !e.isCollection && e.href != folderId)
        .map((DavEntry e) => SyncFileRef(id: e.href, name: e.displayName))
        .toList();

    // HBK-AUDIT-085: route through the single canonical matcher in sync_utils.
    return SyncFileTrio(
      progress: findSyncFileByPrefix(files, 'progress_'),
      statistics: findSyncFileByPrefix(files, 'statistics_'),
      audioBook: findSyncFileByPrefix(files, 'audioBook_'),
    );
  }
}
