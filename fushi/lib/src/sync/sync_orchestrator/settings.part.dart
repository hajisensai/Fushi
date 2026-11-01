part of '../sync_orchestrator.dart';

/// 可移植偏好设置的跨设备同步（反馈 AWp-0BtDDv）。判定与合并规则见
/// `settings_sync.dart` 文件头；这里只是资产层上的读-合并-写。
extension _SyncOrchestratorSettings on SyncOrchestrator {
  /// 读 `__settings__/` 下所有**对端**快照 → 按 key 折叠出最新值 → 与本机按真实修改
  /// 时刻严格 LWW 采纳（每轮同一规则，见 [settingsToAdopt]）→ 本机快照内容变了才回写
  /// 自己那份文件。
  ///
  /// 按设备分文件（同合集清单的 per-device 布局）：每台设备只写自己的
  /// `settings-<deviceId>.json`，两台设备并发同步也不会互相覆盖。对端文件读不出时
  /// 跳过那一份并记错误；LWW 无状态，下一轮读到它时照常收敛。
  ///
  /// 整段 try/catch，错误进 [SyncRunReport.errors] 不中断整体 sweep。
  Future<void> _syncPortableSettings(SyncRunReport report) async {
    try {
      await _backend.findOrCreateRootFolder();
      final String ns = await _backend.ensureNamespace(kSyncSettingsNamespace);
      final String ownName = settingsSnapshotNameFor(deviceId);

      final List<SettingsSnapshot> peers = <SettingsSnapshot>[];
      String? ownCanonical;
      for (final AssetEntry e in await _backend.listChildren(ns)) {
        if (e.isFolder || !isSettingsSnapshotName(e.name)) continue;
        try {
          final SettingsSnapshot s = SettingsSnapshot.fromJson(
            await _backend.getJsonAsset(e.id),
          );
          if (e.name == ownName) {
            ownCanonical = s.canonicalJson();
          } else {
            peers.add(s);
          }
        } catch (err) {
          if (e.name == ownName) {
            // 自己那份坏了：照常合并，最后用本机重写覆盖它（自愈）。
            report.noteError(
              'own settings snapshot unreadable; rewriting',
              err,
            );
          } else {
            report.noteError('peer settings snapshot "${e.name}" skipped', err);
          }
        }
      }

      final Map<String, PortableSettingValue> adopt = settingsToAdopt(
        local: await loadLocalPortableSettings(_db),
        remote: foldSettingsSnapshots(peers),
      );
      if (adopt.isNotEmpty) {
        report.settingsImported += await applyAdoptedSettings(_db, adopt);
      }

      // 采纳之后再拍本机快照：发出去的是合并后的结果，对端下一轮看到的就是一致的值。
      final SettingsSnapshot own = SettingsSnapshot(
        deviceId: deviceId,
        entries: await loadLocalPortableSettings(_db),
      );
      if (own.canonicalJson() != ownCanonical) {
        await _backend.putJsonAsset(ns, ownName, own.toJson());
      }
    } catch (e) {
      report.noteError('settings sync', e);
    }
  }
}
