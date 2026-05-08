import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import 'tables.dart';

part 'database.g.dart';

LazyDatabase _openDb(String dbDirectory) {
  return LazyDatabase(() async {
    final file = File(p.join(dbDirectory, 'hibiki.db'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute('PRAGMA journal_mode=WAL');
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
  ReadingStatistics,
  ReadingHourlyLogs,
  Preferences,
  DictionaryMetadata,
  DictionaryHistory,
])
class HibikiDatabase extends _$HibikiDatabase {
  HibikiDatabase(String dbDirectory) : super(_openDb(dbDirectory));
  HibikiDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(dictionaryMetadata, dictionaryMetadata.type);
          }
          if (from < 3) {
            await m.createTable(readingHourlyLogs);
          }
          if (from < 4) {
            await m.addColumn(readerPositions, readerPositions.ttuCharOffset);
          }
        },
      );

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

  Future<Map<String, String>> getAllPrefs() async {
    final rows = await select(preferences).get();
    return Map.fromEntries(rows.map((r) => MapEntry(r.key, r.value)));
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
    final cnt = countAll();
    final q = selectOnly(mediaItems)
      ..where(mediaItems.mediaTypeIdentifier.equals(typeId))
      ..addColumns([cnt]);
    final row = await q.getSingle();
    final count = row.read(cnt)!;
    if (count <= maxItems) return;
    final surplus = count - maxItems;
    final oldest = await (select(mediaItems)
          ..where((t) => t.mediaTypeIdentifier.equals(typeId))
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(surplus))
        .get();
    for (final r in oldest) {
      await (delete(mediaItems)..where((t) => t.id.equals(r.id))).go();
    }
  }

  // ── anki mappings ───────────────────────────────────────────────
  Future<List<AnkiMappingRow>> getAllMappings() =>
      (select(ankiMappings)..orderBy([(t) => OrderingTerm.asc(t.order)])).get();

  Future<AnkiMappingRow?> getMappingByLabel(String label) =>
      (select(ankiMappings)..where((t) => t.label.equals(label)))
          .getSingleOrNull();

  Future<void> upsertMapping(AnkiMappingsCompanion m) =>
      into(ankiMappings).insert(
        m,
        onConflict: DoUpdate(
          (old) => m,
          target: [ankiMappings.label],
        ),
      );

  Future<int> deleteMappingById(int id) =>
      (delete(ankiMappings)..where((t) => t.id.equals(id))).go();

  Future<void> replaceAllMappings(List<AnkiMappingsCompanion> mappings) =>
      transaction(() async {
        await delete(ankiMappings).go();
        for (final m in mappings) {
          await into(ankiMappings).insert(m);
        }
      });

  // ── search history ──────────────────────────────────────────────
  Future<List<SearchHistoryItemRow>> getAllSearchHistoryItems() =>
      select(searchHistoryItems).get();

  Future<void> upsertSearchHistoryItem(SearchHistoryItemsCompanion item) =>
      into(searchHistoryItems).insert(
        item,
        onConflict: DoUpdate(
          (old) => item,
          target: [searchHistoryItems.uniqueKey],
        ),
      );

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
    final count = await countSearchHistory(historyKey);
    if (count <= maxItems) return;
    final surplus = count - maxItems;
    final oldest = await (select(searchHistoryItems)
          ..where((t) => t.historyKey.equals(historyKey))
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(surplus))
        .get();
    for (final row in oldest) {
      await (delete(searchHistoryItems)..where((t) => t.id.equals(row.id)))
          .go();
    }
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
}
