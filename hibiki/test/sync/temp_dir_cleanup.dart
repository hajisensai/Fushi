import 'dart:io';

import 'package:hibiki/src/sync/backup_service.dart';

/// Recursively deletes a temp dir used by a DB-heavy sync test, tolerating the
/// Windows transient FS-busy race. A `HibikiDatabase` opens its sqlite
/// connection via `NativeDatabase.createInBackground` (a background isolate);
/// on Windows the OS / Defender / search-indexer can keep a handle on the
/// just-written `hibiki.db` (or its `-wal`/`-shm` sidecars) open for a brief
/// window after `close()` returns, so a raw `Directory.delete(recursive: true)`
/// in `addTearDown` intermittently throws `ERROR_DIR_NOT_EMPTY(145)` /
/// `ERROR_SHARING_VIOLATION(32)` / `ERROR_ACCESS_DENIED(5)` and fails the test
/// non-deterministically when many sync suites run in parallel (TODO-1011).
///
/// Routes through the production-grade
/// [BackupService.deleteDirectoryWithRetry] (BUG-272) so the teardown matches
/// the bounded, backing-off cleanup the app itself uses, instead of failing on
/// a transient handle release. A genuine non-transient failure still surfaces.
Future<void> cleanupTempDir(Directory dir) =>
    BackupService.deleteDirectoryWithRetry(
      exists: dir.exists,
      delete: () => dir.delete(recursive: true),
      sleep: (int ms) => Future<void>.delayed(Duration(milliseconds: ms)),
      isWindows: Platform.isWindows,
    );
