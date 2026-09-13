part of '../sync_orchestrator.dart';

/// 聚合快照（统计 / 收藏）与互联 service-config 域的私有实现（B2 按域拆出）。
/// 公开入口留在 [SyncOrchestrator] 本体（库私有 extension 的成员对别的库不可见）；
/// 方法逐字搬自 SyncOrchestrator，共享库私有作用域（_emit / _tmpFile / 字段）。
extension _SyncOrchestratorAggregate on SyncOrchestrator {
  /// 云后端聚合同步：把本机统计 + 收藏经 [AggregateSyncService] 与其它设备的
  /// per-device 快照并集合并（只增不减 / 值不缩小 / 幂等 / 并集），写回本地并
  /// 上传本机最新快照。无 baseline / 无冲突弹窗（集合 + 单调语义无损）。首次同步
  /// （云上无 `__aggregate__` 快照）优雅退化为「只上传本机快照」，不崩。
  ///
  /// 整段包在 try/catch 里，逐轮错误进 [report.errors] 不中断整体 sweep（与其它
  /// 维度同纪律）。删除不跨端传播；无 schema 变更。
  Future<void> _syncAggregate(SyncRunReport report) async {
    try {
      await AggregateSyncService(_db, scope: _scope).sync(
        store: _backend,
        deviceId: deviceId,
      );
    } catch (e) {
      report.noteError('aggregate sync', e);
    }
  }

  /// Pulls the host's explicitly allowlisted service configuration. The host is
  /// authoritative for keys it publishes; no client→host write exists.
  Future<void> _syncServiceConfigLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      // apikey 同步设定重设计：service-config（host 的外部服务 API key）此前是
      // 无 UI 无开关的隐形通道。开关默认 true（行为不变）；关掉 = 本设备不再向
      // host 请求 service-config（连请求都不发，不是拉回来再丢弃）。
      if (!await SyncRepository(_db).isInterconnectServiceConfigSyncEnabled()) {
        return;
      }
      final InterconnectServiceConfigSnapshot? snapshot =
          await backend.getRemoteServiceConfig();
      if (snapshot == null) return;
      report.serviceConfigsImported += await snapshot.applyTo(_db);
    } catch (e) {
      report.noteError('service config live sync', e);
    }
  }

  /// 互联聚合（统计 + 收藏）live 双向合并（TODO-1056 phase C）。
  ///
  /// 复用 [AggregateSyncService.syncOverClient] 的通道无关核心（materialize 本地 →
  /// GET host 快照 → [AggregateMergeService] 并集折叠 → 写回本地 DB（只 MAX / 并集
  /// upsert，幂等）→ PUT 合并后快照回 host）。IO 由本方法注入：GET 走
  /// [InterconnectSyncBackend.getRemoteAggregate]（老 host 无端点返回 404 → null →
  /// 只推不拉，优雅降级），PUT 走 [InterconnectSyncBackend.putRemoteAggregate]。
  ///
  /// 无 baseline / 无冲突弹窗（集合 + 单调语义无损）；删除不跨端传播；无 schema 变更。
  /// 整段 try/catch，逐轮错误进 [report.errors] 不中断整体 sweep（与其它维度同纪律）。
  Future<void> _syncAggregateLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      await AggregateSyncService(_db, scope: _scope).syncOverClient(
        fetchRemote: backend.getRemoteAggregate,
        pushMerged: backend.putRemoteAggregate,
        shareStats: syncStats,
        shareFavorites: syncFavorites,
      );
    } catch (e) {
      report.noteError('aggregate live sync', e);
    }
  }
}
