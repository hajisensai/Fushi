part of '../sync_orchestrator.dart';

/// 本地音频源域 .fushiaudio 包互联 live 通道同步的私有实现（B2 按域拆出）。
/// 公开入口 [SyncOrchestrator.syncLocalAudioSources] / [SyncOrchestrator.syncLocalAudioPackages]
/// 留在本体；方法逐字搬自 SyncOrchestrator。
extension _SyncOrchestratorLocalAudio on SyncOrchestrator {
  /// 互联本地音频 live 同步（Phase 3 T3.4）。
  ///
  /// 直打对端 `/api/library/localaudio` 端点，按 `displayName` union：
  /// - toPull：远端有 ∧ 本端无 → `getRemoteLocalAudio` 下载包 → `onLocalAudioImported` 注册；
  /// - toPush：本端有 ∧ 远端无 → `exportLocalAudioPackage` 打包 → `putRemoteLocalAudio` 上传。
  ///
  /// [direction] 裁剪要做哪一半（显式上传 / 下载动作用；[SyncAssetDirection.both]
  /// 保留完整 union 语义）。只由 [syncLocalAudioSources] 分派调用，不再随 [run] 跑。
  /// 进度走 [SyncPhase.localAudio]，临时文件 finally 清理，逐项错误进 report.errors 不中断。
  Future<void> _syncLocalAudioLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
    SyncAssetDirection direction,
  ) async {
    final List<RemoteLocalAudioInfo> remoteEntries =
        await backend.listRemoteLocalAudio();
    final Set<String> localNames = <String>{
      for (final LocalAudioDbEntry d in localAudioEntries) d.displayName,
    };
    final Set<String> remoteNames = <String>{
      for (final RemoteLocalAudioInfo r in remoteEntries) r.displayName,
    };

    final SyncKeyDiff diff = computeKeyUnionDiff(
      localKeys: localNames,
      remoteKeys: remoteNames,
    );

    // 方向裁剪在循环之外（同 [_syncDictionariesLive]）：total 即本次真实工作量。
    final List<String> pulls = <String>[if (direction.pulls) ...diff.toPull];
    final List<String> pushes = <String>[if (direction.pushes) ...diff.toPush];
    final int total = pulls.length + pushes.length;
    int index = 0;

    // ── Pull：远端独有 → 下载并注册 ────────────────────────────────────────
    for (final String name in pulls) {
      _emit(SyncPhase.localAudio,
          itemIndex: index, itemTotal: total, title: name);
      File? tmp;
      File? stagingDb;
      try {
        tmp = _tmpFile(_localAudioAssetSuffix);
        await backend.getRemoteLocalAudio(
          name,
          tmp,
          onProgress: (double f) => _emit(SyncPhase.localAudio,
              itemIndex: index, itemTotal: total, title: name, fileFraction: f),
        );
        final LocalAudioPackageContents contents =
            await _packages.importLocalAudioPackage(
          packageFile: tmp,
          stagingDir: _tempDir,
        );
        stagingDb = contents.dbFile;
        if (onLocalAudioImported != null) {
          await onLocalAudioImported!(contents);
          report.localAudioImported++;
        }
      } catch (e) {
        report.noteError('live pull local audio "$name"', e);
      } finally {
        _safeDelete(tmp);
        _safeDelete(stagingDb);
      }
      index++;
    }

    // ── Push：本端独有 → 打包并上传 ─────────────────────────────────────────
    for (final String name in pushes) {
      _emit(SyncPhase.localAudio,
          itemIndex: index, itemTotal: total, title: name);
      File? tmp;
      try {
        final LocalAudioDbEntry? entry =
            localAudioEntries.cast<LocalAudioDbEntry?>().firstWhere(
                  (LocalAudioDbEntry? d) => d!.displayName == name,
                  orElse: () => null,
                );
        if (entry == null || !File(entry.path).existsSync()) {
          report.errors.add(
              'live push local audio "$name": DB file missing or not found');
          index++;
          continue;
        }
        tmp = _tmpFile(_localAudioAssetSuffix);
        await _packages.exportLocalAudioPackage(
          displayName: entry.displayName,
          enabled: entry.enabled,
          sources: entry.sources,
          dbFile: File(entry.path),
          outputFile: tmp,
        );
        await backend.putRemoteLocalAudio(
          name,
          tmp,
          onProgress: (double f) => _emit(SyncPhase.localAudio,
              itemIndex: index, itemTotal: total, title: name, fileFraction: f),
        );
        report.localAudioExported++;
      } catch (e) {
        report.noteError('live push local audio "$name"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }
}
