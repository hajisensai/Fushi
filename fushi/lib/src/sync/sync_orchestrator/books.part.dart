part of '../sync_orchestrator.dart';

/// 书籍域互联 live 内容 / 进度 / 阅读位置同步的私有实现（B2 按域拆出）。
/// 公开入口 [SyncOrchestrator.importRemoteBooks] 留在本体；方法逐字搬自 SyncOrchestrator。
extension _SyncOrchestratorBooks on SyncOrchestrator {
  /// 互联书籍内容 live 上传。
  ///
  /// 直打对端 `/api/library/books` 端点，按 `sanitizeTtuFilename(title)` 只处理
  /// toPush：本端有 && 远端无 → `repackageExtractedEpub` 重打包 →
  /// `putRemoteBook` 上传。远端独有书籍留给 compare/interconnect UI 手动下载。
  ///
  /// 仅当 client syncContent / syncMangaContent 任一开时由 [run] 调用；EPUB 等受
  /// syncContent、漫画受 syncMangaContent 门控。进度走 [SyncPhase.books]，
  /// 临时文件 finally 清理，逐项错误进 [report.errors] 不中断整体。
  ///
  /// **删除意图先于推送**（反馈 Et3pmRzo0k）：host 上被「从所有设备删除」的书，本机
  /// 删除前就有的那份不进 diff（[_loadHostPushVetoTombstones]）——否则 host 导入会清掉
  /// 墓碑、删除被静默撤销。本机删后重新导入的（`localAddedAt` 晚于删除）照推，host
  /// 端同一判据放行（[kPeerPushPresentSinceHeader]）。书籍删除本身经
  /// [_syncDeletionTombstonesLive] 双向传播。
  Future<void> _syncBooksContentLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    final DeletionTombstoneEntries? hostTombstones =
        await _loadHostPushVetoTombstones(report, backend, 'live push books');
    if (hostTombstones == null) return;
    final List<RemoteBookInfo> remoteBooks = await backend.listRemoteBooks();
    // 书籍（EPUB 等）与漫画各看各的上传开关（所有者 2026-10-21：书籍和漫画分开）：
    // 开关关着的那类书不进 diff，既不推也不计进度条总数。
    final List<EpubBookRow> localBooks = <EpubBookRow>[
      for (final EpubBookRow b in await _db.getAllEpubBooks())
        if (isBookContentSyncEnabled(
              b,
              syncContent: syncContent,
              syncMangaContent: syncMangaContent,
            ) &&
            // host 端按 sanitizeTtuFilename(书名) 派生键入库、记墓碑；本机行键通常与之
            // 相同，不同时（落地键带后缀等）两个都查。
            !_hostVetoesPush(
              hostTombstones,
              kinds: const <SyncTombstoneKind>[SyncTombstoneKind.book],
              itemKeys: <String>{b.bookKey, sanitizeTtuFilename(b.title)},
              presentSinceAt: b.localAddedAt,
            ))
          b,
    ];

    final Set<String> localKeys = <String>{
      for (final EpubBookRow b in localBooks) sanitizeTtuFilename(b.title),
    };
    final Map<String, bool> remoteKeyHasContent = <String, bool>{
      // 「远端已有内容」= EPUB 内容树 ∨ 漫画包内容（互联完整支持批次）——否则
      // host 上已有的漫画会被本端当「远端无」反复推送。
      for (final RemoteBookInfo r in remoteBooks)
        sanitizeTtuFilename(r.title): r.hasContent || r.hasMangaContent,
    };

    // 按 sanitizeTtuFilename(title) union 计算 diff。
    final BookSyncDiff diff = computeBookSyncDiff(
      localKeys: localKeys,
      remoteKeyHasContent: remoteKeyHasContent,
    );

    // 需要本地 title 原始值用于端点调用（端点按原始 title 寻址）。
    final Map<String, String> localKeyToTitle = <String, String>{
      for (final EpubBookRow b in localBooks)
        sanitizeTtuFilename(b.title): b.title,
    };

    // BUG-1503：本机用户给这些书改的名字 + LWW 戳，随上传一起走 header。一趟读
    // 完（推多本书只查一次偏好表），没改过名的书查不到 → 不发 header。
    final Map<String, OverrideTitleEntry> overrideTitles =
        await readOverrideTitlesByBookKey(_db);

    final int total = diff.toPush.length;
    int index = 0;

    // ── Push：本端独有 → 重打包并上传 ───────────────────────────────────────
    for (final String key in diff.toPush) {
      final String title = localKeyToTitle[key] ?? key;
      _emit(SyncPhase.books, itemIndex: index, itemTotal: total, title: title);
      File? tmp;
      try {
        // 找到本地行取 extractDir。
        final EpubBookRow? row = localBooks.cast<EpubBookRow?>().firstWhere(
          (EpubBookRow? b) => sanitizeTtuFilename(b!.title) == key,
          orElse: () => null,
        );
        if (row == null ||
            row.extractDir.isEmpty ||
            !Directory(row.extractDir).existsSync()) {
          // 本地内容不可用，跳过（与 importRemoteBooks 对称语义）。
          report.errors.add(
            'live push book "$title": extractDir missing or empty',
          );
          index++;
          continue;
        }
        final BookFormat format = BookFormat.parseOrEpub(row.format);
        if (format == BookFormat.pdf) {
          // PDF 无互联内容通道（互联全域盘点已记录）。此前无 format 过滤时每本
          // 漫画/PDF 每轮同步都稳定产出一条 repackage 失败噪音错误——静默跳过。
          index++;
          continue;
        }
        // 在线合集只有元数据占位，没有可上传的漫画页图。
        if (format == BookFormat.manga &&
            !hasExportableMangaContent(row.extractDir)) {
          index++;
          continue;
        }
        // 在线小说占位书（LNReader）同理：推过去是一本补不全的书。
        if (isLnReaderOnlineBookMetadata(row.sourceMetadata)) {
          index++;
          continue;
        }
        tmp = _tmpFile('.epub');
        // 漫画 → 书目录整树 zip（manga.json 标记，host importBook 内容嗅探分流）；
        // EPUB → 既有 repackage。
        final bool built = format == BookFormat.manga
            ? await repackageMangaBook(row.extractDir, tmp.path)
            : await repackageExtractedEpub(row.extractDir, tmp.path);
        if (!built) {
          report.errors.add(
            'live push book "$title": repackage produced no output',
          );
          index++;
          continue;
        }
        // 显示名跟着书走，**身份不跟着走**（BUG-1488 定的红线）：端点寻址、
        // host 端 bookKey 派生仍恒用 raw [title]。
        final OverrideTitleEntry? override = overrideTitles[row.bookKey];
        await backend.putRemoteBook(
          title,
          tmp,
          displayTitle: override?.title,
          displayTitleAt: override?.updatedAt ?? 0,
          presentSinceAt: row.localAddedAt,
          onProgress: (double f, [int? b]) => _emit(
            SyncPhase.books,
            itemIndex: index,
            itemTotal: total,
            title: title,
            fileFraction: f,
            fileBytes: b,
          ),
        );
      } catch (e) {
        report.noteError('live push book "$title"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }

  /// 互联书籍阅读进度 live 双向同步（TODO-767 → BUG-2506 三方判定）。
  ///
  /// 遍历本地 `epub_books`，对每本书：GET host 真相源进度（[RemoteBookClient
  /// .remoteBookProgress]，host 直读自己的 `reader_positions`）+ 读本地
  /// `reader_positions` + 读上次两端达成一致的**位置基线**，用
  /// [resolveBookProgressThreeWay] 判定：只一端偏离基线 → 那端胜出并落到另一端；
  /// 两端位置一致 → 只对齐时间戳；**两端都偏离且互不相同 → 冲突**，谁都不覆盖，
  /// 记进 [report.conflicts] 交冲突弹窗（[SyncCompareDialog]）让用户选。
  ///
  /// 修复根因（BUG-2506）：此前这里是纯「取较新时间戳」LWW，没有冲突概念——host 上
  /// 只要重开过书（位置没动时间戳也刷新）就在下一轮 sweep 把 client 的位置静默盖掉；
  /// 而带三方冲突门的 SyncManager 路径对互联只比较 host 上的 WebDAV 文件箱
  /// （client 自己写的），冲突条件结构上永远为假。IO 落地在
  /// [InterconnectBookProgressSync]，与冲突弹窗的手动解决共用同一份。
  ///
  /// 逐本错误进 [report.errors] 不中断整体。
  Future<void> _syncBookProgressLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    final InterconnectBookProgressSync sync = InterconnectBookProgressSync(
      db: _db,
      backend: backend,
    );
    final List<EpubBookRow> localBooks = await _db.getAllEpubBooks();
    if (localBooks.isEmpty) return;
    // 本端进度 / 基线整轮一次读齐（三条查询）；两端已收敛的书在内存里判定后
    // 跳过，其余照旧逐本重读、判定、落地（快照只用来跳过，从不用来写）。
    final BookProgressSweepSnapshot snapshot = await sync.loadSweepSnapshot();
    for (final EpubBookRow book in localBooks) {
      try {
        final RemoteBookProgress remote = await sync.remoteProgress(book);
        if (InterconnectBookProgressSync.isSettled(
          book: book,
          local: InterconnectBookProgressSync.localProgressFromSnapshot(
            book,
            snapshot,
          ),
          remote: remote,
          snapshot: snapshot,
        )) {
          continue;
        }
        final RemoteBookProgress local = await sync.localProgress(book);
        final BookProgressSyncAction action = await sync.decide(
          book,
          local: local,
          remote: remote,
        );
        switch (action) {
          case BookProgressSyncAction.synced:
            // BUG-686: a host-newer progress pull lands in reader_positions but
            // writes no book content, so it must still flag the shelf for a
            // refresh — the cached fushiBooksProvider otherwise keeps showing
            // the pre-sync progress bar and the sync looks like it did nothing.
            if (await sync.alignSynced(book, local: local, remote: remote)) {
              report.localBookProgressPulled++;
            }
          case BookProgressSyncAction.pushLocal:
            await sync.pushLocal(book, local: local, remote: remote);
          case BookProgressSyncAction.applyRemote:
            // BUG-3537：判定后本地被改写则不落地（比较后写入），不计「已拉取」。
            if (await sync.applyRemote(book, remote, local: local)) {
              report.localBookProgressPulled++;
            }
          case BookProgressSyncAction.conflict:
            report.conflicts.add(
              SyncConflict(
                assetKey: book.bookKey,
                dimension: kInterconnectBookProgressDimension,
                title: book.title,
                localVersion: local.updatedAtMs,
                remoteVersion: remote.updatedAtMs,
              ),
            );
        }
      } catch (e) {
        report.noteError('live book progress "${book.title}"', e);
      }
    }
  }

  /// 互联播放断点 live 双向 sweep 的共享模板（视频 / 有声书）。
  ///
  /// 两条 sweep 只差「哪种条目」与「host 位置从哪读」，读写与基线都在
  /// [InterconnectPlaybackPositionSync]。对 [localKeys] ∩ [hostKeys] 里的每个键：
  /// 读本地位置、[readHost] 取 host 位置、读位置基线，用
  /// [resolvePlaybackPositionThreeWay] 判定（BUG-3367，此前是纯「取较新时间戳」
  /// LWW，两端各自看过时后同步的一端被静默盖掉）：
  /// - 只一端偏离基线 → 那端胜出并落到另一端；
  /// - 两端位置一致 → 只对齐时间戳、记基线；
  /// - **两端都偏离且互不相同 → 冲突**，谁都不覆盖，记进 [report.conflicts] 交
  ///   冲突弹窗让用户选（标题取 [titleOf]）。
  ///
  /// 只对 host 也有的键同步（本地独有条目无 host 真相，跳过）；逐条错误以
  /// `[errorLabel] "<key>": <e>` 进 [report.errors] 不中断整体。host 清单的获取
  /// 与两侧空集合的早退仍在各调用方（保持既有网络行为不变）。
  Future<void> _syncPositionsLive(
    SyncRunReport report, {
    required InterconnectPlaybackPositionSync sync,
    required String errorLabel,
    required Set<String> localKeys,
    required Set<String> hostKeys,
    required Future<PlaybackPosition> Function(String key) readHost,
    required String Function(String key) titleOf,
    required PlaybackPosition Function(String key) localFromSnapshot,
  }) async {
    // 整轮一次读齐基线 / 待确认基线（两条查询）；本端位置由调用方从 sweep 开头的
    // 偏好快照里取（零查询）。两端已收敛的条目在内存里判定后直接跳过，不再逐条
    // 读 3 次、写 2 次；其余条目照旧逐条重读、判定、落地（快照只用来跳过，从不
    // 用来写）。
    final PlaybackBaselineSnapshot baselines = await sync
        .loadBaselineSnapshot();
    for (final String key in localKeys) {
      if (!hostKeys.contains(key)) continue; // host 无此条目：跳过。
      try {
        final PlaybackPosition host = await readHost(key);
        if (InterconnectPlaybackPositionSync.isSettled(
          local: localFromSnapshot(key),
          remote: host,
          snapshot: baselines,
          key: key,
        )) {
          continue;
        }
        final PlaybackPosition local = await sync.localPosition(key);
        final BookProgressSyncAction action = await sync.decide(
          key,
          local: local,
          remote: host,
        );
        switch (action) {
          case BookProgressSyncAction.synced:
            await sync.alignSynced(key, local: local, remote: host);
          case BookProgressSyncAction.pushLocal:
            await sync.pushLocal(key, local: local, remote: host);
          case BookProgressSyncAction.applyRemote:
            await sync.applyRemote(key, host, local: local);
          case BookProgressSyncAction.conflict:
            report.conflicts.add(
              SyncConflict(
                assetKey: key,
                dimension: sync.dimension,
                title: titleOf(key),
                localVersion: local.updatedAtMs,
                remoteVersion: host.updatedAtMs,
              ),
            );
        }
      } catch (e) {
        report.noteError('$errorLabel "$key"', e);
      }
    }
  }
}
