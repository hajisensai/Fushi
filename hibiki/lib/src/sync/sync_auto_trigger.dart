import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:hibiki/src/sync/google_drive_sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

final _bookIdPattern = RegExp(r'hoshi://book/(\d+)');

int _activeSyncs = 0;
final ValueNotifier<bool> syncInProgress = ValueNotifier<bool>(false);
final Set<String> _syncingIds = {};

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

void triggerAutoSyncOnAppOpen({required HibikiDatabase db}) {
  _runAutoSyncAll(db: db);
}

const _syncCooldownMs = 5 * 60 * 1000;

Future<void> _runAutoSyncAll({required HibikiDatabase db}) async {
  if (!_syncingIds.add('__all__')) return;

  _activeSyncs++;
  syncInProgress.value = true;

  try {
    final repo = SyncRepository(db);
    if (!await repo.isAutoSyncEnabled()) return;

    final lastSync = await repo.getLastSyncMs();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lastSync != null && (now - lastSync) < _syncCooldownMs) return;

    final backend = resolveSyncBackend(await repo.getBackendType());
    await backend.restoreAuth(repo);
    if (!await backend.isAuthenticated) return;

    final syncStats = await repo.isSyncStatsEnabled();
    final syncAudioBook = await repo.isSyncAudioBookEnabled();
    final syncContent = await repo.isSyncContentEnabled();

    final manager = SyncManager(db: db, backend: backend);
    await manager.syncAllBooks(
      syncStats: syncStats,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: syncAudioBook,
      syncContent: syncContent,
    );
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
