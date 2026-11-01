part of '../sync_orchestrator.dart';

/// 可移植偏好设置的跨设备同步（反馈 AWp-0BtDDv）。判定与合并规则见
/// `settings_sync.dart` 文件头；这里只是资产层上的读-合并-写。
extension _SyncOrchestratorSettings on SyncOrchestrator {
  /// 读 `__settings__/` 下所有**对端**快照 → 按 key 折叠出最新值 → 与本机比较后采纳
  /// （首次对齐时远端为准，此后严格 LWW）→ 本机快照内容变了才回写自己那份文件。
  ///
  /// 按设备分文件（同合集清单的 per-device 布局）：每台设备只写自己的
  /// `settings-<deviceId>.json`，两台设备并发同步也不会互相覆盖。对端文件读不出时
  /// 跳过那一份并记错误，且本轮**不**完成首次对齐（没看全对端，不能宣布「已对齐」）。
  ///
  /// 整段 try/catch，错误进 [SyncRunReport.errors] 不中断整体 sweep。
  Future<void> _syncPortableSettings(SyncRunReport report) async {
    try {
      await _backend.findOrCreateRootFolder();
      final String ns = await _backend.ensureNamespace(kSyncSettingsNamespace);
      final String ownName = settingsSnapshotNameFor(deviceId);
      final SyncRepository repo = SyncRepository(_db);

      final List<SettingsSnapshot> peers = <SettingsSnapshot>[];
      String? ownCanonical;
      bool skippedPeer = false;
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
            skippedPeer = true;
            report.noteError('peer settings snapshot "${e.name}" skipped', err);
          }
        }
      }

      final bool seeded = await repo.isSettingsSyncSeeded();
      final bool firstAlignment = !seeded && peers.isNotEmpty;
      final Map<String, PortableSettingValue> adopt = settingsToAdopt(
        local: await loadLocalPortableSettings(_db),
        remote: foldSettingsSnapshots(peers),
        firstAlignment: firstAlignment,
      );
      if (adopt.isNotEmpty) {
        report.settingsImported += await applyAdoptedSettings(
          _db,
          adopt,
          firstAlignment: firstAlignment,
        );
      }

      // 采纳之后再拍本机快照：发出去的是合并后的结果，对端下一轮看到的就是一致的值。
      final SettingsSnapshot own = SettingsSnapshot(
        deviceId: deviceId,
        entries: await loadLocalPortableSettings(_db),
      );
      if (own.canonicalJson() != ownCanonical) {
        await _backend.putJsonAsset(ns, ownName, own.toJson());
      }
      if (!seeded && !skippedPeer) await repo.setSettingsSyncSeeded(true);
    } catch (e) {
      report.noteError('settings sync', e);
    }
  }
}
