// 偏好 KV / 最近打开流 / 搜索历史 / 有声书（God 类拆分 2026-08：part+mixin，仓库 reader_fushi
// part 先例；mixin 是真类成员——可被测试子类 override、虚分派正常
// （extension 方案在此翻车过）；私有 mixin 不进公共 API 面。
part of 'database.dart';

mixin _FushiDbPrefsMedia
    on _$FushiDatabase, _FushiDbInfra, _FushiDbLibrary, _FushiDbTagsSync {
  // ── preferences helpers ─────────────────────────────────────────
  Future<String?> getPref(String key) async {
    final q = select(preferences)..where((t) => t.key.equals(key));
    final row = await q.getSingleOrNull();
    return row?.value;
  }

  Future<void> setPref(String key, String value) async {
    // BUG-906 (A): the business write and the version bump MUST land in one
    // transaction. Previously these were two independent awaits, so two
    // concurrent setPref calls could interleave between the insert and the
    // read-modify-write bump inside [_bumpPrefsVersion], losing an increment
    // (both read version=N, both write N+1) → :popup keeps serving a stale
    // pref cache. drift serializes transactions on the single write connection,
    // so wrapping insert+bump makes the whole write atomic w.r.t. any other
    // transactional pref write: no lost increments, and a cross-process reader
    // never observes the new value paired with a stale version.
    await transaction(() async {
      await into(preferences).insertOnConflictUpdate(
        PreferencesCompanion.insert(key: key, value: value),
      );
      // Bump the cross-process change signal for every real pref write. Skip
      // the version key itself (a direct write of it — e.g. a sync/backup
      // restore replaying the persisted counter — must NOT recursively bump on
      // top of its own value, which would double-count and break monotonic
      // alignment).
      if (key != FushiDatabase.prefsVersionKey) {
        await _bumpPrefsVersion();
      }
    });
  }

  /// Writes several preferences as ONE transaction with a SINGLE version bump.
  ///
  /// A multi-key preference (a tri-state projected onto two bool keys, a paired
  /// value+discriminator) is one logical setting: writing it through repeated
  /// [setPref] calls costs one transaction — and one fsync — per key, and
  /// leaves an observable window in which a cross-process reader sees half the
  /// setting applied (BUG-906 guarantees each key's own atomicity, not the
  /// group's). Measured on Windows/WAL: two [setPref] calls median 12.3ms vs
  /// 5.1ms for one, and the caller's UI update sits behind that whole wait.
  ///
  /// Same BUG-906 (A) invariant as [setPref]: the business writes and the bump
  /// land together, so no reader ever pairs a new value with a stale version.
  /// The bump happens once for the whole group (it is a change *signal*, not a
  /// per-key counter) and is skipped when the group only carries the version
  /// key itself. An empty map is a no-op — no transaction, no bump.
  Future<void> setPrefs(Map<String, String> entries) async {
    if (entries.isEmpty) return;
    await transaction(() async {
      for (final MapEntry<String, String> entry in entries.entries) {
        await into(preferences).insertOnConflictUpdate(
          PreferencesCompanion.insert(key: entry.key, value: entry.value),
        );
      }
      if (entries.keys
          .any((String key) => key != FushiDatabase.prefsVersionKey)) {
        await _bumpPrefsVersion();
      }
    });
  }

  /// Atomically replaces one preference only while its raw persisted value is
  /// still [expectedValue]. A successful non-version write advances
  /// [FushiDatabase.prefsVersionKey] in the same transaction; a failed comparison changes
  /// neither row.
  ///
  /// This is the DB-level primitive for migrations that start from a cached
  /// preference snapshot. An unconditional [setPref] would let an old process
  /// overwrite a newer cross-process choice after its snapshot went stale.
  Future<bool> compareAndSetPref(
    String key, {
    required String expectedValue,
    required String newValue,
  }) async {
    return transaction(() async {
      final int updated = await (update(preferences)
            ..where(
              (t) => t.key.equals(key) & t.value.equals(expectedValue),
            ))
          .write(
        PreferencesCompanion(value: Value<String>(newValue)),
      );
      if (updated != 1) return false;
      if (key != FushiDatabase.prefsVersionKey) {
        await _bumpPrefsVersion();
      }
      return true;
    });
  }

  /// Atomically increment the persisted prefs-version directly in the DB so the
  /// next cross-process read observes a strictly larger value. Encoded as a
  /// PrefCodec int (`i:N`) so it round-trips identically to every other int
  /// preference. Writes via the raw [into]/[insertOnConflictUpdate] path (NOT
  /// [setPref]) to avoid re-entering the recursion guard above.
  ///
  /// BUG-906 (A): this read-modify-write is NOT atomic on its own. It MUST be
  /// called from within an enclosing transaction — which its only two callers
  /// ([setPref] and [compareAndSetPref]) now both provide — so that drift's
  /// single-writer transaction lock serializes the read+write against every
  /// other pref write. Called bare (outside a transaction) it can lose
  /// increments under concurrency; do not add such a caller.
  Future<void> _bumpPrefsVersion() async {
    final String? raw = await getPref(FushiDatabase.prefsVersionKey);
    final int current = raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
    await into(preferences).insertOnConflictUpdate(
      PreferencesCompanion.insert(
        key: FushiDatabase.prefsVersionKey,
        value: PrefCodec.encode(current + 1),
      ),
    );
  }

  Future<T> getPrefTyped<T>(String key, T defaultValue) async {
    final raw = await getPref(key);
    if (raw == null) return defaultValue;
    return PrefCodec.decode<T>(raw, defaultValue);
  }

  Future<void> setPrefTyped<T>(String key, T value) =>
      setPref(key, PrefCodec.encode(value));

  Future<void> deletePref(String key) async {
    await (delete(preferences)..where((t) => t.key.equals(key))).go();
  }

  Future<Map<String, String>> getAllPrefs() async {
    final rows = await select(preferences).get();
    return Map.fromEntries(rows.map((r) => MapEntry(r.key, r.value)));
  }

  Future<void> migrateLegacyBookmarkPreferences() async {
    if (!await _tableExists('preferences')) {
      return;
    }
    if (!await _tableExists('bookmarks')) {
      return;
    }
    // Legacy `bookmarks_<int>` prefs predate the v16 book-key migration and key
    // on the int ttu_book_id column. After v16 that column is gone (renamed to
    // book_key) and the v16 prefs migration already drained/re-keyed these, so
    // this drainer is a no-op on the post-v16 schema. Guard on the column so it
    // only runs against the pre-v16 schema it understands.
    if (!await _columnExists('bookmarks', 'ttu_book_id')) {
      return;
    }
    final Map<String, String> allPrefs = await getAllPrefs();
    await transaction(() async {
      for (final MapEntry<String, String> entry in allPrefs.entries) {
        if (!entry.key.startsWith('bookmarks_')) continue;
        final int? ttuBookId =
            int.tryParse(entry.key.substring('bookmarks_'.length));
        if (ttuBookId == null || entry.value.isEmpty) continue;
        final QueryRow countRow = await customSelect(
          'SELECT COUNT(*) AS c FROM bookmarks WHERE ttu_book_id = ?',
          variables: [Variable<int>(ttuBookId)],
        ).getSingle();
        final int existing = countRow.read<int>('c');
        if (existing == 0) {
          List<dynamic> list;
          try {
            list = jsonDecode(entry.value) as List<dynamic>;
          } catch (_) {
            await customStatement(
              'DELETE FROM preferences WHERE key = ?',
              [entry.key],
            );
            continue;
          }
          for (final dynamic raw in list) {
            if (raw is! Map<String, dynamic>) continue;
            final int sectionIndex = raw['sectionIndex'] as int? ?? 0;
            final int normCharOffset = raw['normCharOffset'] as int? ?? 0;
            final String label = raw['label'] as String? ?? '';
            final DateTime createdAt = DateTime.tryParse(
                  raw['createdAt'] as String? ?? '',
                ) ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
            final int rowBookId = raw['ttuBookId'] as int? ?? ttuBookId;
            // bookmarks.ttu_book_id is a FK to epub_books(id). Legacy TTU ids
            // need not map to an imported epub, and INSERT OR IGNORE does NOT
            // suppress FK violations — an unmatched id would abort the whole
            // upgrade transaction (app can't open the DB). Skip orphans.
            final bookExists = await customSelect(
              'SELECT 1 FROM epub_books WHERE id = ? LIMIT 1',
              variables: [Variable<int>(rowBookId)],
            ).getSingleOrNull();
            if (bookExists == null) continue;
            await customStatement(
              'INSERT OR IGNORE INTO bookmarks '
              '(ttu_book_id, section_index, norm_char_offset, label, '
              'created_at, book_title, page_in_chapter, total_pages_in_chapter) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
              [
                rowBookId,
                sectionIndex,
                normCharOffset,
                label,
                createdAt.millisecondsSinceEpoch,
                raw['bookTitle'] as String?,
                raw['pageInChapter'] as int?,
                raw['totalPagesInChapter'] as int?,
              ],
            );
          }
        }
        await customStatement(
          'DELETE FROM preferences WHERE key = ?',
          [entry.key],
        );
      }
    });
  }

  // ── media open history（v78：取代 media_items）─────────────────────
  Future<List<MediaOpenHistoryRow>> getAllMediaOpenHistory() =>
      (select(mediaOpenHistory)
            ..orderBy([(t) => OrderingTerm.desc(t.openedAt)]))
          .get();

  /// upsert 一条最近打开（PK = (mediaSource, mediaId)，重开同条目刷新行）。
  Future<void> upsertMediaOpenHistory(MediaOpenHistoryCompanion entry) =>
      into(mediaOpenHistory).insertOnConflictUpdate(entry);

  Future<int> deleteMediaOpenHistory(String mediaSource, String mediaId) =>
      (delete(mediaOpenHistory)
            ..where((t) =>
                t.mediaSource.equals(mediaSource) & t.mediaId.equals(mediaId)))
          .go();

  Future<int> deleteMediaOpenHistoryByMediaId(String mediaId) =>
      (delete(mediaOpenHistory)..where((t) => t.mediaId.equals(mediaId))).go();

  /// 该类型只保留最近 [maxItems] 条（按 [MediaOpenHistory.openedAt] 旧者先删；
  /// 旧实现按自增 id 序 trim，v80 起时间就是唯一序）。单条批删——本方法在
  /// 每次打开媒体的热路径上，select 全列会把 snapshot（可能含迁移遗留的
  /// base64 封面）整批拉进 Dart 只为数个数（review5-6）。
  Future<void> trimMediaHistory(String typeId, int maxItems) => customStatement(
        'DELETE FROM media_open_history WHERE media_type = ? AND rowid IN ('
        'SELECT rowid FROM media_open_history WHERE media_type = ? '
        'ORDER BY opened_at DESC LIMIT -1 OFFSET ?)',
        <Object?>[typeId, typeId, maxItems],
      );

  // ── search history ──────────────────────────────────────────────
  Future<List<SearchHistoryItemRow>> getAllSearchHistoryItems() =>
      select(searchHistoryItems).get();

  Future<void> upsertSearchHistoryItem(SearchHistoryItemsCompanion item) async {
    await into(searchHistoryItems).insert(
      item,
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<int> deleteSearchHistoryByUniqueKey(String uk) =>
      (delete(searchHistoryItems)..where((t) => t.uniqueKey.equals(uk))).go();

  Future<int> clearSearchHistory(String historyKey) =>
      (delete(searchHistoryItems)
            ..where((t) => t.historyKey.equals(historyKey)))
          .go();

  Future<List<SearchHistoryItemRow>> getSearchHistory(String historyKey) =>
      (select(searchHistoryItems)
            ..where((t) => t.historyKey.equals(historyKey)))
          .get();

  Future<int> countSearchHistory(String historyKey) async {
    final cnt = countAll();
    final q = selectOnly(searchHistoryItems)
      ..where(searchHistoryItems.historyKey.equals(historyKey))
      ..addColumns([cnt]);
    final row = await q.getSingle();
    return row.read(cnt)!;
  }

  Future<void> trimSearchHistory(String historyKey, int maxItems) async {
    await transaction(() async {
      final count = await countSearchHistory(historyKey);
      if (count <= maxItems) return;
      final surplus = count - maxItems;
      final oldestIds = await (select(searchHistoryItems)
            ..where((t) => t.historyKey.equals(historyKey))
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(surplus))
          .map((r) => r.id)
          .get();
      await (delete(searchHistoryItems)..where((t) => t.id.isIn(oldestIds)))
          .go();
    });
  }

  // ── audiobooks ──────────────────────────────────────────────────
  Future<AudiobookRow?> getAudiobookByBookKey(String bookKey) =>
      (select(audiobooks)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  Future<List<AudiobookRow>> getAllAudiobooks() => select(audiobooks).get();

  Future<void> upsertAudiobook(AudiobooksCompanion ab) =>
      into(audiobooks).insert(ab,
          onConflict: DoUpdate((_) => ab, target: [audiobooks.bookKey]));

  Future<int> deleteAudiobookByBookKey(String bookKey) => transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookKey))).go();
        // TODO-616：纯有声书 shelf_entry 以 mediaType='srt'、entryKey=bookKey 登记
        // （deleteAudiobookByBookKey 拿不到 srtUid——srtUid 级联在上层 host
        // deleteAudiobook；故登记键 = 删除键 = bookKey）。幂等（删 0 行不报错）。
        await deleteShelfEntry(MediaKind.srt, bookKey);
        return (delete(audiobooks)..where((t) => t.bookKey.equals(bookKey)))
            .go();
      });

  // ── video_books ─────────────────────────────────────────────────
  Future<void> upsertVideoBook(VideoBooksCompanion vb) async {
    await into(videoBooks).insert(vb,
        onConflict: DoUpdate((_) => vb, target: [videoBooks.bookUid]));
    // 删除传播：重新加入同 bookUid 的视频清除其 sync 删除墓碑（防误判待删）。
    if (vb.bookUid.present) {
      await clearSyncDeletionTombstone('video', vb.bookUid.value);
    }
  }

  Future<VideoBookRow?> getVideoBookByBookUid(String bookUid) =>
      (select(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  Future<List<VideoBookRow>> allVideoBooks() => select(videoBooks).get();

  /// 仅在视频尚未归属来源时回填 [sourceId]。
  ///
  /// 来源重扫复用手动导入的同路径视频时使用。只写 `source_id`，避免以整行 upsert
  /// 意外覆盖观看进度、字幕、封面或用户资料；已属于其它来源的行保持原归属。
  Future<int> assignVideoBookSourceIfNull(String bookUid, int sourceId) =>
      (update(videoBooks)
            ..where(($VideoBooksTable t) =>
                t.bookUid.equals(bookUid) & t.sourceId.isNull()))
          .write(VideoBooksCompanion(sourceId: Value<int?>(sourceId)));
}
