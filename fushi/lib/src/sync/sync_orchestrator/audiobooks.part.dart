part of '../sync_orchestrator.dart';

/// 有声书域互联 live 进度 / 文件同步的私有实现（B2 按域拆出）。
/// 公开入口 [SyncOrchestrator.syncAudiobookPackages] 留在本体；方法逐字搬自 SyncOrchestrator。
extension _SyncOrchestratorAudiobooks on SyncOrchestrator {
  /// 互联有声书播放进度 live 双向同步（BUG-471）。
  ///
  /// 与视频 [_syncVideoProgressLive] 完全对称（共享模板 [_syncPositionsLive]）。
  /// client 听的远端有声书进度落 `audiobook_pos_<bookKey>` +
  /// `audiobook_pos_at_<bookKey>` prefs（见 [AudiobookRepository.updatePositionMs]），
  /// 但互联角色非对称：host 只跑 server，从不回灌自己的 `audiobook_pos_` pref，
  /// 故「立即同步」点了进度不过去（云后端经 SyncManager 双向文件箱正常，互联缺这一段）。
  ///
  /// 同步基底 = 「本地有 `audiobook_pos_<key>` prefs 的 bookKey」∪「本地 Audiobooks
  /// 行的 bookKey」，只对 host 也有的 bookKey 同步（host 无该有声书时其 PUT 端点
  /// 404 / 闸门 no-op，且 GET 无真相可拉，跳过省一次网络）。本地进度真相 =
  /// `audiobook_pos_<bookKey>`（位置）+ `audiobook_pos_at_<bookKey>`（时间戳，
  /// 旧数据无记 0）；写回落同一 prefs 键空间（同 resume/播放写）。
  Future<void> _syncAudiobookProgressLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    // 同步基底：本地 Audiobooks 行 ∪ 本地有 audiobook_pos_<key> prefs 的 bookKey。
    final Set<String> localKeys = <String>{
      for (final AudiobookRow ab in await _db.getAllAudiobooks()) ab.bookKey,
    };
    final Map<String, String> allPrefs = await _db.getAllPrefs();
    for (final String key in allPrefs.keys) {
      final String? bookKey = audiobookKeyFromPositionPrefKey(key);
      if (bookKey != null) localKeys.add(bookKey);
    }
    if (localKeys.isEmpty) return;

    // 有声书进度是 host-truth 模型：只对 host 也有的有声书同步。先取 host 有声书
    // 清单，只同步两端都有的键；本地独有有声书无 host 真相，跳过。
    //
    // 键必须用 [RemoteAudiobookInfo.identity]（srt-backed=bookKey；纯 SRT=uid），
    // 不能用裸 bookKey：纯 SRT standalone 的 bookKey 恒空串，用它建交集会让这类书
    // 的 `audiobook_pos_<uid>` 永远落不进 hostKeys → 听书进度跨设备完全不同步——
    // 而 host 端 get/putAudiobookPosition 本就按 identity（bookKey ∪ SrtBooks.uid）
    // 命中（BUG-1637）。空 identity（异常行）跳过不进集合。
    final Map<String, RemoteAudiobookInfo> hostById =
        <String, RemoteAudiobookInfo>{
      for (final RemoteAudiobookInfo info
          in await backend.listRemoteAudiobooks())
        if (info.identity.isNotEmpty) info.identity: info,
    };
    if (hostById.isEmpty) return;

    await _syncPositionsLive(
      report,
      errorLabel: 'live audiobook progress',
      localKeys: localKeys,
      hostKeys: hostById.keys.toSet(),
      readLocal: (String bookKey) async => (
        positionMs:
            await _db.getPrefTyped<int>(audiobookPositionPrefKey(bookKey), 0),
        updatedAtMs:
            await _db.getPrefTyped<int>(audiobookPositionAtPrefKey(bookKey), 0),
      ),
      // 新 host 清单已内联断点（互联完整支持批次）→ 免逐本 GET；旧 host 清单无此
      // 字段（0@0）→ 退回逐本 GET（真无进度的书多打一次也无害，幂等）。
      readHost: (String bookKey) async {
        final RemoteAudiobookInfo info = hostById[bookKey]!;
        if (info.positionUpdatedAtMs > 0) {
          return (
            positionMs: info.positionMs,
            updatedAtMs: info.positionUpdatedAtMs,
          );
        }
        return backend.remoteAudiobookPosition(bookKey);
      },
      pushToHost: (String bookKey, int positionMs, int updatedAtMs) =>
          backend.putRemoteAudiobookPosition(bookKey, positionMs, updatedAtMs),
      writeBackLocal: (String bookKey, int positionMs, int updatedAtMs) async {
        await _db.setPrefTyped<int>(
            audiobookPositionPrefKey(bookKey), positionMs);
        await _db.setPrefTyped<int>(
            audiobookPositionAtPrefKey(bookKey), updatedAtMs);
      },
    );

    // 有声书调轴双向收敛（互联完整支持批次；与视频 delay sweep 同范式）。
    // 「严格较新时间戳者胜」；两侧都无戳（旧数据/从未调过）无事可做。旧 host 无
    // /delay 端点 → push 404 静默吞（best-effort，不刷 report 噪音）。
    for (final String identity in localKeys) {
      final RemoteAudiobookInfo? info = hostById[identity];
      if (info == null) continue;
      try {
        final int localDelay =
            await _db.getPrefTyped<int>(audiobookDelayPrefKey(identity), 0);
        final int localAt =
            await _db.getPrefTyped<int>(audiobookDelayAtPrefKey(identity), 0);
        if (localAt > info.delayUpdatedAtMs) {
          try {
            await backend.putRemoteAudiobookDelay(
                identity, localDelay, localAt);
          } catch (e) {
            debugPrint(
                '[SyncOrchestrator] audiobook delay push "$identity" failed: $e');
          }
        } else if (info.delayUpdatedAtMs > localAt) {
          await _db.setPrefTyped<int>(
              audiobookDelayPrefKey(identity), info.delayMs);
          await _db.setPrefTyped<int>(
              audiobookDelayAtPrefKey(identity), info.delayUpdatedAtMs);
        }
      } catch (e) {
        report.noteError('live audiobook delay "$identity"', e);
      }
    }
  }

  /// 互联有声书包 live 双向同步（TODO-809：立即/自动同步双向拉取）。
  ///
  /// 直打对端 `/api/library/audiobooks` 端点，按 `bookKey` union：
  /// - Push（本端有 ∧ 远端无）→ `exportAudioDatabasePackage` 打包 → `putRemoteAudiobook`。
  /// - Pull（远端有 ∧ 本端无有声书）→ `getRemoteAudiobook` 下载 →
  ///   `importAudioDatabasePackage` 解包落盘。
  ///
  /// **Pull 防孤儿约束**：`importAudioDatabasePackage` 只 upsert Audiobooks/SrtBooks
  /// 行，不创建 EpubBooks 行。故只对「本端已有同 bookKey 的 EPUB、但当前缺音频」的
  /// 远端项拉取——否则会落下没有书可绑的孤儿有声书行（这正是历史上选 push-only 的
  /// 动机）。无对应本地 EPUB 的远端有声书跳过并记一条 info 级 error，留给手动下载
  /// （书架远端书卡 / 同步对比对话框）补音频。拉取时用本地 EPUB 的 bookKey 作
  /// `bookKeyOverride`，保证写入行与本地 EPUB 字节相等可配对（徽章亮）。
  ///
  /// 仅当 client syncAudioBookFiles 开且 isInterconnect 时由 [run] 调用。
  /// 进度走 [SyncPhase.audiobooks]，临时文件 finally 清理，逐项错误进 report.errors 不中断。
  Future<void> _syncAudiobooksLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    final List<RemoteAudiobookInfo> remoteAudiobooks =
        await backend.listRemoteAudiobooks();
    final List<AudiobookRow> localAudiobooks = await _db.getAllAudiobooks();
    final List<EpubBookRow> localBooks = await _db.getAllEpubBooks();

    final Set<String> localKeys = <String>{
      for (final AudiobookRow ab in localAudiobooks) ab.bookKey,
    };
    // 纯 SRT（standalone）远端有声书（bookKey 空、身份=uid）**不进自动 union**：与
    // 远端独有 EPUB 一样是「手动下载才落地」（TODO-1291 / 书架远端占位卡），自动
    // sweep 只处理 srt-backed（bookKey 非空）有声书文件补拉，避免把独有 standalone
    // 书自动灌进对端，也避免空 bookKey 污染 diff。
    final Set<String> remoteKeys = <String>{
      for (final RemoteAudiobookInfo r in remoteAudiobooks)
        if (r.bookKey.isNotEmpty) r.bookKey,
    };
    // 本端已有 EPUB 的 bookKey 集合：Pull 只对「本端有书但缺音频」的远端项动作，
    // 避免落下无 EpubBooks 行可绑的孤儿有声书（importAudioDatabasePackage 不建书行）。
    final Set<String> localBookKeys = <String>{
      for (final EpubBookRow b in localBooks) b.bookKey,
    };

    final SyncKeyDiff diff = computeKeyUnionDiff(
      localKeys: localKeys,
      remoteKeys: remoteKeys,
    );

    // toPullAudioOnly（场景B）= 远端有 ∧ 本端无有声书 ∧ 本端已有同 bookKey
    // EPUB → 只补音频不重导 EPUB。这是「同步有声书文件」开关下**唯一**的 pull
    // 语义：只对本端已在库的书补/拉其音频文件。
    //
    // TODO-1291（用户决策 A · 解耦）：远端独有（本端完全没有这本书）的书
    // **不**在自动同步里导入/灌书架，即便远端书带有声书且 hasContent。这类书回归
    // 手动下载入口（compare 对比页 / 书架远端卡），与本类文档契约（见类头
    // :126-130「remote-only EPUBs stay remote until the user explicitly
    // downloads them」）一致。历史 TODO-873 的 toPullFullBook 自动灌书路径已在此
    // 摘除——它把「开启同步有声书文件」误当成「自动把远端独有书拉进书架」。
    final List<String> toPullAudioOnly = <String>[
      for (final String key in diff.toPull)
        if (localBookKeys.contains(key)) key,
    ];

    final int total = diff.toPush.length + toPullAudioOnly.length;
    int index = 0;

    // ── Push：本端独有 → 打包并上传 ─────────────────────────────────────────
    for (final String key in diff.toPush) {
      _emit(SyncPhase.audiobooks,
          itemIndex: index, itemTotal: total, title: key);
      File? tmp;
      try {
        final SrtBookRow? srt = await _db.getSrtBookByBookKey(key);
        if (srt == null) {
          report.errors
              .add('live push audiobook "$key": srtBook not found, skipping');
          index++;
          continue;
        }
        tmp = _tmpFile('.fushiaudio');
        await _packages.exportAudioDatabasePackage(
          bookKey: key,
          srtBookUid: srt.uid,
          outputFile: tmp,
        );
        await backend.putRemoteAudiobook(
          key,
          tmp,
          onProgress: (double f) => _emit(SyncPhase.audiobooks,
              itemIndex: index, itemTotal: total, title: key, fileFraction: f),
        );
        report.audiobooksExported++;
      } catch (e) {
        report.noteError('live push audiobook "$key"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    // ── Pull A（场景B）：远端有、本端有书但缺音频 → 下载并解包落盘 ────────────
    for (final String key in toPullAudioOnly) {
      _emit(SyncPhase.audiobooks,
          itemIndex: index, itemTotal: total, title: key);
      File? tmp;
      try {
        tmp = _tmpFile('.fushiaudio');
        await backend.getRemoteAudiobook(
          key,
          tmp,
          onProgress: (double f) => _emit(SyncPhase.audiobooks,
              itemIndex: index, itemTotal: total, title: key, fileFraction: f),
        );
        // 用本地 EPUB 的 bookKey 作 override：远端 key 已等于本地 EPUB 的 bookKey
        // （toPull 已由 localBookKeys 筛过），显式 override 保写入行与 EPUB 可配对。
        await _packages.importAudioDatabasePackage(
          packageFile: tmp,
          audioDatabaseRoot: _audioDatabaseRoot,
          bookKeyOverride: key,
        );
        report.audiobooksImported++;
      } catch (e) {
        report.noteError('live pull audiobook "$key"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }
}
