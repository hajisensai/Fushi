import 'dart:async';
import 'dart:io';

import 'package:hibiki/src/sync/ttu_models.dart' show DriveFile;

/// The single sync root folder name used by every backend (cloud + LAN).
///
/// Historically `ttu-reader-data` (the app began life as a ttu-ebook-reader
/// fork). Renamed to `hibiki-data`; there are no historical cloud users, so no
/// migration is performed — first sync on the new name simply recreates the
/// root. One library must sync identically across all backends, so every
/// backend MUST derive its root from this constant — never hardcode the literal.
const String kSyncRootFolderName = 'hibiki-data';

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

DriveFile? findSyncFileByPrefix(List<DriveFile> files, String prefix) {
  for (final f in files) {
    if (f.name.startsWith(prefix)) return f;
  }
  return null;
}

/// 按文件扩展名猜测同步上传的 Content-Type（各云端后端共用的唯一真源）。
String guessSyncContentType(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.epub')) return 'application/epub+zip';
  if (lower.endsWith('.m4b') || lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.ogg')) return 'audio/ogg';
  if (lower.endsWith('.flac')) return 'audio/flac';
  return 'application/octet-stream';
}

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

  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    rootFolderIdCache =
        rootFolderId == null ? null : normalizeFolderId(rootFolderId);
    if (titleToFolderId != null) {
      titleToFolderId.forEach((String title, String id) {
        folderIdCache[title] = normalizeFolderId(id);
      });
    }
  }

  String? get cachedRootFolderId => rootFolderIdCache;

  Map<String, String> get cachedFolderIds => Map.unmodifiable(folderIdCache);

  void cacheBookFolderIds(List<DriveFile> folders) {
    for (final DriveFile f in folders) {
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
