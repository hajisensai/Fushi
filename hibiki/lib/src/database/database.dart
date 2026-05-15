import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/database/tables.dart';

part 'database.g.dart';

LazyDatabase _openDb(String dbDirectory) {
  return LazyDatabase(() async {
    final file = File(p.join(dbDirectory, 'hibiki.db'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA foreign_keys = ON');
      },
    );
  });
}

@DriftDatabase(tables: [
  MediaItems,
  AnkiMappings,
  SearchHistoryItems,
  Audiobooks,
  AudioCues,
  SrtBooks,
  ReaderPositions,
  Bookmarks,
  ReadingStatistics,
  ReadingHourlyLogs,
  Preferences,
  DictionaryMetadata,
  DictionaryHistory,
  EpubBooks,
  BookTags,
  BookTagMappings,
  Profiles,
  ProfileSettings,
  MediaTypeProfiles,
  BookProfiles,
])
class HibikiDatabase extends _$HibikiDatabase {
  HibikiDatabase(String dbDirectory) : super(_openDb(dbDirectory));
  HibikiDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 11;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          if (details.wasCreated) {
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_profile_settings_profile ON profile_settings (profile_id)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_media_type_profiles_profile ON media_type_profiles (profile_id)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_book_profiles_profile ON book_profiles (profile_id)',
            );
          }
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            if (!await _columnExists('dictionary_metadata', 'type')) {
              await m.addColumn(dictionaryMetadata, dictionaryMetadata.type);
            }
          }
          if (from < 3) {
            await m.createTable(readingHourlyLogs);
          }
          if (from < 4) {
            if (!await _columnExists('reader_positions', 'ttu_char_offset')) {
              await m.addColumn(readerPositions, readerPositions.ttuCharOffset);
            }
          }
          if (from < 5) {
            await m.createTable(epubBooks);
          }
          if (from < 6) {
            await m.createTable(bookTags);
            await m.createTable(bookTagMappings);
          }
          if (from < 7) {
            if (!await _columnExists('book_tags', 'sort_order')) {
              await m.addColumn(bookTags, bookTags.sortOrder);
            }
            await customStatement(
              'UPDATE book_tags SET sort_order = id WHERE sort_order = 0',
            );
          }
          if (from < 8) {
            await m.createTable(profiles);
            await m.createTable(profileSettings);
            await m.createTable(mediaTypeProfiles);
            await m.createTable(bookProfiles);
          }
          if (from < 9) {
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_profile_settings_profile ON profile_settings (profile_id)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_media_type_profiles_profile ON media_type_profiles (profile_id)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_book_profiles_profile ON book_profiles (profile_id)',
            );
          }
          if (from < 10) {
            await customStatement(
              'DELETE FROM book_tag_mappings '
              'WHERE book_id NOT IN (SELECT id FROM epub_books)',
            );
            await customStatement(
              'DELETE FROM book_tag_mappings '
              'WHERE tag_id NOT IN (SELECT id FROM book_tags)',
            );
            await customStatement(
              'DELETE FROM profile_settings '
              'WHERE profile_id NOT IN (SELECT id FROM profiles)',
            );
            await customStatement(
              'DELETE FROM media_type_profiles '
              'WHERE profile_id NOT IN (SELECT id FROM profiles)',
            );
            await customStatement(
              'DELETE FROM book_profiles '
              'WHERE profile_id NOT IN (SELECT id FROM profiles)',
            );
          }
          if (from < 11) {
            await m.createTable(bookmarks);
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_bookmarks_ttu_book_id_created '
              'ON bookmarks (ttu_book_id, created_at DESC)',
            );
            await migrateLegacyBookmarkPreferences();
          }
        },
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_profile_settings_profile ON profile_settings (profile_id)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_media_type_profiles_profile ON media_type_profiles (profile_id)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_book_profiles_profile ON book_profiles (profile_id)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_bookmarks_ttu_book_id_created '
            'ON bookmarks (ttu_book_id, created_at DESC)',
          );
        },
      );

  static final RegExp _identifierRe = RegExp(r'^[a-zA-Z_]\w*$');

  Future<bool> _columnExists(String tableName, String columnName) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
          tableName, 'tableName', 'not a valid identifier');
    }
    if (!_identifierRe.hasMatch(columnName)) {
      throw ArgumentError.value(
          columnName, 'columnName', 'not a valid identifier');
    }
    final rows = await customSelect('PRAGMA table_info($tableName)').get();
    return rows.any((row) => row.read<String>('name') == columnName);
  }

  Future<bool> _tableExists(String tableName) async {
    if (!_identifierRe.hasMatch(tableName)) {
      throw ArgumentError.value(
          tableName, 'tableName', 'not a valid identifier');
    }
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable<String>(tableName)],
    ).get();
    return rows.isNotEmpty;
  }

  // ── preferences helpers ─────────────────────────────────────────
  Future<String?> getPref(String key) async {
    final q = select(preferences)..where((t) => t.key.equals(key));
    final row = await q.getSingleOrNull();
    return row?.value;
  }

  Future<void> setPref(String key, String value) async {
    await into(preferences).insertOnConflictUpdate(
      PreferencesCompanion.insert(key: key, value: value),
    );
  }

  Future<T> getPrefTyped<T>(String key, T defaultValue) async {
    final raw = await getPref(key);
    if (raw == null) return defaultValue;
    if (T == int) return int.parse(raw) as T;
    if (T == double) return double.parse(raw) as T;
    if (T == bool) return (raw == 'true') as T;
    return raw as T;
  }

  Future<void> setPrefTyped<T>(String key, T value) =>
      setPref(key, value.toString());

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
    final Map<String, String> allPrefs = await getAllPrefs();
    await transaction(() async {
      for (final MapEntry<String, String> entry in allPrefs.entries) {
        if (!entry.key.startsWith('bookmarks_')) continue;
        final int? ttuBookId =
            int.tryParse(entry.key.substring('bookmarks_'.length));
        if (ttuBookId == null || entry.value.isEmpty) continue;
        final int existing = await (selectOnly(bookmarks)
              ..where(bookmarks.ttuBookId.equals(ttuBookId))
              ..addColumns([bookmarks.id.count()]))
            .map((row) => row.read(bookmarks.id.count()) ?? 0)
            .getSingle();
        if (existing > 0) continue;
        List<dynamic> list;
        try {
          list = jsonDecode(entry.value) as List<dynamic>;
        } catch (_) {
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
        await customStatement(
          'DELETE FROM preferences WHERE key = ?',
          [entry.key],
        );
      }
    });
  }

  // ── media items ─────────────────────────────────────────────────
  Future<List<MediaItemRow>> getAllMediaItems() =>
      (select(mediaItems)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<void> upsertMediaItem(MediaItemsCompanion item) =>
      into(mediaItems).insertOnConflictUpdate(item);

  Future<int> deleteMediaItemByUniqueKey(String uk) =>
      (delete(mediaItems)..where((t) => t.uniqueKey.equals(uk))).go();

  Future<int> deleteMediaItemById(int id) =>
      (delete(mediaItems)..where((t) => t.id.equals(id))).go();

  Future<int> deleteMediaItemsByIdentifier(String ident) =>
      (delete(mediaItems)..where((t) => t.mediaIdentifier.equals(ident))).go();

  Future<List<MediaItemRow>> getMediaItemsByType(String typeId) =>
      (select(mediaItems)
            ..where((t) => t.mediaTypeIdentifier.equals(typeId))
            ..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<List<MediaItemRow>> getMediaItemsBySource(String sourceId) =>
      (select(mediaItems)
            ..where((t) => t.mediaSourceIdentifier.equals(sourceId))
            ..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<MediaItemRow?> getMediaItemByUniqueKey(String uk) =>
      (select(mediaItems)..where((t) => t.uniqueKey.equals(uk)))
          .getSingleOrNull();

  Future<void> trimMediaHistory(String typeId, int maxItems) async {
    await transaction(() async {
      final cnt = countAll();
      final q = selectOnly(mediaItems)
        ..where(mediaItems.mediaTypeIdentifier.equals(typeId))
        ..addColumns([cnt]);
      final row = await q.getSingle();
      final count = row.read(cnt)!;
      if (count <= maxItems) return;
      final surplus = count - maxItems;
      final oldestIds = await (select(mediaItems)
            ..where((t) => t.mediaTypeIdentifier.equals(typeId))
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(surplus))
          .map((r) => r.id)
          .get();
      await (delete(mediaItems)..where((t) => t.id.isIn(oldestIds))).go();
    });
  }

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

  Future<SearchHistoryItemRow?> getSearchHistoryByUniqueKey(String uk) =>
      (select(searchHistoryItems)..where((t) => t.uniqueKey.equals(uk)))
          .getSingleOrNull();

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
  Future<AudiobookRow?> getAudiobookByBookUid(String bookUid) =>
      (select(audiobooks)..where((t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  Future<List<AudiobookRow>> getAllAudiobooks() => select(audiobooks).get();

  Future<void> upsertAudiobook(AudiobooksCompanion ab) =>
      into(audiobooks).insert(ab,
          onConflict: DoUpdate((_) => ab, target: [audiobooks.bookUid]));

  Future<int> deleteAudiobookByBookUid(String bookUid) =>
      (delete(audiobooks)..where((t) => t.bookUid.equals(bookUid))).go();

  // ── audio cues ──────────────────────────────────────────────────
  Future<List<AudioCueRow>> getCuesForChapter(
          String bookUid, String chapterHref) =>
      (select(audioCues)
            ..where((t) =>
                t.bookUid.equals(bookUid) & t.chapterHref.equals(chapterHref))
            ..orderBy([(t) => OrderingTerm.asc(t.sentenceIndex)]))
          .get();

  Future<List<AudioCueRow>> getCuesForBook(String bookUid) => (select(audioCues)
        ..where((t) => t.bookUid.equals(bookUid))
        ..orderBy([
          (t) => OrderingTerm.asc(t.audioFileIndex),
          (t) => OrderingTerm.asc(t.startMs),
          (t) => OrderingTerm.asc(t.sentenceIndex),
        ]))
      .get();

  Future<AudioCueRow?> findCue(
          String bookUid, String chapterHref, int sentenceIndex) =>
      (select(audioCues)
            ..where((t) =>
                t.bookUid.equals(bookUid) &
                t.chapterHref.equals(chapterHref) &
                t.sentenceIndex.equals(sentenceIndex)))
          .getSingleOrNull();

  Future<void> replaceCuesForBook(
          String bookUid, List<AudioCuesCompanion> cues) =>
      transaction(() async {
        await (delete(audioCues)..where((t) => t.bookUid.equals(bookUid))).go();
        for (final c in cues) {
          await into(audioCues).insert(c);
        }
      });

  // ── srt books ───────────────────────────────────────────────────
  Future<List<SrtBookRow>> getAllSrtBooks() =>
      (select(srtBooks)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<SrtBookRow?> getSrtBookByUid(String uid) =>
      (select(srtBooks)..where((t) => t.uid.equals(uid))).getSingleOrNull();

  Future<SrtBookRow?> getSrtBookByTtuBookId(int ttuBookId) =>
      (select(srtBooks)..where((t) => t.ttuBookId.equals(ttuBookId)))
          .getSingleOrNull();

  Future<void> upsertSrtBook(SrtBooksCompanion book) =>
      into(srtBooks).insertOnConflictUpdate(book);

  Future<void> deleteSrtBookByUid(String uid) => transaction(() async {
        await (delete(audioCues)..where((t) => t.bookUid.equals(uid))).go();
        await (delete(srtBooks)..where((t) => t.uid.equals(uid))).go();
      });

  // ── reader positions ────────────────────────────────────────────
  Future<ReaderPositionRow?> getReaderPosition(int ttuBookId) =>
      (select(readerPositions)..where((t) => t.ttuBookId.equals(ttuBookId)))
          .getSingleOrNull();

  Future<void> upsertReaderPosition(ReaderPositionsCompanion pos) =>
      into(readerPositions).insert(
        pos,
        onConflict: DoUpdate(
          (old) => pos,
          target: [readerPositions.ttuBookId],
        ),
      );

  Future<int> deleteReaderPosition(int ttuBookId) =>
      (delete(readerPositions)..where((t) => t.ttuBookId.equals(ttuBookId)))
          .go();

  // ── reading statistics ──────────────────────────────────────────
  Future<void> upsertReadingStatistic(ReadingStatisticsCompanion stat) =>
      into(readingStatistics).insert(
        stat,
        onConflict: DoUpdate(
          (old) => ReadingStatisticsCompanion(
            charactersRead: stat.charactersRead,
            readingTimeMs: stat.readingTimeMs,
            lastStatisticModified: stat.lastStatisticModified,
          ),
          target: [readingStatistics.title, readingStatistics.dateKey],
        ),
      );

  Future<void> addReadingStatistic({
    required String title,
    required String dateKey,
    required int charsRead,
    required int timeMs,
  }) =>
      transaction(() async {
        final existing = await (select(readingStatistics)
              ..where((t) => t.title.equals(title) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(readingStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(ReadingStatisticsCompanion(
            charactersRead: Value(existing.charactersRead + charsRead),
            readingTimeMs: Value(existing.readingTimeMs + timeMs),
            lastStatisticModified: Value(DateTime.now().millisecondsSinceEpoch),
          ));
        } else {
          await into(readingStatistics).insert(
            ReadingStatisticsCompanion.insert(
              title: title,
              dateKey: dateKey,
              charactersRead: charsRead,
              readingTimeMs: timeMs,
              lastStatisticModified: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
      });

  Future<List<ReadingStatisticRow>> getAllReadingStatistics() =>
      select(readingStatistics).get();

  // ── reading hourly logs ─────────────────────────────────────────
  Future<void> addHourlyReadingTime({
    required String dateKey,
    required int hour,
    required int deltaMs,
  }) =>
      transaction(() async {
        final existing = await (select(readingHourlyLogs)
              ..where((t) => t.dateKey.equals(dateKey) & t.hour.equals(hour)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(readingHourlyLogs)
                ..where((t) => t.id.equals(existing.id)))
              .write(ReadingHourlyLogsCompanion(
            readingTimeMs: Value(existing.readingTimeMs + deltaMs),
          ));
        } else {
          await into(readingHourlyLogs).insert(
            ReadingHourlyLogsCompanion.insert(
              dateKey: dateKey,
              hour: hour,
              readingTimeMs: deltaMs,
            ),
          );
        }
      });

  Future<List<ReadingHourlyLogRow>> getHourlyLogsForDate(String dateKey) =>
      (select(readingHourlyLogs)..where((t) => t.dateKey.equals(dateKey)))
          .get();

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
        for (final item in items) {
          await into(dictionaryHistory).insert(item);
        }
      });

  Future<int> clearDictionaryHistory() => delete(dictionaryHistory).go();

  // ── epub books ──────────────────────────────────────────────────
  Future<List<EpubBookRow>> getAllEpubBooks() =>
      (select(epubBooks)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  Future<EpubBookRow?> getEpubBook(int id) =>
      (select(epubBooks)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<int> insertEpubBook(EpubBooksCompanion book) =>
      into(epubBooks).insert(book);

  Future<int> insertEpubBookOrIgnore(EpubBooksCompanion book) =>
      into(epubBooks).insert(book, mode: InsertMode.insertOrIgnore);

  Future<void> updateEpubBookTitle(int bookId, String title) =>
      (update(epubBooks)..where((t) => t.id.equals(bookId)))
          .write(EpubBooksCompanion(title: Value(title)));

  Future<void> updateEpubBookPath(int bookId, String epubPath) =>
      (update(epubBooks)..where((t) => t.id.equals(bookId)))
          .write(EpubBooksCompanion(epubPath: Value(epubPath)));

  Future<int> deleteEpubBook(int id) =>
      (delete(epubBooks)..where((t) => t.id.equals(id))).go();

  // ── book tags ───────────────────────────────────────────────────
  Future<List<BookTagRow>> getAllTags() => (select(bookTags)
        ..orderBy([
          (t) => OrderingTerm.asc(t.sortOrder),
          (t) => OrderingTerm.asc(t.createdAt),
        ]))
      .get();

  Future<List<BookTagRow>> getTagsForBook(int bookId) {
    final query = select(bookTags).join([
      innerJoin(
        bookTagMappings,
        bookTagMappings.tagId.equalsExp(bookTags.id),
      ),
    ])
      ..where(bookTagMappings.bookId.equals(bookId))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  Future<Set<int>> getBookIdsForAnyTag(Set<int> tagIds) async {
    if (tagIds.isEmpty) return {};
    final query = selectOnly(bookTagMappings)
      ..addColumns([bookTagMappings.bookId])
      ..where(bookTagMappings.tagId.isIn(tagIds));
    final rows = await query.get();
    return rows.map((row) => row.read(bookTagMappings.bookId)!).toSet();
  }

  Future<int> createTag(String name, int colorValue) async {
    final maxQuery = selectOnly(bookTags)
      ..addColumns([bookTags.sortOrder.max()]);
    final maxRow = await maxQuery.getSingleOrNull();
    final int nextOrder = (maxRow?.read(bookTags.sortOrder.max()) ?? 0) + 1;
    return into(bookTags).insert(
      BookTagsCompanion.insert(
        name: name,
        colorValue: Value(colorValue),
        sortOrder: Value(nextOrder),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> updateTag(int id, {String? name, int? colorValue}) =>
      (update(bookTags)..where((t) => t.id.equals(id))).write(
        BookTagsCompanion(
          name: name != null ? Value(name) : const Value.absent(),
          colorValue:
              colorValue != null ? Value(colorValue) : const Value.absent(),
        ),
      );

  Future<int> deleteTag(int id) =>
      (delete(bookTags)..where((t) => t.id.equals(id))).go();

  Future<void> setTagsForBook(int bookId, Set<int> tagIds) =>
      transaction(() async {
        final existing = await (select(bookTagMappings)
              ..where((t) => t.bookId.equals(bookId)))
            .get();
        final existingTagIds = existing.map((e) => e.tagId).toSet();

        final toRemove = existingTagIds.difference(tagIds);
        final toAdd = tagIds.difference(existingTagIds);

        for (final tagId in toRemove) {
          await (delete(bookTagMappings)
                ..where((t) => t.bookId.equals(bookId) & t.tagId.equals(tagId)))
              .go();
        }
        for (final tagId in toAdd) {
          await into(bookTagMappings).insert(
            BookTagMappingsCompanion.insert(
              bookId: bookId,
              tagId: tagId,
            ),
          );
        }
      });

  Future<void> addTagToBook(int bookId, int tagId) =>
      into(bookTagMappings).insert(
        BookTagMappingsCompanion.insert(bookId: bookId, tagId: tagId),
        mode: InsertMode.insertOrIgnore,
      );

  Future<void> removeTagFromBook(int bookId, int tagId) =>
      (delete(bookTagMappings)
            ..where((t) => t.bookId.equals(bookId) & t.tagId.equals(tagId)))
          .go();

  Future<Set<int>> getBookIdsForAllTags(Set<int> tagIds) async {
    if (tagIds.isEmpty) return {};
    final tagCount = tagIds.length;
    final placeholders = List.generate(tagCount, (_) => '?').join(',');
    final variables = <Variable>[
      ...tagIds.map((id) => Variable<int>(id)),
      Variable<int>(tagCount),
    ];
    final rows = await customSelect(
      'SELECT book_id FROM book_tag_mappings '
      'WHERE tag_id IN ($placeholders) '
      'GROUP BY book_id '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: variables,
    ).get();
    return rows.map((row) => row.read<int>('book_id')).toSet();
  }

  Future<List<BookTagMappingRow>> getAllBookTagMappings() =>
      select(bookTagMappings).get();

  Future<void> reorderTags(List<int> orderedTagIds) => transaction(() async {
        for (int i = 0; i < orderedTagIds.length; i++) {
          await (update(bookTags)..where((t) => t.id.equals(orderedTagIds[i])))
              .write(BookTagsCompanion(sortOrder: Value(i)));
        }
      });

  Future<int> countBooksForTag(int tagId) async {
    final cnt = countAll();
    final q = selectOnly(bookTagMappings)
      ..where(bookTagMappings.tagId.equals(tagId))
      ..addColumns([cnt]);
    final row = await q.getSingle();
    return row.read(cnt)!;
  }

  // ── profiles ──────────────────────────────────────────────────────
  Future<List<ProfileRow>> getAllProfiles() =>
      (select(profiles)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

  Future<ProfileRow?> getProfileById(int id) =>
      (select(profiles)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<int> insertProfile(ProfilesCompanion p) => into(profiles).insert(p);

  Future<void> updateProfileName(int id, String name) =>
      (update(profiles)..where((t) => t.id.equals(id))).write(
        ProfilesCompanion(
          name: Value(name),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<int> deleteProfile(int id) =>
      (delete(profiles)..where((t) => t.id.equals(id))).go();

  Future<int> countProfiles() async {
    final cnt = countAll();
    final q = selectOnly(profiles)..addColumns([cnt]);
    final row = await q.getSingle();
    return row.read(cnt)!;
  }

  // ── profile settings ─────────────────────────────────────────────
  Future<List<ProfileSettingRow>> getProfileSettings(int profileId) =>
      (select(profileSettings)..where((t) => t.profileId.equals(profileId)))
          .get();

  Future<void> upsertProfileSetting(ProfileSettingsCompanion s) =>
      into(profileSettings).insert(
        s,
        onConflict: DoUpdate(
          (old) => ProfileSettingsCompanion(value: s.value),
          target: [
            profileSettings.profileId,
            profileSettings.category,
            profileSettings.key,
          ],
        ),
      );

  Future<void> replaceProfileSettings(
          int profileId, List<ProfileSettingsCompanion> settings) =>
      transaction(() async {
        await (delete(profileSettings)
              ..where((t) => t.profileId.equals(profileId)))
            .go();
        for (final s in settings) {
          await into(profileSettings).insert(s);
        }
      });

  // ── media type profiles ──────────────────────────────────────────
  Future<List<MediaTypeProfileRow>> getAllMediaTypeProfiles() =>
      select(mediaTypeProfiles).get();

  Future<MediaTypeProfileRow?> getMediaTypeProfile(String mediaType) =>
      (select(mediaTypeProfiles)..where((t) => t.mediaType.equals(mediaType)))
          .getSingleOrNull();

  Future<void> setMediaTypeProfile(String mediaType, int profileId) =>
      into(mediaTypeProfiles).insertOnConflictUpdate(
        MediaTypeProfilesCompanion.insert(
          mediaType: mediaType,
          profileId: profileId,
        ),
      );

  Future<int> deleteMediaTypeProfile(String mediaType) =>
      (delete(mediaTypeProfiles)..where((t) => t.mediaType.equals(mediaType)))
          .go();

  // ── book profiles ────────────────────────────────────────────────
  Future<BookProfileRow?> getBookProfile(String bookUid) =>
      (select(bookProfiles)..where((t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  Future<void> setBookProfile(String bookUid, int profileId) =>
      into(bookProfiles).insertOnConflictUpdate(
        BookProfilesCompanion.insert(
          bookUid: bookUid,
          profileId: profileId,
        ),
      );

  Future<int> deleteBookProfile(String bookUid) =>
      (delete(bookProfiles)..where((t) => t.bookUid.equals(bookUid))).go();
}
