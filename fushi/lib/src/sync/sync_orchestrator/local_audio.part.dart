part of '../sync_orchestrator.dart';

/// 本地音频源域 .fushiaudio 包互联 live 通道同步的私有实现（B2 按域拆出）。
/// 公开入口 [SyncOrchestrator.syncLocalAudioSources] / [SyncOrchestrator.syncLocalAudioPackages]
/// 留在本体；方法逐字搬自 SyncOrchestrator。
extension _SyncOrchestratorLocalAudio on SyncOrchestrator {
  /// 互联本地音频 live 同步（Phase 3 T3.4）。
  ///
  /// 直打对端 `/api/library/localaudio` 端点，按**内容身份**做 union（拍板
  /// pr3481，见 `local_audio_content_id.dart`）：
  /// - toPull：远端有 ∧ 本端没有同一份库 → `getRemoteLocalAudio` 下载包 → `onLocalAudioImported` 注册；
  /// - toPush：本端有 ∧ 远端没有同一份库 → `exportLocalAudioPackage` 打包 → `putRemoteLocalAudio` 上传。
  ///
  /// 「同一份库」两端都有 contentId 时只比 contentId——显示名不同（`android.db` /
  /// 按子来源起的名 / 推荐包的 Japanese audio）也不再互拉一份 GB 级库；对端是旧
  /// 版本、清单里没有 contentId 时退回按 displayName 比，并在报告里记一条，提示
  /// 升级对端（新旧版本混用的同步问题要看得见，不静默降级）。
  ///
  /// [direction] 裁剪要做哪一半（显式上传 / 下载动作用；[SyncAssetDirection.both]
  /// 保留完整 union 语义）。只由 [syncLocalAudioSources] 分派调用，不再随 [run] 跑。
  /// 进度走 [SyncPhase.localAudio]，临时文件 finally 清理，逐项错误进 report.errors 不中断。
  Future<void> _syncLocalAudioLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
    SyncAssetDirection direction,
  ) async {
    final List<RemoteLocalAudioInfo> remoteEntries = await backend
        .listRemoteLocalAudio();
    // 「本端有」只认库文件真在本机的条目（[localAudioEntries] 的 path 已归一到本机
    // 落点，见 AppModel.localAudioDbsOnThisDevice）。从另一台设备导入的配置方案会
    // 带来同名但文件不在本机的引用（BUG-3702）：把它算作「本端有」，远端那份就永远
    // 不会被拉下来，这条源也就永远修不好。拉下来后由 onLocalAudioImported 原位改指。
    final List<({LocalAudioDbEntry entry, String? contentId})> locals =
        <({LocalAudioDbEntry entry, String? contentId})>[
          for (final LocalAudioDbEntry d in localAudioEntries)
            if (File(d.path).existsSync())
              (entry: d, contentId: await resolveLocalAudioContentId(d)),
        ];
    bool same(
      ({LocalAudioDbEntry entry, String? contentId}) l,
      RemoteLocalAudioInfo r,
    ) => isSameLocalAudioLibrary(
      nameA: l.entry.displayName,
      contentIdA: l.contentId,
      nameB: r.displayName,
      contentIdB: r.contentId,
    );

    // 对端是旧版本（capabilities 没声明内容身份）：只能按显示名匹配，同一份库
    // 改过名就会再传一次。两边都有库时才记——这时匹配结果才受影响。
    if (remoteEntries.isNotEmpty &&
        locals.isNotEmpty &&
        !interconnectHostReportsLocalAudioContentId(
          await _roundHostCapabilities(report, backend),
        )) {
      report.notePeerGap(
        SyncPeerGapDimension.localAudioIdentity,
        outdated: true,
      );
    }

    // 方向裁剪在循环之外（同 [_syncDictionariesLive]）：total 即本次真实工作量。
    final List<RemoteLocalAudioInfo> pulls = <RemoteLocalAudioInfo>[
      if (direction.pulls)
        for (final RemoteLocalAudioInfo r in remoteEntries)
          if (!locals.any(
            (({LocalAudioDbEntry entry, String? contentId}) l) => same(l, r),
          ))
            r,
    ];
    final List<({LocalAudioDbEntry entry, String? contentId})> pushes =
        <({LocalAudioDbEntry entry, String? contentId})>[
          if (direction.pushes)
            for (final ({LocalAudioDbEntry entry, String? contentId}) l
                in locals)
              if (!remoteEntries.any((RemoteLocalAudioInfo r) => same(l, r))) l,
        ];
    final int total = pulls.length + pushes.length;
    int index = 0;

    // ── Pull：远端独有 → 下载并注册 ────────────────────────────────────────
    for (final RemoteLocalAudioInfo remote in pulls) {
      final String name = remote.displayName;
      // 安全检查点：上一项已完整落地，这一项还没开始。
      _checkpoint();
      _emit(
        SyncPhase.localAudio,
        itemIndex: index,
        itemTotal: total,
        title: name,
      );
      File? tmp;
      File? stagingDb;
      try {
        tmp = resumableTmpFile(
          'localaudio',
          remote.key,
          _localAudioAssetSuffix,
        );
        await backend.getRemoteLocalAudio(
          remote.key,
          tmp,
          onProgress: (double f, [int? b]) => _emit(
            SyncPhase.localAudio,
            itemIndex: index,
            itemTotal: total,
            title: name,
            fileFraction: f,
            fileBytes: b,
          ),
        );
        final LocalAudioPackageContents contents = await _packages
            .importLocalAudioPackage(packageFile: tmp, stagingDir: _tempDir);
        stagingDb = contents.dbFile;
        if (onLocalAudioImported != null) {
          await onLocalAudioImported!(contents);
          report.localAudioImported++;
        }
      } catch (e) {
        _noteDimensionError(report, 'live pull local audio "$name"', e);
      } finally {
        _safeDelete(tmp);
        _safeDelete(stagingDb);
      }
      index++;
    }

    // ── Push：本端独有 → 打包并上传 ─────────────────────────────────────────
    for (final ({LocalAudioDbEntry entry, String? contentId}) local in pushes) {
      final LocalAudioDbEntry entry = local.entry;
      final String name = entry.displayName;
      // 安全检查点：上一项已完整落地，这一项还没开始。
      _checkpoint();
      _emit(
        SyncPhase.localAudio,
        itemIndex: index,
        itemTotal: total,
        title: name,
      );
      File? tmp;
      try {
        if (!File(entry.path).existsSync()) {
          report.errors.add(
            'live push local audio "$name": DB file missing or not found',
          );
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
          contentId: local.contentId,
        );
        await backend.putRemoteLocalAudio(
          name,
          tmp,
          onProgress: (double f, [int? b]) => _emit(
            SyncPhase.localAudio,
            itemIndex: index,
            itemTotal: total,
            title: name,
            fileFraction: f,
            fileBytes: b,
          ),
        );
        report.localAudioExported++;
      } catch (e) {
        _noteDimensionError(report, 'live push local audio "$name"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }
}
