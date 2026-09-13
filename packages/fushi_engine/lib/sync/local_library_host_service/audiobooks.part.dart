part of '../local_library_host_service.dart';

/// 有声书域（B4 按域拆出）：清单、字幕延迟、导出 / 打包 / 导入 / 删除、播放位置。
/// 方法逐字搬自 LocalLibraryHostService。
mixin _LocalLibraryHostAudiobooks
    on _LocalLibraryHostBase, _LocalLibraryHostShared {
  /// host 当前可导出的有声书清单。
  ///
  /// 两类：
  /// - **srt-backed**（既有 Audiobooks 又有 SrtBooks 行）：身份键 = bookKey（不变）。
  /// - **纯 SRT（standalone）有声书**（SrtBooks 行 bookKey 为空、无 Audiobooks 行）：
  ///   身份键 = uid。旧枚举只遍历 Audiobooks 表，完全遗漏这类书 → 无法跨设备下载。
  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async {
    final List<AudiobookRow> rows = await _db.getAllAudiobooks();
    final List<RemoteAudiobookInfo> result = <RemoteAudiobookInfo>[];
    final Set<String> emittedUids = <String>{};
    // 清单内联断点 + 调轴（互联完整支持批次）：与视频清单同范式，sweep/下载回填
    // 免逐本 GET（旧实现 N 本书 = N 次网络往返）。一趟 prefs 批读。
    final Map<String, String> allPrefs = await _db.getAllPrefs();
    RemoteAudiobookInfo build(String bookKey, String uid, String? title) {
      final String identity = bookKey.isNotEmpty ? bookKey : uid;
      return RemoteAudiobookInfo(
        bookKey: bookKey,
        uid: uid,
        title: title,
        positionMs: PrefCodec.decode<int>(
            allPrefs[audiobookPositionPrefKey(identity)] ?? '', 0),
        positionUpdatedAtMs: PrefCodec.decode<int>(
            allPrefs[audiobookPositionAtPrefKey(identity)] ?? '', 0),
        delayMs: PrefCodec.decode<int>(
            allPrefs[audiobookDelayPrefKey(identity)] ?? '', 0),
        delayUpdatedAtMs: PrefCodec.decode<int>(
            allPrefs[audiobookDelayAtPrefKey(identity)] ?? '', 0),
      );
    }

    for (final AudiobookRow r in rows) {
      final SrtBookRow? srt = await _db.getSrtBookByBookKey(r.bookKey);
      if (srt == null) continue;
      result.add(build(r.bookKey, srt.uid, srt.title));
      emittedUids.add(srt.uid);
    }
    // 纯 SRT（standalone）有声书：bookKey 为空、不落 Audiobooks 行，身份 = uid。
    final List<SrtBookRow> srtRows = await _db.getAllSrtBooks();
    for (final SrtBookRow srt in srtRows) {
      if (srt.bookKey.isNotEmpty) continue; // srt-backed 已在上面枚举
      if (!emittedUids.add(srt.uid)) continue; // 去重（防重复 uid）
      result.add(build('', srt.uid, srt.title));
    }
    return result;
  }

  /// 读 host 端有声书 [identity] 的调轴（[AudiobookDelayHost]）。值键是既有
  /// `audiobook_delay_` pref（旧数据无戳记 0，被任何带戳对端值盖过）。
  @override
  Future<({int delayMs, int updatedAtMs})> getAudiobookDelay(
      String identity) async {
    final int delay =
        await _db.getPrefTyped<int>(audiobookDelayPrefKey(identity), 0);
    final int at =
        await _db.getPrefTyped<int>(audiobookDelayAtPrefKey(identity), 0);
    return (delayMs: delay, updatedAtMs: at);
  }

  /// 把 client 上报的有声书 [identity] 调轴写入 host（[AudiobookDelayHost]）。
  /// 存在性闸门 / clamp / 未来戳截断 / LWW 与视频 [putVideoDelay] 同纪律；
  /// 有声书调轴本地读取就是这对 prefs，写入即对 host 本机播放生效（无行写穿）。
  @override
  Future<void> putAudiobookDelay(
      String identity, int delayMs, int updatedAtMs) async {
    if (!await audiobookExists(identity)) return;
    final int clamped =
        delayMs.clamp(-kVideoSubtitleDelayLimitMs, kVideoSubtitleDelayLimitMs);
    final int nowCapMs = DateTime.now().millisecondsSinceEpoch + 5 * 60 * 1000;
    final int cappedAt = updatedAtMs > nowCapMs ? nowCapMs : updatedAtMs;
    final ({int delayMs, int updatedAtMs}) current =
        await getAudiobookDelay(identity);
    final ({int delayMs, int updatedAtMs}) winner = resolveDelayLww(
      aDelayMs: current.delayMs,
      aUpdatedAtMs: current.updatedAtMs,
      bDelayMs: clamped,
      bUpdatedAtMs: cappedAt,
    );
    if (winner.updatedAtMs == current.updatedAtMs &&
        winner.delayMs == current.delayMs) {
      return; // host 已存更新或相等，no-op。
    }
    await _db.setPrefTyped<int>(
        audiobookDelayPrefKey(identity), winner.delayMs);
    await _db.setPrefTyped<int>(
        audiobookDelayAtPrefKey(identity), winner.updatedAtMs);
  }

  /// 即时把身份键为 [identity] 的有声书打包成临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。
  ///
  /// [identity] 解析：先按 bookKey 查 Audiobooks（srt-backed），命中即打含 audiobook
  /// 段的包；否则按 uid 查 SrtBooks（纯 SRT standalone），命中即打无 audiobook 段的
  /// 纯 SRT 包。两者都查不到抛 [StateError]。含路径穿越字符时抛 [ArgumentError]。
  @override
  Future<File> exportAudiobook(String identity) async {
    _assertSafeName(identity);

    // srt-backed：identity = bookKey，Audiobooks 行 + SrtBooks 行齐备。
    final AudiobookRow? ab = await _db.getAudiobookByBookKey(identity);
    if (ab != null) {
      final SrtBookRow? srt = await _db.getSrtBookByBookKey(identity);
      if (srt == null) {
        throw StateError('srtBook not found for bookKey: $identity');
      }
      return _packAudiobook(
        identity: identity,
        srtBookUid: srt.uid,
        bookKey: identity,
      );
    }

    // 纯 SRT（standalone）：identity = uid，无 Audiobooks 行，bookKey 空。
    final SrtBookRow? srtStandalone = await _db.getSrtBookByUid(identity);
    if (srtStandalone != null) {
      return _packAudiobook(
        identity: identity,
        srtBookUid: identity,
        bookKey: null, // 无 Audiobooks 行 → 打纯 SRT 包
      );
    }

    throw StateError('audiobook not found for identity: $identity');
  }

  /// 打包成 `<identity>.fushiaudio` 临时文件（srt-backed 传 [bookKey]；纯 SRT 传
  /// null，包管线据此省略 audiobook 段、cue 走 uid 命名空间）。
  Future<File> _packAudiobook({
    required String identity,
    required String srtBookUid,
    required String? bookKey,
  }) async {
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_audiobook_export');
    final File out = File(p.join(tmpDir.path, '$identity.fushiaudio'));
    await _packages.exportAudioDatabasePackage(
      srtBookUid: srtBookUid,
      outputFile: out,
      bookKey: bookKey,
    );
    return out;
  }

  /// 廉价判断 host 库是否存在 bookKey 为 [bookKey] 的有声书（BUG-471a）：仅一次
  /// `Audiobooks` 行查询，不触发 [exportAudiobook] 的整包打包 zip I/O。与
  /// [putAudiobookPosition] 自身用的存在性闸门同一查询。
  @override
  Future<bool> audiobookExists(String identity) async {
    _assertSafeName(identity);
    if (await _db.getAudiobookByBookKey(identity) != null) return true;
    // 纯 SRT standalone：无 Audiobooks 行，按 uid 查 SrtBooks。
    return await _db.getSrtBookByUid(identity) != null;
  }

  /// 把有声书包文件导入 host（解包写 DB + 音频文件）。
  /// 需要在构造器传入 [audioDatabaseRoot]；为 null 时抛 [UnsupportedError]。
  @override
  Future<void> importAudiobook(File packageFile,
      {String? bookKeyOverride}) async {
    final Directory? root = _audioDatabaseRoot;
    if (root == null) {
      throw UnsupportedError(
        'importAudiobook requires audioDatabaseRoot to be provided',
      );
    }
    await _runExclusive(() async {
      await _packages.importAudioDatabasePackage(
        packageFile: packageFile,
        audioDatabaseRoot: root,
        bookKeyOverride: bookKeyOverride,
      );
    });
  }

  /// 从 host 删除 bookKey 为 [bookKey] 的有声书（Audiobooks/SrtBooks/AudioCues 行
  /// + 磁盘音频目录）。[bookKey] 含路径穿越字符时抛 [ArgumentError]；
  /// 不存在则静默跳过（幂等）。
  @override
  Future<void> deleteAudiobook(String bookKey) async {
    _assertSafeName(bookKey);
    await _runExclusive(() async {
      final AudiobookRow? ab = await _db.getAudiobookByBookKey(bookKey);
      if (ab != null) {
        // 先取 audioRoot，再删 DB 行（磁盘清理在 DB 删除后，同 deleteBook 顺序）。
        final String? audioRoot = ab.audioRoot;

        // 删除 SrtBooks 行（按 bookKey），其关联的 SrtBook 级别 audioCues 由事务处理。
        // getSrtBookByBookKey 先拿 uid，再用 deleteSrtBookByUid 级联删 audioCue 行。
        final SrtBookRow? srt = await _db.getSrtBookByBookKey(bookKey);
        if (srt != null) {
          await _db.deleteSrtBookByUid(srt.uid);
        }

        // 删除 Audiobooks 行（及其 audioCues 级联，via deleteAudiobookByBookKey）。
        await _db.deleteAudiobookByBookKey(bookKey);

        await _deleteAudioRootIfPersisted(audioRoot);
        return;
      }

      // 纯 SRT standalone：identity = uid，无 Audiobooks 行。按 uid 删 SrtBooks 行
      // （级联 uid 命名空间的 audioCues）+ 其持久音频目录。
      final SrtBookRow? srt = await _db.getSrtBookByUid(bookKey);
      if (srt == null) return; // 幂等：都不存在则静默跳过
      final String? audioRoot = srt.audioRoot;
      await _db.deleteSrtBookByUid(srt.uid);
      await _deleteAudioRootIfPersisted(audioRoot);
    });
  }

  /// 删除 [audioRoot] 磁盘目录，但仅当它在 app 内部持久根（<appDoc>/audiobooks）下
  /// —— 绝不递归删用户「引用导入」的原始外部目录（TODO-935 ①A）。
  Future<void> _deleteAudioRootIfPersisted(String? audioRoot) async {
    if (audioRoot == null || audioRoot.isEmpty) return;
    final String persistRoot = await AudiobookStorage.audiobooksRootDir();
    final bool referenced = AudiobookStorage.isReferencedPath(
      filePath: audioRoot,
      persistRoot: persistRoot,
    );
    if (!referenced) {
      final Directory dir = Directory(audioRoot);
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  }

  /// 读 host 端有声书 [bookKey] 的播放断点（BUG-471）。真相源是
  /// `audiobook_pos_<bookKey>` + `audiobook_pos_at_<bookKey>` prefs（host 本机播放
  /// 与远端 resume 路径统一写此键空间，见 [AudiobookRepository.updatePositionMs]）。
  ///
  /// 向后兼容：旧数据只写位置不写时间戳，缺时间戳时记 0，被任何带时间戳的对端进度
  /// 在 [resolvePositionLww] 中盖过——既能读出旧本机播放位置，又不让无时间戳
  /// 旧值盖过更新的对端进度。
  @override
  Future<({int positionMs, int updatedAtMs})> getAudiobookPosition(
    String bookKey,
  ) async {
    final int pos =
        await _db.getPrefTyped<int>(audiobookPositionPrefKey(bookKey), 0);
    final int at =
        await _db.getPrefTyped<int>(audiobookPositionAtPrefKey(bookKey), 0);
    return (positionMs: pos, updatedAtMs: at);
  }

  /// 把 client 上报的有声书 [bookKey] 断点写入 host（BUG-471）。
  ///
  /// 存在性闸门：host 无该 bookKey 的 Audiobooks 行 → no-op，不写孤儿
  /// `audiobook_pos_` pref（与视频 [putVideoPosition]「视频不存在不写脏」、书
  /// [putBookProgress]「书不存在不写孤儿行」同语义）。
  ///
  /// 冲突解决「取较新时间戳」（[resolvePositionLww]）：仅当 [updatedAtMs]
  /// 严格新于 host 已存时间戳才覆盖。负位置 clamp 0。
  @override
  Future<void> putAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {
    // host 库不存在该有声书 → no-op（防任意 client 上报任意 key 写脏 prefs）。
    // srt-backed 按 bookKey 查 Audiobooks；纯 SRT standalone 按 uid 查 SrtBooks。
    // 进度 pref key = audiobook_pos_<identity>：standalone 的 identity=uid 恰为
    // SrtBook 进度键，故写穿即写到正确命名空间。
    if (await _db.getAudiobookByBookKey(bookKey) == null &&
        await _db.getSrtBookByUid(bookKey) == null) {
      return;
    }
    final ({int positionMs, int updatedAtMs}) current =
        await getAudiobookPosition(bookKey);
    final ({int positionMs, int updatedAtMs}) winner = resolvePositionLww(
      localPositionMs: current.positionMs,
      localUpdatedAtMs: current.updatedAtMs,
      remotePositionMs: positionMs < 0 ? 0 : positionMs,
      remoteUpdatedAtMs: updatedAtMs,
    );
    if (winner.updatedAtMs == current.updatedAtMs &&
        winner.positionMs == current.positionMs) {
      return; // host 已存更新或相等，no-op。
    }
    await _db.setPrefTyped<int>(
        audiobookPositionPrefKey(bookKey), winner.positionMs);
    await _db.setPrefTyped<int>(
        audiobookPositionAtPrefKey(bookKey), winner.updatedAtMs);
  }
}
