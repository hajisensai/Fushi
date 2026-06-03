import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

final _bookIdPattern = RegExp(r'hoshi://book/(\d+)');

int _activeSyncs = 0;
final ValueNotifier<bool> syncInProgress = ValueNotifier<bool>(false);
final Set<String> _syncingIds = {};

// HBK-AUDIT-049: cloud backends (GoogleDrive/Dropbox/OneDrive/WebDAV/SMB) are
// process-wide singletons holding mutable shared state (_accessToken,
// _cachedApi, _rootFolderId, _titleToFolderId) with no per-operation lock.
// _syncingIds only dedups identical keys, so two DIFFERENT books — or a
// per-book sync overlapping the '__all__' sweep — used to run concurrently and
// interleave on that shared state. Serialize every auto-sync operation through
// one app-wide mutex so a backend's token/api/cache is only ever touched by a
// single in-flight sync. Dedup (_syncingIds) still short-circuits redundant
// triggers before they queue on the mutex.
final AsyncMutex _autoSyncMutex = AsyncMutex();

void triggerAutoSyncAfterClose({
  required HibikiDatabase db,
  required String mediaIdentifier,
  required ScaffoldMessengerState messenger,
}) {
  _runAutoSync(
    db: db,
    mediaIdentifier: mediaIdentifier,
    messenger: messenger,
  );
}

void triggerAutoSyncOnBackground({
  required HibikiDatabase db,
  required String mediaIdentifier,
}) {
  _runAutoSync(db: db, mediaIdentifier: mediaIdentifier, messenger: null);
}

/// Full bidirectional sweep on app open: imports remote-only books, syncs all
/// book progress/content, and union-syncs dictionaries + audiobook packages.
/// The asset directories come from [AppModel] (the sync layer must not depend
/// on it) — [audioDatabaseRoot] is where pulled audiobook packages land.
void triggerAutoSyncOnAppOpen({
  required HibikiDatabase db,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
}) {
  _runAutoSyncAll(
    db: db,
    dictionaryResourceRoot: dictionaryResourceRoot,
    audioDatabaseRoot: audioDatabaseRoot,
    tempDir: tempDir,
  );
}

const _syncCooldownMs = 5 * 60 * 1000;

Future<void> _runAutoSyncAll({
  required HibikiDatabase db,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
}) async {
  if (!_syncingIds.add('__all__')) return;

  _activeSyncs++;
  syncInProgress.value = true;

  try {
    // HBK-AUDIT-049: serialize the actual sync work so it never overlaps a
    // per-book sync mutating the same singleton backend state.
    await _autoSyncMutex.withLock(() async {
      final repo = SyncRepository(db);
      if (!await repo.isAutoSyncEnabled()) return;

      final lastSync = await repo.getLastSyncMs();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (lastSync != null && (now - lastSync) < _syncCooldownMs) return;

      final backend = resolveSyncBackend(await repo.getBackendType());
      await backend.restoreAuth(repo);
      if (!await backend.isAuthenticated) return;

      final orchestrator = SyncOrchestrator(
        db: db,
        backend: backend,
        dictionaryResourceRoot: dictionaryResourceRoot,
        audioDatabaseRoot: audioDatabaseRoot,
        tempDir: tempDir,
        syncStats: await repo.isSyncStatsEnabled(),
        syncAudioBookPosition: await repo.isSyncAudioBookEnabled(),
        syncContent: await repo.isSyncContentEnabled(),
        syncAudioBookFiles: await repo.isSyncAudioBookFilesEnabled(),
        syncDictionary: await repo.isSyncDictionaryEnabled(),
      );
      await orchestrator.run();
    });
  } catch (e) {
    developer.log(
      'Auto-sync on app open failed',
      error: e,
      name: 'SyncAutoTrigger',
    );
  } finally {
    _syncingIds.remove('__all__');
    _activeSyncs--;
    syncInProgress.value = _activeSyncs > 0;
  }
}

Future<void> _runAutoSync({
  required HibikiDatabase db,
  required String mediaIdentifier,
  required ScaffoldMessengerState? messenger,
}) async {
  final match = _bookIdPattern.firstMatch(mediaIdentifier);
  if (match == null) return;
  if (_syncingIds.contains('__all__')) return;
  if (!_syncingIds.add(mediaIdentifier)) return;

  _activeSyncs++;
  syncInProgress.value = true;

  try {
    // HBK-AUDIT-049: serialize against any other in-flight auto-sync (other
    // books or the '__all__' sweep) so the shared singleton backend's
    // token/api/folder cache is never mutated concurrently.
    await _autoSyncMutex.withLock(() async {
      final repo = SyncRepository(db);
      if (!await repo.isAutoSyncEnabled()) return;

      final backend = resolveSyncBackend(await repo.getBackendType());
      await backend.restoreAuth(repo);
      if (!await backend.isAuthenticated) return;

      final bookId = int.parse(match.group(1)!);
      final book = await db.getEpubBook(bookId);
      if (book == null) return;

      final syncStats = await repo.isSyncStatsEnabled();
      final syncAudioBook = await repo.isSyncAudioBookEnabled();
      final syncContent = await repo.isSyncContentEnabled();

      final manager = SyncManager(db: db, backend: backend);
      final result = await manager.syncBook(
        book: book,
        syncStats: syncStats,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: syncAudioBook,
        syncContent: syncContent,
      );

      final String? message = switch (result.direction) {
        SyncResult.imported =>
          t.sync_auto_complete(direction: '↓', title: book.title),
        SyncResult.exported =>
          t.sync_auto_complete(direction: '↑', title: book.title),
        SyncResult.synced => null,
        SyncResult.skipped => null,
      };

      if (message != null && messenger != null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ));
      }
    });
  } catch (e) {
    developer.log(
      'Auto-sync failed for $mediaIdentifier',
      error: e,
      name: 'SyncAutoTrigger',
    );
  } finally {
    _syncingIds.remove(mediaIdentifier);
    _activeSyncs--;
    syncInProgress.value = _activeSyncs > 0;
  }
}
