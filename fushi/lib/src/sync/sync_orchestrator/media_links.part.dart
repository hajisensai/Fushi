part of '../sync_orchestrator.dart';

/// 作品图谱（media_links）互联 live 通道：跨模块作品连接（手动连接、推断建议、
/// 否决墓碑）跨设备保持一致（`media_link_sync.dart`）。
extension _SyncOrchestratorMediaLinks on SyncOrchestrator {
  /// 作品图谱双向同步：GET host 清单 → [applyMediaLinkManifest] 按整行 LWW 并入
  /// 本地 → 本机清单未被 host 覆盖（[mediaLinkManifestCovers]）才 POST。
  ///
  /// 整行 LWW 与应用顺序无关、重放幂等，中途失败下轮原样重来。老 host 无端点
  /// （GET 404 → null）只跳过这一维度：作品图谱是新功能，老 host 上本来就没有
  /// 任何连接，不像标签那样「用户看见没同步」需要线索，计入 report.errors 只会让
  /// 每轮同步报一条无从处理的错。
  Future<void> _syncMediaLinksLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      final MediaLinkManifest? remote = await backend
          .getRemoteMediaLinkManifest();
      if (remote == null) return;
      late final MediaLinkManifest local;
      // 与本机作为 host 处理对端 POST 的 mergeMediaLinkManifest 持同一把窄锁。
      await runExclusiveWithSyncStateApply(() async {
        report.mediaLinksUpdated += await applyMediaLinkManifest(_db, remote);
        local = await loadLocalMediaLinkManifest(_db);
      });
      if (!mediaLinkManifestCovers(remote, local)) {
        await backend.putRemoteMediaLinkManifest(local);
      }
    } catch (e) {
      report.noteError('media links live sync', e);
    }
  }
}
