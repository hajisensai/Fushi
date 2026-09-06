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

  /// 互联书籍阅读进度 live 双向同步（TODO-767）。
  ///
  /// 遍历本地 `epub_books`，对每本书：GET host 真相源进度（[RemoteBookClient
  /// .remoteBookProgress]，host 直读自己的 `reader_positions`）+ 读本地
  /// `reader_positions`，用 [resolveBookProgressSync]「取较新时间戳」选胜者；胜者
  /// 严格新于 host 时 PUT 上报 host（[RemoteBookClient.putRemoteBookProgress]，host
  /// 再防御性取较新落自己的 DB），胜者不同于本地时 upsert 回本地。
  ///
  /// 修复根因：互联「立即同步」此前书籍进度只走 SyncManager 的 WebDAV 文件箱
  /// （progress_*.json），host 从不读回自己的 reader_positions DB，故进度不过去。
  /// 这里补对称视频 TODO-653 的 live 端点 + host-apply，让进度真正落 host DB。
  ///
  /// 逐本错误进 [report.errors] 不中断整体。
  Future<void> _syncBookProgressLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    final List<EpubBookRow> localBooks = await _db.getAllEpubBooks();
    for (final EpubBookRow book in localBooks) {
      try {
        final RemoteBookProgress remote =
            await backend.remoteBookProgress(book.bookKey);
        // v82：wire 键仍是 bookKey（REST 路径冻结），本地子表键是书 uid。
        final ReaderPositionRow? localRow =
            await _db.getReaderPosition(book.uid);
        final RemoteBookProgress local = localRow == null
            ? RemoteBookProgress.empty
            : RemoteBookProgress(
                sectionIndex: localRow.sectionIndex,
                normCharOffset: localRow.normCharOffset,
                charOffset: localRow.charOffset,
                updatedAtMs: localRow.updatedAt,
              );
        final RemoteBookProgress winner =
            resolveBookProgressSync(local: local, remote: remote);

        // 本地→host：胜者严格新于 host 时上报（host 端再取较新，幂等安全）。
        if (winner.updatedAtMs > remote.updatedAtMs ||
            (winner.updatedAtMs == remote.updatedAtMs &&
                (winner.sectionIndex != remote.sectionIndex ||
                    winner.normCharOffset != remote.normCharOffset ||
                    winner.charOffset != remote.charOffset))) {
          await backend.putRemoteBookProgress(book.bookKey, winner);
        }

        // host→本地：胜者不同于本地时 upsert 回本地 reader_positions。
        final bool localChanged = winner.sectionIndex != local.sectionIndex ||
            winner.normCharOffset != local.normCharOffset ||
            winner.charOffset != local.charOffset ||
            winner.updatedAtMs != local.updatedAtMs;
        if (localChanged && winner.updatedAtMs > 0) {
          await _db.upsertReaderPosition(ReaderPositionsCompanion(
            bookUid: Value(book.uid),
            sectionIndex: Value(winner.sectionIndex),
            normCharOffset: Value(winner.normCharOffset),
            charOffset: Value(winner.charOffset),
            updatedAt: Value(winner.updatedAtMs),
          ));
          // BUG-686: a host-newer progress pull lands in reader_positions but
          // writes no book content, so it must still flag the shelf for a
          // refresh — the cached fushiBooksProvider otherwise keeps showing the
          // pre-sync progress bar and the sync looks like it did nothing.
          report.localBookProgressPulled++;
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
