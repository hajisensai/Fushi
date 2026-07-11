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
/// - statistics (reading / video / hourly / mining / lookup+mine counters) ->
///   per-bucket MAX-union, so re-importing the same backup is idempotent and
///   never double-counts.
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
  BackupMergeEngine(
    this._db, {
    String srcAlias = 'mergesrc',
    Set<String> carriedVideoSourcePaths = const <String>{},
  })  : _srcAlias = srcAlias,
        _carriedVideoSourcePaths = carriedVideoSourcePaths;

  final HibikiDatabase _db;
  final String _srcAlias;

  /// Source-device absolute video paths whose file actually travelled inside the
  /// backup (= `BackupMeta.videoFiles.keys`). A merged `video_books` row is only
  /// materialised when it is REACHABLE on this device: either a streaming book
  /// (its `video_path` is an `http(s)` URL, self-contained — re-opens by URL) or
  /// a local-file book whose file is in this set (so `_copyTreeIfAbsent` lands it
  /// and `_rebaseVideoPaths` re-points it). A local video whose file never
  /// travelled would otherwise import as a dead "empty video" shell that can
  /// never play (TODO-1261). The preview counter applies the SAME predicate so
  /// the confirm dialog's "will add N" matches what the merge actually inserts.
  final Set<String> _carriedVideoSourcePaths;

  /// SQL fragment (on the src alias `s`) selecting only REACHABLE video rows —
  /// streaming URLs plus local files carried by the backup. Empty carried set →
  /// streaming only. Callers append this to the row's own NOT EXISTS guard.
  String get _reachableVideoPredicate {
    final StringBuffer buf = StringBuffer(
      "(s.video_path LIKE 'http://%' OR s.video_path LIKE 'https://%'",
    );
    if (_carriedVideoSourcePaths.isNotEmpty) {
      final String placeholders =
          List<String>.filled(_carriedVideoSourcePaths.length, '?').join(', ');
      buf.write(' OR s.video_path IN ($placeholders)');
    }
    buf.write(')');
    return buf.toString();
  }

  /// Positional args matching the `?` placeholders in [_reachableVideoPredicate]
  /// (the carried local-file paths, in a stable order). Same order as the set is
  /// iterated when the predicate's placeholders are built.
  List<String> get _reachableVideoArgs => _carriedVideoSourcePaths.toList();

  /// Preference key holding the favorite-sentence JSON list. Mirrors
  /// `FavoriteSentenceRepository._key`; kept in sync by
  /// `favorite_sentence_pref_key_guard_test.dart`.
  static const String _favoriteSentencesPrefKey = 'favorite_sentences';

  /// Content-config preference keys carrying the local-audio registry (their
  /// referenced `.db` files travel in the backup), merged by
  /// [_mergeAudioSourcePrefs] instead of being dropped as device settings.
  static const List<String> _audioSourcePrefKeys = <String>[
    'local_audio_dbs',
    'audio_source_configs',
  ];

  /// Runs the whole merge inside a single transaction. The backup DB must
  /// already be ATTACHed as [_srcAlias] on [_db]'s connection by the caller.
  Future<void> merge() async {
    await _db.transaction(() async {
      await _insertMissing('epub_books', 'book_key', skipBookTombstones: true);
      await _insertMissingVideoBooks();
      await _insertMissing('dictionary_metadata', 'name');
      // srt_books dedups on `uid` but must honour the deleted book's tombstone
      // via its own `book_key` — else deleting a book then merging an old backup
      // resurrects an orphan srt row (no epub) = an "empty book" on the shelf.
      await _insertMissing('srt_books', 'uid',
          skipBookTombstones: true, tombstoneKeyColumn: 'book_key');
      await _insertMissing('audiobooks', 'book_key', skipBookTombstones: true);
      await _insertAudioCues();
      await _mergeReaderPositions();
      await _mergeReadingStatistics();
      await _mergeVideoWatchStatistics();
      await _mergeHourlyLogs('reading_hourly_logs', 'reading_time_ms');
      await _mergeHourlyLogs('video_hourly_logs', 'watch_time_ms');
      await _mergeMiningStatistics();
      await _mergeLookupMiningCounters();
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
      await _mergeAudioSourcePrefs();
    });
  }

  /// Read-only estimate of what [merge] would change, for the import confirm
  /// dialog (TODO-1195 part B). Runs no mutations and opens no transaction, so
  /// the caller may ATTACH the backup DB to the LIVE connection and call this
  /// before deciding to import. Counts the user-meaningful deltas: books that
  /// would newly appear (epub + video + audiobook, excluding tombstoned keys)
  /// and reading positions that would be inserted or advanced by LWW.
  Future<BackupMergePreview> preview() async {
    final int epub =
        await _countMissing('epub_books', 'book_key', skipBookTombstones: true);
    final int video = await _countMissingVideoBooks();
    final int audio =
        await _countMissing('audiobooks', 'book_key', skipBookTombstones: true);
    final int positions = await _countReaderPositionChanges();
    return BackupMergePreview(
      newEpubBooks: epub,
      newVideoBooks: video,
      newAudiobooks: audio,
      updatedReaderPositions: positions,
    );
  }

  /// Counts src rows whose [keyColumn] is absent from the target (and, when
  /// [skipBookTombstones], not tombstoned) — mirrors [_insertMissing]'s WHERE.
  Future<int> _countMissing(
    String table,
    String keyColumn, {
    bool skipBookTombstones = false,
  }) async {
    final String tombstoneGuard = skipBookTombstones
        ? 'AND s.$keyColumn NOT IN (SELECT book_key FROM book_tombstones) '
        : '';
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM $_srcAlias.$table AS s '
          'WHERE NOT EXISTS (SELECT 1 FROM $table AS t '
          'WHERE t.$keyColumn = s.$keyColumn) $tombstoneGuard',
        )
        .getSingle();
    return row.data['c'] as int;
  }

  /// Counts `video_books` rows the merge would ADD: absent from the target AND
  /// REACHABLE ([_reachableVideoPredicate]) — streaming books or local files the
  /// backup carried. Mirrors [_insertMissingVideoBooks]'s WHERE exactly so the
  /// preview's "will add N" equals what the merge actually inserts (TODO-1261).
  Future<int> _countMissingVideoBooks() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM $_srcAlias.video_books AS s '
          'WHERE NOT EXISTS (SELECT 1 FROM video_books AS t '
          'WHERE t.book_uid = s.book_uid) '
          'AND $_reachableVideoPredicate',
          variables: _reachableVideoArgs
              .map((String p) => Variable<String>(p))
              .toList(),
        )
        .getSingle();
    return row.data['c'] as int;
  }

  /// Counts reader positions the merge would touch: a src book the target lacks
  /// (new) or a src position strictly newer than the target's (LWW update).
  Future<int> _countReaderPositionChanges() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM $_srcAlias.reader_positions AS s '
          'WHERE NOT EXISTS (SELECT 1 FROM reader_positions AS t '
          'WHERE t.book_key = s.book_key) '
          'OR EXISTS (SELECT 1 FROM reader_positions AS t '
          'WHERE t.book_key = s.book_key AND s.updated_at > t.updated_at)',
        )
        .getSingle();
    return row.data['c'] as int;
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
  ///
  /// [skipBookTombstones] additionally excludes any src row whose book key is
  /// tombstoned in the target — i.e. the user deleted that book on this device,
  /// so an old backup must never resurrect it (TODO-1195 part B). The tombstoned
  /// column is [keyColumn] by default, but a table that dedups on a non-book-key
  /// column (e.g. `srt_books` dedups on `uid` yet carries its own `book_key`)
  /// passes [tombstoneKeyColumn] so the guard still matches `book_tombstones`.
  /// Overwrite import does not go through here.
  Future<void> _insertMissing(
    String table,
    String keyColumn, {
    bool skipBookTombstones = false,
    String? tombstoneKeyColumn,
  }) async {
    final List<String> cols = await _columnsExceptId(table);
    final String colList = cols.join(', ');
    final String tombCol = tombstoneKeyColumn ?? keyColumn;
    final String tombstoneGuard = skipBookTombstones
        ? 'AND s.$tombCol NOT IN (SELECT book_key FROM book_tombstones) '
        : '';
    await _db.customStatement(
      'INSERT INTO $table ($colList) '
      'SELECT $colList FROM $_srcAlias.$table AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM $table AS t '
      'WHERE t.$keyColumn = s.$keyColumn) $tombstoneGuard',
    );
  }

  /// Inserts every backup `video_books` row the target lacks, but ONLY when it
  /// is REACHABLE on this device ([_reachableVideoPredicate]): a streaming book
  /// (self-contained http(s) URL) or a local file the backup actually carried.
  /// A local-file video whose file never travelled is skipped so it never lands
  /// as a dead "empty video" shell that can't play (TODO-1261). `video_books`
  /// has no autoincrement id (PK is `book_uid`), so every column travels.
  Future<void> _insertMissingVideoBooks() async {
    final List<String> cols = await _columnsExceptId('video_books');
    final String colList = cols.join(', ');
    await _db.customStatement(
      'INSERT INTO video_books ($colList) '
      'SELECT $colList FROM $_srcAlias.video_books AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM video_books AS t '
      'WHERE t.book_uid = s.book_uid) '
      'AND $_reachableVideoPredicate',
      _reachableVideoArgs,
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
      'WHERE t.book_key = s.book_key) '
      // TODO-1195 part B: never bring back a deleted book's cues.
      'AND s.book_key NOT IN (SELECT book_key FROM book_tombstones)',
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
      'WHERE t.book_key = s.book_key) '
      // TODO-1195 part B: never re-add a deleted book's reading position.
      'AND s.book_key NOT IN (SELECT book_key FROM book_tombstones)',
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
      'WHERE t.title = s.title AND t.date_key = s.date_key) '
      // TODO-1204 后续：用户删过该书统计（book 墓碑）→ 旧备份不得复活它。
      'AND s.title NOT IN (SELECT title FROM statistics_tombstones '
      "WHERE source_type = 'book')",
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
      'WHERE t.title = s.title AND t.date_key = s.date_key) '
      // TODO-1204 后续：用户删过该视频统计（video 墓碑）→ 旧备份不得复活它。
      'AND s.title NOT IN (SELECT title FROM statistics_tombstones '
      "WHERE source_type = 'video')",
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

  /// LookupMiningCounters MAX-union per {title, sourceType, dateKey} (TODO-1204).
  /// Both counter columns (lookup_count / mine_count) are MAX-ed independently,
  /// so a re-import of the same backup stays idempotent and never double-counts
  /// (mirrors setLookupCount / setMineCountPerBook). Keyed by {title,
  /// source_type, date_key} exactly like the table's unique key.
  ///
  /// This has NO book_tombstones guard (per-title activity, not per-book_key
  /// content), but DOES honour statistics_tombstones (TODO-1204 后续): once the
  /// user explicitly deleted a book/video's stats in the stats page, an old
  /// backup must not resurrect its lookup/mine counters. The INSERT below skips
  /// src rows whose (title, source_type) is tombstoned; the UPDATE only touches
  /// buckets the target already has (deleted buckets are gone), so it needs no
  /// guard. On the INSERT of a bucket the target lacks, the src book_key travels;
  /// on an UPDATE the target keeps its own book_key unless it was null, in which
  /// case it adopts the src's non-null value (COALESCE) so book identity converges.
  Future<void> _mergeLookupMiningCounters() async {
    await _db.customStatement(
      'INSERT INTO lookup_mining_counters '
      '(book_key, title, source_type, date_key, lookup_count, mine_count) '
      'SELECT book_key, title, source_type, date_key, lookup_count, mine_count '
      'FROM $_srcAlias.lookup_mining_counters AS s '
      'WHERE NOT EXISTS (SELECT 1 FROM lookup_mining_counters AS t '
      'WHERE t.title = s.title AND t.source_type = s.source_type '
      'AND t.date_key = s.date_key) '
      // TODO-1204 后续：用户删过该 (title, sourceType) 统计 → 旧备份不得复活其计数。
      'AND NOT EXISTS (SELECT 1 FROM statistics_tombstones st '
      'WHERE st.title = s.title AND st.source_type = s.source_type)',
    );
    await _db.customStatement(
      'UPDATE lookup_mining_counters SET '
      'lookup_count = MAX(lookup_count, ('
      'SELECT s.lookup_count FROM $_srcAlias.lookup_mining_counters AS s '
      'WHERE s.title = lookup_mining_counters.title '
      'AND s.source_type = lookup_mining_counters.source_type '
      'AND s.date_key = lookup_mining_counters.date_key)), '
      'mine_count = MAX(mine_count, ('
      'SELECT s.mine_count FROM $_srcAlias.lookup_mining_counters AS s '
      'WHERE s.title = lookup_mining_counters.title '
      'AND s.source_type = lookup_mining_counters.source_type '
      'AND s.date_key = lookup_mining_counters.date_key)), '
      'book_key = COALESCE(book_key, ('
      'SELECT s.book_key FROM $_srcAlias.lookup_mining_counters AS s '
      'WHERE s.title = lookup_mining_counters.title '
      'AND s.source_type = lookup_mining_counters.source_type '
      'AND s.date_key = lookup_mining_counters.date_key)) '
      'WHERE EXISTS (SELECT 1 FROM $_srcAlias.lookup_mining_counters AS s '
      'WHERE s.title = lookup_mining_counters.title '
      'AND s.source_type = lookup_mining_counters.source_type '
      'AND s.date_key = lookup_mining_counters.date_key)',
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

  /// The audio-source registry prefs are CONTENT config, not device settings:
  /// the local-audio `.db` files they reference DO travel in the backup (packed
  /// under `localAudio/` and copied by [BackupService.mergeImportBackupFiles]),
  /// so their config must travel too — otherwise the restored files are orphaned
  /// and "音频来源" is silently lost on a merge (the pref-non-merge default
  /// dropped them). Adopt the backup's value when the device has none/an empty
  /// list (a fresh app writes an empty `[]` placeholder, so a bare NOT-EXISTS on
  /// the key is not enough); keep the device's own list otherwise (merge never
  /// clobbers local). The raw value is copied verbatim so its typed prefix is
  /// preserved; [BackupService] re-homes the embedded paths onto this device's
  /// support dir afterwards.
  Future<void> _mergeAudioSourcePrefs() async {
    for (final String key in _audioSourcePrefKeys) {
      final String? src = await _readPrefValue(key, isSrc: true);
      if (_isEmptyListPref(src)) continue; // backup carries no audio sources
      final String? local = await _readPrefValue(key, isSrc: false);
      if (!_isEmptyListPref(local)) continue; // keep the device's own list
      await _db.customStatement(
        'INSERT OR REPLACE INTO preferences ("key", "value") VALUES (?, ?)',
        <Object?>[key, src],
      );
    }
  }

  /// Reads an arbitrary preference [key] value from the target ([isSrc] false)
  /// or the ATTACHed src ([isSrc] true); null when the row is absent.
  Future<String?> _readPrefValue(String key, {required bool isSrc}) async {
    final String table = isSrc ? '$_srcAlias.preferences' : 'preferences';
    final rows = await _db.customSelect(
      'SELECT "value" FROM $table WHERE "key" = ?',
      variables: <Variable<Object>>[Variable<String>(key)],
    ).get();
    if (rows.isEmpty) return null;
    return rows.first.data['value'] as String?;
  }

  /// Whether a typed list-pref value is absent or an empty list. Tolerates the
  /// typed prefix (`s:`/`j:`) by parsing from the first `[`; a value we cannot
  /// parse as a non-empty list counts as empty (never worth clobbering with).
  static bool _isEmptyListPref(String? raw) {
    if (raw == null || raw.isEmpty) return true;
    final int i = raw.indexOf('[');
    if (i < 0) return true;
    try {
      final dynamic decoded = jsonDecode(raw.substring(i));
      return decoded is! List || decoded.isEmpty;
    } catch (_) {
      return true;
    }
  }
}

/// Preference keys that must never travel between devices on a merge import.
/// Re-exported for the caller / tests; the engine itself only touches audiobook
/// positions, so device-local sync prefs are inherently never merged.
List<String> mergeSkippedDeviceLocalPrefKeys() =>
    List<String>.unmodifiable(SyncRepository.deviceLocalPrefKeys);

/// Read-only summary of what a backup MERGE import would change on this device
/// (TODO-1195 part B), shown in the import confirm dialog. Produced by
/// [BackupMergeEngine.preview]; counts only the user-meaningful deltas.
class BackupMergePreview {
  const BackupMergePreview({
    required this.newEpubBooks,
    required this.newVideoBooks,
    required this.newAudiobooks,
    required this.updatedReaderPositions,
  });

  /// EPUB books present in the backup but not on this device (and not
  /// tombstoned), that the merge would add.
  final int newEpubBooks;

  /// Video books the merge would add.
  final int newVideoBooks;

  /// Audiobooks the merge would add (their EPUB shell is counted in
  /// [newEpubBooks]; this is the audio-alignment rows).
  final int newAudiobooks;

  /// Reading positions the merge would insert or advance (LWW).
  final int updatedReaderPositions;

  /// Total books that would newly appear on the shelf (EPUB + video).
  int get newBooks => newEpubBooks + newVideoBooks;
}
