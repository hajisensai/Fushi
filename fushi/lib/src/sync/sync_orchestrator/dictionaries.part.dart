part of '../sync_orchestrator.dart';

/// 词典域 .fushidict 包在云通道（staged）与互联 live 通道同步的私有实现（B2 按域拆出）。
/// 公开入口 [SyncOrchestrator.syncDictionaries] 留在本体；方法逐字搬自 SyncOrchestrator。
extension _SyncOrchestratorDictionaries on SyncOrchestrator {
  /// 互联直读对端实时词典：按名 union，绝不创建/读写 __dictionaries__。
  Future<void> _syncDictionariesLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
    SyncAssetDirection direction,
  ) async {
    final List<DictionaryMetaRow> localDicts =
        await _db.getAllDictionaryMetadata();
    final List<RemoteDictionaryInfo> remoteDicts =
        await backend.listRemoteDictionaries();

    final SyncKeyDiff diff = computeKeyUnionDiff(
      localKeys: <String>{for (final DictionaryMetaRow d in localDicts) d.name},
      remoteKeys: <String>{
        for (final RemoteDictionaryInfo d in remoteDicts) d.name
      },
    );

    // 方向裁剪放在**循环之外**：total 从一开始就是这次真正要做的量，循环体一行不
    // 改。把 if 塞进循环里只会让进度分母撒谎（显示 0/5 却只做 2 件事）。
    final List<String> pulls = <String>[if (direction.pulls) ...diff.toPull];
    final List<String> pushes = <String>[if (direction.pushes) ...diff.toPush];
    final int total = pulls.length + pushes.length;
    int index = 0;

    for (final String name in pulls) {
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: name);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await backend.getRemoteDictionary(name, tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: name,
                fileFraction: f));
        await _packages.importDictionaryPackage(
          packageFile: tmp,
          dictionaryResourceRoot: _dictionaryResourceRoot,
        );
        report.dictionariesImported++;
      } catch (e) {
        report.noteError('pull dictionary "$name"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    for (final String name in pushes) {
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: name);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _packages.exportDictionaryPackage(
          dictionaryName: name,
          dictionaryResourceRoot: _dictionaryResourceRoot,
          outputFile: tmp,
        );
        await backend.putRemoteDictionary(name, tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: name,
                fileFraction: f));
        report.dictionariesExported++;
      } catch (e) {
        report.noteError('push dictionary "$name"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }

  /// Union-syncs dictionary packages in the `__dictionaries__` namespace.
  Future<void> _syncDictionariesStaged(
    SyncRunReport report,
    SyncAssetDirection direction,
  ) async {
    final String ns = await _backend.ensureNamespace(kSyncDictionaryNamespace);
    final List<DictionaryMetaRow> localDicts =
        await _db.getAllDictionaryMetadata();
    final List<AssetEntry> remote = await _backend.listChildren(ns);

    final Set<String> remoteNames = <String>{
      for (final AssetEntry e in remote)
        if (!e.isFolder && _isDictionaryAsset(e.name))
          _stripDictionaryAssetSuffix(e.name),
    };
    final Set<String> localNames = <String>{
      for (final DictionaryMetaRow d in localDicts) d.name,
    };

    // Resolve both sides' work first so progress has a real denominator.
    final List<DictionaryMetaRow> toPush = <DictionaryMetaRow>[
      if (direction.pushes)
        for (final DictionaryMetaRow d in localDicts)
          if (!remoteNames.contains(d.name)) d,
    ];
    final List<AssetEntry> toPull = <AssetEntry>[
      if (direction.pulls)
        for (final AssetEntry e in remote)
          if (!e.isFolder &&
              _isDictionaryAsset(e.name) &&
              !localNames.contains(_stripDictionaryAssetSuffix(e.name)))
            e,
    ];
    final int total = toPush.length + toPull.length;
    int index = 0;

    // Push local-only dictionaries.
    for (final DictionaryMetaRow d in toPush) {
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: d.name);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _packages.exportDictionaryPackage(
          dictionaryName: d.name,
          dictionaryResourceRoot: _dictionaryResourceRoot,
          outputFile: tmp,
        );
        await _backend.putAsset(ns, '${d.name}$_dictionaryAssetSuffix', tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: d.name,
                fileFraction: f));
        report.dictionariesExported++;
      } catch (e) {
        report.noteError('export dictionary "${d.name}"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    // Pull remote-only dictionaries.
    for (final AssetEntry e in toPull) {
      // Show the clean dictionary name in progress, matching the push side —
      // the asset name still carries the `.fushidict`（或 Hibiki 时代的
      // `.fushidict`）suffix, which otherwise surfaces as a "weird" entry in
      // the progress list.
      final String displayName = _stripDictionaryAssetSuffix(e.name);
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: displayName);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _backend.getAsset(e.id, tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: displayName,
                fileFraction: f));
        await _packages.importDictionaryPackage(
          packageFile: tmp,
          dictionaryResourceRoot: _dictionaryResourceRoot,
        );
        report.dictionariesImported++;
      } catch (err) {
        report.noteError('import dictionary "${e.name}"', err);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }
}
