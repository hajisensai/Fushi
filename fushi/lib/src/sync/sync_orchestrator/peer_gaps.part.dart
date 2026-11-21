part of '../sync_orchestrator.dart';

/// 互联同步维度在 host 上走不通时，统一判定「对端版本过旧」还是「对端不支持」并记
/// 进报告（拍板 other-sync-peer-version-errors）。
extension _SyncOrchestratorPeerGaps on SyncOrchestrator {
  /// [dimension] 这一维度在 host 上走不通（端点 404 / 删除端点回「不支持」）时调用。
  ///
  /// 有能力位的维度再问一次 `/api/capabilities`（只在走不通时问，正常轮次零额外
  /// 请求；本轮该维度已记过也不问）：
  /// - 键缺失（或 host 连能力端点都没有）→ 对端版本过旧，记一条提示升级；
  /// - 键在但为 false → host 版本认识这项能力、只是不提供：
  ///   [SyncPeerGapDimension.reportWhenDeclaredOff] 的维度记「对端不支持」，其余不记；
  /// - 键为 true 却走不通 → 不是版本问题，不记（调用方自己的错误路径照常）。
  ///
  /// 没有能力位的维度（[SyncPeerGapDimension.capabilityKey] 为 null）端点 404 即版本
  /// 过旧。能力表读失败（网络 / 鉴权）如实记进 [report.errors]，不猜。
  Future<void> _notePeerGapLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
    SyncPeerGapDimension dimension,
  ) async {
    if (report.hasPeerGap(dimension)) return;
    final String? key = dimension.capabilityKey;
    if (key == null) {
      report.notePeerGap(dimension, outdated: true);
      return;
    }
    final LiveLibraryCapabilityState state;
    try {
      state = await backend.liveLibraryCapability(key);
    } catch (e) {
      report.noteError('${dimension.label}: peer capabilities unreadable', e);
      return;
    }
    _notePeerGapFromState(report, dimension, state);
  }

  /// 已知能力位状态 [state] 时直接按 [_notePeerGapLive] 的规则记（PDF 推送在推之前
  /// 就要问能力位，不必再问一次）。
  void _notePeerGapFromState(
    SyncRunReport report,
    SyncPeerGapDimension dimension,
    LiveLibraryCapabilityState state,
  ) {
    switch (state) {
      case LiveLibraryCapabilityState.supported:
        return;
      case LiveLibraryCapabilityState.undeclared:
        report.notePeerGap(dimension, outdated: true);
      case LiveLibraryCapabilityState.declaredOff:
        if (dimension.reportWhenDeclaredOff) {
          report.notePeerGap(dimension, outdated: false);
        }
    }
  }
}
