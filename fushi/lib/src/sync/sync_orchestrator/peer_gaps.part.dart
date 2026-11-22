part of '../sync_orchestrator.dart';

/// 互联同步维度在 host 上走不通时，统一判定「对端版本过旧」还是「对端不支持」并记
/// 进报告（拍板 other-sync-peer-version-errors）。
extension _SyncOrchestratorPeerGaps on SyncOrchestrator {
  /// 本轮（[report]）host 的 `/api/capabilities` 解码结果（老 host = null）。
  ///
  /// 每轮每个 backend 至多发一次请求：第一次调用发起读取并挂到 [report] 上，之后的
  /// 调用（别的维度、PDF 推送、本地音频身份）复用同一个 Future——成功复用结果，失败
  /// 复用同一个异常，不重发。只在真有调用方需要时才读，正常轮次零额外请求。
  Future<Object?> _roundHostCapabilities(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) {
    final ({InterconnectSyncBackend backend, Future<Object?> read})? held =
        report._hostCapabilities;
    if (held != null && identical(held.backend, backend)) return held.read;
    final Future<Object?> read = backend.readHostCapabilities();
    report._hostCapabilities = (backend: backend, read: read);
    return read;
  }

  /// [dimension] 这一维度在 host 上走不通（端点 404 / 删除端点回「不支持」）时调用。
  ///
  /// 每轮每维度只判一次（[SyncRunReport._peerGapsJudged]）：删除推送逐条墓碑都可能走
  /// 不通，判定结果与「能力表读不到」的错误行都只记一条。有能力位的维度看本轮的能力表
  /// （[_roundHostCapabilities]，整轮至多一次请求）：
  /// - 键缺失（或 host 连能力端点都没有）→ 对端版本过旧，记一条提示升级；
  /// - 键在但为 false → host 版本认识这项能力、只是不提供：
  ///   [SyncPeerGapDimension.reportWhenDeclaredOff] 的维度记「对端不支持」，其余不记；
  /// - 键为 true 却走不通 → 不是版本问题，不记（调用方自己的错误路径照常）。
  ///
  /// 没有能力位的维度（[SyncPeerGapDimension.capabilityKey] 为 null）端点 404 即版本
  /// 过旧。能力表读失败（网络 / 鉴权）如实记进 [report.errors]（本维度一条），不猜。
  Future<void> _notePeerGapLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
    SyncPeerGapDimension dimension,
  ) async {
    if (report.hasPeerGap(dimension)) return;
    if (!report._peerGapsJudged.add(dimension)) return;
    final String? key = dimension.capabilityKey;
    if (key == null) {
      report.notePeerGap(dimension, outdated: true);
      return;
    }
    final LiveLibraryCapabilityState state;
    try {
      state = liveLibraryCapabilityState(
        await _roundHostCapabilities(report, backend),
        key,
      );
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
    report._peerGapsJudged.add(dimension);
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
