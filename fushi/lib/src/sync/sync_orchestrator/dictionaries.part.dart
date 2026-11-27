part of '../sync_orchestrator.dart';

/// 词典域 .fushidict 包在云通道（staged）与互联 live 通道同步的私有实现（B2 按域拆出）。
/// 公开入口 [SyncOrchestrator.syncDictionaries] 留在本体；方法逐字搬自 SyncOrchestrator。

/// 本机词典在同步眼里的样子：登记的元数据行 + 磁盘文件状态（[localDictionaryFileStates]）。
///
/// 反馈 ujt4V8GdT8：此前「本机有没有这本」只看元数据，文件丢了（外部书库被整树删掉）的
/// 词典既拉不回来（同名 = 已装），还会被当成本机独有打成空包推给别人。
class _LocalDictionaries {
  _LocalDictionaries(this.rows, this.files);

  /// 按名的元数据行。
  final Map<String, DictionaryMetaRow> rows;
  final LocalDictionaryFileStates files;

  /// 本机真有这本：登记了，且不是「文件丢了、可以从别处恢复」的那种。资源根读不到时
  /// 登记的都算有（读不到不等于没了，不拉不覆盖）。
  bool has(String name) =>
      rows.containsKey(name) && !files.restorable.contains(name);

  /// 可以打包推出去：文件齐全。
  bool canPush(String name) => files.complete.contains(name);

  /// 要从别处拉回来恢复的那本的本机行（拉完把它的顺序 / 开关写回）；不是恢复为 null。
  DictionaryMetaRow? restoringRow(String name) =>
      files.restorable.contains(name) ? rows[name] : null;
}

extension _SyncOrchestratorDictionaries on SyncOrchestrator {
  /// 读本机词典的元数据与文件状态（[_LocalDictionaries]）。
  Future<_LocalDictionaries> _localDictionaries() async {
    final Map<String, DictionaryMetaRow> rows = <String, DictionaryMetaRow>{
      for (final DictionaryMetaRow d in await _db.getAllDictionaryMetadata())
        d.name: d,
    };
    return _LocalDictionaries(
      rows,
      await localDictionaryFileStates(_dictionaryResourceRoot, rows.keys),
    );
  }

  /// 互联直读对端实时词典：按名 union，绝不创建/读写 __dictionaries__。
  Future<void> _syncDictionariesLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
    SyncAssetDirection direction,
  ) async {
    final _LocalDictionaries local = await _localDictionaries();
    final List<RemoteDictionaryInfo> remoteDicts = await backend
        .listRemoteDictionaries();
    // 服务器托管词典目录（v153）：连接中这台 host 的清单已经拿在手上，顺手对账进
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

    // 拉：本机没有（含文件丢了、只剩元数据的，[_LocalDictionaries.has]）而对端有的；
    // 推：本机文件齐全而对端没有的。只剩元数据的那本绝不推（推出去是空包）。
    final Set<String> remoteNames = <String>{
      for (final RemoteDictionaryInfo d in remoteDicts) d.name,
    };
    final SyncKeyDiff diff = computeKeyUnionDiff(
      localKeys: <String>{
        for (final String name in local.rows.keys)
          if (local.has(name)) name,
      },
      remoteKeys: remoteNames,
    );

    // 方向裁剪放在**循环之外**：total 从一开始就是这次真正要做的量，循环体一行不
    // 改。把 if 塞进循环里只会让进度分母撒谎（显示 0/5 却只做 2 件事）。
    final List<String> pulls = <String>[if (direction.pulls) ...diff.toPull];
    final List<String> pushes = <String>[
      if (direction.pushes)
        for (final String name in diff.toPush)
          if (local.canPush(name)) name,
    ];
    final int total = pulls.length + pushes.length;
    int index = 0;

    for (final String name in pulls) {
      // 安全检查点：上一项已完整落地，这一项还没开始。
      _checkpoint();
      try {
        await _pullLiveDictionary(
          backend,
          name,
          itemIndex: index,
          itemTotal: total,
          restoring: local.restoringRow(name),
        );
        report.dictionariesImported++;
      } catch (e) {
        report.noteError('pull dictionary "$name"', e);
      }
      index++;
    }

    for (final String name in pushes) {
      // 安全检查点：上一项已完整落地，这一项还没开始。
      _checkpoint();
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
  ///
  /// 导入后本机这份接替管理页上那条服务器目录行的位置与开关
  /// （[DictionaryRepository.adoptCatalogPlacement]）：包里带的是 host 自己词典表的
  /// `order` / 开关（另一条数轴、另一个配置）。放在这里而不是各调用方，整轮同步的
  /// 拉取与单本「下载到本机」就不会一条接替、一条照搬。在后置钩子重载词典之前写，
  /// 重载读到的就是最终值。
  ///
  /// [restoring]：本机登记着、文件丢了的那一行（恢复，[_LocalDictionaries.restoringRow]）。
  /// 这时不接替目录行，而是把本机原来的顺序 / 开关写回（[_importDictionaryPackage]）。
  Future<void> _pullLiveDictionary(
    InterconnectSyncBackend backend,
    String name, {
    required int itemIndex,
    required int itemTotal,
    void Function()? onImporting,
    DictionaryMetaRow? restoring,
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
      await _importDictionaryPackage(tmp, restoring: restoring);
      if (restoring == null) {
        await DictionaryRepository.adoptCatalogPlacement(
          _db,
          hostId: await backend.connectedHostIdentity(),
          name: name,
        );
      }
    } finally {
      _safeDelete(tmp);
    }
  }

  /// 导入一本同步拉来的词典包。[restoring] 非空（本机登记着、文件丢了的那一行）时导入后把
  /// 它的「怎么排、开不开」整份写回（[DictionaryRepository.restoreLocalPlacement]）：包里的
  /// `order` / 开关是对端自己的值，恢复不能把用户在本机的设置换成对端的。
  Future<void> _importDictionaryPackage(
    File packageFile, {
    DictionaryMetaRow? restoring,
  }) async {
    await _packages.importDictionaryPackage(
      packageFile: packageFile,
      dictionaryResourceRoot: _dictionaryResourceRoot,
    );
    if (restoring != null) {
      await DictionaryRepository.restoreLocalPlacement(_db, restoring);
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
    final _LocalDictionaries local = await _localDictionaries();
    final List<AssetEntry> remote = await _backend.listChildren(ns);

    final Set<String> remoteNames = <String>{
      for (final AssetEntry e in remote)
        if (!e.isFolder && _isDictionaryAsset(e.name))
          _stripDictionaryAssetSuffix(e.name),
    };

    // Resolve both sides' work first so progress has a real denominator.
    // 「本机有」按 [_LocalDictionaries] 判（与互联路径同一判据）：文件丢了的那本照拉、不推。
    final List<DictionaryMetaRow> toPush = <DictionaryMetaRow>[
      if (direction.pushes)
        for (final DictionaryMetaRow d in local.rows.values)
          if (!remoteNames.contains(d.name) && local.canPush(d.name)) d,
    ];
    final List<AssetEntry> toPull = <AssetEntry>[
      if (direction.pulls)
        for (final AssetEntry e in remote)
          if (!e.isFolder &&
              _isDictionaryAsset(e.name) &&
              !local.has(_stripDictionaryAssetSuffix(e.name)))
            e,
    ];
    final int total = toPush.length + toPull.length;
    int index = 0;

    // Push local-only dictionaries.
    for (final DictionaryMetaRow d in toPush) {
      // 安全检查点：上一项已完整落地，这一项还没开始。
      _checkpoint();
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
      // 安全检查点：上一项已完整落地，这一项还没开始。
      _checkpoint();
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
        await _importDictionaryPackage(
          tmp,
          restoring: local.restoringRow(displayName),
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
