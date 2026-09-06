part of '../backup_service.dart';

// Windows 文件系统忙重试（B1 从 BackupService 拆出）：目录删除 / 改名的有界重试。

/// Whether a Windows OS error code is a transient filesystem-busy condition
/// that clears once an external handle is released. The recursive delete of
/// the export's temp dir runs right after [_stripCredentials] /
/// [_stripDictionaryState] closed their sqlite connections; on Windows the OS
/// (and Defender / search-indexer scanning the just-written `hibiki.db` copy)
/// can keep a handle open for a brief window after `close()` returns, so the
/// delete fails with ERROR_ACCESS_DENIED(5), ERROR_SHARING_VIOLATION(32) or
/// ERROR_DIR_NOT_EMPTY(145, a child file still locked). Same family as the
/// dictionary-import rename lock (BUG-050).
bool _isWindowsTransientFsBusy(int? code) =>
    code == 5 || code == 32 || code == 145;

/// Pure, dependency-injected core of [_deleteDirectoryIfPresent]: deletes a
/// directory tree, tolerating both a vanished tree ([PathNotFoundException]:
/// already cleaned up) and -- on Windows only -- a transient filesystem-busy
/// error (see [_isWindowsTransientFsBusy]) via a bounded, backing-off retry
/// that gives the lingering external handle time to release.
///
/// A non-Windows error, or a Windows error that is NOT transient FS-busy, is
/// rethrown immediately (never swallowed -- a real cleanup failure must
/// surface). If every attempt hits transient FS-busy the last exception is
/// rethrown rather than silently leaving the temp tree on disk. POSIX deletes
/// succeed on the first attempt and never enter the retry branch.
@visibleForTesting
Future<void> deleteDirectoryWithRetry({
  required Future<bool> Function() exists,
  required Future<void> Function() delete,
  required Future<void> Function(int delayMs) sleep,
  required bool isWindows,
  int maxAttempts = 10,
}) async {
  for (int attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      if (await exists()) {
        await delete();
      }
      return;
    } on PathNotFoundException {
      // Cleanup is already satisfied if the temp tree vanished between the
      // existence check and deletion.
      return;
    } on FileSystemException catch (e) {
      final int? code = e.osError?.errorCode;
      final bool transient = isWindows && _isWindowsTransientFsBusy(code);
      if (!transient || attempt == maxAttempts) rethrow;
      await sleep(50 * attempt); // backoff: 50ms,100ms,... let handle drop
    }
  }
}

/// Retries a directory [rename] that hits a transient Windows filesystem-busy
/// error (access denied / sharing violation — see [_isWindowsTransientFsBusy])
/// with a bounded backoff. The content-tree swap renames a freshly-EXTRACTED
/// `.import-tmp` into place; on Windows an antivirus / indexer scanning the
/// just-written tree briefly holds handles, so the immediate rename can fail
/// with `errno 5` (the "备份导入失败: Rename failed … 拒绝访问" the user hit).
/// A non-Windows error, or a non-transient Windows error, is rethrown at once.
/// The longer cap than the delete retry (backoff to ~1s/attempt) gives a big
/// multi-GB tree's scan time to finish.
@visibleForTesting
Future<void> renameDirectoryWithRetry({
  required Future<void> Function() rename,
  required Future<void> Function(int delayMs) sleep,
  required bool isWindows,
  int maxAttempts = 20,
}) async {
  for (int attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      await rename();
      return;
    } on FileSystemException catch (e) {
      final int? code = e.osError?.errorCode;
      final bool transient = isWindows && _isWindowsTransientFsBusy(code);
      if (!transient || attempt == maxAttempts) rethrow;
      // backoff: 100ms,200ms,... capped at 1s → ~15s total over 20 attempts.
      await sleep((100 * attempt).clamp(100, 1000));
    }
  }
}
