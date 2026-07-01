import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/sync/book_exit_sync_scope.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_progress.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

final _bookKeyPattern = RegExp(r'hoshi://book/(.+)');

int _activeSyncs = 0;
final ValueNotifier<bool> syncInProgress = ValueNotifier<bool>(false);

/// App-wide latest sync progress tick, fed by EVERY full-sweep run (manual
/// "立即同步" AND the app-open/background auto-sweep). The settings "立即同步" row
/// reflects this so its inline progress bar shows whenever a sync is in flight —
/// not only for the run that row triggered (BUG-101). null between runs (and for
/// the single-book auto-sync path, which has no phase structure → indeterminate).
final ValueNotifier<SyncProgress?> syncProgress =
    ValueNotifier<SyncProgress?>(null);
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

/// Run [body] under the same app-wide mutex that serializes every auto/manual
/// sync run, so operations that touch the shared singleton backend from OUTSIDE
/// the sync pipeline — chiefly the local-vs-remote compare / conflict dialog's
/// network fetch and apply — can never run concurrently with an in-flight sync.
///
/// Without this, opening compare (or the conflict prompter auto-popping it
/// mid-sync) re-listed the remote and rewrote the singleton's folder-id cache
/// while a sync was mutating the same state, which interrupted the sync and made
/// the compare load slowly or even time out on the contended connection
/// (BUG-083). Joining the lock makes the later of the two simply wait.
///
/// Non-reentrant (see [AsyncMutex]): [body] must NOT call any sync entry point
/// (or this helper again) that would re-acquire the lock.
Future<T> runExclusiveWithSync<T>(Future<T> Function() body) =>
    _autoSyncMutex.withLock(body);

/// Fired after an auto-sync run produced a [SyncRunReport], carrying the
/// already-resolved+authenticated [SyncBackend] so the caller can drive a
/// conflict-resolution dialog without re-resolving/re-authing. Only invoked when
/// the run actually reached a report (auth ok, sync ran); skipped/aborted runs
/// never call it.
typedef SyncReportCallback = void Function(
  SyncRunReport report,
  SyncBackend backend,
);

/// Fired after a full sync run mutates the local library. The sync layer stays
/// UI-agnostic; AppModel uses this hook to refresh caches and visible shelves.
typedef SyncPostRunCallback = Future<void> Function(SyncRunReport report);

@visibleForTesting
void logSyncReportErrors(SyncRunReport report) {
  if (report.errors.isEmpty) return;
  ErrorLogService.instance.log(
    'SyncRunReport.errors',
    report.errors.join('\n'),
  );
}

void triggerAutoSyncAfterClose({
  required HibikiDatabase db,
  required String mediaIdentifier,
  required ScaffoldMessengerState messenger,
  SyncReportCallback? onReport,
}) {
  // TODO-132 诉求B：退出书同步是 fire-and-forget（不 await，不阻塞 onWillPop /
  // 退出 UI）。但把这个游离 Future 登记进 app-scope [BookExitSyncScope]，使页面
  // 销毁后它照样跑完，且进程退出路径能有界等它落定——避免「退出书后立刻杀应用」
  // 时关书 export 被打成半截（与 132A/BUG-201 的 baseline 原子化互补）。
  // messenger 仍传入（保留签名 + 留给冲突对话框的祖先上下文经 onReport 走
  // navigatorKey，不依赖它），但**不再**用它弹打断式「同步成功」SnackBar。
  BookExitSyncScope.instance.register(
    _runAutoSync(
      db: db,
      mediaIdentifier: mediaIdentifier,
      messenger: messenger,
      onReport: onReport,
    ),
  );
}

void triggerAutoSyncOnBackground({
  required HibikiDatabase db,
  required String mediaIdentifier,
}) {
  // Background (app→paused) intentionally has NO onReport: the user can't see a
  // dialog, so conflicts stay silent until a later visible sync surfaces them.
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
  required List<LocalAudioDbEntry> localAudioEntries,
  required Future<void> Function(LocalAudioPackageContents)
      onLocalAudioImported,
  SyncReportCallback? onReport,
  SyncPostRunCallback? onPostRun,
}) {
  _runAutoSyncAll(
    db: db,
    dictionaryResourceRoot: dictionaryResourceRoot,
    audioDatabaseRoot: audioDatabaseRoot,
    tempDir: tempDir,
    localAudioEntries: localAudioEntries,
    onLocalAudioImported: onLocalAudioImported,
    onReport: onReport,
    onPostRun: onPostRun,
  );
}

const _syncCooldownMs = 5 * 60 * 1000;

Future<void> _runAutoSyncAll({
  required HibikiDatabase db,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
  required List<LocalAudioDbEntry> localAudioEntries,
  required Future<void> Function(LocalAudioPackageContents)
      onLocalAudioImported,
  SyncReportCallback? onReport,
  SyncPostRunCallback? onPostRun,
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
        deviceId: await repo.getOrCreateDeviceId(),
        syncStats: await repo.isSyncStatsEnabled(),
        syncAudioBookPosition: await repo.isSyncAudioBookEnabled(),
        syncContent: await repo.isSyncContentEnabled(),
        syncAudioBookFiles: await repo.isSyncAudioBookFilesEnabled(),
        syncDictionary: await repo.isSyncDictionaryEnabled(),
        syncLocalAudio: await repo.isSyncLocalAudioEnabled(),
        localAudioEntries: localAudioEntries,
        onLocalAudioImported: onLocalAudioImported,
        // Publish progress globally so a settings "立即同步" row visible during
        // the app-open sweep shows the live bar instead of a bare toast.
        onProgress: (SyncProgress p) => syncProgress.value = p,
      );
      final SyncRunReport report = await orchestrator.run();
      logSyncReportErrors(report);
      await onPostRun?.call(report);
      onReport?.call(report, backend);
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
    if (_activeSyncs == 0) syncProgress.value = null;
  }
}

/// 手动「立即同步」的结果。
enum ManualSyncOutcome { completed, notConfigured, busy }

class ManualSyncResult {
  const ManualSyncResult(this.outcome, [this.report]);
  final ManualSyncOutcome outcome;
  final SyncRunReport? report;
}

/// 用户手点"立即同步"：跑完整双向全量同步（同 [triggerAutoSyncOnAppOpen]），
/// 但绕过自动同步开关与 5 分钟冷却（手动是显式意图）。仍尊重各资产 gate 与后端
/// 认证；与后台同步共用 [_autoSyncMutex]，避免并发改 singleton backend 状态。
Future<ManualSyncResult> runManualFullSync({
  required HibikiDatabase db,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
  required List<LocalAudioDbEntry> localAudioEntries,
  required Future<void> Function(LocalAudioPackageContents)
      onLocalAudioImported,
  SyncPostRunCallback? onPostRun,
  SyncProgressCallback? onProgress,
}) async {
  if (!_syncingIds.add('__all__')) {
    return const ManualSyncResult(ManualSyncOutcome.busy);
  }
  _activeSyncs++;
  syncInProgress.value = true;
  try {
    return await _autoSyncMutex.withLock(() async {
      final repo = SyncRepository(db);
      final backend = resolveSyncBackend(await repo.getBackendType());
      await backend.restoreAuth(repo);
      if (!await backend.isAuthenticated) {
        return const ManualSyncResult(ManualSyncOutcome.notConfigured);
      }
      final orchestrator = SyncOrchestrator(
        db: db,
        backend: backend,
        dictionaryResourceRoot: dictionaryResourceRoot,
        audioDatabaseRoot: audioDatabaseRoot,
        tempDir: tempDir,
        deviceId: await repo.getOrCreateDeviceId(),
        syncStats: await repo.isSyncStatsEnabled(),
        syncAudioBookPosition: await repo.isSyncAudioBookEnabled(),
        syncContent: await repo.isSyncContentEnabled(),
        syncAudioBookFiles: await repo.isSyncAudioBookFilesEnabled(),
        syncDictionary: await repo.isSyncDictionaryEnabled(),
        syncLocalAudio: await repo.isSyncLocalAudioEnabled(),
        localAudioEntries: localAudioEntries,
        onLocalAudioImported: onLocalAudioImported,
        // Publish to the app-wide notifier in addition to the caller's callback,
        // so any other visible "立即同步" surface reflects the same live bar.
        onProgress: (SyncProgress p) {
          syncProgress.value = p;
          onProgress?.call(p);
        },
      );
      final SyncRunReport report = await orchestrator.run();
      logSyncReportErrors(report);
      await onPostRun?.call(report);
      return ManualSyncResult(ManualSyncOutcome.completed, report);
    });
  } finally {
    _syncingIds.remove('__all__');
    _activeSyncs--;
    syncInProgress.value = _activeSyncs > 0;
    if (_activeSyncs == 0) syncProgress.value = null;
  }
}

Future<void> _runAutoSync({
  required HibikiDatabase db,
  required String mediaIdentifier,
  required ScaffoldMessengerState? messenger,
  SyncReportCallback? onReport,
}) async {
  final String? bookKey = ReaderHibikiSource.parseBookKey(mediaIdentifier);
  if (bookKey == null || !_bookKeyPattern.hasMatch(mediaIdentifier)) return;
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

      final book = await db.getEpubBook(bookKey);
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

      // TODO-132 诉求B：退出书同步静默——不再弹 imported/exported「同步成功」
      // SnackBar（打断用户、让用户误以为「必须等同步成功条才能离开」=卡手）。
      // 同步是 fire-and-forget 后台动作，成功无需打断式提示；真正需要用户介入的
      // **冲突**仍经下方 onReport → presentAutoConflicts 弹对话框（不是 SnackBar）。
      // messenger 参数保留（签名兼容，背景/app-open 路径本就传 null）。

      // Surface a genuine fork to the caller as a one-conflict report so the
      // book-exit flow can prompt resolution. The single-book path runs
      // SyncManager.syncBook (not the orchestrator), so build the report here
      // from the conflict fields SyncManager fills on SyncResult.conflict.
      if (onReport != null) {
        final SyncRunReport report = SyncRunReport();
        if (result.direction == SyncResult.conflict) {
          report.conflicts.add(SyncConflict(
            assetKey: result.conflictAssetKey!,
            dimension: result.conflictDimension!,
            title: result.title,
            localVersion: result.conflictLocalVersion,
            remoteVersion: result.conflictRemoteVersion,
          ));
        }
        onReport(report, backend);
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
