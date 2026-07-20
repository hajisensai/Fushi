import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:drift/drift.dart' show TableUpdateQuery;
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

/// option B 双通道：把每轮完整同步要跑的通道后端列出来。云备份通道恒尝试（用户
/// 选定的 [SyncRepository.getBackendType]），互联通道仅当 [SyncRepository
/// .isInterconnectEnabled] 时追加——互联与云备份不再互斥（backendType 曾把互联
/// 当成互斥单选项，现已解耦成独立开关）。两条通道各用自己的后端实例、各自认证成功
/// 才真正跑（未配置的通道在 [_runSyncChannel] 里 no-op）。
///
/// 去重：互联后端 [HibikiClientSyncBackend] 是单例；若云通道解析出的恰是同一单例
/// （历史遗留 backendType=='hibikiServer'，迁移后不再出现，仅防御测试直接构造），
/// 只保留一条，避免同一通道跑两遍。
Future<List<SyncBackend>> _enabledSyncChannelBackends(
  SyncRepository repo,
) async {
  final SyncBackend cloud = resolveSyncBackend(await repo.getBackendType());
  final List<SyncBackend> backends = <SyncBackend>[cloud];
  if (await repo.isInterconnectEnabled()) {
    final SyncBackend interconnect =
        resolveSyncBackend(SyncBackendType.hibikiServer);
    if (!identical(interconnect, cloud)) backends.add(interconnect);
  }
  return backends;
}

/// 为单个 [backend] 通道构建并运行一轮完整同步编排。认证失败（未配置该通道）返回
/// null，调用方视为该通道 no-op 跳过。云备份通道与互联通道各调一次（见
/// [_enabledSyncChannelBackends]），互不排斥（option B 双通道）。
Future<SyncRunReport?> _runSyncChannel({
  required HibikiDatabase db,
  required SyncRepository repo,
  required SyncBackend backend,
  required Directory dictionaryResourceRoot,
  required Directory audioDatabaseRoot,
  required Directory tempDir,
  required List<LocalAudioDbEntry> localAudioEntries,
  required Future<void> Function(LocalAudioPackageContents)
      onLocalAudioImported,
  required void Function(SyncProgress) onProgress,
}) async {
  await backend.restoreAuth(repo);
  if (!await backend.isAuthenticated) return null;
  final SyncOrchestrator orchestrator = SyncOrchestrator(
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
    syncVideoFiles: await repo.isSyncVideoFilesEnabled(),
    syncDictionary: await repo.isSyncDictionaryEnabled(),
    syncLocalAudio: await repo.isSyncLocalAudioEnabled(),
    localAudioEntries: localAudioEntries,
    onLocalAudioImported: onLocalAudioImported,
    onProgress: onProgress,
  );
  return orchestrator.run();
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

      // option B 双通道：依次跑云备份通道 + 互联通道（若启用），互不排斥。每条通道
      // 各自认证成功才实际跑；未配置的通道 no-op（_runSyncChannel 返回 null）。
      for (final SyncBackend backend
          in await _enabledSyncChannelBackends(repo)) {
        final SyncRunReport? report = await _runSyncChannel(
          db: db,
          repo: repo,
          backend: backend,
          dictionaryResourceRoot: dictionaryResourceRoot,
          audioDatabaseRoot: audioDatabaseRoot,
          tempDir: tempDir,
          localAudioEntries: localAudioEntries,
          onLocalAudioImported: onLocalAudioImported,
          // Publish progress globally so a settings "立即同步" row visible during
          // the app-open sweep shows the live bar instead of a bare toast.
          onProgress: (SyncProgress p) => syncProgress.value = p,
        );
        if (report == null) continue;
        logSyncReportErrors(report);
        await onPostRun?.call(report);
        onReport?.call(report, backend);
      }
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

/// 单条同步通道（云备份 or 互联）的报告 + 它自己的后端实例。手动同步冲突对话框按
/// 通道逐条呈现，用**各自的** backend 去 apply——否则合并报告的冲突可能来自互联
/// 通道却被云后端错误地 apply（option B 双通道）。
class ManualSyncChannelReport {
  const ManualSyncChannelReport(this.backend, this.report);
  final SyncBackend backend;
  final SyncRunReport report;
}

class ManualSyncResult {
  const ManualSyncResult(
    this.outcome, [
    this.report,
    this.channelReports = const <ManualSyncChannelReport>[],
  ]);
  final ManualSyncOutcome outcome;

  /// 合并所有通道后的汇总报告（用于「立即同步」结果 SnackBar 的计数摘要）。
  final SyncRunReport? report;

  /// 逐通道报告（用于把每条通道的冲突用其自身后端呈现/解决）。
  final List<ManualSyncChannelReport> channelReports;
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
      // option B 双通道：云备份通道 + 互联通道（若启用），互不排斥。合并两条通道的
      // 报告成单一汇总返回；任一通道认证成功即算 completed，两条都未配置才是
      // notConfigured。
      final SyncRunReport merged = SyncRunReport();
      final List<ManualSyncChannelReport> channelReports =
          <ManualSyncChannelReport>[];
      for (final SyncBackend backend
          in await _enabledSyncChannelBackends(repo)) {
        final SyncRunReport? report = await _runSyncChannel(
          db: db,
          repo: repo,
          backend: backend,
          dictionaryResourceRoot: dictionaryResourceRoot,
          audioDatabaseRoot: audioDatabaseRoot,
          tempDir: tempDir,
          localAudioEntries: localAudioEntries,
          onLocalAudioImported: onLocalAudioImported,
          // Publish to the app-wide notifier in addition to the caller's
          // callback, so any other visible "立即同步" surface reflects the bar.
          onProgress: (SyncProgress p) {
            syncProgress.value = p;
            onProgress?.call(p);
          },
        );
        if (report == null) continue;
        logSyncReportErrors(report);
        await onPostRun?.call(report);
        merged.mergeFrom(report);
        channelReports.add(ManualSyncChannelReport(backend, report));
      }
      if (channelReports.isEmpty) {
        return const ManualSyncResult(ManualSyncOutcome.notConfigured);
      }
      return ManualSyncResult(
        ManualSyncOutcome.completed,
        merged,
        channelReports,
      );
    });
  } finally {
    _syncingIds.remove('__all__');
    _activeSyncs--;
    syncInProgress.value = _activeSyncs > 0;
    if (_activeSyncs == 0) syncProgress.value = null;
  }
}

Timer? _collectionsSyncDebounce;
StreamSubscription<void>? _collectionsWatchSub;
Duration _collectionsSyncDebounceDuration = const Duration(seconds: 8);

/// 装载「合集变更 → 防抖轻量同步」观察者（AppModel 初始化时调用一次；幂等，
/// 重复调用先撤旧订阅）。
///
/// 根因修复：合集维度只搭载在低频的全量 sweep 上（app 冷启动 + 5 分钟冷却，或
/// 手动「立即同步」），而用户高频触发的关书/切后台同步走单本路径、从不同步合集
/// ——增删合集/成员后长时间不推送，即「合集经常没同步」。现在任何合集表写入
/// （合集行/成员/墓碑，无论来自哪个页面）都会在 [debounce] 后跑一轮只含合集
/// 维度的轻量同步（[SyncOrchestrator.runCollectionsOnly]，云 + 互联双通道）。
///
/// 不成环：同步自身 apply 的写入会再触发一轮，但清单 canonicalJson 相等即不
/// 回写、目标态调和无 diff 即不写库——第二轮收敛为纯读 no-op 后不再有表事件。
void installCollectionsSyncWatcher({
  required HibikiDatabase db,
  Duration debounce = const Duration(seconds: 8),
}) {
  uninstallCollectionsSyncWatcher();
  _collectionsSyncDebounceDuration = debounce;
  _collectionsWatchSub = db
      .tableUpdates(TableUpdateQuery.onAllTables([
        db.mediaCollections,
        db.mediaCollectionItems,
        db.collectionMemberTombstones,
      ]))
      .listen((_) => _scheduleCollectionsSync(db));
}

/// 撤销 [installCollectionsSyncWatcher] 的订阅与未决防抖定时器（测试 teardown /
/// DB 关闭前用；无观察者时 no-op）。
void uninstallCollectionsSyncWatcher() {
  _collectionsWatchSub?.cancel();
  _collectionsWatchSub = null;
  _collectionsSyncDebounce?.cancel();
  _collectionsSyncDebounce = null;
}

/// 测试观察点：观察者累计排定的防抖次数（仅测试断言「合集写入确实触发调度」用）。
@visibleForTesting
int collectionsSyncScheduledForTest = 0;

void _scheduleCollectionsSync(HibikiDatabase db) {
  collectionsSyncScheduledForTest++;
  _collectionsSyncDebounce?.cancel();
  _collectionsSyncDebounce = Timer(_collectionsSyncDebounceDuration, () {
    _collectionsSyncDebounce = null;
    unawaited(_runCollectionsSync(db: db));
  });
}

/// 跑一轮只含合集维度的轻量同步（云备份 + 互联双通道，各自认证成功才跑）。
/// 全量 sweep 进行中则重排到下个防抖窗——sweep 本就带合集维度，且它 apply 的
/// 表写入还会再触发一次本观察者，最终收敛。
@visibleForTesting
Future<void> runCollectionsSyncNow({required HibikiDatabase db}) =>
    _runCollectionsSync(db: db);

Future<void> _runCollectionsSync({required HibikiDatabase db}) async {
  if (_syncingIds.contains('__all__')) {
    _scheduleCollectionsSync(db);
    return;
  }
  if (!_syncingIds.add('__collections__')) return;
  _activeSyncs++;
  syncInProgress.value = true;
  try {
    await _autoSyncMutex.withLock(() async {
      final repo = SyncRepository(db);
      if (!await repo.isAutoSyncEnabled()) return;
      for (final SyncBackend backend
          in await _enabledSyncChannelBackends(repo)) {
        await backend.restoreAuth(repo);
        if (!await backend.isAuthenticated) continue;
        final SyncOrchestrator orchestrator = SyncOrchestrator(
          db: db,
          backend: backend,
          // 合集维度不触碰词典/音频/临时目录；systemTemp 仅为满足构造器形参，
          // runCollectionsOnly 保证不落任何文件。
          dictionaryResourceRoot: Directory.systemTemp,
          audioDatabaseRoot: Directory.systemTemp,
          tempDir: Directory.systemTemp,
          deviceId: await repo.getOrCreateDeviceId(),
          syncStats: false,
          syncAudioBookPosition: false,
          syncContent: false,
          syncAudioBookFiles: false,
          syncVideoFiles: false,
          syncDictionary: false,
          syncLocalAudio: false,
          localAudioEntries: const <LocalAudioDbEntry>[],
          onLocalAudioImported: (LocalAudioPackageContents _) async {},
        );
        final SyncRunReport report = await orchestrator.runCollectionsOnly();
        logSyncReportErrors(report);
      }
    });
  } catch (e) {
    developer.log(
      'Collections auto-sync failed',
      error: e,
      name: 'SyncAutoTrigger',
    );
  } finally {
    _syncingIds.remove('__collections__');
    _activeSyncs--;
    syncInProgress.value = _activeSyncs > 0;
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

      final book = await db.getEpubBook(bookKey);
      if (book == null) return;

      final syncStats = await repo.isSyncStatsEnabled();
      final syncAudioBook = await repo.isSyncAudioBookEnabled();
      final syncContent = await repo.isSyncContentEnabled();

      // option B 双通道：退出书时对每条启用的通道（云备份 + 互联）各跑一次 per-book
      // 同步，互不排斥。每条通道各自认证成功才跑；未配置的通道 continue 跳过。
      for (final SyncBackend backend
          in await _enabledSyncChannelBackends(repo)) {
        await backend.restoreAuth(repo);
        if (!await backend.isAuthenticated) continue;

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
