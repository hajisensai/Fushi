part of '../local_library_host_service.dart';

/// 本地音频源域（B4 按域拆出）：.fushiaudio 包清单 / 导出 / 导入 / 删除。
/// 方法逐字搬自 LocalLibraryHostService。
mixin _LocalLibraryHostLocalAudio
    on _LocalLibraryHostBase, _LocalLibraryHostShared {
  // ── 本地音频（T3.1）────────────────────────────────────────────────────────

  /// host 当前本地音频来源清单（从注入的 [_localAudioEntries] 取 displayName，
  /// 并带上内容身份 contentId——对端据此按内容去重，拍板 pr3481）。
  ///
  /// 只列库文件真在本机的来源：从别的设备导入的配置方案会带来文件不在本机的同名
  /// 引用（BUG-3702），列出来对端就会来拉一个 [exportLocalAudio] 必然抛错的库。
  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async {
    return <RemoteLocalAudioInfo>[
      for (final LocalAudioDbEntry e in _localAudioEntries)
        if (await File(e.path).exists())
          RemoteLocalAudioInfo(
            displayName: e.displayName,
            contentId: await resolveLocalAudioContentId(e),
          ),
    ];
  }

  /// [key] 指向的已登记库（只用于导出这种只读操作）：先按内容身份认（新版本
  /// 客户端传 contentId，不受撞名影响），再按 displayName 认（旧版本客户端）。
  /// 删除不走这里，只认内容身份（[deleteLocalAudio]）。
  Future<LocalAudioDbEntry?> _localAudioEntryFor(String key) async {
    final List<LocalAudioDbEntry> entries = _localAudioEntries;
    if (isLocalAudioContentId(key)) {
      for (final LocalAudioDbEntry e in entries) {
        if (await resolveLocalAudioContentId(e) == key) return e;
      }
    }
    for (final LocalAudioDbEntry e in entries) {
      if (e.displayName == key) return e;
    }
    return null;
  }

  /// 即时把 [key]（contentId 或 displayName）指向的本地音频库打包成临时文件，
  /// 返回该文件。调用方负责删除返回的临时文件（及其父临时目录）。
  /// [key] 含路径穿越字符时抛 [ArgumentError]；
  /// 找不到该来源或其 DB 文件不存在时抛 [StateError]。
  @override
  Future<File> exportLocalAudio(String key) async {
    _assertSafeName(key);
    final LocalAudioDbEntry? entry = await _localAudioEntryFor(key);
    if (entry == null) {
      throw StateError('local audio not found: $key');
    }
    final File dbFile = File(entry.path);
    if (!await dbFile.exists()) {
      throw StateError('local audio DB file not found: ${entry.path}');
    }

    final Directory tmpDir = await Directory.systemTemp.createTemp(
      'fushi_local_audio_export',
    );
    // 包文件名不取 displayName：key 改认 contentId 后显示名不再经过
    // _assertSafeName，可能含路径分隔符；临时目录本就独占，固定名即可。
    final File out = File(p.join(tmpDir.path, 'local_audio.fushiaudiolib'));
    await _packages.exportLocalAudioPackage(
      displayName: entry.displayName,
      enabled: entry.enabled,
      sources: entry.sources,
      dbFile: dbFile,
      outputFile: out,
      contentId: await resolveLocalAudioContentId(entry),
    );
    return out;
  }

  /// 把本地音频包文件导入 host（解包 + 注册）。
  /// 需要在构造器传入 [onLocalAudioImported] 回调；回调为 null 时抛 [UnsupportedError]。
  @override
  Future<void> importLocalAudio(File packageFile) async {
    final Future<void> Function(LocalAudioPackageContents)? callback =
        _onLocalAudioImported;
    if (callback == null) {
      throw UnsupportedError(
        'importLocalAudio requires onLocalAudioImported callback to be provided',
      );
    }
    await _runExclusive(() async {
      final Directory stagingDir =
          _localAudioStagingDir ?? Directory.systemTemp;
      final LocalAudioPackageContents contents = await _packages
          .importLocalAudioPackage(
            packageFile: packageFile,
            stagingDir: stagingDir,
          );
      try {
        await callback(contents);
      } finally {
        // 登记回调已把 DB 拷进库目录（或按重名跳过）；解包副本动辄几百 MB，
        // 不删会在 staging 目录里每推一次攒一份（BUG-2815）。
        if (await contents.dbFile.exists()) await contents.dbFile.delete();
      }
    });
  }

  /// 从 host 删除内容身份为 [key] 的本地音频来源（HBK-AUDIT-022）。
  ///
  /// 只认内容身份：同一份库在各端可以叫不同的名字，按显示名删会落到这台 host 上
  /// 恰好同名的另一份库、原目标反而留下。[key] 不是合格身份（旧版本客户端按名发来
  /// 的删除）时无法确认要删哪一份，不删（幂等返回）。
  ///
  /// 注：本地音频来源的注册信息存于 Preferences（不在 Drift DB），删除经
  /// [_removeLocalAudioEntry] 回调（按内容身份删），生产由 AppModel / 服务端注入。
  /// 回调为 null 时静默跳过（幂等）。[key] 含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<void> deleteLocalAudio(String key) async {
    _assertSafeName(key);
    final Future<void> Function(String)? remover = _removeLocalAudioEntry;
    if (remover == null) return; // 回调未注入：静默跳过（幂等）
    if (!isLocalAudioContentId(key)) return;
    await _runExclusive(() => remover(key));
  }
}
