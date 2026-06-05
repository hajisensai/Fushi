import 'dart:async';

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
