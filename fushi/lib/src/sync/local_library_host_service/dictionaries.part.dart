part of '../local_library_host_service.dart';

/// 词典域（B4 按域拆出）：.fushidict 包清单 / 导出 / 导入 / 删除。
/// 方法逐字搬自 LocalLibraryHostService；字段经 _LocalLibraryHostBase 的抽象私有 getter 取用。
mixin _LocalLibraryHostDictionaries
    on _LocalLibraryHostBase, _LocalLibraryHostShared {
  /// host 当前实时词典清单（从 DictionaryMeta 表读）。
  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async {
    final List<DictionaryMetaRow> rows = await _db.getAllDictionaryMetadata();
    return <RemoteDictionaryInfo>[
      for (final DictionaryMetaRow r in rows)
        RemoteDictionaryInfo(name: r.name, type: r.type),
    ];
  }

  /// 即时把名为 [name] 的实时词典打包成临时 .fushidict 文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。词典不存在抛 [StateError]。
  /// 名称含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<File> exportDictionary(String name) async {
    _assertSafeName(name);
    final List<DictionaryMetaRow> rows = await _db.getAllDictionaryMetadata();
    final bool exists = rows.any((DictionaryMetaRow r) => r.name == name);
    if (!exists) throw StateError('dictionary not found: $name');

    final Directory tmpDir =
        Directory.systemTemp.createTempSync('fushi_dict_export');
    final File out = File(p.join(tmpDir.path, '$name$_dictionaryAssetSuffix'));
    await _packages.exportDictionaryPackage(
      dictionaryName: name,
      dictionaryResourceRoot: _dictionaryResourceRoot,
      outputFile: out,
    );
    return out;
  }

  /// 把 [packageFile]（.fushidict）导入 host 实时库（幂等：同名覆盖资源 + upsert 元数据）。
  @override
  Future<void> importDictionary(File packageFile) async {
    await _runExclusive(() async {
      // 同名覆盖会往既有词典目录里写 blobs.bin / hash.table，而这些文件正被引擎
      // MapViewOfFile 映射着 —— Windows 拒绝以写方式打开，覆盖导入直接失败
      // （BUG-1756）。收尾的 _refreshDictionaryCache 会把引擎重新加载回来。
      //
      // 装回必须走 finally：releaseAllMappings 之后引擎是空的，而
      // importDictionaryPackage 会因包损坏 / 磁盘满 / 权限抛出。写在 try 之后就被
      // 跳过 —— host 引擎永久空转，所有互联对端查词返回空，直到 host 重启。
      FushiDicts.releaseAllMappings();
      try {
        await _packages.importDictionaryPackage(
          packageFile: packageFile,
          dictionaryResourceRoot: _dictionaryResourceRoot,
        );
      } finally {
        await _refreshDictionaryCache();
      }
    });
  }

  /// 从 host 实时库删除名为 [name] 的词典（DB 元数据 + 资源目录）。
  /// 名称含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<void> deleteDictionary(String name) async {
    _assertSafeName(name);
    await _runExclusive(() async {
      await _db.deleteDictionaryMeta(name);
      // 顺序不可交换（BUG-1756）：先 refresh —— 它 loadFromDb 把 host 刚改过的 DB
      // 同步进 Dart 侧 cache，再据此重载引擎，于是被删的那本立刻从引擎里掉出去、
      // 它的 mmap view 被释放。反过来写（先删目录）在 Windows 上必抛
      // ERROR_USER_MAPPED_FILE，且 refresh 永远执行不到。
      //
      // 这一次 refresh 不能省成「交给原语的 reloadEngine」：目录不存在时原语直接
      // 返回、不碰引擎，cache 就会停在「已删的词典还在」的旧状态上。
      await _refreshDictionaryCache();
      await deleteDictionaryDirectory(
        Directory(p.join(_dictionaryResourceRoot.path, name)),
        reloadEngine: _refreshDictionaryCache,
      );
    });
  }
}

// ── 本域私有的顶层 helper（原 LocalLibraryHostService 的 private static；mixin 体内看不到
//    宿主类的 static，故提到库顶层）。

const String _dictionaryAssetSuffix = '.fushidict';
