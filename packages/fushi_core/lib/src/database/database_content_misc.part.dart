// 词典 / 剪贴板 / EPUB 书目 / 书与统计墓碑（God 类拆分 2026-08：part+mixin，仓库 reader_fushi
// part 先例；mixin 是真类成员——可被测试子类 override、虚分派正常
// （extension 方案在此翻车过）；私有 mixin 不进公共 API 面。
part of 'database.dart';

mixin _FushiDbContentMisc
    on _$FushiDatabase, _FushiDbLibrary, _FushiDbTagsSync {
  // ── dictionary metadata ─────────────────────────────────────────
  Future<List<DictionaryMetaRow>> getAllDictionaryMetadata() =>
      select(dictionaryMetadata).get();

  Future<void> upsertDictionaryMeta(DictionaryMetadataCompanion meta) =>
      into(dictionaryMetadata).insertOnConflictUpdate(meta);

  Future<int> deleteDictionaryMeta(String name) =>
      (delete(dictionaryMetadata)..where((t) => t.name.equals(name))).go();

  Future<int> clearAllDictionaryMeta() => delete(dictionaryMetadata).go();

  // ── dictionary history ──────────────────────────────────────────
  Future<List<DictionaryHistoryRow>> getAllDictionaryHistory() =>
      (select(dictionaryHistory)
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .get();

  Future<void> replaceAllDictionaryHistory(
          List<DictionaryHistoryCompanion> items) =>
      transaction(() async {
        await delete(dictionaryHistory).go();
        await batch((b) {
          for (final item in items) {
            b.insert(dictionaryHistory, item);
          }
        });
      });

  Future<int> clearDictionaryHistory() => delete(dictionaryHistory).go();

  // ── clipboard history ──────────────────
  Future<List<ClipboardHistoryRow>> getAllClipboardHistory() =>
      (select(clipboardHistory)..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .get();

  Future<void> replaceAllClipboardHistory(
          List<ClipboardHistoryCompanion> items) =>
      transaction(() async {
        await delete(clipboardHistory).go();
        await batch((b) {
          for (final item in items) {
            b.insert(clipboardHistory, item);
          }
        });
      });

  Future<int> clearClipboardHistory() => delete(clipboardHistory).go();

  // ── epub books ──────────────────────────────────────────────────
  Future<List<EpubBookRow>> getAllEpubBooks() =>
      (select(epubBooks)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  /// 监听 EPUB 书 bookKey 集合，供书架在任意导入路径落库后自动刷新（同
  /// [watchVideoBookUids]，BUG-793）。消费方按集合 `.distinct` 去重，改作者/封面等
  /// 纯列更新（集合不变）不触发重算。
  Stream<List<String>> watchEpubBookKeys() =>
      select(epubBooks).map((EpubBookRow row) => row.bookKey).watch();

  Future<EpubBookRow?> getEpubBook(String bookKey) =>
      (select(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  /// 按 extractDir 反查书（CSS 编辑器只有 extractDir，需拿 bookKey 记 book_custom_css）。
  Future<EpubBookRow?> getEpubBookByExtractDir(String extractDir) =>
      (select(epubBooks)
            ..where((t) => t.extractDir.equals(extractDir))
            ..limit(1))
          .getSingleOrNull();

  /// 把 [bookKey] 的书标记为「已读完」（[at] 非 null）或清除完成（[at] == null）。
  /// 书架卡菜单手动切换「标记为已读完/取消」时调用。返回受影响行数。有声书共用同一列
  /// （其配对 EpubBooks 行的 bookKey），故无需 SRT 专用方法。
  Future<int> setEpubBookCompleted(String bookKey, DateTime? at) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
          .write(EpubBooksCompanion(completedAt: Value(at)));

  /// 读到全书末尾时自动写完成时间戳——仅在当前未完成（completed_at IS NULL）时写入，
  /// 幂等：已手动/已自动完成过的书重复读到末尾不刷新时间戳，绝不覆盖用户已手动清除的
  /// 状态（用户取消完成后再读到末尾会重新自动置上，属预期）。返回受影响行数。
  Future<int> markEpubBookCompletedIfUnset(String bookKey, DateTime at) =>
      (update(epubBooks)
            ..where((t) => t.bookKey.equals(bookKey) & t.completedAt.isNull()))
          .write(EpubBooksCompanion(completedAt: Value(at)));

  /// 当前所有「已完成」书的 bookKey 集合（completed_at 非 null），供书架概览
  /// 「Completed」统计与卡片完成角标一次性取用（EPUB 小说卡按自身 bookKey、有声书
  /// SRT 卡按其配对 bookKey 命中同一集合）。
  Future<Set<String>> getCompletedEpubBookKeys() async {
    final query = selectOnly(epubBooks)
      ..addColumns([epubBooks.bookKey])
      ..where(epubBooks.completedAt.isNotNull());
    final List<TypedResult> rows = await query.get();
    return rows.map((TypedResult row) => row.read(epubBooks.bookKey)!).toSet();
  }

  /// Inserts a book; returns its bookKey (the primary key) on success.
  Future<String> insertEpubBook(EpubBooksCompanion book) async {
    await into(epubBooks).insert(book);
    // Re-adding a book cancels any prior deletion tombstone so a later merge
    // may bring its data again (TODO-1195 part B).
    await clearBookTombstone(book.bookKey.value);
    // 删除传播：重新导入同 bookKey 的书清除其 sync 删除墓碑（防「删了又加、墓碑还在」
    // 被 compare 误判成待删）。
    await clearSyncDeletionTombstone('book', book.bookKey.value);
    return book.bookKey.value;
  }

  // ── book tombstones (TODO-1195 part B) ──────────────────────────────
  /// Records that [bookKey] was deleted, so a subsequent backup MERGE import
  /// never resurrects it from an old backup. Idempotent (upsert on the PK).
  Future<void> insertBookTombstone(String bookKey) =>
      into(bookTombstones).insertOnConflictUpdate(
        BookTombstonesCompanion.insert(
          bookKey: bookKey,
          deletedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  /// Removes the deletion tombstone for [bookKey] (called when the book is
  /// re-added). Returns the number of rows deleted (0 when none existed).
  Future<int> clearBookTombstone(String bookKey) =>
      (delete(bookTombstones)..where((t) => t.bookKey.equals(bookKey))).go();

  /// The set of book_keys currently tombstoned (deleted and not re-added).
  Future<Set<String>> getBookTombstoneKeys() async {
    final List<BookTombstoneRow> rows = await select(bookTombstones).get();
    return rows.map((BookTombstoneRow r) => r.bookKey).toSet();
  }

  // ── statistics tombstones (TODO-1204 后续：统计删除) ─────────────────

  /// 记一条统计删除墓碑 (title, sourceType)：用户在统计页删除某本书/视频的统计后，
  /// 云同步 [applySnapshotToLocal] 与备份合并 MAX-union INSERT 会跳过它，避免 peer /
  /// 旧备份把删掉的书统计复活。幂等（upsert on PK {title, sourceType}）。
  Future<void> insertStatisticsTombstone(String title, String sourceType) =>
      into(statisticsTombstones).insertOnConflictUpdate(
        StatisticsTombstonesCompanion.insert(
          title: title,
          sourceType: sourceType,
          deletedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  /// 清除 (title, sourceType) 的统计删除墓碑（用户又读该书 / 查词、新写当日统计时
  /// 调用，让该书统计重新生效）。返回删除的行数（无墓碑时 0）。
  Future<int> clearStatisticsTombstone(String title, String sourceType) =>
      (delete(statisticsTombstones)
            ..where(
                (t) => t.title.equals(title) & t.sourceType.equals(sourceType)))
          .go();

  /// 当前全部统计墓碑键 (title, sourceType) 集合，供 [applySnapshotToLocal] 在写回
  /// 合并快照时按键跳过被删的书统计。
  Future<Set<(String, String)>> getStatisticsTombstoneKeys() async {
    final List<StatisticsTombstoneRow> rows =
        await select(statisticsTombstones).get();
    return rows
        .map((StatisticsTombstoneRow r) => (r.title, r.sourceType))
        .toSet();
  }

  /// 删除某本书（按 [title] 聚合）的**纯统计**：阅读时长/字数（reading_statistics）与
  /// 查词/制卡计数（lookup_mining_counters 的 book 行）。同一事务内立一条 book 墓碑，
  /// 防止云同步 / 备份合并把 peer / 旧备份里的旧数字复活。
  ///
  /// **不触碰用户内容**：不删 mined_sentences（制卡历史，收藏夹页展示、可跳回原文）、
  /// 不删 favorite_words / favorite_sentences（收藏）。小时日志（reading_hourly_logs）
  /// 只按 (dateKey, hour) 聚合、不带 title，无法按书精确清理，故不动（全局时段分布仍
  /// 含该书历史贡献，属已知精度边界）。
  Future<void> deleteReadingStatisticsForTitle(String title) =>
      transaction(() async {
        await (delete(readingStatistics)..where((t) => t.title.equals(title)))
            .go();
        await (delete(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) &
                  t.sourceType.equals(FushiDatabase.statSourceBook)))
            .go();
        await insertStatisticsTombstone(title, FushiDatabase.statSourceBook);
      });

  /// 删除某视频的纯统计：观看时长/字幕字数（video_watch_statistics）与查词/制卡
  /// 计数（lookup_mining_counters 的 video 行）。同一事务内立一条 video 墓碑防复活。
  /// 与 [deleteReadingStatisticsForTitle] 同样不动收藏 / 制卡历史 / 小时日志。
  ///
  /// v76（v39 的删除侧收尾）：旧版按 [title] 连坐删——删 A 视频统计把同名 B 的
  /// per-uid 行一起删掉。改为身份感知：
  ///  - [bookUid] 非空 = 删该 uid 的行；[includeUnattributed] 再连带该 title 的
  ///    无身份遗留行（读取端把 unique-title 遗留行归并进该 uid 的 tile，删 tile
  ///    即删其展示的全部行——见 stat_shared 的身份分组契约）；
  ///  - [bookUid] 为 null = 只删该 title 的无身份遗留行（歧义遗留 tile）。
  ///    无身份判定 NULL 与 '' 都算（review-10：与展示层 `bookUid ?? ''` 的判据
  ///    对齐，防止未来写入方存 '' 造出「显示得出、删不掉」的行）。
  ///
  /// 墓碑维持 (title, sourceType) 粒度、且覆盖被删 uid 行的**无歧义**历史 title
  /// （review-6：改名视频的旧 title 行也被本删除清掉，墓碑不跟上会从旧备份复活；
  /// review4-1：历史 title 逐个过与展示层同源的歧义复核——库表同名 ≥2 或存在其它
  /// 身份的统计行 → 该 title 的无身份行显示在别的 tile 里，不扫不立碑）。
  /// wire 协议是 title 粒度，更细的墓碑对同步复活无判别力——代价是**双向**已知
  /// 限制：①被删视频的统计不被 peer 复活（目的）；②本 tile 自身 title 的同名幸存
  /// 视频来自 peer/备份的统计贡献同样被压制，直到其新的本地活动清碑（副作用；
  /// review-3 要求写明的另一半）。随 wire 升级 per-uid 一并解除。
  Future<void> deleteVideoStatisticsForIdentity({
    required String title,
    String? bookUid,
    bool includeUnattributed = false,
  }) =>
      transaction(() async {
        // 本 tile 自身的 title 恒立碑（被删行的防复活；同名幸存者被连带压制是
        // wire title 粒度的已知限制，见方法 doc）。
        final Set<String> tombstoneTitles = <String>{title};
        // 被删 uid 涉足的其它历史 title（改名视频）候选。
        final Set<String> candidateTitles = <String>{};
        if (bookUid != null) {
          final List<VideoWatchStatisticRow> uidWatchRows =
              await (select(videoWatchStatistics)
                    ..where((t) => t.bookUid.equals(bookUid)))
                  .get();
          final List<LookupMiningCounterRow> uidCounterRows =
              await (select(lookupMiningCounters)
                    ..where((t) =>
                        t.bookKey.equals(bookUid) &
                        t.sourceType.equals(FushiDatabase.statSourceVideo)))
                  .get();
          candidateTitles
            ..addAll(uidWatchRows.map((VideoWatchStatisticRow r) => r.title))
            ..addAll(uidCounterRows.map((LookupMiningCounterRow r) => r.title))
            ..add(title);
          await (delete(videoWatchStatistics)
                ..where((t) => t.bookUid.equals(bookUid)))
              .go();
          await (delete(lookupMiningCounters)
                ..where((t) =>
                    t.bookKey.equals(bookUid) &
                    t.sourceType.equals(FushiDatabase.statSourceVideo)))
              .go();
        }
        // '' 不是合法的墓碑/扫面 title：no-book 计数行的 title 就是 ''，给它立碑
        // 会永久压制全部无书查词计数的同步，且没有任何写入方能清（清碑都守
        // isNotEmpty；review3-7）。
        candidateTitles.remove('');
        // 逐 title 歧义复核（review4-1，与展示层吸收判据同源）：库表同名 ≥2
        // （= 页面 ambiguousTitles 判据）或该 title 上还有**其它**非空身份的统计
        // 行（= owners ≥2 判据）→ 该 title 的无身份行被展示层否决吸收、显示在
        // 别的 orphan/幸存者 tile 里，不属于本 tile 展示面——不扫（扫了是越权
        // 连坐）也不立碑（立碑压制幸存同名视频的同步）。被删 uid 在歧义 title
        // 下的行已被上面的 uid 精确删除清掉；其经 peer title 粒度记录的复活只
        // 会以无身份形式回来，属 wire 粒度已知限制。
        final Set<String> sweepTitles = <String>{};
        for (final String candidate in candidateTitles) {
          final List<VideoBookRow> libraryRows = await (select(videoBooks)
                ..where((t) => t.title.equals(candidate)))
              .get();
          if (libraryRows.length >= 2) continue;
          final VideoWatchStatisticRow? otherIdentityWatch =
              await (select(videoWatchStatistics)
                    ..where((t) =>
                        t.title.equals(candidate) &
                        t.bookUid.isNotNull() &
                        t.bookUid.equals('').not() &
                        t.bookUid.equals(bookUid ?? '').not())
                    ..limit(1))
                  .getSingleOrNull();
          if (otherIdentityWatch != null) continue;
          final LookupMiningCounterRow? otherIdentityCounter =
              await (select(lookupMiningCounters)
                    ..where((t) =>
                        t.title.equals(candidate) &
                        t.sourceType.equals(FushiDatabase.statSourceVideo) &
                        t.bookKey.equals('').not() &
                        t.bookKey.equals(bookUid ?? '').not())
                    ..limit(1))
                  .getSingleOrNull();
          if (otherIdentityCounter != null) continue;
          sweepTitles.add(candidate);
          tombstoneTitles.add(candidate);
        }
        if (bookUid == null) {
          // 歧义遗留 tile：tile 展示面就是该 title 的无身份行本身，按用户意图删。
          sweepTitles
            ..clear()
            ..add(title);
        } else if (!includeUnattributed) {
          sweepTitles.clear();
        }
        if (sweepTitles.isNotEmpty) {
          final List<String> sweepList = sweepTitles.toList();
          await (delete(videoWatchStatistics)
                ..where((t) =>
                    t.title.isIn(sweepList) &
                    (t.bookUid.isNull() | t.bookUid.equals(''))))
              .go();
          await (delete(lookupMiningCounters)
                ..where((t) =>
                    t.bookKey.equals('') &
                    t.title.isIn(sweepList) &
                    t.sourceType.equals(FushiDatabase.statSourceVideo)))
              .go();
        }
        for (final String tombstoneTitle in tombstoneTitles) {
          await insertStatisticsTombstone(
              tombstoneTitle, FushiDatabase.statSourceVideo);
        }
      });

  /// TODO-1322: 一键清空**全部阅读统计**（book 域纯统计数字）：阅读时长 / 字数
  /// (reading_statistics)、按小时时段日志 (reading_hourly_logs)、per-book 查词 / 制卡
  /// 计数 (lookup_mining_counters 的 book 行) 与全局按日制卡计数 (mining_statistics 的
  /// book 行)。一次事务原子清空。
  ///
  /// **绝不触碰用户内容**：收藏词 / 句 (favorite_words / favorite_sentences)、制卡历史
  /// (mined_sentences，收藏夹页展示、可跳回原文)、书籍 / 词典本体一律保留（与 per-book
  /// [deleteReadingStatisticsForTitle] 同一「只清纯统计」边界）。
  ///
  /// 与 per-book 删除不同：这是**本地整体重置**，不逐标题写墓碑——墓碑是定向删除的防
  /// 同步复活机制，全量重置若逐 title 立碑会永久毒化标题命名空间、阻断以后重新导入这些
  /// 书的统计。云同步开启时下次聚合仍可能从云端 MAX-union 回灌（清空是本地动作，云端为
  /// 权威源）——属已知边界，不在本方法处理。
  Future<void> clearAllReadingStatistics() => transaction(() async {
        await delete(readingStatistics).go();
        await delete(readingHourlyLogs).go();
        await (delete(lookupMiningCounters)
              ..where((t) => t.sourceType.equals(FushiDatabase.statSourceBook)))
            .go();
        await (delete(miningStatistics)
              ..where((t) => t.sourceType.equals(FushiDatabase.statSourceBook)))
            .go();
      });

  /// TODO-1322: 一键清空**全部视频统计**（video 域纯统计数字）：观看时长 / 字幕字数
  /// (video_watch_statistics)、按小时时段日志 (video_hourly_logs)、per-video 查词 / 制卡
  /// 计数 (lookup_mining_counters 的 video 行) 与全局按日制卡计数 (mining_statistics 的
  /// video 行)。与 [clearAllReadingStatistics] 对称，同样不动收藏 / 制卡历史 / 视频本体，
  /// 也不写墓碑。
  Future<void> clearAllVideoStatistics() => transaction(() async {
        await delete(videoWatchStatistics).go();
        await delete(videoHourlyLogs).go();
        await (delete(lookupMiningCounters)
              ..where(
                  (t) => t.sourceType.equals(FushiDatabase.statSourceVideo)))
            .go();
        await (delete(miningStatistics)
              ..where(
                  (t) => t.sourceType.equals(FushiDatabase.statSourceVideo)))
            .go();
      });

  Future<void> updateEpubBookPath(String bookKey, String epubPath) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
          .write(EpubBooksCompanion(epubPath: Value(epubPath)));

  /// Update a book's author (BUG-220). Unlike a title rename (which would
  /// change the primary key bookKey = sanitized title and require a cascading
  /// re-key), the author column is NOT the primary key, so this is a plain
  /// UPDATE with no cascading re-key. Pass a blank/empty [author] to clear
  /// it (stored as NULL) so the detail dialog hides the author line.
  Future<void> updateEpubBookAuthor(String bookKey, String? author) {
    final String? trimmed = author?.trim();
    final String? value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    return (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
        .write(EpubBooksCompanion(author: Value(value)));
  }

  /// 「书 ↔ 漫画」转化：就地改写一本书的**身份格式**及其连带的产物指针列。
  ///
  /// 主键 `bookKey` 不变，因此 `(mediaType='epub', entryKey=bookKey)` 这个统一媒体
  /// 身份完全不动——合集成员 / 标签 / 阅读进度 / 统计 / Profile / 墓碑全部原地存活，
  /// 零悬挂引用。变的只是「这本书用哪个阅读器打开、产物在哪」：
  /// - [format]：[BookFormat]（阅读器路由的唯一真相源）。收枚举而非裸串——这是
  ///   本列唯一不受常量约束的落库入口，收裸串就等于把「写进未知值」的可能性留在
  ///   运行期，而未知值会让路由静默 fallback 到 EPUB 阅读器、在解析路径出错；
  /// - [epubPath]：漫画指向 `manga.json`，书指向原始 `.epub`/`.pdf` 文件名；
  /// - [coverPath]：漫画取首页页图相对路径，书取原封面。**null = 保持原封面不变**
  ///   （与相邻的 [updateEpubBookContentPaths] 同一约定）——转化从不以「清空封面」
  ///   为目的，若用 `Value(null)` 写穿，调用方一旦漏传就把用户封面静默抹掉；
  /// - [chapterCount] / [chaptersJson]：漫画是页数 + `'[]'`，EPUB 是章数 + 每章
  ///   字数数组（转回书时必须**重新解析**原文件得到，转漫画时被覆盖会丢，故反向
  ///   转化是重建而非撤销）；
  /// - [mangaReadingMode]：仅 `format='manga'` 的行有意义，转成非漫画时必须清 null
  ///   （表约定：其它书身份恒 null）。**这一列 null 是有意义的取值**（漫画上 =
  ///   「跟随页图比例自动判定」，非漫画上 = 唯一合法值），故与 [coverPath] 相反，
  ///   必须无条件写穿，不能沿用「null = 不变」。
  ///
  /// 单条 UPDATE，不动 `extractDir`（三种格式共用同一个书目录）。
  Future<void> updateEpubBookFormat(
    String bookKey, {
    required BookFormat format,
    required String epubPath,
    required int chapterCount,
    required String chaptersJson,
    String? coverPath,
    String? mangaReadingMode,
  }) {
    return (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
        .write(EpubBooksCompanion(
      format: Value(format.dbValue),
      epubPath: Value(epubPath),
      chapterCount: Value(chapterCount),
      chaptersJson: Value(chaptersJson),
      coverPath: coverPath == null ? const Value.absent() : Value(coverPath),
      mangaReadingMode: Value(mangaReadingMode),
    ));
  }

  /// TODO-1192: 重写一本书的 `chaptersJson`（每章元数据 + `characters` 计数 +
  /// `charCaliber` 口径版本）。开书时若发现落库计数是旧口径（含标点/括号/空白），
  /// 按新口径 [japaneseCharCount] 后台重算后回写，使书架总字数与后续统计对齐
  /// hoshi。`chaptersJson` 不是主键（bookKey = sanitized title），plain UPDATE，
  /// 无级联 re-key。
  Future<void> updateEpubBookChaptersJson(
          String bookKey, String chaptersJson) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
          .write(EpubBooksCompanion(chaptersJson: Value(chaptersJson)));

  /// Persist the non-sensitive restart descriptor for a Mihon-backed manga.
  ///
  /// Online manga deliberately reuse [EpubBooks] so the existing shelf,
  /// collections, tags and reader identity keep working. The descriptor only
  /// contains extension/source identities, manga metadata and chapter URLs;
  /// cookies, request headers and bearer tokens must never be written here.
  Future<void> updateEpubBookMihonState(
    String bookKey, {
    required String sourceMetadata,
    required int chapterCount,
    required String chaptersJson,
  }) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
        EpubBooksCompanion(
          sourceMetadata: Value(sourceMetadata),
          chapterCount: Value(chapterCount),
          chaptersJson: Value(chaptersJson),
        ),
      );

  /// Rewrites a book's on-disk content paths (full-data backup restore rebases
  /// absolute paths to this device's roots). Only supplied fields are written;
  /// null leaves a column unchanged.
  Future<void> updateEpubBookContentPaths(
    String bookKey, {
    String? epubPath,
    String? extractDir,
    String? coverPath,
  }) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
        EpubBooksCompanion(
          epubPath: epubPath == null ? const Value.absent() : Value(epubPath),
          extractDir:
              extractDir == null ? const Value.absent() : Value(extractDir),
          coverPath:
              coverPath == null ? const Value.absent() : Value(coverPath),
        ),
      );

  /// Rewrites an audiobook's on-disk paths (full-data backup restore). Only
  /// supplied fields are written. `alignmentPath` is non-null in the schema, so
  /// callers that rebase it always pass a value.
  Future<void> updateAudiobookPaths(
    String bookKey, {
    String? audioRoot,
    String? audioPathsJson,
    String? alignmentPath,
  }) =>
      (update(audiobooks)..where((t) => t.bookKey.equals(bookKey))).write(
        AudiobooksCompanion(
          audioRoot:
              audioRoot == null ? const Value.absent() : Value(audioRoot),
          audioPathsJson: audioPathsJson == null
              ? const Value.absent()
              : Value(audioPathsJson),
          alignmentPath: alignmentPath == null
              ? const Value.absent()
              : Value(alignmentPath),
        ),
      );

  /// Deletes a book and all of its dependent rows in one transaction. When
  /// [tombstone] is true (a user-initiated shelf/library delete), a
  /// `book_tombstones` row is recorded so a later backup MERGE import never
  /// resurrects this book from an old backup (TODO-1195 part B). Internal
  /// deletes that are NOT user intent (e.g. an import-rollback, or stripping a
  /// book from an export copy) pass the default false so no tombstone leaks.
  Future<int> deleteEpubBook(String bookKey, {bool tombstone = false}) =>
      transaction(() async {
        await (delete(readerPositions)..where((t) => t.bookKey.equals(bookKey)))
            .go();
        // bookmarks / book_tag_mappings declare ON DELETE CASCADE on
        // epub_books(bookKey), but we delete them explicitly rather than rely on
        // the cascade: this stays correct regardless of the runtime
        // foreign_keys pragma state and documents the full set of dependent
        // rows in one place.
        await (delete(bookmarks)..where((t) => t.bookKey.equals(bookKey))).go();
        // SRT books linked to this epub key their cues on srt_books.uid, NOT
        // the epub bookKey, so delete those cues before dropping the srt rows.
        // (HBK-AUDIT-041 follow-up: deleteEpubBook owns the full cascade; the
        // reader source no longer deletes these rows itself.)
        final List<String> srtUids = await (selectOnly(srtBooks)
              ..addColumns([srtBooks.uid])
              ..where(srtBooks.bookKey.equals(bookKey)))
            .map((r) => r.read(srtBooks.uid)!)
            .get();
        for (final String uid in srtUids) {
          await (delete(audioCues)..where((t) => t.bookKey.equals(uid))).go();
          // v77：标签映射是逻辑外键，随宿主显式清理（附属 SRT 行也一并清）。
          await deleteTagAssignmentsForHost(TagHostKind.srt, uid);
        }
        await (delete(srtBooks)..where((t) => t.bookKey.equals(bookKey))).go();
        await deleteTagAssignmentsForHost(TagHostKind.epub, bookKey);
        // Audiobook + its cues are keyed directly by bookKey now.
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookKey))).go();
        await (delete(audiobooks)..where((t) => t.bookKey.equals(bookKey)))
            .go();
        // TODO-616：同事务清 shelf_entry（mediaType='epub'、entryKey=bookKey）。
        // 若该书还登记过 'srt' 行（EPUB 附属有声书），deleteAudiobookByBookKey 已
        // 幂等清，此处只清 'epub' 行。
        await deleteShelfEntry(MediaKind.epub, bookKey);
        if (tombstone) {
          await into(bookTombstones).insertOnConflictUpdate(
            BookTombstonesCompanion.insert(
              bookKey: bookKey,
              deletedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
        return (delete(epubBooks)..where((t) => t.bookKey.equals(bookKey)))
            .go();
      });
}
