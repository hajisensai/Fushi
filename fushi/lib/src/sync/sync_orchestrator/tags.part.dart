part of '../sync_orchestrator.dart';

/// 标签（tags manifest）互联 live 通道：书 / 漫画 / 字幕书 / 视频 / 合集 / 游戏
/// 六类宿主的标签跨设备保持一致（`tag_sync.dart`）。
extension _SyncOrchestratorTags on SyncOrchestrator {
  /// 标签双向同步：GET host 标签清单 → [applyTagManifest] 按 LWW 并入本地 →
  /// 本机清单未被 host 覆盖（[tagManifestCovers]）才 POST → host 同一内核并入。
  ///
  /// 按名 LWW 与应用顺序无关、重放幂等，不需要合集那样的因果基线；中途失败下轮
  /// 原样重来即可。老 host 无端点（GET 404 → null）计入 report.errors（同合集：
  /// 静默跳过会让用户只看见「标签没同步」却没有任何线索），其余维度照常。
  Future<void> _syncTagsLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      final TagManifest? remote = await backend.getRemoteTagManifest();
      if (remote == null) {
        report.errors.add('tags live sync: host has no tags endpoint '
            '(older app version) — update the host app to sync tags');
        return;
      }
      late final TagManifest local;
      // 与本机作为 host 处理对端 POST 的 mergeTagManifest 持同一把窄锁（只包本地
      // 读-改-写，网络在锁外）。
      await runExclusiveWithSyncStateApply(() async {
        report.tagsUpdated += await applyTagManifest(_db, remote);
        local = await loadLocalTagManifest(_db);
      });
      if (!tagManifestCovers(remote, local)) {
        await backend.putRemoteTagManifest(local);
      }
    } catch (e) {
      report.noteError('tags live sync', e);
    }
  }
}
