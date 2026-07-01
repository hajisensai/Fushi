import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:hibiki/src/sync/aggregate_merge_service.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_audio/hibiki_audio.dart' show FavoriteSentence;
import 'package:hibiki_core/hibiki_core.dart';

/// ATTACH-then-upsert merge engine for backup "merge" import (TODO-888).
///
/// The current device DB is the live target; a backup DB (already migrated to
/// the current schema and ATTACHed as [_srcAlias]) is the source. Every table
/// is merged row-by-row by its BUSINESS key, never by autoincrement `id` (two
/// DBs' ids collide and carry no cross-device meaning). The whole run executes
/// inside ONE [HibikiDatabase.transaction] so a mid-merge failure rolls the
/// target back to byte-for-byte its pre-merge state (the caller also keeps a
/// `pre-merge.bak` copy as a belt-and-braces net).
///
/// Conflict resolution mirrors the existing sync semantics:
/// - content lists (books / videos / dictionaries / audio) -> push-only UNION.
/// - progress (reader positions) -> LWW by `updatedAt` (larger wins).
/// - statistics (reading / video / hourly / mining) -> per-bucket MAX-union, so
///   re-importing the same backup is idempotent and never double-counts.
/// - favorites / mined sentences -> dedupe-UNION (both kept, duplicates dropped).
/// - favorite SENTENCES (a `favorite_sentences` preference JSON blob, NOT a
///   table) -> content dedupe-UNION, delegated to [AggregateMergeService] (the
///   ATTACH SQL cannot merge a JSON blob, so this used to be dropped entirely).
/// - tags / profiles -> UNION by name with cross-DB id REMAPPING for every child
///   row referencing the autoincrement id.
///
/// The aggregate MAX-union / dedupe-union families are the relational
/// projection of the pure folds defined in [AggregateMergeService]; that class
/// is the single source of truth for those semantics and is what online sync
/// (TODO-1056 phase B/C) calls directly on materialised snapshots. The
/// favorite-sentence pref blob is merged here by literally calling that pure
/// service, so its logic lives in exactly one place.
///
/// Device-local rows are deliberately skipped: `media_sources` (device-local
/// scan paths), `sync_baselines` (would corrupt later incremental sync fork
/// detection), and device-local sync prefs ([SyncRepository.deviceLocalPrefKeys]).
class BackupMergeEngine {
  BackupMergeEngine(this._db, {String srcAlias = 'mergesrc'})
      : _srcAlias = srcAlias;

  final HibikiDatabase _db;
  final String _srcAlias;

  /// Preference key holding the favorite-sentence JSON list. Mirrors
  /// `FavoriteSentenceRepository._key`; kept in sync by
  /// `favorite_sentence_pref_key_guard_test.dart`.
  static const String _favoriteSentencesPrefKey = 'favorite_sentences';

  /// Runs the whole merge inside a single transaction. The backup DB must
  /// already be ATTACHed as [_srcAlias] on [_db]'s connection by the caller.
  Future<void> merge() async {
    await _db.transaction(() async {
      await _insertMissing('epub_books', 'book_key');
      await _insertMissing('video_books', 'book_uid');
      await _insertMissing('dictionary_metadata', 'name');
      await _insertMissing('srt_books', 'uid');
      await _insertMissing('audiobooks', 'book_key');
      await _insertAudioCues();
      await _mergeReaderPositions();
      await _mergeReadingStatistics();
      await _mergeVideoWatchStatistics();
      await _mergeHourlyLogs('reading_hourly_logs', 'reading_time_ms');
      await _mergeHourlyLogs('video_hourly_logs', 'watch_time_ms');
      await _mergeMiningStatistics();
      await _mergeFavoriteWords();
      await _mergeMinedSentences();
      await _mergeFavoriteSentencePrefs();
      await _mergeTagsAndMappings();
      await _mergeProfilesAndChildren();
      await _insertMissing('media_items', 'unique_key');
      await _insertMissing('search_history_items', 'unique_key');
      await _insertMissing('anki_mappings', 'label');
      await _mergeBookmarks();
      await _mergeAudiobookPositionPrefs();
    });
  }

  /// Column names of [table] excluding autoincrement `id` (so INSERT...SELECT
  /// lets SQLite assign fresh ids). Both DBs are at the current schema so the
  /// target's column set matches src.
  Future<List<String>> _columnsExceptId(String table) async {
    final rows = await _db.customSelect('PRAGMA table_info($table)').get();
    return rows
        .map((r) => r.data['name'] as String)
        .where((String c) => c != 'id')
        // Quote identifiers so SQL reserved words (order / key / value / ...)
        // used as column names don't break the generated statements.
        .map((String c) => '"$c"')
        .toList();
  }

  /// UNION push-only: insert every src row whose [keyColumn] value is not
  /// already present in the target. Explicit column list (minus `id`) so SQLite
  /// assigns fresh autoincrement ids and never reuses the src id.
  Future<void> _insertMissing(String table, String keyColumn) async {
    final List<String> cols = await _columnsExceptId(table);
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO $table ($colList) '
      'SELECT $colList FROM $_srcAlias.$table AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM $table AS t '
      'WHERE t.$keyColumn = s.$keyColumn)',
    );
  }

  /// AudioCues: import only cues for book_keys with no existing cues in the
  /// target (idempotent, no duplicate streams).
  Future<void> _insertAudioCues() async {
    final List<String> cols = await _columnsExceptId('audio_cues');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO audio_cues ($colList) '
      'SELECT $colList FROM $_srcAlias.audio_cues AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM audio_cues AS t '
      'WHERE t.book_key = s.book_key)',
    );
  }

  /// Reader positions LWW: a src row wins only when the target lacks a row for
  /// that book_key, or the src `updated_at` is strictly greater.
  Future<void> _mergeReaderPositions() async {
    final List<String> cols = await _columnsExceptId('reader_positions');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO reader_positions ($colList) '
      'SELECT $colList FROM $_srcAlias.reader_positions AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM reader_positions AS t '
      'WHERE t.book_key = s.book_key)',
    );
    final String setClause = cols
        .where((String c) => c != '"book_key"')
        .map((String c) => '$c = ('
            'SELECT s.$c FROM $_srcAlias.reader_positions AS s '
            'WHERE s.book_key = reader_positions.book_key)')
        .join(', ');
    await _db.customStatement(
      'UPDATE reader_positions SET $setClause '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.reader_positions AS s '
      'WHERE s.book_key = reader_positions.book_key '
      'AND s.updated_at > reader_positions.updated_at)',
    );
  }

  /// ReadingStatistics MAX-union per {title, dateKey} bucket. Grouping is by
  /// {title, date_key} so a dateKey with many titles is never folded into one.
  Future<void> _mergeReadingStatistics() async {
    await _db.customStatement(
      'INSERT INTO reading_statistics '
      '(title, date_key, characters_read, reading_time_ms, '
      'last_statistic_modified) '
      'SELECT title, date_key, characters_read, reading_time_ms, '
      'last_statistic_modified FROM $_srcAlias.reading_statistics AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM reading_statistics AS t '
      'WHERE t.title = s.title AND t.date_key = s.date_key)',
    );
    await _db.customStatement(
      'UPDATE reading_statistics SET '
      'characters_read = MAX(characters_read, ('
      'SELECT s.characters_read FROM $_srcAlias.reading_statistics AS s '
      'WHERE s.title = reading_statistics.title '
      'AND s.date_key = reading_statistics.date_key)), '
      'reading_time_ms = MAX(reading_time_ms, ('
      'SELECT s.reading_time_ms FROM $_srcAlias.reading_statistics AS s '
      'WHERE s.title = reading_statistics.title '
      'AND s.date_key = reading_statistics.date_key)), '
      'last_statistic_modified = MAX(last_statistic_modified, ('
      'SELECT s.last_statistic_modified FROM $_srcAlias.reading_statistics AS s '
      'WHERE s.title = reading_statistics.title '
      'AND s.date_key = reading_statistics.date_key)) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.reading_statistics AS s '
      'WHERE s.title = reading_statistics.title '
      'AND s.date_key = reading_statistics.date_key)',
    );
  }

  /// VideoWatchStatistics MAX-union per {title, dateKey}.
  Future<void> _mergeVideoWatchStatistics() async {
    await _db.customStatement(
      'INSERT INTO video_watch_statistics '
      '(title, date_key, subtitle_chars, watch_time_ms, last_modified) '
      'SELECT title, date_key, subtitle_chars, watch_time_ms, last_modified '
      'FROM $_srcAlias.video_watch_statistics AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM video_watch_statistics AS t '
      'WHERE t.title = s.title AND t.date_key = s.date_key)',
    );
    await _db.customStatement(
      'UPDATE video_watch_statistics SET '
      'subtitle_chars = MAX(subtitle_chars, ('
      'SELECT s.subtitle_chars FROM $_srcAlias.video_watch_statistics AS s '
      'WHERE s.title = video_watch_statistics.title '
      'AND s.date_key = video_watch_statistics.date_key)), '
      'watch_time_ms = MAX(watch_time_ms, ('
      'SELECT s.watch_time_ms FROM $_srcAlias.video_watch_statistics AS s '
      'WHERE s.title = video_watch_statistics.title '
      'AND s.date_key = video_watch_statistics.date_key)), '
      'last_modified = MAX(last_modified, ('
      'SELECT s.last_modified FROM $_srcAlias.video_watch_statistics AS s '
      'WHERE s.title = video_watch_statistics.title '
      'AND s.date_key = video_watch_statistics.date_key)) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.video_watch_statistics AS s '
      'WHERE s.title = video_watch_statistics.title '
      'AND s.date_key = video_watch_statistics.date_key)',
    );
  }

  /// Hourly logs MAX-union per {dateKey, hour}. [valueColumn] is the single
  /// duration column (reading_time_ms / watch_time_ms).
  Future<void> _mergeHourlyLogs(String table, String valueColumn) async {
    await _db.customStatement(
      'INSERT INTO $table (date_key, hour, $valueColumn) '
      'SELECT date_key, hour, $valueColumn FROM $_srcAlias.$table AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM $table AS t '
      'WHERE t.date_key = s.date_key AND t.hour = s.hour)',
    );
    await _db.customStatement(
      'UPDATE $table SET '
      '$valueColumn = MAX($valueColumn, ('
      'SELECT s.$valueColumn FROM $_srcAlias.$table AS s '
      'WHERE s.date_key = $table.date_key AND s.hour = $table.hour)) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.$table AS s '
      'WHERE s.date_key = $table.date_key AND s.hour = $table.hour)',
    );
  }

  /// MiningStatistics MAX-union per {sourceType, dateKey} -- MAX, never SUM, so
  /// a re-import of the same backup stays idempotent (mirrors setMiningCount).
  Future<void> _mergeMiningStatistics() async {
    await _db.customStatement(
      'INSERT INTO mining_statistics (source_type, date_key, "count") '
      'SELECT source_type, date_key, "count" FROM $_srcAlias.mining_statistics '
      'AS s WHERE NOT EXISTS (SELECT 1 FROM mining_statistics AS t '
      'WHERE t.source_type = s.source_type AND t.date_key = s.date_key)',
    );
    await _db.customStatement(
      'UPDATE mining_statistics SET "count" = MAX("count", ('
      'SELECT s."count" FROM $_srcAlias.mining_statistics AS s '
      'WHERE s.source_type = mining_statistics.source_type '
      'AND s.date_key = mining_statistics.date_key)) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.mining_statistics AS s '
      'WHERE s.source_type = mining_statistics.source_type '
      'AND s.date_key = mining_statistics.date_key)',
    );
  }

  /// FavoriteWords dedupe-UNION by {expression, reading, sourceType} (declared
  /// unique key -> the duplicate is dropped, the earlier createdAt kept).
  Future<void> _mergeFavoriteWords() async {
    final List<String> cols = await _columnsExceptId('favorite_words');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO favorite_words ($colList) '
      'SELECT $colList FROM $_srcAlias.favorite_words AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM favorite_words AS t '
      'WHERE t.expression = s.expression AND t.reading = s.reading '
      'AND t.source_type = s.source_type)',
    );
  }

  /// MinedSentences have NO unique constraint, so INSERT OR IGNORE would never
  /// dedupe. Dedupe by content fingerprint {source, date_key, expression,
  /// reading, created_at} via NOT EXISTS (select-then-insert at SQL scope).
  Future<void> _mergeMinedSentences() async {
    final List<String> cols = await _columnsExceptId('mined_sentences');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO mined_sentences ($colList) '
      'SELECT $colList FROM $_srcAlias.mined_sentences AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM mined_sentences AS t '
      'WHERE t.source = s.source AND t.date_key = s.date_key '
      'AND t.expression = s.expression AND t.reading = s.reading '
      'AND t.created_at = s.created_at)',
    );
  }

  /// Favorite SENTENCES dedupe-UNION. Unlike favorite words / mined sentences
  /// these are NOT a table but a JSON list stored in the target's and src's
  /// `preferences` row `favorite_sentences`, so the ATTACH SQL merge cannot
  /// touch them -- before this the backup's favorite sentences were silently
  /// dropped. Read both blobs, delegate the union+dedupe to the pure
  /// [AggregateMergeService.mergeFavoriteSentences] (single source of truth for
  /// this semantic, shared with online sync), and write the merged blob back.
  ///
  /// A missing/empty src blob is a no-op; a missing target blob just adopts the
  /// merged src set. Runs inside the merge transaction, so a failure here rolls
  /// the whole merge back with everything else.
  Future<void> _mergeFavoriteSentencePrefs() async {
    final String? targetRaw = await _readPref(isSrc: false);
    final String? srcRaw = await _readPref(isSrc: true);
    // Nothing to merge in from the backup: leave the device's blob untouched.
    if (srcRaw == null || srcRaw.isEmpty) return;

    final List<FavoriteSentence> localList =
        _decodeFavoriteSentences(targetRaw);
    final List<FavoriteSentence> remoteList = _decodeFavoriteSentences(srcRaw);
    final List<FavoriteSentence> merged =
        AggregateMergeService.mergeFavoriteSentences(localList, remoteList);

    final String mergedJson =
        jsonEncode(merged.map((FavoriteSentence s) => s.toJson()).toList());
    // Upsert the target preference row (INSERT OR REPLACE on the key PK).
    await _db.customStatement(
      'INSERT OR REPLACE INTO preferences ("key", "value") VALUES (?, ?)',
      <Object?>[_favoriteSentencesPrefKey, mergedJson],
    );
  }

  /// Reads the `favorite_sentences` preference value from either the target
  /// ([isSrc] false) or the ATTACHed src ([isSrc] true). Returns null when the
  /// row is absent.
  Future<String?> _readPref({required bool isSrc}) async {
    final String table = isSrc ? '$_srcAlias.preferences' : 'preferences';
    final rows = await _db.customSelect(
      'SELECT "value" FROM $table WHERE "key" = ?',
      variables: <Variable<Object>>[
        Variable<String>(_favoriteSentencesPrefKey)
      ],
    ).get();
    if (rows.isEmpty) return null;
    return rows.first.data['value'] as String?;
  }

  /// Decodes a `favorite_sentences` JSON blob into models, tolerating a
  /// null/empty/malformed value (returns an empty list) so a corrupt pref on
  /// either side never aborts the whole merge.
  static List<FavoriteSentence> _decodeFavoriteSentences(String? raw) {
    if (raw == null || raw.isEmpty) return const <FavoriteSentence>[];
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return const <FavoriteSentence>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(FavoriteSentence.fromJson)
          .toList();
    } catch (_) {
      return const <FavoriteSentence>[];
    }
  }

  /// BookTags UNION by name (device keeps its own tag row + id on a name clash),
  /// then the three mapping tables with the src tagId REMAPPED to the target id
  /// resolved by tag name. Owner rows (book/srt/video) must already be merged.
  Future<void> _mergeTagsAndMappings() async {
    await _db.customStatement(
      'INSERT INTO book_tags (name, color_value, sort_order, created_at) '
      'SELECT name, color_value, sort_order, created_at '
      'FROM $_srcAlias.book_tags AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM book_tags AS t WHERE t.name = s.name)',
    );
    await _db.customStatement(
      'INSERT INTO book_tag_mappings (book_key, tag_id) '
      'SELECT sm.book_key, tt.id '
      'FROM $_srcAlias.book_tag_mappings AS sm '
      'JOIN $_srcAlias.book_tags AS st ON st.id = sm.tag_id '
      'JOIN book_tags AS tt ON tt.name = st.name '
      'WHERE EXISTS '
      '(SELECT 1 FROM epub_books AS b WHERE b.book_key = sm.book_key) '
      'AND NOT EXISTS (SELECT 1 FROM book_tag_mappings AS m '
      'WHERE m.book_key = sm.book_key AND m.tag_id = tt.id)',
    );
    await _db.customStatement(
      'INSERT INTO srt_book_tag_mappings (srt_book_id, tag_id) '
      'SELECT ts.id, tt.id '
      'FROM $_srcAlias.srt_book_tag_mappings AS sm '
      'JOIN $_srcAlias.srt_books AS ss ON ss.id = sm.srt_book_id '
      'JOIN srt_books AS ts ON ts.uid = ss.uid '
      'JOIN $_srcAlias.book_tags AS st ON st.id = sm.tag_id '
      'JOIN book_tags AS tt ON tt.name = st.name '
      'WHERE NOT EXISTS (SELECT 1 FROM srt_book_tag_mappings AS m '
      'WHERE m.srt_book_id = ts.id AND m.tag_id = tt.id)',
    );
    await _db.customStatement(
      'INSERT INTO video_book_tag_mappings (video_book_uid, tag_id) '
      'SELECT sm.video_book_uid, tt.id '
      'FROM $_srcAlias.video_book_tag_mappings AS sm '
      'JOIN $_srcAlias.book_tags AS st ON st.id = sm.tag_id '
      'JOIN book_tags AS tt ON tt.name = st.name '
      'WHERE EXISTS (SELECT 1 FROM video_books AS v '
      'WHERE v.book_uid = sm.video_book_uid) '
      'AND NOT EXISTS (SELECT 1 FROM video_book_tag_mappings AS m '
      'WHERE m.video_book_uid = sm.video_book_uid AND m.tag_id = tt.id)',
    );
  }

  /// Profiles UNION by name (device keeps its own profile + id on a name clash),
  /// then the three child tables with src profile_id REMAPPED to the target id
  /// resolved by profile name (necessary because Profiles.id is autoincrement --
  /// FK children would otherwise dangle / cross).
  Future<void> _mergeProfilesAndChildren() async {
    await _db.customStatement(
      'INSERT INTO profiles (name, created_at, updated_at) '
      'SELECT name, created_at, updated_at FROM $_srcAlias.profiles AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM profiles AS t WHERE t.name = s.name)',
    );
    await _db.customStatement(
      'INSERT INTO profile_settings (profile_id, category, "key", "value") '
      'SELECT tp.id, sps.category, sps."key", sps."value" '
      'FROM $_srcAlias.profile_settings AS sps '
      'JOIN $_srcAlias.profiles AS sp ON sp.id = sps.profile_id '
      'JOIN profiles AS tp ON tp.name = sp.name '
      'WHERE NOT EXISTS (SELECT 1 FROM profile_settings AS m '
      'WHERE m.profile_id = tp.id AND m.category = sps.category '
      'AND m."key" = sps."key")',
    );
    await _db.customStatement(
      'INSERT INTO media_type_profiles (media_type, profile_id) '
      'SELECT smtp.media_type, tp.id '
      'FROM $_srcAlias.media_type_profiles AS smtp '
      'JOIN $_srcAlias.profiles AS sp ON sp.id = smtp.profile_id '
      'JOIN profiles AS tp ON tp.name = sp.name '
      'WHERE NOT EXISTS (SELECT 1 FROM media_type_profiles AS m '
      'WHERE m.media_type = smtp.media_type)',
    );
    await _db.customStatement(
      'INSERT INTO book_profiles (book_key, profile_id) '
      'SELECT sbp.book_key, tp.id '
      'FROM $_srcAlias.book_profiles AS sbp '
      'JOIN $_srcAlias.profiles AS sp ON sp.id = sbp.profile_id '
      'JOIN profiles AS tp ON tp.name = sp.name '
      'WHERE NOT EXISTS (SELECT 1 FROM book_profiles AS m '
      'WHERE m.book_key = sbp.book_key)',
    );
  }

  /// Bookmarks dedupe-union by {book_key, section_index, norm_char_offset,
  /// created_at}, FK-guarded on epub_books(book_key) so a bookmark for a book
  /// the backup omitted is skipped rather than violating the cascade FK.
  Future<void> _mergeBookmarks() async {
    final List<String> cols = await _columnsExceptId('bookmarks');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO bookmarks ($colList) '
      'SELECT $colList FROM $_srcAlias.bookmarks AS s '
      'WHERE EXISTS '
      '(SELECT 1 FROM epub_books AS b WHERE b.book_key = s.book_key) '
      'AND NOT EXISTS (SELECT 1 FROM bookmarks AS t '
      'WHERE t.book_key = s.book_key AND t.section_index = s.section_index '
      'AND t.norm_char_offset = s.norm_char_offset '
      'AND t.created_at = s.created_at)',
    );
  }

  /// Preferences are device settings -> kept (non-merge by default). The single
  /// exception is audiobook positions (per-book content): UNION push-only so the
  /// backup positions for books the device lacks are added, without clobbering
  /// the device's existing positions.
  Future<void> _mergeAudiobookPositionPrefs() async {
    await _db.customStatement(
      'INSERT INTO preferences ("key", "value") '
      'SELECT "key", "value" FROM $_srcAlias.preferences AS s '
      "WHERE s.\"key\" LIKE 'audiobook_pos_%' "
      'AND NOT EXISTS (SELECT 1 FROM preferences AS t WHERE t."key" = s."key")',
    );
  }
}

/// Preference keys that must never travel between devices on a merge import.
/// Re-exported for the caller / tests; the engine itself only touches audiobook
/// positions, so device-local sync prefs are inherently never merged.
List<String> mergeSkippedDeviceLocalPrefKeys() =>
    List<String>.unmodifiable(SyncRepository.deviceLocalPrefKeys);
