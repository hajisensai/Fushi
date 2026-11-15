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
      // 「远端已有内容」= EPUB 内容树 ∨ 漫画包内容（互联完整支持批次）∨ PDF 原件
      // （反馈 Jq1_ujHa4t）——否则 host 上已有的漫画 / PDF 会被本端当「远端无」反复推送。
      for (final RemoteBookInfo r in remoteBooks)
        sanitizeTtuFilename(r.title):
            r.hasContent || r.hasMangaContent || r.hasPdfContent,
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
    // host 能否收 PDF（`liveLibrary.pdfBooks`）：轮到第一本 PDF 时才问一次，没有
    // PDF 要推的轮次零额外请求。
    bool? hostAcceptsPdf;

    // ── Push：本端独有 → 重打包并上传 ───────────────────────────────────────
    for (final String key in diff.toPush) {
      final String title = localKeyToTitle[key] ?? key;
      // 安全检查点：上一项已完整落地，这一项还没开始。
      _checkpoint();
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
        // PDF（反馈 Jq1_ujHa4t）：包 = 书目录里的 PDF 原件，直接上传，不重打包。
        // 只推给显式宣称能收 PDF 的 host——老 host 会把它当 EPUB 导入失败，无头
        // 服务端没有 PDF 引擎；这两种对端上 PDF 留在本机（能力边界，不是错误）。
        File? upload;
        if (format == BookFormat.pdf) {
          final bool acceptsPdf = hostAcceptsPdf ??= await backend
              .hostAcceptsPdfBooks();
          if (!acceptsPdf) {
            index++;
            continue;
          }
          if (!hasExportablePdfContent(row)) {
            report.errors.add('live push book "$title": pdf file missing');
            index++;
            continue;
          }
          upload = File(pdfBookFilePath(row));
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
        if (upload == null) {
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
          upload = tmp;
        }
        // 显示名跟着书走，**身份不跟着走**（BUG-1488 定的红线）：端点寻址、
        // host 端 bookKey 派生仍恒用 raw [title]。
        final OverrideTitleEntry? override = overrideTitles[row.bookKey];
        await backend.putRemoteBook(
          title,
          upload,
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
  ///
  /// 反馈 kM-Gb_Xnu-：host 端进度改为一次 `GET /api/library/book-progress` 取齐
  /// （老 host 回落逐本 GET，4 路并发预取），不再每本书一次串行往返；判定与落地
  /// 仍逐本、按书架顺序串行（[InterconnectBookProgressSync.syncOne]），本地写入
  /// 顺序与改动前一致。
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
    // 先绑定这一轮的 host（BUG-4434）：基线读写落这台 host 的作用域，之后的 host
    // 读写都钉住它，中途换了 host 本阶段就此结束。
    try {
      await sync.bind();
    } catch (e) {
      report.noteError('live book progress', e);
      return;
    }
    // BUG-1569③：退出书的单本同步不再等整轮 sweep 结束，它在互联上只锁那本书。
    // 下面的批量读与本端快照都是「此刻」的，若在本阶段跑到某本书之前它已被单本
    // 同步改过（推了 host、或落了本地、记了新基线），拿这份旧快照去判定就会把 host
    // 的旧值当成「远端改了」落回本机——进度倒退。所以先记下每本书锁的代数，轮到
    // 这本书时代数变了就不信快照：重读 host、整套重新判定。必须在读快照**之前**记。
    final Map<String, int> lockGenerations = <String, int>{
      for (final EpubBookRow book in localBooks)
        book.bookKey: syncResourceLocks.generationOf(
          syncBookResource(book.bookKey),
        ),
    };
    // 本端进度 / 基线整轮一次读齐（三条查询）；两端已收敛的书在内存里判定后
    // 跳过，其余照旧逐本重读、判定、落地（快照只用来跳过，从不用来写）。
    final BookProgressSweepSnapshot snapshot = await sync.loadSweepSnapshot();
    final List<Future<RemoteBookProgressRead>> remotes;
    try {
      remotes = await sync.readRemoteForSweep(localBooks);
    } catch (e) {
      // 整批读不到（网络 / 鉴权 / 5xx）：本阶段整体失败，记一条，后续阶段照跑。
      report.noteError('live book progress', e);
      return;
    }
    try {
      for (int i = 0; i < localBooks.length; i++) {
        // 安全检查点：上一项已完整落地，这一项还没开始。
        _checkpoint();
        await _syncOneBookProgressLive(
          report,
          sync: sync,
          book: localBooks[i],
          index: i,
          total: localBooks.length,
          lockGeneration: lockGenerations[localBooks[i].bookKey],
          listed: remotes[i],
          snapshot: snapshot,
        );
      }
    } on InterconnectHostChangedException catch (e) {
      // 会话中途换了 host（BUG-4434）：用这台 host 的基线判另一台 host 的值会把它
      // 当成「对端单边改动」落到本机。本阶段到此为止，报一条，下一轮重新绑定。
      report.noteError('live progress: host changed mid-round', e);
    }
  }

  /// [_syncBookProgressLive] 里的一本书。会话换了 host 时
  /// [InterconnectHostChangedException] 原样抛出，由阶段统一结束。
  Future<void> _syncOneBookProgressLive(
    SyncRunReport report, {
    required InterconnectBookProgressSync sync,
    required EpubBookRow book,
    required int index,
    required int total,
    required int? lockGeneration,
    required Future<RemoteBookProgressRead> listed,
    required BookProgressSweepSnapshot snapshot,
  }) async {
    _emit(
      SyncPhase.readingData,
      itemIndex: index,
      itemTotal: total,
      title: book.title,
      itemKind: SyncItemKind.book,
    );
    final String lockKey = syncBookResource(book.bookKey);
    try {
      // 判定 + 落地在这本书的锁里做，与退出书的单本同步互斥（见上）。
      await syncResourceLocks.withResources(<String>{lockKey}, () async {
        final bool touched =
            syncResourceLocks.generationOf(lockKey) != lockGeneration;
        final RemoteBookProgress remote;
        if (touched) {
          remote = await sync.remoteProgress(book);
        } else {
          final RemoteBookProgressRead read = await listed;
          final Object? readError = read.error;
          if (readError != null) {
            Error.throwWithStackTrace(readError, read.stackTrace!);
          }
          remote = read.progress!;
        }
        final BookProgressSyncStep step = await sync.syncOne(
          book,
          remote: remote,
          snapshot: touched ? null : snapshot,
        );
        if (step.localChanged) report.localBookProgressPulled++;
        // 摘要计数（BUG-4302）只数位置真的挪动了的：落地了 host 的进度 / host 确认
        // 采纳了本机的进度（BUG-4431）。只对齐时间戳（synced）不算变化。
        if (step.action == BookProgressSyncAction.applyRemote &&
            step.localChanged) {
          report.bookProgressReceived++;
        } else if (step.pushed) {
          report.bookProgressSent++;
        }
        if (step.action == BookProgressSyncAction.conflict) {
          report.conflicts.add(
            SyncConflict(
              assetKey: book.bookKey,
              dimension: kInterconnectBookProgressDimension,
              title: book.title,
              localVersion: step.localUpdatedAtMs,
              remoteVersion: step.remoteUpdatedAtMs,
            ),
          );
        }
      });
    } on InterconnectHostChangedException {
      rethrow;
    } catch (e) {
      report.noteError('live book progress "${book.title}"', e);
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
  ///
  /// 每条「重读本端 → 判定 → 落地」在该条目的位置锁里做（BUG-4432），与播放页实时
  /// 上报、冲突弹窗互斥。
  ///
  /// [readHost]（host 清单）只用来跳过已收敛的条目：清单可能是钉住 host 之前取的、
  /// 甚至来自另一台 host 的缓存，也可能在取清单之后被实时上报推进过。所以未收敛的
  /// 条目一律在锁里经 [InterconnectPlaybackPositionSync.remotePosition]（钉住本轮
  /// 绑定的 host）重读再判定（BUG-4434）；跳过是安全的，判定只用重读的值。会话中途
  /// 换了 host 时本阶段就此结束、报一条。
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
    try {
      await sync.bind();
    } catch (e) {
      report.noteError(errorLabel, e);
      return;
    }
    // 整轮一次读齐基线 / 待确认基线（两条查询）；本端位置由调用方从 sweep 开头的
    // 偏好快照里取（零查询）。两端已收敛的条目在内存里判定后直接跳过，不再逐条
    // 读 3 次、写 2 次；其余条目照旧逐条重读、判定、落地（快照只用来跳过，从不
    // 用来写）。基线落本轮绑定的 host 的作用域（BUG-4434）。
    final PlaybackBaselineSnapshot baselines = await sync
        .loadBaselineSnapshot();
    final List<String> keys = <String>[
      for (final String key in localKeys)
        if (hostKeys.contains(key)) key, // host 无此条目：跳过。
    ];
    final SyncItemKind itemKind = switch (sync.kind) {
      PlaybackPositionKind.video => SyncItemKind.video,
      PlaybackPositionKind.audiobook => SyncItemKind.audiobook,
    };
    try {
      for (int i = 0; i < keys.length; i++) {
        // 安全检查点：上一项已完整落地，这一项还没开始。
        _checkpoint();
        await _syncOnePositionLive(
          report,
          sync: sync,
          errorLabel: errorLabel,
          key: keys[i],
          index: i,
          total: keys.length,
          itemKind: itemKind,
          readHost: readHost,
          titleOf: titleOf,
          localFromSnapshot: localFromSnapshot,
          baselines: baselines,
        );
      }
    } on InterconnectHostChangedException catch (e) {
      report.noteError('live progress: host changed mid-round', e);
    }
  }

  /// [_syncPositionsLive] 里的一条。会话换了 host 时
  /// [InterconnectHostChangedException] 原样抛出，由阶段统一结束。
  Future<void> _syncOnePositionLive(
    SyncRunReport report, {
    required InterconnectPlaybackPositionSync sync,
    required String errorLabel,
    required String key,
    required int index,
    required int total,
    required SyncItemKind itemKind,
    required Future<PlaybackPosition> Function(String key) readHost,
    required String Function(String key) titleOf,
    required PlaybackPosition Function(String key) localFromSnapshot,
    required PlaybackBaselineSnapshot baselines,
  }) async {
    // 任务面板要能说出「在同步哪个视频 / 哪本有声书」（反馈 kM-Gb_Xnu-）。
    _emit(
      SyncPhase.readingData,
      itemIndex: index,
      itemTotal: total,
      title: titleOf(key),
      itemKind: itemKind,
    );
    try {
      final PlaybackPosition listed = await readHost(key);
      if (InterconnectPlaybackPositionSync.isSettled(
        local: localFromSnapshot(key),
        remote: listed,
        snapshot: baselines,
        key: key,
      )) {
        return;
      }
      final String lockKey = syncPlaybackPositionResource(sync.kind, key);
      await syncResourceLocks.withResources(<String>{lockKey}, () async {
        // 判定与落地与播放页开播共用同一份（BUG-4436）；前置条件 = 本次判定读到
        // 的 host 位置（BUG-4432）。
        final PlaybackPositionSyncStep step = await sync.syncOne(
          key,
          remote: await sync.remotePosition(key),
        );
        // 摘要计数（BUG-4302）：落地了 host 的位置（判定后本端被改写则未落地，
        // BUG-3537）/ host 确认采纳了本机的位置（BUG-4431）。
        if (step.action == BookProgressSyncAction.applyRemote &&
            step.localChanged) {
          report.notePlaybackPositionMoved(sync.kind, received: true);
        } else if (step.push == LivePushStatus.confirmed) {
          report.notePlaybackPositionMoved(sync.kind, received: false);
        }
        if (step.action == BookProgressSyncAction.conflict) {
          report.conflicts.add(
            SyncConflict(
              assetKey: key,
              dimension: sync.dimension,
              title: titleOf(key),
              localVersion: step.local.updatedAtMs,
              remoteVersion: step.remote.updatedAtMs,
            ),
          );
        }
      });
    } on InterconnectHostChangedException {
      rethrow;
    } catch (e) {
      report.noteError('$errorLabel "$key"', e);
    }
  }
}
