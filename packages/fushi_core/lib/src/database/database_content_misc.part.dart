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

  /// 把 profile 快照拥有的四列（顺序 + 语言可见性 + 折叠 + 语言覆盖）写回一本
  /// **已安装**的词典行，返回受影响行数。
  ///
  /// 0 = 这本词典当前不在库里（快照比库旧，或它在别处被删了）。调用方据此**跳过**
  /// 而不是插一行——`insertOnConflictUpdate` 会凭空造出一行没有磁盘目录的幽灵元
  /// 数据，之后每次查词都会去 load 一个不存在的词典。
  ///
  /// 刻意不碰 `formatKey` / `type` / `metadataJson`：那三列是「装的是什么」的安装
  /// 事实，唯一写者是导入路径；profile 只拥有「怎么排、开不开」（BUG-1994）。
  Future<int> applyDictionaryMetaProfileColumns({
    required String name,
    required int order,
    required String hiddenLanguagesJson,
    required String collapsedLanguagesJson,
    required String? languageOverride,
  }) => (update(dictionaryMetadata)..where((t) => t.name.equals(name))).write(
    DictionaryMetadataCompanion(
      order: Value(order),
      hiddenLanguagesJson: Value(hiddenLanguagesJson),
      collapsedLanguagesJson: Value(collapsedLanguagesJson),
      languageOverride: Value(languageOverride),
    ),
  );

  Future<int> clearAllDictionaryMeta() => delete(dictionaryMetadata).go();

  // ── dictionary history ──────────────────────────────────────────
  Future<List<DictionaryHistoryRow>> getAllDictionaryHistory() => (select(
    dictionaryHistory,
  )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();

  Future<void> replaceAllDictionaryHistory(
    List<DictionaryHistoryCompanion> items,
  ) => transaction(() async {
    await delete(dictionaryHistory).go();
    await batch((b) {
      for (final item in items) {
        b.insert(dictionaryHistory, item);
      }
    });
  });

  Future<int> clearDictionaryHistory() => delete(dictionaryHistory).go();

  // ── clipboard history ──────────────────
  Future<List<ClipboardHistoryRow>> getAllClipboardHistory() => (select(
    clipboardHistory,
  )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();

  Future<void> replaceAllClipboardHistory(
    List<ClipboardHistoryCompanion> items,
  ) => transaction(() async {
    await delete(clipboardHistory).go();
    await batch((b) {
      for (final item in items) {
        b.insert(clipboardHistory, item);
      }
    });
  });

  Future<int> clearClipboardHistory() => delete(clipboardHistory).go();

  // ── epub books ──────────────────────────────────────────────────
  Future<List<EpubBookRow>> getAllEpubBooks() => (select(
    epubBooks,
  )..orderBy([(t) => OrderingTerm.desc(t.importedAt)])).get();

  /// 监听 EPUB 书 bookKey 集合，供书架在任意导入路径落库后自动刷新（同
  /// [watchVideoBookUids]，BUG-793）。消费方按集合 `.distinct` 去重，改作者/封面等
  /// 纯列更新（集合不变）不触发重算。
  Stream<List<String>> watchEpubBookKeys() =>
      select(epubBooks).map((EpubBookRow row) => row.bookKey).watch();

  Future<EpubBookRow?> getEpubBook(String bookKey) => (select(
    epubBooks,
  )..where((t) => t.bookKey.equals(bookKey))).getSingleOrNull();

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
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
        EpubBooksCompanion(completedAt: Value(at)),
      );

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
  ///
  /// v81：companion 未携带（或空）本机稳定 uid 时在此**单点自动生成**——
  /// 全部导入方（epub/manga/pdf/远端下载/格式重建）零改动即获得身份列。
  Future<String> insertEpubBook(EpubBooksCompanion book) async {
    final EpubBooksCompanion withUid =
        (book.uid.present && book.uid.value.isNotEmpty)
        ? book
        : book.copyWith(uid: Value(generateEpubBookUid()));
    await into(epubBooks).insert(withUid);
    // Re-adding a book cancels any prior deletion tombstone so a later merge
    // may bring its data again (TODO-1195 part B).
    await clearBookTombstone(book.bookKey.value);
    // 删除传播：重新导入同 bookKey 的书清除其 sync 删除墓碑（防「删了又加、墓碑还在」
    // 被 compare 误判成待删）。
    await clearSyncDeletionTombstone('book', book.bookKey.value);
    return book.bookKey.value;
  }

  /// 按本机稳定 uid 取书（v81；身份与展示解耦的读取口）。
  Future<EpubBookRow?> getEpubBookByUid(String uid) =>
      (select(epubBooks)..where((t) => t.uid.equals(uid))).getSingleOrNull();

  /// bookKey → 本机稳定 uid 换算口（v82；wire/备份/旧偏好等 bookKey 面貌
  /// 冻结的通道在落 uid 键子表前经此换算）。书不在库返回 null——调用方沿用
  /// no-op 语义（host service 写入闸门同款），不得用 bookKey 兜底写入。
  Future<String?> resolveEpubBookUid(String bookKey) async {
    final String? uid =
        await (selectOnly(epubBooks)
              ..addColumns([epubBooks.uid])
              ..where(epubBooks.bookKey.equals(bookKey)))
            .map((r) => r.read(epubBooks.uid))
            .getSingleOrNull();
    return (uid == null || uid.isEmpty) ? null : uid;
  }

  // uid → bookKey 反向换算口 resolveEpubBookKeyByUid（[resolveEpubBookUid]
  // 的对偶）定义在 database_library.part.dart——墓碑键域归一
  // （_tombstoneEntryKeyOf）在那个 mixin 里，而本 mixin 在 on 链上位于其上，
  // 方法只能住在被依赖侧。

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

  /// 写入 / 抬高一条按身份墓碑：同键只在 [deletedAt] 严格更大时覆盖（碑戳只增
  /// 不减，BUG-2220）。本机删除与同步 / 备份落地都经这里。
  Future<void> upsertStudySegmentTombstone({
    required String mediaKind,
    required String mediaKey,
    required int deletedAt,
  }) => into(studySegmentTombstones).insert(
    StudySegmentTombstonesCompanion.insert(
      mediaKind: mediaKind,
      mediaKey: mediaKey,
      deletedAt: deletedAt,
    ),
    onConflict: DoUpdate(
      (old) => StudySegmentTombstonesCompanion(deletedAt: Value(deletedAt)),
      target: [
        studySegmentTombstones.mediaKind,
        studySegmentTombstones.mediaKey,
      ],
      where: (old) => old.deletedAt.isSmallerThanValue(deletedAt),
    ),
  );

  /// v92：删某媒体的 `study_segments` 事实 + 立按身份的墓碑（同一事务）。墓碑
  /// 语义（BUG-2214 / BUG-2220）：压制 `startAt < deletedAt` 的段——删除之后开始的
  /// 新段（时钟下一次开段）自然存活，墓碑不需要清、也永不退场；碑戳只增不减
  /// （重复删只抬高、绝不倒退）。
  Future<int> deleteStudySegmentsForMedia({
    required String mediaKind,
    required String mediaKey,
  }) => transaction(() async {
    final int removed =
        await (delete(studySegments)..where(
              (t) =>
                  t.mediaKind.equals(mediaKind) & t.mediaKey.equals(mediaKey),
            ))
            .go();
    await upsertStudySegmentTombstone(
      mediaKind: mediaKind,
      mediaKey: mediaKey,
      deletedAt: DateTime.now().millisecondsSinceEpoch,
    );
    return removed;
  });

  /// v92：清空某媒体种类的全部段（统计页「清空全部」）。BUG-2215：清空前对该种类
  /// **每个身份**逐一立碑（`deletedAt = now`）再删行——否则互联 / 云同步下次聚合把
  /// 对端持有的全部历史整批回灌。新墓碑语义只压制 `startAt < deletedAt` 的段，立碑
  /// 不再「毒化身份空间」：之后再读同一本书开的新段照常存活。返回删掉的段数。
  Future<int> clearStudySegments(String mediaKind) => transaction(() async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<QueryRow> keys = await customSelect(
      'SELECT DISTINCT media_key FROM study_segments WHERE media_kind = ?',
      variables: [Variable.withString(mediaKind)],
      readsFrom: {studySegments},
    ).get();
    for (final QueryRow row in keys) {
      await upsertStudySegmentTombstone(
        mediaKind: mediaKind,
        mediaKey: row.read<String>('media_key'),
        deletedAt: now,
      );
    }
    return (delete(
      studySegments,
    )..where((t) => t.mediaKind.equals(mediaKind))).go();
  });

  /// 用户在时段明细里删某媒体某几天的统计：段**写零**而不是删行——零值就是一次新的
  /// 绝对值写（`updatedAt = now`），经既有 LWW 同步（`upsertStudySegmentsIfNewer` /
  /// 聚合 merge 同 uid 取 updatedAt 大者）自然传到对端，不需要 per-uid 墓碑或新 wire
  /// 字段；读取端对零行本就无贡献（活动流过滤、日面求和为 0、最近观看排除）。
  /// 返回改写的行数。
  Future<int> zeroStudySegmentsOnDays({
    required String mediaKind,
    required String mediaKey,
    required Set<String> dateKeys,
  }) {
    if (dateKeys.isEmpty || mediaKey.isEmpty) return Future<int>.value(0);
    return (update(studySegments)..where(
          (t) =>
              t.mediaKind.equals(mediaKind) &
              t.mediaKey.equals(mediaKey) &
              t.dateKey.isIn(dateKeys),
        ))
        .write(
          StudySegmentsCompanion(
            durationMs: const Value(0),
            chars: const Value(0),
            pages: const Value(0),
            updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  /// 时段明细 sheet 的「删这一条」（BUG-2108 用户诉求：看着不对的数据要能删）：
  /// 删某媒体在 [dateKeys] 这几天的**全部统计事实**——正是 sheet 那一行求和用到的
  /// 行集，不多不少。
  ///  * v92 段：按 uid 写零（[zeroStudySegmentsOnDays]，同步安全）；
  ///  * legacy 日行：按域删行（阅读按 title、视频按 bookUid / 无身份按 title）；
  ///    legacy wire 是 title 粒度 MAX-union，对端若还持有这几行会复活——旧数据的
  ///    旧口径已知边界，单机无影响；
  ///  * 游戏：删该游戏这几天的 galgame_sessions + legacy 活动行的 game 字数行
  ///    （游玩会话不进互联同步，无副作用）。
  /// 不动收藏 / 制卡历史 / 查词计数（与按媒体删同一「只清纯统计」边界）；不立墓碑
  /// （按天删不是「忘掉这部」，覆盖并集也不动——之后重看仍不计）。
  Future<void> deleteStatFactsOnDays({
    required String mediaKind,
    required String mediaKey,
    required String title,
    required Set<String> dateKeys,
  }) => transaction(() async {
    if (dateKeys.isEmpty) return;
    await zeroStudySegmentsOnDays(
      mediaKind: mediaKind,
      mediaKey: mediaKey,
      dateKeys: dateKeys,
    );
    switch (mediaKind) {
      case kActivityMediaBook:
        await (delete(
          readingStatistics,
        )..where((t) => t.title.equals(title) & t.dateKey.isIn(dateKeys))).go();
      case kActivityMediaVideo:
        await (delete(videoWatchStatistics)..where(
              (t) =>
                  (mediaKey.isNotEmpty
                      ? t.bookUid.equals(mediaKey)
                      : (t.bookUid.isNull() | t.bookUid.equals('')) &
                            t.title.equals(title)) &
                  t.dateKey.isIn(dateKeys),
            ))
            .go();
      case kActivityMediaGame:
        if (mediaKey.isNotEmpty) {
          await (delete(galgameSessions)..where(
                (t) => t.gameId.equals(mediaKey) & t.dateKey.isIn(dateKeys),
              ))
              .go();
        }
        await (delete(activityEvents)..where(
              (t) =>
                  t.eventType.equals(kActivityGame) &
                  (mediaKey.isNotEmpty
                      ? t.mediaKey.equals(mediaKey)
                      : t.title.equals(title)) &
                  t.dateKey.isIn(dateKeys),
            ))
            .go();
    }
  });

  /// 清除 (title, sourceType) 的统计删除墓碑（用户又读该书 / 查词、新写当日统计时
  /// 调用，让该书统计重新生效）。返回删除的行数（无墓碑时 0）。
  Future<int> clearStatisticsTombstone(String title, String sourceType) =>
      (delete(statisticsTombstones)..where(
            (t) => t.title.equals(title) & t.sourceType.equals(sourceType),
          ))
          .go();

  /// 当前全部统计墓碑键 (title, sourceType) 集合，供 [applySnapshotToLocal] 在写回
  /// 合并快照时按键跳过被删的书统计。
  Future<Set<(String, String)>> getStatisticsTombstoneKeys() async {
    final List<StatisticsTombstoneRow> rows = await select(
      statisticsTombstones,
    ).get();
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
  ///
  /// v92：[bookKey] 非空时同一事务连带删该书的 `study_segments` 事实并立按身份的
  /// 墓碑（legacy 行仍按 title 删、按 (title, sourceType) 立碑——两套墓碑各管各的
  /// wire 家族）。
  Future<void> deleteReadingStatisticsForTitle(
    String title, {
    String? bookKey,
  }) => transaction(() async {
    if (bookKey != null && bookKey.isNotEmpty) {
      await deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: bookKey,
      );
    }
    await (delete(readingStatistics)..where((t) => t.title.equals(title))).go();
    await (delete(lookupMiningCounters)..where(
          (t) =>
              t.title.equals(title) &
              t.sourceType.equals(FushiDatabase.statSourceBook),
        ))
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
  }) => transaction(() async {
    // v92：有身份即连带删 study_segments 事实 + 按身份立碑。BUG-2108：连带
    // 忘掉「已看过的片内区间」——删统计 = 当没看过，之后重看重新计首次覆盖。
    if (bookUid != null && bookUid.isNotEmpty) {
      await deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaVideo,
        mediaKey: bookUid,
      );
      await (delete(
        preferences,
      )..where((t) => t.key.equals(videoWatchCoveragePrefKey(bookUid)))).go();
    }
    // 本 tile 自身的 title 恒立碑（被删行的防复活；同名幸存者被连带压制是
    // wire title 粒度的已知限制，见方法 doc）。
    final Set<String> tombstoneTitles = <String>{title};
    // 被删 uid 涉足的其它历史 title（改名视频）候选。
    final Set<String> candidateTitles = <String>{};
    if (bookUid != null) {
      final List<VideoWatchStatisticRow> uidWatchRows = await (select(
        videoWatchStatistics,
      )..where((t) => t.bookUid.equals(bookUid))).get();
      final List<LookupMiningCounterRow> uidCounterRows =
          await (select(lookupMiningCounters)..where(
                (t) =>
                    t.bookKey.equals(bookUid) &
                    t.sourceType.equals(FushiDatabase.statSourceVideo),
              ))
              .get();
      candidateTitles
        ..addAll(uidWatchRows.map((VideoWatchStatisticRow r) => r.title))
        ..addAll(uidCounterRows.map((LookupMiningCounterRow r) => r.title))
        ..add(title);
      await (delete(
        videoWatchStatistics,
      )..where((t) => t.bookUid.equals(bookUid))).go();
      await (delete(lookupMiningCounters)..where(
            (t) =>
                t.bookKey.equals(bookUid) &
                t.sourceType.equals(FushiDatabase.statSourceVideo),
          ))
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
      final List<VideoBookRow> libraryRows = await (select(
        videoBooks,
      )..where((t) => t.title.equals(candidate))).get();
      if (libraryRows.length >= 2) continue;
      final VideoWatchStatisticRow? otherIdentityWatch =
          await (select(videoWatchStatistics)
                ..where(
                  (t) =>
                      t.title.equals(candidate) &
                      t.bookUid.isNotNull() &
                      t.bookUid.equals('').not() &
                      t.bookUid.equals(bookUid ?? '').not(),
                )
                ..limit(1))
              .getSingleOrNull();
      if (otherIdentityWatch != null) continue;
      final LookupMiningCounterRow? otherIdentityCounter =
          await (select(lookupMiningCounters)
                ..where(
                  (t) =>
                      t.title.equals(candidate) &
                      t.sourceType.equals(FushiDatabase.statSourceVideo) &
                      t.bookKey.equals('').not() &
                      t.bookKey.equals(bookUid ?? '').not(),
                )
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
      await (delete(videoWatchStatistics)..where(
            (t) =>
                t.title.isIn(sweepList) &
                (t.bookUid.isNull() | t.bookUid.equals('')),
          ))
          .go();
      await (delete(lookupMiningCounters)..where(
            (t) =>
                t.bookKey.equals('') &
                t.title.isIn(sweepList) &
                t.sourceType.equals(FushiDatabase.statSourceVideo),
          ))
          .go();
    }
    for (final String tombstoneTitle in tombstoneTitles) {
      await insertStatisticsTombstone(
        tombstoneTitle,
        FushiDatabase.statSourceVideo,
      );
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
  /// 与 per-book 删除不同：这是**本地整体重置**，legacy 家族不逐标题写墓碑——title
  /// 墓碑是定向删除的防同步复活机制，全量重置若逐 title 立碑会永久毒化标题命名空间、
  /// 阻断以后重新导入这些书的统计；legacy 行云同步下次聚合仍可能从云端 MAX-union 回灌
  /// （旧数据的旧口径，已知边界）。v92 段则**逐身份立碑**（[clearStudySegments]，
  /// BUG-2215）：新墓碑语义只压制清空之前开始的段，之后再读照常计。
  Future<void> clearAllReadingStatistics() => transaction(() async {
    await clearStudySegments(kActivityMediaBook);
    await delete(readingStatistics).go();
    await delete(readingHourlyLogs).go();
    await (delete(
      lookupMiningCounters,
    )..where((t) => t.sourceType.equals(FushiDatabase.statSourceBook))).go();
    await (delete(
      miningStatistics,
    )..where((t) => t.sourceType.equals(FushiDatabase.statSourceBook))).go();
  });

  /// TODO-1322: 一键清空**全部视频统计**（video 域纯统计数字）：观看时长 / 字幕字数
  /// (video_watch_statistics)、按小时时段日志 (video_hourly_logs)、per-video 查词 / 制卡
  /// 计数 (lookup_mining_counters 的 video 行) 与全局按日制卡计数 (mining_statistics 的
  /// video 行)。与 [clearAllReadingStatistics] 对称，同样不动收藏 / 制卡历史 / 视频本体；
  /// legacy 家族不写 title 墓碑，v92 段逐身份立碑（[clearStudySegments]，BUG-2215）。
  Future<void> clearAllVideoStatistics() => transaction(() async {
    await clearStudySegments(kActivityMediaVideo);
    // BUG-2108：清统计 = 全部当没看过，覆盖并集一并清。
    await (delete(
      preferences,
    )..where((t) => t.key.like('$kVideoWatchCoveragePrefPrefix%'))).go();
    await delete(videoWatchStatistics).go();
    await delete(videoHourlyLogs).go();
    await (delete(
      lookupMiningCounters,
    )..where((t) => t.sourceType.equals(FushiDatabase.statSourceVideo))).go();
    await (delete(
      miningStatistics,
    )..where((t) => t.sourceType.equals(FushiDatabase.statSourceVideo))).go();
  });

  Future<void> updateEpubBookPath(String bookKey, String epubPath) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
        EpubBooksCompanion(epubPath: Value(epubPath)),
      );

  /// Update a book's author (BUG-220). Unlike a title rename (which would
  /// change the primary key bookKey = sanitized title and require a cascading
  /// re-key), the author column is NOT the primary key, so this is a plain
  /// UPDATE with no cascading re-key. Pass a blank/empty [author] to clear
  /// it (stored as NULL) so the detail dialog hides the author line.
  Future<void> updateEpubBookAuthor(String bookKey, String? author) {
    final String? trimmed = author?.trim();
    final String? value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    return (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
      EpubBooksCompanion(author: Value(value)),
    );
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
    return (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
      EpubBooksCompanion(
        format: Value(format.dbValue),
        epubPath: Value(epubPath),
        chapterCount: Value(chapterCount),
        chaptersJson: Value(chaptersJson),
        coverPath: coverPath == null ? const Value.absent() : Value(coverPath),
        mangaReadingMode: Value(mangaReadingMode),
      ),
    );
  }

  /// v87：改写一本书的内容语言（BCP-47），决定正文用哪条字体链。
  ///
  /// null 是**有意义的取值**（= 未知，阅读器不写 `font-family`，保持浏览器默认），
  /// 所以无条件写穿，不沿用「null = 不变」的约定——与相邻 [updateEpubBookFormat]
  /// 处理 `mangaReadingMode` 的理由相同。
  Future<void> updateEpubBookLanguage(String bookKey, String? language) =>
      (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
        EpubBooksCompanion(language: Value(language)),
      );

  /// v87：改写视频的内容语言（BCP-47）。决定字幕用哪条字体链。
  /// null = 未指定，字幕层退回「当前字幕轨的 language」，再没有则用历史兜底链。
  Future<void> updateVideoBookLanguage(String bookUid, String? language) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid))).write(
        VideoBooksCompanion(language: Value(language)),
      );

  /// v87：改写字幕书/有声书的内容语言（BCP-47）。null = 未知。
  Future<void> updateSrtBookLanguage(String uid, String? language) =>
      (update(srtBooks)..where((t) => t.uid.equals(uid))).write(
        SrtBooksCompanion(language: Value(language)),
      );

  /// v87：改写 galgame 的文本语言（BCP-47）。null = 未知。
  Future<void> updateGalgameLanguage(String id, String? language) =>
      (update(galgames)..where((t) => t.id.equals(id))).write(
        GalgamesCompanion(language: Value(language)),
      );

  /// TODO-1192: 重写一本书的 `chaptersJson`（每章元数据 + `characters` 计数 +
  /// `charCaliber` 口径版本）。开书时若发现落库计数是旧口径（含标点/括号/空白），
  /// 按新口径 `countStudyChars` 后台重算后回写，使书架总字数与后续统计对齐
  /// hoshi。`chaptersJson` 不是主键（bookKey = sanitized title），plain UPDATE，
  /// 无级联 re-key。
  Future<void> updateEpubBookChaptersJson(
    String bookKey,
    String chaptersJson,
  ) => (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
    EpubBooksCompanion(chaptersJson: Value(chaptersJson)),
  );

  /// 就地重写一本书的正文章节元数据（`chapterCount` + `chaptersJson`），不动
  /// bookKey / extractDir / format / 封面。
  ///
  /// 字幕书换字幕时正文由新 cue 重新生成（[EpubImporter.rebuildExtractedInPlace]），
  /// 章节数与每章字数随之变化，必须与解压树同一次写入对齐；沿用
  /// [updateEpubBookChaptersJson] 的理由——`chaptersJson` 不是主键，plain UPDATE，
  /// 无级联 re-key。与 [updateEpubBookFormat] 的区别是**不碰 format/epubPath**，
  /// 避免为了改两列而把无关列一起重写。
  Future<void> updateEpubBookChapters(
    String bookKey, {
    required int chapterCount,
    required String chaptersJson,
  }) => (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
    EpubBooksCompanion(
      chapterCount: Value(chapterCount),
      chaptersJson: Value(chaptersJson),
    ),
  );

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
  }) => (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
    EpubBooksCompanion(
      sourceMetadata: Value(sourceMetadata),
      chapterCount: Value(chapterCount),
      chaptersJson: Value(chaptersJson),
    ),
  );

  // ── manga_chapter_states（v89）─────────────────────────────────────
  //
  // 「章」的读取状态。为什么不并进 reader_positions：那张表 bookUid 是
  // unique()，一本书恒一条，表达不了「这本书的第 37 章读到第 8 页」。

  /// 一本书的全部章状态，按 `chapterKey` 索引。
  ///
  /// 作品页一次读全量而不是逐章查：章节列表本来就要整屏渲染，N 次单行查询在
  /// 几百章的长篇上是纯粹的往返浪费。
  Future<Map<String, MangaChapterStateRow>> getMangaChapterStates(
    String bookUid,
  ) async {
    if (bookUid.isEmpty) return const <String, MangaChapterStateRow>{};
    final List<MangaChapterStateRow> rows = await (select(
      mangaChapterStates,
    )..where((t) => t.bookUid.equals(bookUid))).get();
    return <String, MangaChapterStateRow>{
      for (final MangaChapterStateRow row in rows) row.chapterKey: row,
    };
  }

  Future<MangaChapterStateRow?> getMangaChapterState({
    required String bookUid,
    required String chapterKey,
  }) {
    if (bookUid.isEmpty || chapterKey.isEmpty) {
      return Future<MangaChapterStateRow?>.value();
    }
    return (select(mangaChapterStates)..where(
          (t) => t.bookUid.equals(bookUid) & t.chapterKey.equals(chapterKey),
        ))
        .getSingleOrNull();
  }

  /// 记录一次章内进度。
  ///
  /// [readAt] 只在**读完**该章时传：它是「已读」的唯一判据，一旦置上就不再被
  /// 后续的普通进度写入抹掉（重读一遍不该把已读标记退回未读）。传 null 表示
  /// 「本次不改变已读状态」，而不是「标记未读」——清除已读走
  /// [clearMangaChapterRead]，让两种意图在调用点就分开。
  Future<void> saveMangaChapterState({
    required String bookUid,
    required String chapterKey,
    required int lastPage,
    int lastFraction = -1,
    int? pageCount,
    int? readAt,
  }) async {
    if (bookUid.isEmpty || chapterKey.isEmpty) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final MangaChapterStateRow? existing = await getMangaChapterState(
      bookUid: bookUid,
      chapterKey: chapterKey,
    );
    await into(mangaChapterStates).insertOnConflictUpdate(
      MangaChapterStatesCompanion.insert(
        bookUid: bookUid,
        chapterKey: chapterKey,
        lastPage: Value<int>(lastPage),
        lastFraction: Value<int>(lastFraction),
        // 整行覆盖 upsert 会清空没传的列，所以未知页数必须回填既有值而不是
        // 让它退回 NULL。
        pageCount: Value<int?>(pageCount ?? existing?.pageCount),
        readAt: Value<int?>(readAt ?? existing?.readAt),
        updatedAt: now,
      ),
    );
  }

  /// 显式把一章标回未读（作品页的「标为未读」动作）。
  Future<void> clearMangaChapterRead({
    required String bookUid,
    required String chapterKey,
  }) async {
    if (bookUid.isEmpty || chapterKey.isEmpty) return;
    await (update(mangaChapterStates)..where(
          (t) => t.bookUid.equals(bookUid) & t.chapterKey.equals(chapterKey),
        ))
        .write(
          MangaChapterStatesCompanion(
            readAt: const Value<int?>(null),
            updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  /// 批量标记已读（作品页的「标记此章及更早为已读」）。
  Future<void> markMangaChaptersRead({
    required String bookUid,
    required List<String> chapterKeys,
  }) async {
    if (bookUid.isEmpty || chapterKeys.isEmpty) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await batch((Batch batch) {
      for (final String chapterKey in chapterKeys) {
        if (chapterKey.isEmpty) continue;
        batch.insert(
          mangaChapterStates,
          MangaChapterStatesCompanion.insert(
            bookUid: bookUid,
            chapterKey: chapterKey,
            readAt: Value<int?>(now),
            updatedAt: now,
          ),
          onConflict: DoUpdate(
            (_) => MangaChapterStatesCompanion(
              readAt: Value<int?>(now),
              updatedAt: Value<int>(now),
            ),
          ),
        );
      }
    });
  }

  /// Rewrites a book's on-disk content paths (full-data backup restore rebases
  /// absolute paths to this device's roots). Only supplied fields are written;
  /// null leaves a column unchanged.
  Future<void> updateEpubBookContentPaths(
    String bookKey, {
    String? epubPath,
    String? extractDir,
    String? coverPath,
  }) => (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
    EpubBooksCompanion(
      epubPath: epubPath == null ? const Value.absent() : Value(epubPath),
      extractDir: extractDir == null ? const Value.absent() : Value(extractDir),
      coverPath: coverPath == null ? const Value.absent() : Value(coverPath),
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
  }) => (update(audiobooks)..where((t) => t.bookKey.equals(bookKey))).write(
    AudiobooksCompanion(
      audioRoot: audioRoot == null ? const Value.absent() : Value(audioRoot),
      audioPathsJson: audioPathsJson == null
          ? const Value.absent()
          : Value(audioPathsJson),
      alignmentPath: alignmentPath == null
          ? const Value.absent()
          : Value(alignmentPath),
    ),
  );

  /// Rewrites a standalone SRT/有声书行的落盘路径（备份恢复 / 合并导入把绝对路径
  /// rebase 到本机根）。与 [updateAudiobookPaths] 同范式：只写传入的列，null =
  /// 不动该列。
  ///
  /// 键是 **uid**（唯一列）而不是 `bookKey`：独立字幕书的 `bookKey` 是空串
  /// 哨兵且可重复，拿它做 WHERE 会一次改写全部独立字幕书。
  Future<void> updateSrtBookPaths(
    String uid, {
    String? audioRoot,
    String? audioPathsJson,
    String? srtPath,
    String? coverPath,
  }) => (update(srtBooks)..where((t) => t.uid.equals(uid))).write(
    SrtBooksCompanion(
      audioRoot: audioRoot == null ? const Value.absent() : Value(audioRoot),
      audioPathsJson: audioPathsJson == null
          ? const Value.absent()
          : Value(audioPathsJson),
      srtPath: srtPath == null ? const Value.absent() : Value(srtPath),
      coverPath: coverPath == null ? const Value.absent() : Value(coverPath),
    ),
  );

  /// Deletes a book and all of its dependent rows in one transaction. When
  /// [tombstone] is true (a user-initiated shelf/library delete), a
  /// `book_tombstones` row is recorded so a later backup MERGE import never
  /// resurrects this book from an old backup (TODO-1195 part B). Internal
  /// deletes that are NOT user intent (e.g. an import-rollback, or stripping a
  /// book from an export copy) pass the default false so no tombstone leaks.
  Future<int> deleteEpubBook(
    String bookKey, {
    bool tombstone = false,
  }) => transaction(() async {
    // v82：uid 键子表（reader_positions/bookmarks/book_custom_css/
    // revealed_images）按书行 uid 显式清理——这些表刻意无 SQL FK（uid 唯一
    // 性是 partial 索引，FK 会 mismatch），本函数即全量级联的唯一真相源，
    // 与 runtime foreign_keys pragma 状态无关。
    final String? bookUid =
        await (selectOnly(epubBooks)
              ..addColumns([epubBooks.uid])
              ..where(epubBooks.bookKey.equals(bookKey)))
            .map((r) => r.read(epubBooks.uid))
            .getSingleOrNull();
    if (bookUid != null && bookUid.isNotEmpty) {
      await (delete(
        readerPositions,
      )..where((t) => t.bookUid.equals(bookUid))).go();
      await (delete(bookmarks)..where((t) => t.bookUid.equals(bookUid))).go();
      await (delete(
        bookCustomCss,
      )..where((t) => t.bookUid.equals(bookUid))).go();
      await (delete(
        revealedImages,
      )..where((t) => t.bookUid.equals(bookUid))).go();
      // v89：每章状态同族（uid 键、刻意无 FK），随书一起清，否则重装同一部
      // 在线漫画会捡到上一次的已读标记。
      await (delete(
        mangaChapterStates,
      )..where((t) => t.bookUid.equals(bookUid))).go();
    }
    // SRT books linked to this epub key their cues on srt_books.uid, NOT
    // the epub bookKey, so delete those cues before dropping the srt rows.
    // (HBK-AUDIT-041 follow-up: deleteEpubBook owns the full cascade; the
    // reader source no longer deletes these rows itself.)
    final List<String> srtUids =
        await (selectOnly(srtBooks)
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
    await (delete(audiobooks)..where((t) => t.bookKey.equals(bookKey))).go();
    // TODO-616：同事务清 shelf_entry。v83 起 epub 域 entryKey = uid。
    // 若该书还登记过 'srt' 行（EPUB 附属有声书），deleteAudiobookByBookKey 已
    // 幂等清，此处只清 'epub' 行。
    if (bookUid != null && bookUid.isNotEmpty) {
      await deleteShelfEntry(MediaKind.epub, bookUid);
      // v83 顺手修的历史缺口：epub 删除此前不清合集成员行 → 计数虚高、
      // 移空自删失效、孤儿被 sync 原样发布。与 video/game 删除路径对齐。
      await removeEntryFromAllCollections(MediaKind.epub, bookUid);
    }
    if (tombstone) {
      await into(bookTombstones).insertOnConflictUpdate(
        BookTombstonesCompanion.insert(
          bookKey: bookKey,
          deletedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    return (delete(epubBooks)..where((t) => t.bookKey.equals(bookKey))).go();
  });
}
