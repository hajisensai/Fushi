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
  /// 仅当 client syncContent 开时由 [run] 调用。进度走 [SyncPhase.books]，
  /// 临时文件 finally 清理，逐项错误进 [report.errors] 不中断整体。
  ///
  /// **删除传播**：现有实现不传播书籍删除（SyncManager 云路径同语义）。
  /// 若后续需要互联书籍删除传播，参考词典删除传播（BUG-086）扩展此方法。
  Future<void> _syncBooksContentLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    final List<RemoteBookInfo> remoteBooks = await backend.listRemoteBooks();
    final List<EpubBookRow> localBooks = await _db.getAllEpubBooks();

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
          report.errors
              .add('live push book "$title": extractDir missing or empty');
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
        tmp = _tmpFile('.epub');
        // 漫画 → 书目录整树 zip（manga.json 标记，host importBook 内容嗅探分流）；
        // EPUB → 既有 repackage。
        final bool built = format == BookFormat.manga
            ? await repackageMangaBook(row.extractDir, tmp.path)
            : await repackageExtractedEpub(row.extractDir, tmp.path);
        if (!built) {
          report.errors
              .add('live push book "$title": repackage produced no output');
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
          onProgress: (double f) => _emit(SyncPhase.books,
              itemIndex: index,
              itemTotal: total,
              title: title,
              fileFraction: f),
        );
      } catch (e) {
        report.noteError('live push book "$title"', e);
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }

  /// 互联书籍阅读进度 live 双向同步（TODO-767 → BUG-2497 三方判定）。
  ///
  /// 遍历本地 `epub_books`，对每本书：GET host 真相源进度（[RemoteBookClient
  /// .remoteBookProgress]，host 直读自己的 `reader_positions`）+ 读本地
  /// `reader_positions` + 读上次两端达成一致的**位置基线**，用
  /// [resolveBookProgressThreeWay] 判定：只一端偏离基线 → 那端胜出并落到另一端；
  /// 两端位置一致 → 只对齐时间戳；**两端都偏离且互不相同 → 冲突**，谁都不覆盖，
  /// 记进 [report.conflicts] 交冲突弹窗（[SyncCompareDialog]）让用户选。
  ///
  /// 修复根因（BUG-2497）：此前这里是纯「取较新时间戳」LWW，没有冲突概念——host 上
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
    final InterconnectBookProgressSync sync =
        InterconnectBookProgressSync(db: _db, backend: backend);
    final List<EpubBookRow> localBooks = await _db.getAllEpubBooks();
    for (final EpubBookRow book in localBooks) {
      try {
        final RemoteBookProgress remote = await sync.remoteProgress(book);
        final RemoteBookProgress local = await sync.localProgress(book);
        final BookProgressBaseline? base = await sync.baseline(book);
        final BookProgressSyncAction action = resolveBookProgressThreeWay(
          local: local,
          remote: remote,
          base: base,
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
            await sync.applyRemote(book, remote);
            report.localBookProgressPulled++;
          case BookProgressSyncAction.conflict:
            report.conflicts.add(SyncConflict(
              assetKey: book.bookKey,
              dimension: kInterconnectBookProgressDimension,
              title: book.title,
              localVersion: local.updatedAtMs,
              remoteVersion: remote.updatedAtMs,
            ));
        }
      } catch (e) {
        report.noteError('live book progress "${book.title}"', e);
      }
    }
  }

  /// 互联播放断点 live 双向 sweep 的共享模板（视频 / 有声书）。
  ///
  /// 两条 sweep 历史上 ~90% 逐字同构，仅四个探针不同，命名统一轮收口于此。
  /// 对 [localKeys] ∩ [hostKeys] 里的每个键：
  /// 1. [readLocal] 取本地 (位置, 时间戳)，[readHost] 取 host (位置, 时间戳)；
  /// 2. [resolvePositionLww]「取较新时间戳」选胜者；
  /// 3. 本地→host：胜者新于 host（或同戳不同位）→ [pushToHost] 上报
  ///    （host 端再取较新，幂等安全）；
  /// 4. host→本地：胜者不同于本地 → [writeBackLocal] 写回。
  ///
  /// 只对 host 也有的键同步（本地独有条目无 host 真相，跳过）；逐条错误以
  /// `[errorLabel] "<key>": <e>` 进 [report.errors] 不中断整体。host 清单的获取
  /// 与两侧空集合的早退仍在各调用方（保持既有网络行为不变）。
  Future<void> _syncPositionsLive(
    SyncRunReport report, {
    required String errorLabel,
    required Set<String> localKeys,
    required Set<String> hostKeys,
    required Future<({int positionMs, int updatedAtMs})> Function(String key)
        readLocal,
    required Future<({int positionMs, int updatedAtMs})> Function(String key)
        readHost,
    required Future<void> Function(String key, int positionMs, int updatedAtMs)
        pushToHost,
    required Future<void> Function(String key, int positionMs, int updatedAtMs)
        writeBackLocal,
  }) async {
    for (final String key in localKeys) {
      if (!hostKeys.contains(key)) continue; // host 无此条目：跳过。
      try {
        final ({int positionMs, int updatedAtMs}) local = await readLocal(key);
        final ({int positionMs, int updatedAtMs}) host = await readHost(key);

        final ({int positionMs, int updatedAtMs}) winner = resolvePositionLww(
          localPositionMs: local.positionMs,
          localUpdatedAtMs: local.updatedAtMs,
          remotePositionMs: host.positionMs,
          remoteUpdatedAtMs: host.updatedAtMs,
        );

        // 本地→host：胜者新于 host 时上报（host 端再取较新，幂等安全）。
        if (winner.updatedAtMs > host.updatedAtMs ||
            (winner.updatedAtMs == host.updatedAtMs &&
                winner.positionMs != host.positionMs)) {
          await pushToHost(key, winner.positionMs, winner.updatedAtMs);
        }

        // host→本地：胜者不同于本地时写回。
        if (winner.positionMs != local.positionMs ||
            winner.updatedAtMs != local.updatedAtMs) {
          await writeBackLocal(key, winner.positionMs, winner.updatedAtMs);
        }
      } catch (e) {
        report.noteError('$errorLabel "$key"', e);
      }
    }
  }
}
