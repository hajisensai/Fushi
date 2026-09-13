part of '../local_library_host_service.dart';

/// 本地音频源域（B4 按域拆出）：.fushiaudio 包清单 / 导出 / 导入 / 删除。
/// 方法逐字搬自 LocalLibraryHostService。
mixin _LocalLibraryHostLocalAudio
    on _LocalLibraryHostBase, _LocalLibraryHostShared {
  // ── 本地音频（T3.1）────────────────────────────────────────────────────────

  /// host 当前本地音频来源清单（从注入的 [_localAudioEntries] 取 displayName）。
  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async {
    return <RemoteLocalAudioInfo>[
      for (final LocalAudioDbEntry e in _localAudioEntries)
        RemoteLocalAudioInfo(displayName: e.displayName),
    ];
  }

  /// 即时把 displayName 为 [displayName] 的本地音频库打包成临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  /// [displayName] 含路径穿越字符时抛 [ArgumentError]；
  /// 找不到该来源或其 DB 文件不存在时抛 [StateError]。
  @override
  Future<File> exportLocalAudio(String displayName) async {
    _assertSafeName(displayName);
    final LocalAudioDbEntry? entry =
        _localAudioEntries.cast<LocalAudioDbEntry?>().firstWhere(
              (LocalAudioDbEntry? e) => e!.displayName == displayName,
              orElse: () => null,
            );
    if (entry == null) {
      throw StateError('local audio not found: $displayName');
    }
    final File dbFile = File(entry.path);
    if (!dbFile.existsSync()) {
      throw StateError('local audio DB file not found: ${entry.path}');
    }

    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_local_audio_export');
    final File out = File(p.join(tmpDir.path, '$displayName.fushiaudiolib'));
    await _packages.exportLocalAudioPackage(
      displayName: entry.displayName,
      enabled: entry.enabled,
      sources: entry.sources,
      dbFile: dbFile,
      outputFile: out,
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
      final LocalAudioPackageContents contents =
          await _packages.importLocalAudioPackage(
        packageFile: packageFile,
        stagingDir: stagingDir,
      );
      await callback(contents);
    });
  }

  /// 从 host 删除 displayName 为 [displayName] 的本地音频来源。
  ///
  /// 注：本地音频来源的注册信息存于 Preferences（不在 Drift DB），删除需经
  /// [_removeLocalAudioEntry] 回调，生产由 AppModel 注入。回调为 null 时静默
  /// 跳过实际删除（等同 no-op，保持幂等）。
  /// [displayName] 含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<void> deleteLocalAudio(String displayName) async {
    _assertSafeName(displayName);
    final Future<void> Function(String)? remover = _removeLocalAudioEntry;
    if (remover == null) return; // 回调未注入：静默跳过（幂等）
    await _runExclusive(() => remover(displayName));
  }
}
