part of '../sync_orchestrator.dart';

/// 视频刮削元数据（host → 客户端，7c）互联 live 通道。
/// `docs/specs/2026-09-12-interconnect-scrape-metadata.md` §2/§3。
extension _SyncOrchestratorVideoMetadata on SyncOrchestrator {
  /// 拉 host 全部作品刮削元数据并落本地（[applyRemoteVideoMetadata]）。
  ///
  /// 放在合集同步**之后**：合集级作品按自然键解析本地合集行，行得先由合集清单
  /// 同步建出来。老 host 无端点（404 → null）静默跳过——它不像合集那样是用户明
  /// 确期待的双向数据，不往 errors 里塞噪音。单条 apply 失败记日志、不中断。
  Future<void> _syncVideoMetadataLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      final List<VideoMetadataWorkEntry>? entries =
          await backend.getRemoteVideoMetadata();
      if (entries == null || entries.isEmpty) return;
      report.videoMetadataUpdated += await applyRemoteVideoMetadata(
        _db,
        entries,
        onError: (Object e, StackTrace stack) {
          debugPrint('[sync] video metadata apply failed: $e');
          report.noteError('video metadata apply', e);
        },
      );
    } catch (e) {
      report.noteError('video metadata live sync', e);
    }
  }
}
