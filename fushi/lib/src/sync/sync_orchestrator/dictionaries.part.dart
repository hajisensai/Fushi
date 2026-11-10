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
    final List<DictionaryMetaRow> localDicts = await _db
        .getAllDictionaryMetadata();
    final List<RemoteDictionaryInfo> remoteDicts = await backend
        .listRemoteDictionaries();
    // 服务器托管词典目录（v149）：连接中这台 host 的清单已经拿在手上，顺手对账进
    // `remote_dictionary_metadata`，不另发请求。对账失败只记进报告，不影响词典同步。
    try {
      await RemoteDictionaryCatalogService.reconcileHost(
        _db,
        hostId: await backend.connectedHostIdentity(),
        infos: remoteDicts,
        now: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      report.noteError('refresh server dictionary catalog', e);
    }

    final SyncKeyDiff diff = computeKeyUnionDiff(
      localKeys: <String>{for (final DictionaryMetaRow d in localDicts) d.name},
      remoteKeys: <String>{
        for (final RemoteDictionaryInfo d in remoteDicts) d.name,
      },
    );

    // 方向裁剪放在**循环之外**：total 从一开始就是这次真正要做的量，循环体一行不
    // 改。把 if 塞进循环里只会让进度分母撒谎（显示 0/5 却只做 2 件事）。
    final List<String> pulls = <String>[if (direction.pulls) ...diff.toPull];
    final List<String> pushes = <String>[if (direction.pushes) ...diff.toPush];
    final int total = pulls.length + pushes.length;
    int index = 0;

    for (final String name in pulls) {
      try {
        await _pullLiveDictionary(
          backend,
          name,
          itemIndex: index,
          itemTotal: total,
        );
        report.dictionariesImported++;
      } catch (e) {
        report.noteError('pull dictionary "$name"', e);
      }
      index++;
    }

    for (final String name in pushes) {
      try {
        await _pushLiveDictionary(
          backend,
          name,
          itemIndex: index,
          itemTotal: total,
        );
        report.dictionariesExported++;
      } catch (e) {
        report.noteError('push dictionary "$name"', e);
      }
      index++;
    }
  }

  /// 从互联对端拉一本词典包并导入本机（同步阶段与按 host 的单本下载共用这一份）。
  /// 失败原样抛出，由调用方决定记账还是上屏。
  Future<void> _pullLiveDictionary(
    InterconnectSyncBackend backend,
    String name, {
    required int itemIndex,
    required int itemTotal,
    void Function()? onImporting,
  }) async {
    _emit(
      SyncPhase.dictionaries,
      itemIndex: itemIndex,
      itemTotal: itemTotal,
      title: name,
    );
    File? tmp;
    try {
      tmp = resumableTmpFile('dictionary', name, _dictionaryAssetSuffix);
      await backend.getRemoteDictionary(
        name,
        tmp,
        onProgress: (double f, [int? b]) => _emit(
          SyncPhase.dictionaries,
          itemIndex: itemIndex,
          itemTotal: itemTotal,
          title: name,
          fileFraction: f,
          fileBytes: b,
        ),
      );
      onImporting?.call();
      await _packages.importDictionaryPackage(
        packageFile: tmp,
        dictionaryResourceRoot: _dictionaryResourceRoot,
      );
    } finally {
      _safeDelete(tmp);
    }
  }

  /// 把本机一本词典打包推到互联对端（同步阶段与按 host 的单本推送共用这一份）。
  /// 失败原样抛出。
  Future<void> _pushLiveDictionary(
    InterconnectSyncBackend backend,
    String name, {
    required int itemIndex,
    required int itemTotal,
  }) async {
    _emit(
      SyncPhase.dictionaries,
      itemIndex: itemIndex,
      itemTotal: itemTotal,
      title: name,
    );
    File? tmp;
    try {
      tmp = _tmpFile(_dictionaryAssetSuffix);
      await _packages.exportDictionaryPackage(
        dictionaryName: name,
        dictionaryResourceRoot: _dictionaryResourceRoot,
        outputFile: tmp,
      );
      await backend.putRemoteDictionary(
        name,
        tmp,
        onProgress: (double f, [int? b]) => _emit(
          SyncPhase.dictionaries,
          itemIndex: itemIndex,
          itemTotal: itemTotal,
          title: name,
          fileFraction: f,
          fileBytes: b,
        ),
      );
    } finally {
      _safeDelete(tmp);
    }
  }

  /// Union-syncs dictionary packages in the `__dictionaries__` namespace.
  Future<void> _syncDictionariesStaged(
    SyncRunReport report,
    SyncAssetDirection direction,
  ) async {
    final String ns = await _backend.ensureNamespace(kSyncDictionaryNamespace);
    final List<DictionaryMetaRow> localDicts = await _db
        .getAllDictionaryMetadata();
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
      _emit(
        SyncPhase.dictionaries,
        itemIndex: index,
        itemTotal: total,
        title: d.name,
      );
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _packages.exportDictionaryPackage(
          dictionaryName: d.name,
          dictionaryResourceRoot: _dictionaryResourceRoot,
          outputFile: tmp,
        );
        await _backend.putAsset(
          ns,
          '${d.name}$_dictionaryAssetSuffix',
          tmp,
          onProgress: (double f, [int? b]) => _emit(
            SyncPhase.dictionaries,
            itemIndex: index,
            itemTotal: total,
            title: d.name,
            fileFraction: f,
            fileBytes: b,
          ),
        );
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
      _emit(
        SyncPhase.dictionaries,
        itemIndex: index,
        itemTotal: total,
        title: displayName,
      );
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _backend.getAsset(
          e.id,
          tmp,
          onProgress: (double f, [int? b]) => _emit(
            SyncPhase.dictionaries,
            itemIndex: index,
            itemTotal: total,
            title: displayName,
            fileFraction: f,
            fileBytes: b,
          ),
        );
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
