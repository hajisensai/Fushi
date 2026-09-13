part of '../sync_orchestrator.dart';

/// 删除墓碑（deletion tombstones）互联 live 推送/拉取的私有实现（B2 按域拆出）。
/// 公开入口 [SyncOrchestrator.syncDeletionTombstones] 留在本体；方法逐字搬自 SyncOrchestrator。
extension _SyncOrchestratorTombstones on SyncOrchestrator {
  /// 收集本设备当前在库的资产（按 mediaType 分组 → `itemKey → 存在起始时刻`），供删除
  /// 墓碑消费端算 deleteLocal 候选（远端有删除标记 ∧ 本地仍在库 ∧ 标记管得着这条）。
  /// itemKey 与写墓碑点严格一致：book/audiobook = bookKey（[writeSyncDeletionTombstone]
  /// 调用点 reader_fushi_source / audiobook），video = bookUid（video_book_repository），
  /// localaudio = displayName，srtbook = srt_books.uid（仅 standalone，见下）。
  ///
  /// 键一律用 [SyncTombstoneKind.dbValue] 而非裸字符串字面量：这张 map 与写墓碑点必须
  /// 逐字一致，拼错一个字符的后果是「对端删了、本地永远不弹确认」这种静默失效。
  ///
  /// BUG-2044：值是**存在起始时刻**而不再是单纯的「在不在库」。删除后又重新加回来的条目
  /// 时刻晚于墓碑 deletedAt，[tombstoneAppliesTo] 据此把它排除在候选之外——否则本机自己
  /// 取消收藏产生、发布到远端后再也不会被 GC 的那条墓碑，会在用户重新收藏同一句之后被读
  /// 回来，弹「其他设备已删除」问用户要不要删掉自己刚收藏的东西。
  Future<DeletionPresentEntries> _collectPresentDeletionKeys() async {
    return <String, Map<String, int?>>{
      SyncTombstoneKind.book.dbValue: <String, int?>{
        for (final EpubBookRow r in await _db.getAllEpubBooks())
          r.bookKey: r.importedAt,
      },
      // 有声书表没有自己的导入时刻列，且与 epub 共享 bookKey——借 epub 的 importedAt
      // 会把「书早就在、有声书是后加的」记成前者。宁可 null（多问一次），不编造时刻。
      SyncTombstoneKind.audiobook.dbValue: <String, int?>{
        for (final AudiobookRow r in await _db.getAllAudiobooks())
          r.bookKey: null,
      },
      // 纯字幕书（standalone SRT）身份 = uid。**只收 bookKey 为空的行**：与
      // [SrtBookRepository.delete] 的写墓碑判据同源——srt-backed 行的身份是 bookKey，
      // 已由上面的 book 键覆盖，重复收进来会让同一资产在对端弹两条确认（TODO-2470）。
      SyncTombstoneKind.srtbook.dbValue: <String, int?>{
        for (final SrtBookRow r in await _db.getAllSrtBooks())
          if (r.bookKey.isEmpty) r.uid: r.importedAt,
      },
      SyncTombstoneKind.video.dbValue: <String, int?>{
        for (final VideoBookRow r in await _db.allVideoBooks())
          r.bookUid: r.importedAt,
      },
      // localaudio 条目不记录加入时刻 → null = 无从仲裁，保持「只看在不在库」的旧语义。
      SyncTombstoneKind.localaudio.dbValue: <String, int?>{
        for (final LocalAudioDbEntry e in localAudioEntries)
          e.displayName: null,
      },
      SyncTombstoneKind.favoriteword.dbValue: <String, int?>{
        for (final FavoriteWordRow r in await _db.getAllFavoriteWords())
          FushiDatabase.favoriteWordItemKey(
              r.expression, r.reading, r.sourceType): r.createdAt,
      },
      // 收藏句无稳定 id，用内容键（[FavoriteSentenceRepository.itemKeyOf]）；与写墓碑点、
      // aggregate 去重键同源。时刻取 createdAt——重新收藏会生成新的 createdAt，正是
      // BUG-2044 仲裁所依据的那个时刻。
      SyncTombstoneKind.favoritesentence.dbValue: <String, int?>{
        for (final FavoriteSentence s
            in await FavoriteSentenceRepository(_db).getAll())
          FavoriteSentenceRepository.itemKeyOf(s):
              s.createdAt.millisecondsSinceEpoch,
      },
    };
  }

  /// 删除墓碑同步（互联 host API 通道），**双向**：
  ///
  /// 1. 推送（client→host，[_pushDeletionTombstonesLive]）：把本机「从所有设备删除」
  ///    产生的墓碑真的删到对端 host 上。host 自己的 delete 会写它自己的墓碑，于是
  ///    第三台设备下轮照常收到确认提示——链路闭合。
  /// 2. 消费（host→client）：GET host 墓碑（老 host 404 → null 优雅跳过）→ 与本地在库键
  ///    求交 deleteLocal 候选 → 过基线守卫 → 塞 report，UI 弹逐条确认。
  ///
  /// 此处曾是 GET-only（注释原文「client 自身删除不经此推给 host，各端自行确认删除」），
  /// 后果是勾了「从所有设备删除」对互联对端完全无效——墓碑只留在本地表里没人发布。
  /// 消费语义仍与云 [syncDeletionTombstones] 一致；推送是互联独有（云通道的对应动作是
  /// 往 `__tombstones__` 写标记，两者各记各的基线，见
  /// [SyncRepository.getDeletionTombstonesPushBaselineMs]）。
  Future<void> _syncDeletionTombstonesLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      final int nextBaseline = DateTime.now().millisecondsSinceEpoch;
      // 先推后拉：本机的删除意图先发出去，再看对端有什么要删的。两步共用同一个
      // nextBaseline（预取，防 IO 期间时钟漂移造成窗口空洞）。推送整段自带 try，
      // 失败不挡消费。
      await _pushDeletionTombstonesLive(report, backend, nextBaseline);

      final List<({String mediaType, String itemKey, int deletedAt})>? remote =
          await backend.getRemoteDeletionTombstones();
      if (remote == null) return; // 老 host 无 /api/tombstones 端点，优雅跳过。

      final DeletionTombstoneEntries remoteTombstones =
          <String, Map<String, int>>{};
      for (final r in remote) {
        final Map<String, int> byKey =
            remoteTombstones.putIfAbsent(r.mediaType, () => <String, int>{});
        final int? prev = byKey[r.itemKey];
        if (prev == null || r.deletedAt > prev) {
          byKey[r.itemKey] = r.deletedAt;
        }
      }

      final SyncRepository repo = SyncRepository(_db);
      final DeletionPresentEntries present =
          await _collectPresentDeletionKeys();
      int baseline = await repo.getDeletionTombstonesBaselineMs(_scope);
      if (baseline > nextBaseline) baseline = nextBaseline;

      final List<DeletionPropagationCandidate> raw = computeDeletionPropagation(
        localTombstones: const <String, Map<String, int>>{},
        remoteTombstones: remoteTombstones,
        localPresent: present,
        remotePresent: const <String, Map<String, int?>>{},
      );
      for (final DeletionPropagationCandidate c in raw) {
        if (c.direction != DeletionPropagationDirection.deleteLocal) continue;
        final int? at = remoteTombstones[c.mediaType]?[c.itemKey];
        if (at == null || at <= baseline) continue;
        report.deletionCandidates.add(c);
        report.noteDeletionHighWater(_scope, at);
      }
    } catch (e) {
      report.noteError('deletion tombstones live sync', e);
    }
  }

  /// 把本机未推送的删除墓碑推给对端 host（client→host，「从所有设备删除」的落地端）。
  ///
  /// 墓碑只在用户显式选 [DeleteScope.syncEverywhere] 时才写（各实体删除路径的门控），
  /// 所以走到这里的每一条都是用户明确要求「所有设备都删」的条目——推送不需要再问一次。
  ///
  /// 因果轴用 [SyncRepository.getDeletionTombstonesPushBaselineMs]：只推
  /// `baseline < deletedAt <= nextBaseline` 的墓碑，整批成功才推进基线。**不碰墓碑行上的
  /// `remotePublishedAt`**——那是云通道 `__tombstones__` 的账，互联去标它会让同时配了云
  /// 备份的设备永远跳过这条、只连云的第三台设备再也收不到这次删除。
  ///
  /// 两类失败区别对待：
  /// * **异常**（网络 / host 5xx）→ 不推进基线，下轮整批重试。这类失败通常是整体性的
  ///   （断网），整批重试正是想要的；DELETE 端点幂等，重推已成功的无害。
  /// * **host 不支持**（视频 DELETE 端点 404/405 = 对端版本过旧）→ 记 `report.errors`
  ///   但**不**阻塞基线。能力缺失不是暂时性故障，为它永久卡住基线会让书 / 有声书的
  ///   删除每轮无谓重推。代价是对端升级前的这条视频删除会漏掉——UI 侧长按删除路径会
  ///   直接提示「对端版本过旧」，同步路径则留在日志里。
  Future<void> _pushDeletionTombstonesLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
    int nextBaseline,
  ) async {
    try {
      final SyncRepository repo = SyncRepository(_db);
      int baseline = await repo.getDeletionTombstonesPushBaselineMs();
      // 时钟回拨钳制：基线晚于本轮取的 now 时按 now 算，否则一次回拨会把窗口永久关死。
      if (baseline > nextBaseline) baseline = nextBaseline;

      final List<SyncDeletionTombstoneRow> rows =
          await _db.getSyncDeletionTombstones();
      bool retryable = false;
      for (final SyncDeletionTombstoneRow row in rows) {
        // 窗口两端都要卡：晚于 nextBaseline 的（本地时钟超前写出的未来戳）留到下轮，
        // 否则推进基线会把它一并盖掉、这条删除就此蒸发。
        if (row.deletedAt <= baseline || row.deletedAt > nextBaseline) continue;
        final SyncTombstoneKind? kind =
            SyncTombstoneKind.tryParse(row.mediaType);
        // 未知 kind = 比本端新的版本写的墓碑，本端不认识就别猜着删（前向兼容）。
        if (kind == null) continue;
        if (!_hasInterconnectDeletionChannel(kind)) continue;
        try {
          final bool supported =
              await _pushOneDeletionLive(backend, kind, row.itemKey);
          if (!supported) {
            report.errors.add(
              'host does not support deleting ${row.mediaType} '
              '"${row.itemKey}" (peer app too old); skipped',
            );
          }
        } catch (e) {
          retryable = true;
          report.noteError(
            'deletion push ${row.mediaType}/${row.itemKey}',
            e,
          );
        }
      }
      if (!retryable) {
        await repo.setDeletionTombstonesPushBaselineMs(nextBaseline);
      }
    } catch (e) {
      report.noteError('deletion tombstones live push', e);
    }
  }

  /// 该 kind 在互联 live 通道上有没有删除端点。
  ///
  /// 收藏词 / 收藏句没有：它们经聚合快照通道同步，而 `applyAggregateSnapshot` 按设计
  /// 只做 MAX / 并集（删除不跨端传播）。这里如实跳过——不假装推过（那会静默丢删除），
  /// 也不算作失败（那会为一件永远做不成的事永久卡住基线）。
  static bool _hasInterconnectDeletionChannel(SyncTombstoneKind kind) {
    switch (kind) {
      case SyncTombstoneKind.book:
      case SyncTombstoneKind.audiobook:
      case SyncTombstoneKind.srtbook:
      case SyncTombstoneKind.localaudio:
      case SyncTombstoneKind.video:
        return true;
      case SyncTombstoneKind.favoriteword:
      case SyncTombstoneKind.favoritesentence:
        return false;
    }
  }

  /// 按 kind 分派到对应的 host 删除端点。返回 host 是否支持该删除（false = 对端版本
  /// 过旧，端点 404/405）；其余失败照常抛给调用方计入 retryable。
  ///
  /// 纯字幕书（srtbook）与有声书共用 `DELETE /api/library/audiobooks/<identity>`：host
  /// 端 identity 解析同时查 `Audiobooks(bookKey)` 与 `SrtBooks(uid)`，两种键都能命中。
  Future<bool> _pushOneDeletionLive(
    InterconnectSyncBackend backend,
    SyncTombstoneKind kind,
    String itemKey,
  ) async {
    switch (kind) {
      case SyncTombstoneKind.book:
        await backend.deleteRemoteBook(itemKey);
        return true;
      case SyncTombstoneKind.audiobook:
      case SyncTombstoneKind.srtbook:
        await backend.deleteRemoteAudiobook(itemKey);
        return true;
      case SyncTombstoneKind.localaudio:
        await backend.deleteRemoteLocalAudio(itemKey);
        return true;
      case SyncTombstoneKind.video:
        // 唯一会如实报「不支持」的一条：视频删除端点是本次新增的，旧 host 没有。
        return backend.deleteRemoteVideo(itemKey);
      case SyncTombstoneKind.favoriteword:
      case SyncTombstoneKind.favoritesentence:
        // [_hasInterconnectDeletionChannel] 已挡在前面，走不到这里。
        return true;
    }
  }
}
