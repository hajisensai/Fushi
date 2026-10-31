import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, protected;
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
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
        final ({String mimeType, String extension}) format = detectCoverFormat(
          coverData,
        );
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

/// 把一次对同步根 [rootHref] 的树列举（PROPFIND，至少列到孙层）装配成
/// [RemoteListingSnapshot]（BUG-3743）。
///
/// 与逐本 [WebDavPathBackendMixin.listSyncFiles] 给出同一批 id / 名字：书文件夹名取该
/// 文件夹条目的 `displayName`（与 [WebDavPathBackendMixin.listBooks] 同源），文件 id 是
/// 回包 href 原样、名字是 `displayName`；三件套再由快照的 `trioFor` 走同一个 canonical
/// matcher。
///
/// 回包形状不对就返回 null（调用方回退逐本列举），不做「尽量凑」：
/// - 缺根自身条目（任何合法 PROPFIND 回包都带请求目标自身）；
/// - 出现不在同步根下的 href；
/// - 孙层条目找不到所属文件夹条目。
/// 层级按 href 的**路径部分**算（去掉 `scheme://authority`），不受默认端口写法等
/// 来源差异影响。
RemoteListingSnapshot? remoteListingFromDavTree(
  List<DavEntry> entries,
  String rootHref,
) {
  final String rootPath = _davPathOf(ensureFolderIdTrailingSlash(rootHref));
  bool sawRoot = false;
  final Map<String, String> folderNameBySegment = <String, String>{};
  final List<(String, DavEntry)> grandchildren = <(String, DavEntry)>[];
  final RemoteListingBuilder builder = RemoteListingBuilder();

  for (final DavEntry e in entries) {
    final String path = _davPathOf(e.href);
    if (!path.startsWith(rootPath)) {
      if (ensureFolderIdTrailingSlash(path) == rootPath) {
        sawRoot = true;
        continue;
      }
      return null;
    }
    String rel = path.substring(rootPath.length);
    if (rel.endsWith('/')) rel = rel.substring(0, rel.length - 1);
    if (rel.isEmpty) {
      sawRoot = true;
      continue;
    }
    final int slash = rel.indexOf('/');
    if (slash < 0) {
      // 同步根的直接子项：文件夹登记（空文件夹也要能与「不存在」区分）；直接躺在
      // 根下的文件是 BUG-619 的 spill 残留，不属于任何书。
      if (e.isCollection) {
        folderNameBySegment[rel] = e.displayName;
        builder.addFolder(e.displayName);
      }
      continue;
    }
    // 更深的层级当前布局里不存在（host 也不会列），忽略而不是硬塞进某个文件夹。
    if (rel.indexOf('/', slash + 1) >= 0) continue;
    grandchildren.add((rel.substring(0, slash), e));
  }
  if (!sawRoot) return null;

  for (final (String segment, DavEntry e) in grandchildren) {
    final String? parentName = folderNameBySegment[segment];
    if (parentName == null) return null;
    builder.addEntry(
      parentName: parentName,
      name: e.displayName,
      id: e.href,
      isFolder: e.isCollection,
    );
  }
  return builder.build();
}

/// href 的路径部分：绝对 URL 去掉 `scheme://authority`，相对路径原样。不经
/// [Uri.parse]——[DavEntry.href] 是已解码的可读形态（含中文 / 空格），解析会改写它。
String _davPathOf(String href) {
  final int scheme = href.indexOf('://');
  if (scheme < 0) return href;
  final int slash = href.indexOf('/', scheme + 3);
  return slash < 0 ? '/' : href.substring(slash);
}
