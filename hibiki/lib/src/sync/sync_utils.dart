import 'dart:async';
import 'dart:io';

import 'package:hibiki/src/sync/sync_file_ref.dart' show SyncFileRef;
import 'package:hibiki_core/hibiki_core.dart' show mimeTypeForFilePath;

/// The single sync root folder name used by every backend (cloud + LAN).
///
/// Historically `ttu-reader-data` (the app began life as a ttu-ebook-reader
/// fork). Renamed to `hibiki-data`; there are no historical cloud users, so no
/// migration is performed — first sync on the new name simply recreates the
/// root. One library must sync identically across all backends, so every
/// backend MUST derive its root from this constant — never hardcode the literal.
const String kSyncRootFolderName = 'fushi-data';

/// 改名前的云端根文件夹名（Fushi 改名迁移用）：各 backend 首次连接时若新根不存在
/// 而旧根存在，把旧根**远端改名**成新根（数据原地不动，只换目录名）。
const String kLegacySyncRootFolderName = 'hibiki-data';

/// 该 folderId 是否以**路径段**形式嵌入了旧同步根名（`hibiki-data`）。
///
/// 路径式后端（Dropbox / WebDAV / FTP / SFTP / 互联）持久化的 folderId 是裸路径，
/// 旧版本落盘的缓存会把 `hibiki-data` 钉死在路径里；恢复这种陈旧缓存会让
/// findOrCreateRootFolder 的 Fushi 改名迁移永远没机会跑（根缓存命中直接短路）。
/// [SyncFolderCache.restoreCache] 用本判据把它们过滤掉，强制走一次按名查/迁移。
///
/// 按段匹配（段边界 = 串首/尾或 `/`），不会误杀恰好含子串的书名
/// （如 `hibiki-database`）；Google Drive 的不透明 ID 无斜杠也不可能整串等于
/// 旧根名，天然不受影响。
bool syncFolderIdEmbedsLegacyRoot(String folderId) {
  final RegExp segment =
      RegExp('(^|/)${RegExp.escape(kLegacySyncRootFolderName)}(/|\$)');
  return segment.hasMatch(folderId);
}

/// Non-reentrant async mutex. Calling [withLock] from within a [withLock] callback will deadlock.
class AsyncMutex {
  Completer<void>? _completer;

  Future<T> withLock<T>(Future<T> Function() fn) async {
    while (_completer != null) {
      await _completer!.future;
    }
    _completer = Completer<void>();
    try {
      return await fn();
    } finally {
      final c = _completer!;
      _completer = null;
      c.complete();
    }
  }
}

SyncFileRef? findSyncFileByPrefix(List<SyncFileRef> files, String prefix) {
  for (final f in files) {
    if (f.name.startsWith(prefix)) return f;
  }
  return null;
}

/// 按文件扩展名猜测同步上传的 Content-Type（各云端后端共用的薄 shim）。
///
/// 命名统一轮 G8：MIME 推断收敛到 hibiki_core 单一映射表 [mimeTypeForFilePath]
/// （旧本地副本只认 epub/m4b/m4a/mp3/ogg/flac，其余上传一律 octet-stream）。
String guessSyncContentType(String fileName) => mimeTypeForFilePath(fileName);

/// 六个同步后端（WebDAV / OneDrive / Dropbox / FTP / SFTP / Google Drive）共享的
/// 「书名→folderId」缓存样板：一个根 folderId + 一张书名→folderId 映射，以及围绕
/// 它们的 clearCache / restoreCache / cachedRootFolderId / cachedFolderIds /
/// cacheBookFolderIds / evictFolderId 六个方法。抽成 mixin 消除六份逐字节相同的副本。
///
/// 路径式后端（WebDAV、hibiki 互联）把 folderId 当作裸路径前缀用（`folderId +
/// fileName` 不插分隔符），要求 folderId 必须以 `/` 结尾，否则文件会溢出到同步根
/// （BUG-845）。这类后端覆写 [normalizeFolderId] 在每个入缓存点归一化尾斜杠；其余
/// 后端沿用默认恒等实现，行为逐字节不变。
mixin SyncFolderCache {
  /// 同步根文件夹的 folderId（各后端语义不同：Drive 是不可变 ID，路径式后端是带
  /// 尾斜杠的路径前缀）。
  String? rootFolderIdCache;

  /// 书名（sanitized title）→ folderId 缓存。
  final Map<String, String> folderIdCache = <String, String>{};

  /// 在把 folderId 存入/比对缓存前归一化。默认恒等；路径式后端覆写为
  /// [ensureFolderIdTrailingSlash] 以维持「缓存的 folderId 必以 `/` 结尾」不变量
  /// （BUG-845）。
  String normalizeFolderId(String id) => id;

  void clearCache() {
    rootFolderIdCache = null;
    folderIdCache.clear();
  }

  /// 恢复持久化缓存。嵌着旧根名（`hibiki-data` 路径段）的条目一律丢弃
  /// （[syncFolderIdEmbedsLegacyRoot]）：那是改名迁移前落盘的陈旧路径，恢复它会让
  /// 根缓存命中短路掉 findOrCreateRootFolder 里的迁移逻辑，旧数据永远搬不过来。
  /// 丢弃只是缓存未命中——下一轮按名查/建会把新 folderId 重新学回来。
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    rootFolderIdCache =
        (rootFolderId == null || syncFolderIdEmbedsLegacyRoot(rootFolderId))
            ? null
            : normalizeFolderId(rootFolderId);
    if (titleToFolderId != null) {
      titleToFolderId.forEach((String title, String id) {
        if (syncFolderIdEmbedsLegacyRoot(id)) return;
        folderIdCache[title] = normalizeFolderId(id);
      });
    }
  }

  String? get cachedRootFolderId => rootFolderIdCache;

  Map<String, String> get cachedFolderIds => Map.unmodifiable(folderIdCache);

  void cacheBookFolderIds(List<SyncFileRef> folders) {
    for (final SyncFileRef f in folders) {
      folderIdCache[f.name] = normalizeFolderId(f.id);
    }
  }

  /// 删除某本书的远端文件夹（[folderId] = `ensureBookFolder` 返回的定位符）后，把
  /// 书名→folderId 缓存里所有指向 [folderId] 的条目逐出（按值反查），消除删书后
  /// 陈旧态（BUG-202）。缓存值已在入缓存点统一归一化，入参也先 [normalizeFolderId]
  /// 再比，避免尾斜杠差异漏逐出（BUG-845）。
  void evictFolderId(String folderId) {
    final String normalized = normalizeFolderId(folderId);
    folderIdCache.removeWhere((_, String id) => id == normalized);
  }
}

/// 把远端下载流 [source] 写入本地文件 [destination] 的共享半写清理骨架——五个
/// 云端/远端后端（Google Drive / OneDrive / Dropbox / WebDAV / SFTP）的
/// downloadContentFile 曾各持一份逐字节相同的实现。
///
/// 语义（保持逐字节等价）：逐块写入并按 [totalBytes] 上报进度（仅当已知且 > 0），
/// 全部写完才把 `success` 置真；任何异常都在 finally 里先关闭 sink，再删除半写文件
/// 并把异常继续上抛——绝不留下截断文件冒充完整下载。删除半写文件时的失败经
/// [onCleanupError] 回调上报（默认静默吞掉，与原 OneDrive/Dropbox/SFTP 行为一致；
/// WebDAV/Drive 传入回调打 debugPrint）。
Future<void> writeSyncStreamToFile({
  required Stream<List<int>> source,
  required File destination,
  int? totalBytes,
  void Function(double progress)? onProgress,
  void Function(Object error)? onCleanupError,
}) async {
  final IOSink sink = destination.openWrite();
  int bytesReceived = 0;
  bool success = false;
  try {
    await for (final List<int> chunk in source) {
      sink.add(chunk);
      bytesReceived += chunk.length;
      if (totalBytes != null && totalBytes > 0) {
        onProgress?.call(bytesReceived / totalBytes);
      }
    }
    success = true;
  } finally {
    await sink.close();
    if (!success) {
      try {
        destination.deleteSync();
      } catch (e) {
        onCleanupError?.call(e);
      }
    }
  }
}
