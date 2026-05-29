import 'dart:async';

import 'package:hibiki/src/sync/ttu_models.dart' show DriveFile;

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
