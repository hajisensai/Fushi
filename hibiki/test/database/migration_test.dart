import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 14` database that lacks the sync_baselines table,
/// forcing the real `if (from < 15) createTable(syncBaselines)` onUpgrade
/// branch in database.dart to run when HibikiDatabase opens it.
Future<HibikiDatabase> _openV14DbWithoutSyncBaselines() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // A v14 DB created before SyncBaselines existed: no sync_baselines
        // table. We only need the version marker — the from<15 branch creates
        // exactly that table, and from<14 (index backfill) does not fire.
        rawDb.execute('PRAGMA user_version = 14');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 15` database that lacks the video_books table,
/// forcing the real `if (from < 16) createTable(videoBooks)` onUpgrade branch
/// in database.dart to run when HibikiDatabase opens it.
Future<HibikiDatabase> _openV15DbWithoutVideoBooks() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // A v15 DB created before VideoBooks existed: no video_books table.
        // The from<17 branch creates the full video_books table (book_uid PK).
        // The name-PK v16 step (from<16) runs first but no-ops here because
        // this synthetic seed has no epub_books id column to re-key.
        rawDb.execute('PRAGMA user_version = 15');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 20` database that has a book_uid-keyed video_books
/// table but lacks video_book_tag_mappings, forcing the real
/// `if (from < 21) createTable(videoBookTagMappings)` onUpgrade branch to run.
Future<HibikiDatabase> _openV20DbWithoutVideoTagMappings() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Minimal but realistic v20 video_books (book_uid PK) so the FK target
        // for video_book_tag_mappings exists. Only the from<21 branch fires.
        rawDb.execute(
          'CREATE TABLE video_books ('
          'book_uid TEXT NOT NULL PRIMARY KEY, '
          'title TEXT NOT NULL, '
          'video_path TEXT NOT NULL, '
          'last_position_ms INTEGER NOT NULL DEFAULT 0, '
          'current_episode INTEGER NOT NULL DEFAULT 0, '
          'delay_ms INTEGER NOT NULL DEFAULT 0)',
        );
        rawDb.execute(
          'INSERT INTO video_books(book_uid, title, video_path) '
          "VALUES('video/seed', 'Seed', '/abs/seed.mp4')",
        );
        // book_tags is a v1 baseline table (created in onCreate, never in the
        // onUpgrade ladder), so a realistic v20 DB already has it. Seed it so
        // the shared-pool assertion (createTag) works after the v21 step.
        rawDb.execute(
          'CREATE TABLE book_tags ('
          'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
          'name TEXT NOT NULL UNIQUE, '
          'color_value INTEGER NOT NULL DEFAULT 4288585374, '
          'sort_order INTEGER NOT NULL DEFAULT 0, '
          'created_at INTEGER NOT NULL)',
        );
        rawDb.execute('PRAGMA user_version = 20');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 21` database that has a book_uid-keyed video_books
/// table (WITHOUT completed_at) and no video stats tables, forcing the real
/// `if (from < 22)` onUpgrade branch (create two stats tables + addColumn
/// completed_at) to run.
Future<HibikiDatabase> _openV21DbWithoutVideoStats() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Realistic v21 video_books: book_uid PK, full v17 column set, but no
        // completed_at (added in v22) and no video stats tables.
        rawDb.execute(
          'CREATE TABLE video_books ('
          'book_uid TEXT NOT NULL PRIMARY KEY, '
          'title TEXT NOT NULL, '
          'video_path TEXT NOT NULL, '
          'subtitle_source TEXT, '
          'subtitle_format TEXT, '
          'embedded_subtitle_track INTEGER, '
          'cover_path TEXT, '
          'last_position_ms INTEGER NOT NULL DEFAULT 0, '
          'imported_at INTEGER, '
          'playlist_json TEXT, '
          'current_episode INTEGER NOT NULL DEFAULT 0, '
          'audio_track_id TEXT, '
          'delay_ms INTEGER NOT NULL DEFAULT 0)',
        );
        rawDb.execute(
          'INSERT INTO video_books(book_uid, title, video_path, last_position_ms) '
          "VALUES('video/seed', 'Seed', '/abs/seed.mp4', 4242)",
        );
        rawDb.execute('PRAGMA user_version = 21');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 22` database lacking favorite_words / mining_statistics,
/// forcing the real `if (from < 23)` onUpgrade branch (create both tables) to run.
/// The activity-stats migration is self-contained (only creates two tables), so a
/// bare v22 DB is enough to exercise it without seeding other v22 baseline tables.
Future<HibikiDatabase> _openV22DbWithoutActivityTables() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA user_version = 22');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 15` database with epub_books on the legacy
/// autoincrement id PK and reader_positions / bookmarks keyed by the legacy int
/// `ttu_book_id`. Opening it must drive the from<16 re-key (`_migrateBookKeyV16`)
/// which rebuilds those relation tables under `book_key`. The legacy DDL mirrors
/// `srt_cue_migration_test.dart` (_openV11DbWithSrtCues) so the columns the
/// re-key JOINs through are byte-faithful — getting them wrong would false-green.
///
/// `bookKeyA` / `bookKeyB` are the sanitized keys the re-key derives from the
/// seeded titles; for ASCII titles with no reserved chars the key equals the
/// title verbatim, which the test asserts via getReaderPosition.
Future<HibikiDatabase> _openV15DbWithReaderRowsKeyedByTtuId() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA foreign_keys = OFF');
        rawDb.execute('''
CREATE TABLE epub_books (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  author TEXT,
  cover_path TEXT,
  epub_path TEXT NOT NULL,
  extract_dir TEXT NOT NULL,
  chapter_count INTEGER NOT NULL,
  chapters_json TEXT NOT NULL,
  toc_json TEXT,
  source_metadata TEXT,
  imported_at INTEGER NOT NULL
)
''');
        rawDb.execute('''
CREATE TABLE reader_positions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ttu_book_id INTEGER NOT NULL UNIQUE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  ttu_char_offset INTEGER NOT NULL DEFAULT -1,
  updated_at INTEGER NOT NULL
)
''');
        rawDb.execute('''
CREATE TABLE bookmarks (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ttu_book_id INTEGER NOT NULL REFERENCES epub_books(id) ON DELETE CASCADE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  label TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  book_title TEXT,
  page_in_chapter INTEGER,
  total_pages_in_chapter INTEGER
)
''');
        // Two ASCII-keyed books (keys sanitize verbatim).
        rawDb.execute(
          'INSERT INTO epub_books '
          '(id, title, epub_path, extract_dir, chapter_count, chapters_json, '
          ' imported_at) '
          "VALUES (1, 'AlphaBook', '/abs/a.epub', '/abs/a', 1, '[]', 10)",
        );
        rawDb.execute(
          'INSERT INTO epub_books '
          '(id, title, epub_path, extract_dir, chapter_count, chapters_json, '
          ' imported_at) '
          "VALUES (2, 'BetaBook', '/abs/b.epub', '/abs/b', 1, '[]', 20)",
        );
        // reader_positions keyed by legacy ttu_book_id (= epub id).
        rawDb.execute(
          'INSERT INTO reader_positions '
          '(ttu_book_id, section_index, norm_char_offset, ttu_char_offset, '
          'updated_at) VALUES (1, 4, 1234, 555, 9001)',
        );
        rawDb.execute(
          'INSERT INTO reader_positions '
          '(ttu_book_id, section_index, norm_char_offset, ttu_char_offset, '
          'updated_at) VALUES (2, 8, 5678, -1, 9002)',
        );
        // A bookmark on book 1.
        rawDb.execute(
          'INSERT INTO bookmarks '
          '(ttu_book_id, section_index, norm_char_offset, label, created_at, '
          'book_title) '
          "VALUES (1, 4, 1234, 'Chapter 1', 9003, 'AlphaBook')",
        );
        rawDb.execute('PRAGMA user_version = 15');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 24` database lacking mined_sentences, forcing the real
/// `if (from < 25)` onUpgrade branch (create the table) to run. The mined-sentence
/// history migration is self-contained (only creates one table), so a bare v24 DB is
/// enough to exercise it without seeding other v24 baseline tables.
Future<HibikiDatabase> _openV24DbWithoutMinedSentences() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA user_version = 24');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 26` database that already has minimal video_books /
/// epub_books rows (WITHOUT the v27 source_id column and WITHOUT media_sources),
/// forcing the real `if (from < 27)` onUpgrade branch (create media_sources +
/// add source_id to both book tables) to run. This is the TODO-817 lossless-
/// migration check: the seeded rows must survive with source_id defaulting to
/// NULL. The DDL mirrors the v26 generated shape minus the new column.
Future<HibikiDatabase> _openV26DbWithBookRows() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA foreign_keys = OFF');
        rawDb.execute('''
CREATE TABLE epub_books (
  book_key TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  author TEXT,
  cover_path TEXT,
  epub_path TEXT NOT NULL,
  extract_dir TEXT NOT NULL,
  chapter_count INTEGER NOT NULL,
  chapters_json TEXT NOT NULL,
  toc_json TEXT,
  source_metadata TEXT,
  imported_at INTEGER NOT NULL
)
''');
        rawDb.execute('''
CREATE TABLE video_books (
  book_uid TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  video_path TEXT NOT NULL,
  subtitle_source TEXT,
  subtitle_format TEXT,
  embedded_subtitle_track INTEGER,
  cover_path TEXT,
  last_position_ms INTEGER NOT NULL DEFAULT 0,
  imported_at INTEGER,
  playlist_json TEXT,
  current_episode INTEGER NOT NULL DEFAULT 0,
  audio_track_id TEXT,
  delay_ms INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER
)
''');
        rawDb.execute(
          'INSERT INTO epub_books '
          '(book_key, title, epub_path, extract_dir, chapter_count, '
          ' chapters_json, imported_at) '
          "VALUES ('GammaBook', 'GammaBook', '/abs/g.epub', '/abs/g', 1, "
          "'[]', 30)",
        );
        rawDb.execute(
          'INSERT INTO video_books '
          '(book_uid, title, video_path) '
          "VALUES ('video/seed', 'SeedVideo', '/abs/seed.mp4')",
        );
        rawDb.execute('PRAGMA user_version = 26');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 27` database whose video_books has the v27 `source_id`
/// column but lacks the v28 `secondary_subtitle_source` column, forcing the real
/// `if (from < 28)` onUpgrade branch (add secondary_subtitle_source to
/// video_books) to run. This is the TODO-857 lossless-migration check: the
/// seeded video row must survive with secondary_subtitle_source defaulting to
/// NULL. The DDL mirrors the v27 generated shape minus the new column.
Future<HibikiDatabase> _openV27DbWithVideoRow() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA foreign_keys = OFF');
        rawDb.execute('''
CREATE TABLE video_books (
  book_uid TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  video_path TEXT NOT NULL,
  subtitle_source TEXT,
  subtitle_format TEXT,
  embedded_subtitle_track INTEGER,
  cover_path TEXT,
  last_position_ms INTEGER NOT NULL DEFAULT 0,
  imported_at INTEGER,
  playlist_json TEXT,
  current_episode INTEGER NOT NULL DEFAULT 0,
  audio_track_id TEXT,
  delay_ms INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER,
  source_id TEXT
)
''');
        rawDb.execute(
          'INSERT INTO video_books '
          '(book_uid, title, video_path, subtitle_source) '
          "VALUES ('video/seed27', 'SeedVideo27', '/abs/seed27.mp4', "
          "'embedded:0')",
        );
        rawDb.execute('PRAGMA user_version = 27');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

void main() {
  group('Database schema', () {
    test('fresh database has expected schema version', () async {
      final db = await _openDb();
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], db.schemaVersion);
    });

    test('all expected tables exist', () async {
      final db = await _openDb();
      final tables = await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
          .get();
      final tableNames = tables.map((r) => r.data['name'] as String).toSet();

      expect(
        tableNames,
        containsAll([
          'preferences',
          'media_items',
          'epub_books',
          'audiobooks',
          'audio_cues',
          'srt_books',
          'dictionary_metadata',
          'dictionary_history',
          'profiles',
          'profile_settings',
          'book_tags',
          'book_tag_mappings',
          'reader_positions',
          'bookmarks',
          'reading_statistics',
          'anki_mappings',
          'search_history_items',
          'sync_baselines',
          'video_books',
          'video_book_tag_mappings',
          'video_watch_statistics',
          'video_hourly_logs',
          'favorite_words',
          'mining_statistics',
          'mined_sentences',
          'media_sources',
        ]),
      );
    });

    test('sync_baselines table is usable on a fresh database', () async {
      final db = await _openDb();
      // Fresh DB goes through onCreate/createAll; the table exists (no
      // exception) and reports null for an absent baseline.
      expect(await db.getSyncBaseline('x', 'progress'), isNull);
    });

    test('real v14->v15 upgrade creates a usable sync_baselines table',
        () async {
      // A pre-v15 DB has no sync_baselines table; opening it must drive the
      // from<15 onUpgrade branch (createTable(syncBaselines)) rather than
      // onCreate.
      final db = await _openV14DbWithoutSyncBaselines();

      // The upgrade ladder bumped the schema to the current version (a v14 DB
      // walks the full ladder past 15 to the latest schema).
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // The newly-migrated table exists and querying an absent baseline does
      // not throw.
      expect(await db.getSyncBaseline('x', 'progress'), isNull);
    });

    test('real v15->v17 upgrade creates a book_uid-keyed video_books table',
        () async {
      // A pre-v16 (v15) DB has no video_books table; opening it must walk the
      // ladder past the name-PK v16 step and drive the from<17 onUpgrade branch
      // (createTable(videoBooks)) — building the full schema (book_uid PK +
      // playlist_json / current_episode / audio_track_id / delay_ms) in one
      // shot, because develop users never had a video_books table.
      final db = await _openV15DbWithoutVideoBooks();

      // The upgrade ladder bumped the schema to the current version.
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // The table carries the full v17 column set (no stepwise add-column
      // ladder remains).
      final cols =
          await db.customSelect("PRAGMA table_info('video_books')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(
        colNames,
        containsAll([
          'book_uid',
          'playlist_json',
          'current_episode',
          'audio_track_id',
          'delay_ms'
        ]),
      );
      // book_uid is the primary key (pk == 1); there is no autoincrement id.
      expect(colNames, isNot(contains('id')));
      final bookUidCol = cols.firstWhere((r) => r.data['name'] == 'book_uid');
      expect(bookUidCol.data['pk'], 1);

      // The newly-migrated table is usable: upsert then read back.
      await db.upsertVideoBook(const VideoBooksCompanion(
        bookUid: Value('video/migrated'),
        title: Value('Migrated'),
        videoPath: Value('/abs/migrated.mp4'),
      ));
      final row = await db.getVideoBookByBookUid('video/migrated');
      expect(row, isNotNull);
      expect(row!.title, 'Migrated');
      expect(row.lastPositionMs, 0);
      expect(row.delayMs, 0);
    });

    test('real v20->v21 upgrade creates a usable video_book_tag_mappings table',
        () async {
      // A v20 DB has video_books but no video_book_tag_mappings; opening it must
      // drive the from<21 onUpgrade branch (createTable(videoBookTagMappings))
      // rather than onCreate.
      final db = await _openV20DbWithoutVideoTagMappings();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // The new mapping table exists and shares the BookTags pool: tag the
      // seeded video book and read it back.
      final tagId = await db.createTag('Migrated', 0xFF112233);
      await db.addTagToVideoBook('video/seed', tagId);
      final tags = await db.getTagsForVideoBook('video/seed');
      expect(tags, hasLength(1));
      expect(tags.single.name, 'Migrated');
    });

    test(
        'real v21->v22 upgrade adds video stats tables + completed_at losslessly',
        () async {
      // A v21 DB has video_books (no completed_at) and no video stats tables;
      // opening it must drive the from<22 onUpgrade branch.
      final db = await _openV21DbWithoutVideoStats();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // The pre-existing video_books row survived the migration, with the new
      // completed_at column defaulting to null (lossless add-column).
      final row = await db.getVideoBookByBookUid('video/seed');
      expect(row, isNotNull);
      expect(row!.title, 'Seed');
      expect(row.lastPositionMs, 4242);
      expect(row.completedAt, isNull);

      // The two new stats tables are usable.
      await db.addVideoWatchStatistic(
          title: 'Seed',
          dateKey: '2026-06-06',
          subtitleChars: 12,
          watchTimeMs: 3000);
      final stats = await db.getAllVideoWatchStatistics();
      expect(stats, hasLength(1));
      expect(stats.single.subtitleChars, 12);

      await db.addVideoHourlyWatchTime(
          dateKey: '2026-06-06', hour: 8, deltaMs: 500);
      final hourly = await db.getVideoHourlyLogsForDate('2026-06-06');
      expect(hourly, hasLength(1));
      expect(hourly.single.watchTimeMs, 500);

      // markVideoCompleted works on the migrated row.
      final ts = DateTime(2026, 6, 6, 20);
      await db.markVideoCompleted('video/seed', ts);
      final completed = await db.getVideoBookByBookUid('video/seed');
      expect(completed!.completedAt, ts);
    });

    test(
        'real v22->v23 upgrade creates usable favorite_words + mining_statistics',
        () async {
      // A v22 DB lacks favorite_words / mining_statistics; opening it must drive
      // the from<23 onUpgrade branch (createTable both) rather than onCreate.
      final db = await _openV22DbWithoutActivityTables();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // 收藏：新增→已存在判定→取消，全链可用。
      final added = await db.addFavoriteWord(
        expression: '猫',
        reading: 'ねこ',
        glossary: 'cat',
        sourceType: 'video',
        dateKey: '2026-06-07',
      );
      expect(added, isTrue);
      final dup = await db.addFavoriteWord(
        expression: '猫',
        reading: 'ねこ',
        glossary: 'cat',
        sourceType: 'video',
        dateKey: '2026-06-07',
      );
      expect(dup, isFalse, reason: '同 (expression,reading,sourceType) 幂等不重复');
      expect(
          await db.isFavoriteWord(
              expression: '猫', reading: 'ねこ', sourceType: 'video'),
          isTrue);
      // 来源隔离：book 来源未收藏。
      expect(
          await db.isFavoriteWord(
              expression: '猫', reading: 'ねこ', sourceType: 'book'),
          isFalse);
      expect((await db.getFavoriteWordsBySource('video')), hasLength(1));
      await db.removeFavoriteWord(
          expression: '猫', reading: 'ねこ', sourceType: 'video');
      expect((await db.getFavoriteWordsBySource('video')), isEmpty);

      // 制卡计数：同 (sourceType,dateKey) 累加。
      await db.addMiningCount(sourceType: 'video', dateKey: '2026-06-07');
      await db.addMiningCount(
          sourceType: 'video', dateKey: '2026-06-07', delta: 2);
      final mined = await db.getMiningStatisticsBySource('video');
      expect(mined, hasLength(1));
      expect(mined.single.count, 3);
      expect(await db.getMiningStatisticsBySource('book'), isEmpty);
    });

    test('real v24->v25 upgrade creates a usable mined_sentences table',
        () async {
      // A v24 DB lacks mined_sentences; opening it must drive the from<25
      // onUpgrade branch (createTable) rather than onCreate.
      final db = await _openV24DbWithoutMinedSentences();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // The migrated table is usable: record two mined sentences (history is a
      // flow, not deduplicated) then read them back newest-first.
      await db.addMinedSentence(
        source: 'book',
        dateKey: '2026-06-21',
        expression: '猫',
        reading: 'ねこ',
        glossary: 'cat',
        sentence: '猫が好きです。',
        documentTitle: 'AlphaBook',
        bookKey: 'AlphaBook',
        sectionIndex: 2,
        normCharOffset: 1234,
      );
      await db.addMinedSentence(
        source: 'video',
        dateKey: '2026-06-21',
        expression: '犬',
        reading: 'いぬ',
        sentence: '犬も好きです。',
        documentTitle: 'Clip',
        bookKey: 'video/clip',
        sectionIndex: 0,
        normCharOffset: 5000,
        normCharLength: 2000,
        noteId: 4242,
      );

      final all = await db.getAllMinedSentences();
      expect(all, hasLength(2));
      // newest (video) first.
      expect(all.first.expression, '犬');
      expect(all.first.source, 'video');
      expect(all.first.bookKey, 'video/clip');
      expect(all.first.normCharLength, 2000);
      expect(all.first.noteId, 4242);
      expect(all.last.expression, '猫');
      expect(all.last.sentence, '猫が好きです。');

      // Delete one by id; clear empties the rest.
      await db.removeMinedSentence(all.first.id);
      expect(await db.getAllMinedSentences(), hasLength(1));
      await db.clearMinedSentences();
      expect(await db.getAllMinedSentences(), isEmpty);
    });

    test('real v26->v27 creates media_sources + adds source_id (lossless)',
        () async {
      // TODO-817 M0: the from<27 onUpgrade branch must (a) create the
      // media_sources table, (b) add a nullable source_id FK column to both
      // video_books and epub_books, and (c) leave the pre-existing book rows
      // intact with source_id defaulting to NULL ("Never break userspace").
      final db = await _openV26DbWithBookRows();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // media_sources table now exists.
      final tables = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      final tableNames = tables.map((r) => r.data['name'] as String).toSet();
      expect(tableNames, contains('media_sources'));

      // Both book tables gained the source_id column.
      final epubCols =
          (await db.customSelect("PRAGMA table_info('epub_books')").get())
              .map((r) => r.data['name'] as String)
              .toSet();
      expect(epubCols, contains('source_id'));
      final videoCols =
          (await db.customSelect("PRAGMA table_info('video_books')").get())
              .map((r) => r.data['name'] as String)
              .toSet();
      expect(videoCols, contains('source_id'));

      // Lossless: the seeded rows survive, with source_id NULL.
      final epub = await db
          .customSelect(
              "SELECT book_key, source_id FROM epub_books WHERE book_key='GammaBook'")
          .getSingle();
      expect(epub.read<String>('book_key'), 'GammaBook');
      expect(epub.data['source_id'], isNull);

      final video = await db
          .customSelect(
              "SELECT book_uid, source_id FROM video_books WHERE book_uid='video/seed'")
          .getSingle();
      expect(video.read<String>('book_uid'), 'video/seed');
      expect(video.data['source_id'], isNull);
    });

    test('real v27->v28 adds video_books.secondary_subtitle_source (lossless)',
        () async {
      // TODO-857: the from<28 onUpgrade branch must add a nullable
      // secondary_subtitle_source column to video_books and leave the
      // pre-existing video row intact (subtitle_source untouched,
      // secondary_subtitle_source defaulting to NULL — "Never break userspace").
      final db = await _openV27DbWithVideoRow();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // video_books gained the secondary_subtitle_source column.
      final videoCols =
          (await db.customSelect("PRAGMA table_info('video_books')").get())
              .map((r) => r.data['name'] as String)
              .toSet();
      expect(videoCols, contains('secondary_subtitle_source'));

      // Lossless: the seeded row survives, primary subtitle untouched, the new
      // secondary subtitle column defaulting to NULL.
      final video = await db
          .customSelect(
              'SELECT book_uid, subtitle_source, secondary_subtitle_source '
              "FROM video_books WHERE book_uid='video/seed27'")
          .getSingle();
      expect(video.read<String>('book_uid'), 'video/seed27');
      expect(video.read<String>('subtitle_source'), 'embedded:0');
      expect(video.data['secondary_subtitle_source'], isNull);
    });

    test(
        'real v15->v16 re-key preserves reader_positions + bookmarks ROW DATA '
        'under book_key', () async {
      // video_books_migration_v20_test only asserts epub_books ROWS survive the
      // v16 re-key; it never checks the reader_positions / bookmarks row
      // contents. This is the load-bearing "Never break userspace" check for a
      // user's saved reading positions and bookmarks across the int->book_key
      // migration.
      final db = await _openV15DbWithReaderRowsKeyedByTtuId();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // epub_books re-keyed to book_key PK; both books survive.
      final epubColNames =
          (await db.customSelect("PRAGMA table_info('epub_books')").get())
              .map((r) => r.data['name'] as String)
              .toSet();
      expect(epubColNames, contains('book_key'));
      expect(epubColNames, isNot(contains('id')));

      // reader_positions row-level preservation: both positions re-keyed from
      // ttu_book_id -> book_key, every payload column intact, reachable via the
      // typed getReaderPosition(bookKey). (ASCII titles sanitize verbatim.)
      final posA = await db.getReaderPosition('AlphaBook');
      expect(posA, isNotNull,
          reason: 'book 1 reading position survived the re-key');
      expect(posA!.sectionIndex, 4);
      expect(posA.normCharOffset, 1234);
      expect(posA.updatedAt, 9001);
      final posB = await db.getReaderPosition('BetaBook');
      expect(posB, isNotNull,
          reason: 'book 2 reading position survived the re-key');
      expect(posB!.sectionIndex, 8);
      expect(posB.normCharOffset, 5678);
      expect(posB.updatedAt, 9002);
      // The standalone ttu offset column was dropped by v24; char_offset is the
      // -1 fallback for carried-over rows.
      expect(posA.charOffset, -1);
      expect(posB.charOffset, -1);

      // bookmarks row-level preservation: the seeded bookmark re-keyed to
      // book_key with all payload fields intact.
      final bm = await db
          .customSelect('SELECT book_key, section_index, norm_char_offset, '
              'label, created_at, book_title FROM bookmarks')
          .get();
      expect(bm, hasLength(1), reason: 'the bookmark survived the re-key');
      expect(bm.single.read<String>('book_key'), 'AlphaBook');
      expect(bm.single.read<int>('section_index'), 4);
      expect(bm.single.read<int>('norm_char_offset'), 1234);
      expect(bm.single.read<String>('label'), 'Chapter 1');
      expect(bm.single.read<int>('created_at'), 9003);
      expect(bm.single.read<String>('book_title'), 'AlphaBook');
    });

    test('video_book_tag_mappings references video_books and book_tags',
        () async {
      final db = await _openDb();
      final fks = await db
          .customSelect("PRAGMA foreign_key_list('video_book_tag_mappings')")
          .get();
      final tables = fks.map((r) => r.data['table'] as String).toSet();
      expect(tables, containsAll(['video_books', 'book_tags']));
    });

    test('preferences table has key and value columns', () async {
      final db = await _openDb();
      final cols =
          await db.customSelect("PRAGMA table_info('preferences')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['key', 'value']));
    });

    test('media_items has unique_key column with UNIQUE constraint', () async {
      final db = await _openDb();
      final indices =
          await db.customSelect("PRAGMA index_list('media_items')").get();
      final uniqueIndices = indices
          .where((r) => r.data['unique'] == 1)
          .map((r) => r.data['name'] as String)
          .toList();
      expect(uniqueIndices, isNotEmpty);
    });

    test('epub_books has epub_path and extract_dir columns', () async {
      final db = await _openDb();
      final cols =
          await db.customSelect("PRAGMA table_info('epub_books')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['epub_path', 'extract_dir']));
    });

    test('audio_cues has book_key and chapter_href columns', () async {
      final db = await _openDb();
      final cols =
          await db.customSelect("PRAGMA table_info('audio_cues')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['book_key', 'chapter_href']));
    });

    test('reading_statistics has date_key and characters_read columns',
        () async {
      final db = await _openDb();
      final cols = await db
          .customSelect("PRAGMA table_info('reading_statistics')")
          .get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(['date_key', 'characters_read']));
    });

    test('book_tag_mappings references book_tags via foreign key', () async {
      final db = await _openDb();
      final fks = await db
          .customSelect("PRAGMA foreign_key_list('book_tag_mappings')")
          .get();
      final tables = fks.map((r) => r.data['table'] as String).toSet();
      expect(tables, contains('book_tags'));
    });
  });
}
