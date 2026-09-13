part of '../sync_orchestrator.dart';

/// 合集（collections manifest）互联 live 通道的私有实现（B2 按域拆出）。
/// 公开入口 [SyncOrchestrator.syncCollections] 留在本体；方法逐字搬自 SyncOrchestrator。
extension _SyncOrchestratorCollections on SyncOrchestrator {
  /// 合集双向同步（多端库联合视图 §2.3 任务5.3，互联 host API 通道）。
  ///
  /// 读-合并-写，与云后端 [syncCollections] 完全同构，仅通道不同（host API 而非
  /// WebDAV `__collections__` 文件箱）：GET host 合集清单
  /// （[InterconnectSyncBackend.getRemoteCollectionManifest]）→ [CollectionSyncEngine.merge]
  /// 与本地全量快照合并（成员并集 + 移出/删除墓碑按基线裁决 + 手动序整合集 LWW）→
  /// [applyCollectionLocalChanges] 落本地 DB（计入 [SyncRunReport.collectionsUpdated]）→
  /// 合并后清单与 host 字节不同才 POST 回写（host 端再经 mergeCollectionManifest 并入
  /// 自己 DB，同一引擎）。
  ///
  /// 老 host 无端点（GET 404 → null）时优雅跳过（不 POST，不崩）。基线（本端
  /// [SyncRepository.getCollectionsSyncBaselineMs]）在整轮成功后才推进；中途失败保持
  /// 旧基线，下轮同一批墓碑重当「新闻」裁决——应用端按目标态调和幂等重放安全。
  /// 整段 try/catch，错误进 [report.errors] 不中断整体 sweep（与其它维度同纪律）。
  Future<void> _syncCollectionsLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      // 竞态修复：读远端清单**之前**先预取本轮基线时刻，整轮成功后写这个预取值
      // （而非结束时的新 now），并作 publishedAt 发布时戳。
      final int nextBaseline = DateTime.now().millisecondsSinceEpoch;
      final CollectionManifest? remote =
          await backend.getRemoteCollectionManifest();
      if (remote == null) {
        // 老 host 无 /api/library/collections 端点（对端 app 版本过旧）。以前静默
        // return，用户只看见「合集没同步」却无任何线索（BUG-938 次因）。计入
        // report.errors：错误日志留痕 + 手动「立即同步」按错误计数提示；其余维度
        // 不受影响照常同步。
        report.errors.add(
            'collections live sync: host has no collections endpoint '
            '(older app version) — update the host app to sync collections');
        return;
      }

      final CollectionManifest local = await loadLocalCollectionManifest(_db);
      final SyncRepository repo = SyncRepository(_db);
      // 时钟回拨钳制：持久化基线晚于 now 时钳到 now。
      int baseline = await repo.getCollectionsSyncBaselineMs(_scope);
      if (baseline > nextBaseline) baseline = nextBaseline;
      final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
        local: local,
        remote: remote,
        lastSyncedAtMs: baseline,
        nowMs: nextBaseline,
      );

      report.collectionsUpdated +=
          await applyCollectionLocalChanges(_db, outcome.changes);

      // 回写门槛：字节有变才 POST（确定性排序保证内容相等 ⇒ 字节相等，避免每轮
      // 无谓写放大）。
      if (outcome.merged.canonicalJson() != remote.canonicalJson()) {
        await backend.putRemoteCollectionManifest(outcome.merged);
      }
      await repo.setCollectionsSyncBaselineMs(_scope, nextBaseline);
    } catch (e) {
      report.noteError('collections live sync', e);
    }
  }
}
