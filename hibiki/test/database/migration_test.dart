import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 33` database that lacks the statistics_tombstones
/// table, forcing the real `if (from < 34) createTable(statisticsTombstones)`
/// onUpgrade branch (TODO-1204 后续) to run when HibikiDatabase opens it.
Future<HibikiDatabase> _openV33DbWithoutStatisticsTombstones() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA user_version = 33');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 34` database whose video_books table lacks the
/// stream_spec_json column, forcing the real `if (from < 35) addColumn(
/// videoBooks.streamSpecJson)` onUpgrade branch (TODO-1157) to run.
Future<HibikiDatabase> _openV34DbWithoutStreamSpecJson() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Minimal video_books shaped like the v34 schema (no stream_spec_json).
        rawDb.execute('CREATE TABLE video_books ('
            'book_uid TEXT NOT NULL PRIMARY KEY, '
            'title TEXT NOT NULL, '
            'video_path TEXT NOT NULL, '
            'subtitle_source TEXT, '
            'secondary_subtitle_source TEXT, '
            'subtitle_format TEXT, '
            'embedded_subtitle_track INTEGER, '
            'cover_path TEXT, '
            'last_position_ms INTEGER NOT NULL DEFAULT 0, '
            'imported_at INTEGER, '
            'playlist_json TEXT, '
            'current_episode INTEGER NOT NULL DEFAULT 0, '
            'audio_track_id TEXT, '
            'delay_ms INTEGER NOT NULL DEFAULT 0, '
            'completed_at INTEGER, '
            'source_id INTEGER)');
        rawDb.execute('INSERT INTO video_books (book_uid, title, video_path, '
            'last_position_ms, current_episode, delay_ms) VALUES '
            "('video/stream/x', 't', 'https://x/y.m3u8', 0, 0, 0)");
        rawDb.execute('PRAGMA user_version = 34');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 44` database whose media_collections table lacks the
/// anilist_id column, forcing the real `if (from < 45) addColumn(
/// mediaCollections.anilistId)` onUpgrade branch (合集字幕批量下载) to run.
Future<HibikiDatabase> _openV44DbWithoutCollectionAnilistId() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Minimal media_collections shaped like the v44 schema (no anilist_id).
        rawDb.execute('CREATE TABLE media_collections ('
            'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
            'name TEXT NOT NULL, '
            "collection_type TEXT NOT NULL DEFAULT 'collection', "
            'cover_source TEXT, '
            'sort_order INTEGER NOT NULL DEFAULT 0, '
            'created_at INTEGER NOT NULL, '
            'order_updated_at INTEGER NOT NULL DEFAULT 0)');
        rawDb.execute('INSERT INTO media_collections (id, name, created_at) '
            "VALUES (1, 'Bocchi the Rock!', 1)");
        rawDb.execute('PRAGMA user_version = 44');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a `user_version = 35` database whose favorite_words table lacks the
/// book_key / title columns, forcing the real `if (from < 36) addColumn(
/// favoriteWords.bookKey / .title)` onUpgrade branch (TODO-1252) to run.
Future<HibikiDatabase> _openV35DbWithoutFavoriteBookColumns() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Minimal favorite_words shaped like the v35 schema (no book_key/title).
        rawDb.execute('CREATE TABLE favorite_words ('
            'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
            'expression TEXT NOT NULL, '
            'reading TEXT NOT NULL, '
            'glossary TEXT NOT NULL, '
            'source_type TEXT NOT NULL, '
            'date_key TEXT NOT NULL, '
            'created_at INTEGER NOT NULL, '
            'UNIQUE (expression, reading, source_type))');
        rawDb.execute('INSERT INTO favorite_words (expression, reading, '
            'glossary, source_type, date_key, created_at) VALUES '
            "('語', 'ご', 'g', 'book', '2026-07-06', 1)");
        rawDb.execute('PRAGMA user_version = 35');
      },
    ),
  );
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

/// Opens a `user_version = 28` database whose audiobooks/srt_books/epub_books
/// have the v28 shape, seeded with:
///  - EPUB-backed audiobook key='A' (epub_books + audiobooks rows, NO srt_books
///    row) — the TODO-894 bug shape that the v29 backfill must heal.
///  - a standalone subtitle book (epub_books + a srt_books row with a non-empty
///    book_key but NO audiobooks row) — the天然豁免对照 that must survive
///    untouched (it never enters `FROM audiobooks a`).
Future<HibikiDatabase> _openV28DbWithUnpairedAudiobook() async {
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
  imported_at INTEGER NOT NULL,
  source_id INTEGER
)
''');
        rawDb.execute('''
CREATE TABLE audiobooks (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL UNIQUE,
  audio_root TEXT,
  audio_paths_json TEXT,
  alignment_format TEXT NOT NULL,
  alignment_path TEXT NOT NULL,
  health_kind_raw TEXT,
  match_rate_pct INTEGER,
  health_measured_at INTEGER,
  health_reason TEXT,
  follow_audio INTEGER
)
''');
        rawDb.execute('''
CREATE TABLE srt_books (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  uid TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  author TEXT,
  audio_root TEXT,
  audio_paths_json TEXT,
  srt_path TEXT NOT NULL,
  cover_path TEXT,
  imported_at INTEGER NOT NULL,
  book_key TEXT NOT NULL DEFAULT ''
)
''');

        // (1) EPUB-backed unpaired audiobook (the bug): epub_books + audiobooks
        //     keyed 'A', NO srt_books row.
        rawDb.execute('''
INSERT INTO epub_books
(book_key, title, author, epub_path, extract_dir, chapter_count,
 chapters_json, imported_at)
VALUES ('A', '安達としまむら', '入間人間', '/abs/A.epub',
 '/abs/A/extract', 1, '["ch1"]', 111000)
''');
        rawDb.execute('''
INSERT INTO audiobooks
(book_key, audio_paths_json, alignment_format, alignment_path)
VALUES ('A', '["/abs/persist/A/disc1.mp3"]', 'srt',
 '/abs/persist/A/aligned.srt')
''');

        // (2) standalone subtitle book: epub_books + a srt_books row with a
        //     non-empty book_key but NO audiobooks row -> must stay untouched.
        rawDb.execute('''
INSERT INTO epub_books
(book_key, title, epub_path, extract_dir, chapter_count,
 chapters_json, imported_at)
VALUES ('Standalone', 'Standalone Sub', '/abs/S.epub',
 '/abs/S/extract', 1, '["ch1"]', 222000)
''');
        rawDb.execute('''
INSERT INTO srt_books
(uid, title, srt_path, imported_at, book_key)
VALUES ('srtbook_222', 'Standalone Sub', '/abs/persist/S/s.srt',
 222000, 'Standalone')
''');

        rawDb.execute('PRAGMA user_version = 28');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// TODO-1288：打开一个 `user_version = 36` 的库，其 audiobooks/srt_books/epub_books
/// 为当前形状，种入一条「EPUB-backed 但缺配对 srt_books 行」的有声书（key='B'）。
///
/// 这正是 TODO-1288 的病灶数据形状：`audiobook_import_dialog` 给已有 EPUB 书加/换
/// 音频时只写 audiobooks 行、漏写配对 srt_books 行；而 v29 的一次性 backfill 只在
/// 「升级跨过 29」时跑一次，故 DB 已 ≥29 后经该对话框新导入的有声书重新变回未配对，
/// 不再被自愈。v37 self-heal（重跑幂等 backfill）必须把它治好。
///
/// 同时种一条 standalone 字幕书（有 srt_books、无 audiobooks 行）作对照，必须原封不动。
Future<HibikiDatabase> _openV36DbWithUnpairedAudiobook() async {
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
  imported_at INTEGER NOT NULL,
  source_id INTEGER
)
''');
        rawDb.execute('''
CREATE TABLE audiobooks (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL UNIQUE,
  audio_root TEXT,
  audio_paths_json TEXT,
  alignment_format TEXT NOT NULL,
  alignment_path TEXT NOT NULL,
  health_kind_raw TEXT,
  match_rate_pct INTEGER,
  health_measured_at INTEGER,
  health_reason TEXT,
  follow_audio INTEGER
)
''');
        rawDb.execute('''
CREATE TABLE srt_books (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  uid TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  author TEXT,
  audio_root TEXT,
  audio_paths_json TEXT,
  srt_path TEXT NOT NULL,
  cover_path TEXT,
  imported_at INTEGER NOT NULL,
  book_key TEXT NOT NULL DEFAULT ''
)
''');

        // (1) TODO-1288 bug shape：EPUB-backed 有声书 key='B'，无配对 srt_books 行
        //     （模拟 v29 之后经 audiobook_import_dialog 新导入）。
        rawDb.execute('''
INSERT INTO epub_books
(book_key, title, author, epub_path, extract_dir, chapter_count,
 chapters_json, imported_at)
VALUES ('B', 'よつばと！', 'あずまきよひこ', '/abs/B.epub',
 '/abs/B/extract', 1, '["ch1"]', 333000)
''');
        rawDb.execute('''
INSERT INTO audiobooks
(book_key, audio_paths_json, alignment_format, alignment_path)
VALUES ('B', '["/abs/persist/B/ch1.mp3"]', 'srt',
 '/abs/persist/B/aligned.srt')
''');

        // (2) standalone 字幕书：有 srt_books、无 audiobooks 行 -> 必须原封不动。
        rawDb.execute('''
INSERT INTO epub_books
(book_key, title, epub_path, extract_dir, chapter_count,
 chapters_json, imported_at)
VALUES ('StandaloneB', 'Standalone Sub B', '/abs/SB.epub',
 '/abs/SB/extract', 1, '["ch1"]', 444000)
''');
        rawDb.execute('''
INSERT INTO srt_books
(uid, title, srt_path, imported_at, book_key)
VALUES ('srtbook_444', 'Standalone Sub B', '/abs/persist/SB/sb.srt',
 444000, 'StandaloneB')
''');

        rawDb.execute('PRAGMA user_version = 36');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// Opens a minimal `user_version = 29` database for the TODO-616 v29->v30
/// migration. It has the v29-shape epub_books table seeded with one row (to
/// assert既有数据不丢 across the bump) and NO series / shelf_entries tables —
/// forcing the real `if (from < 30) createTable(series/shelfEntries)` onUpgrade
/// branch to run. No audiobooks/srt_books seeding needed: the from<29 backfill
/// only INSERTs paired rows for EPUB-backed audiobooks, and this DB seeds none.
Future<HibikiDatabase> _openV29Db() async {
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
  imported_at INTEGER NOT NULL,
  source_id INTEGER
)
''');
        rawDb.execute('''
INSERT INTO epub_books
(book_key, title, author, epub_path, extract_dir, chapter_count,
 chapters_json, imported_at)
VALUES ('PreV30', 'PreExistingBook', 'AuthorX', '/abs/p.epub',
 '/abs/p/extract', 1, '["ch1"]', 333000)
''');
        rawDb.execute('PRAGMA user_version = 29');
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
          'activity_events',
          'clipboard_history',
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
        'real v28->v29 backfills a paired srt_books row for an EPUB-backed '
        'audiobook (TODO-894), heals push gating', () async {
      // TODO-894: a v28 DB with an EPUB-backed audiobook (key 'A') but NO
      // srt_books row is the bug shape — push (live + syncAudiobookPackages)
      // looks up getSrtBookByBookKey('A')==null and skips the whole book. The
      // from<29 backfill must INSERT exactly one paired srt_books row.
      final db = await _openV28DbWithUnpairedAudiobook();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      // NOTE(TODO-616/TODO-1017): schemaVersion is the single global getter,
      // now 31 (v30 series/shelf_entries + v31 hibiki_paired_peers). This v28 DB
      // upgrades all the way to current; TODO-894's backfill still ran (asserted
      // below). The literal had to track the bump.
      expect(db.schemaVersion, 71,
          reason: 'global schemaVersion is now 38 (TODO-616 v30 + TODO-1017 '
              'v31 + TODO-1195 v32 + TODO-1204 v33 + v34 statistics_tombstones + '
              'TODO-1157 v35 stream_spec_json + TODO-1252 v36 favorite_words '
              'book_key/title + TODO-1288 v37 audiobook srt_books self-heal + '
              'v38 unified media_collections + v39 watch-stats book_uid + '
              'v40 collection order_updated_at/tombstones + '
              'v49 activity_events + v50 clipboard_history + '
              'v51 epub_books format + v52 media_collections '
              'audio_track_id/subtitle_delay_ms 系列级音轨/调轴记忆 + v53 epub_books manga_reading_mode 漫画阅读形态 + '
              'v54 video_scrape_meta 视频条目刮削资料 + v55 galgames 游戏库三表); '
              'TODO-894 backfill behavior asserted by the srt_books checks below');

      // The previously-unpaired EPUB-backed audiobook now has a srt_books row.
      final paired = await db.getSrtBookByBookKey('A');
      expect(paired, isNotNull,
          reason: 'backfill must create the missing paired SrtBook for key A');
      expect(paired!.uid, 'srtbook_epub_A',
          reason: 'uid must be the stable derivation shared with the importer');
      expect(paired.title, '安達としまむら', reason: 'title from epub_books');
      expect(paired.author, '入間人間', reason: 'author from epub_books');
      expect(paired.srtPath, '/abs/persist/A/aligned.srt',
          reason: 'srt_path = audiobooks.alignment_path');
      expect(paired.audioPathsJson, '["/abs/persist/A/disc1.mp3"]',
          reason: 'audio_paths_json passed through from audiobooks');
      expect(paired.coverPath, isNull,
          reason: 'cover_path intentionally empty');
      expect(paired.importedAt, 111000, reason: 'imported_at from epub_books');

      // The standalone subtitle book (no audiobooks row) is untouched: still
      // exactly one srt_books row for it, original uid/title preserved, and the
      // backfill never created a phantom audiobook for it.
      final standalone = await db.getSrtBookByBookKey('Standalone');
      expect(standalone, isNotNull);
      expect(standalone!.uid, 'srtbook_222',
          reason: 'standalone row must keep its original uid (untouched)');
      expect(standalone.title, 'Standalone Sub');
      expect(await db.getAudiobookByBookKey('Standalone'), isNull,
          reason: 'backfill must not invent an audiobook for standalone books');

      // Exactly two srt_books rows total: the healed 'A' + the standalone.
      final all = await db.getAllSrtBooks();
      expect(all, hasLength(2));
    });

    test('v28->v29 backfill is idempotent: re-running adds no rows, uid stable',
        () async {
      final db = await _openV28DbWithUnpairedAudiobook();
      // First open already ran the migration (schemaVersion now 29).
      final beforeAll = await db.getAllSrtBooks();
      expect(beforeAll, hasLength(2));
      final healedBefore = (await db.getSrtBookByBookKey('A'))!;

      // Re-run the backfill path directly (simulates an extra migration pass):
      // WHERE NOT IN + INSERT OR IGNORE must be a no-op now.
      await db.backfillMissingAudiobookSrtBooksV29();

      final afterAll = await db.getAllSrtBooks();
      expect(afterAll, hasLength(2), reason: '幂等：re-run must not add rows');
      final healedAfter = (await db.getSrtBookByBookKey('A'))!;
      expect(healedAfter.uid, healedBefore.uid,
          reason: 'uid stable across runs');
      expect(healedAfter.uid, 'srtbook_epub_A');
    });

    test(
        'real v36->v37 self-heals an EPUB-backed audiobook left unpaired by '
        'audiobook_import_dialog after v29 (TODO-1288)', () async {
      // TODO-1288: audiobook_import_dialog（给已有 EPUB 书加/换音频）在修复前只写
      // audiobooks 行、漏写配对 srt_books 行。v29 的一次性 backfill 只在跨过 29 时
      // 跑一次，故 DB 已 ≥29 后经该对话框新导入的有声书重新变回未配对 → 互联 host 的
      // hasAudiobook 判据认不出 → 对端显示成普通书、音频永不同步。v37 self-heal
      // （重跑幂等 backfill）必须治好这条历史破损数据。
      final db = await _openV36DbWithUnpairedAudiobook();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      expect(db.schemaVersion, 71,
          reason:
              'TODO-1288 bumps schema to v37 (audiobook srt_books self-heal)');

      // 之前未配对的 EPUB-backed 有声书 'B' 现在有了配对 srt_books 行。
      final paired = await db.getSrtBookByBookKey('B');
      expect(paired, isNotNull,
          reason: 'v37 self-heal 必须为 key B 补写缺失的配对 SrtBook');
      expect(paired!.uid, 'srtbook_epub_B', reason: 'uid 必须是与导入路径共用的稳定派生');
      expect(paired.title, 'よつばと！', reason: 'title from epub_books');
      expect(paired.author, 'あずまきよひこ', reason: 'author from epub_books');
      expect(paired.srtPath, '/abs/persist/B/aligned.srt',
          reason: 'srt_path = audiobooks.alignment_path');
      expect(paired.audioPathsJson, '["/abs/persist/B/ch1.mp3"]',
          reason: 'audio_paths_json passed through from audiobooks');
      expect(paired.coverPath, isNull,
          reason: 'cover_path intentionally empty');
      expect(paired.importedAt, 333000, reason: 'imported_at from epub_books');

      // standalone 字幕书（无 audiobooks 行）原封不动。
      final standalone = await db.getSrtBookByBookKey('StandaloneB');
      expect(standalone, isNotNull);
      expect(standalone!.uid, 'srtbook_444',
          reason: 'standalone row must keep its original uid (untouched)');
      expect(await db.getAudiobookByBookKey('StandaloneB'), isNull,
          reason:
              'self-heal must not invent an audiobook for standalone books');

      // 总共两行 srt_books：治愈的 'B' + standalone。
      final all = await db.getAllSrtBooks();
      expect(all, hasLength(2));
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

    test(
        'real v29->v30 creates series + shelf_entries, bumps user_version to 30, '
        'preserves既有数据 (TODO-616)', () async {
      final db = await _openV29Db();

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      expect(db.schemaVersion, 71,
          reason: 'global schemaVersion is now 38 (…v35 + TODO-1252 v36 + '
              'TODO-1288 v37 audiobook srt_books self-heal + v38 unified '
              'media_collections); v29->v30 '
              'series/shelf_entries creation asserted below');

      // Both new tables now exist.
      final tableNames = (await db
              .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
              .get())
          .map((r) => r.data['name'] as String)
          .toSet();
      expect(tableNames, contains('series'),
          reason: 'from<30 must createTable(series)');
      expect(tableNames, contains('shelf_entries'),
          reason: 'from<30 must createTable(shelf_entries)');

      // shelf_entries.series_id is a real FK to series(id) (onDelete:setNull).
      final fks = await db
          .customSelect("PRAGMA foreign_key_list('shelf_entries')")
          .get();
      final fkTables = fks.map((r) => r.data['table'] as String).toSet();
      expect(fkTables, contains('series'),
          reason: 'shelf_entries.series_id references series(id)');

      // 既有数据不丢：the seeded pre-v30 epub_books row survives the bump.
      final preserved = await db.getEpubBook('PreV30');
      expect(preserved, isNotNull,
          reason: 'v30 createTable migration must not touch existing rows');
      expect(preserved!.title, 'PreExistingBook');
      expect(preserved.author, 'AuthorX');
      expect(preserved.importedAt, 333000);

      // The new tables start empty (no backfill) -> default散书 + importedAt
      // 倒序退化 (Never break userspace).
      expect(await db.getAllSeries(), isEmpty);
      expect(await db.getAllShelfEntries(), isEmpty);
    });

    test('v29->v30 createTable migration is idempotent on a fresh DB',
        () async {
      // A fresh DB is created at v30 by onCreate's createAll; the from<30 guard
      // (_tableExists) must make re-entering the step a no-op rather than a
      // "table already exists" failure.
      final db = await _openDb();
      final tableNames = (await db
              .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
              .get())
          .map((r) => r.data['name'] as String)
          .toSet();
      expect(tableNames, containsAll(['series', 'shelf_entries']));
      expect(db.schemaVersion, 71);
    });

    test(
        'fresh DB (v33) has lookup_mining_counters with the expected columns '
        '(TODO-1204)', () async {
      final db = await _openDb();
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      expect(db.schemaVersion, 71,
          reason:
              'TODO-1288 v37 audiobook srt_books self-heal; v38 unified media_collections (series→collection + playlist split)');

      final tableNames = (await db
              .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
              .get())
          .map((r) => r.data['name'] as String)
          .toSet();
      expect(tableNames, contains('lookup_mining_counters'),
          reason: 'from<33 must createTable(lookup_mining_counters)');

      final cols = await db
          .customSelect("PRAGMA table_info('lookup_mining_counters')")
          .get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(
          colNames,
          containsAll(<String>[
            'book_key',
            'title',
            'source_type',
            'date_key',
            'lookup_count',
            'mine_count',
          ]));
    });

    test(
        'fresh DB (v34) has statistics_tombstones with the expected columns '
        '(TODO-1204 后续)', () async {
      final db = await _openDb();
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      expect(db.schemaVersion, 71,
          reason:
              'TODO-1288 v37 audiobook srt_books self-heal; v38 unified media_collections (series→collection + playlist split)');

      final tableNames = (await db
              .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
              .get())
          .map((r) => r.data['name'] as String)
          .toSet();
      expect(tableNames, contains('statistics_tombstones'));

      final cols = await db
          .customSelect("PRAGMA table_info('statistics_tombstones')")
          .get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames,
          containsAll(<String>['title', 'source_type', 'deleted_at']));
    });

    test(
        'real v33->v34 creates statistics_tombstones, bumps user_version to 34 '
        '(TODO-1204 后续)', () async {
      final db = await _openV33DbWithoutStatisticsTombstones();
      // Opening triggers the from<34 branch; the table must now exist and a
      // tombstone round-trips.
      final tableNames = (await db
              .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
              .get())
          .map((r) => r.data['name'] as String)
          .toSet();
      expect(tableNames, contains('statistics_tombstones'),
          reason: 'from<34 must createTable(statisticsTombstones)');
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      await db.insertStatisticsTombstone('A', 'book');
      expect(await db.getStatisticsTombstoneKeys(), contains(('A', 'book')));
    });
    test('fresh DB (v35) has video_books.stream_spec_json column (TODO-1157)',
        () async {
      final db = await _openDb();
      expect(db.schemaVersion, 71);
      final cols =
          await db.customSelect("PRAGMA table_info('video_books')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, contains('stream_spec_json'),
          reason: 'fresh createAll must include TODO-1157 stream_spec_json');
    });

    test(
        'real v34->v35 adds video_books.stream_spec_json, preserves rows, '
        'bumps user_version (TODO-1157)', () async {
      final db = await _openV34DbWithoutStreamSpecJson();
      // Opening triggers from<35 addColumn(streamSpecJson).
      final cols =
          await db.customSelect("PRAGMA table_info('video_books')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, contains('stream_spec_json'),
          reason: 'from<35 must addColumn(videoBooks.streamSpecJson)');
      // 既有行保留、新列默认 NULL（无损迁移）。
      final rows = await db
          .customSelect(
              "SELECT stream_spec_json FROM video_books WHERE book_uid='video/stream/x'")
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.data['stream_spec_json'], isNull);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
    });

    test('fresh DB (v45) has media_collections.anilist_id column', () async {
      final db = await _openDb();
      expect(db.schemaVersion, 71);
      final cols =
          await db.customSelect("PRAGMA table_info('media_collections')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, contains('anilist_id'),
          reason: 'fresh createAll must include v45 anilist_id');
    });

    test(
        'real v44->v45 adds media_collections.anilist_id, preserves rows, '
        'DAO round-trips', () async {
      final db = await _openV44DbWithoutCollectionAnilistId();
      // Opening triggers from<45 addColumn(mediaCollections.anilistId).
      final cols =
          await db.customSelect("PRAGMA table_info('media_collections')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, contains('anilist_id'),
          reason: 'from<45 must addColumn(mediaCollections.anilistId)');
      // 既有行保留、新列默认 NULL（无损迁移）。
      final row = await db.getMediaCollectionById(1);
      expect(row, isNotNull);
      expect(row!.name, 'Bocchi the Rock!');
      expect(row.anilistId, isNull);
      // DAO 绑定/清除往返。
      await db.setMediaCollectionAnilistId(1, 12345);
      expect((await db.getMediaCollectionById(1))!.anilistId, 12345);
      await db.setMediaCollectionAnilistId(1, null);
      expect((await db.getMediaCollectionById(1))!.anilistId, isNull);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
    });

    test('fresh DB (v46) has epub_books.completed_at column', () async {
      final db = await _openDb();
      expect(db.schemaVersion, 71);
      final cols =
          await db.customSelect("PRAGMA table_info('epub_books')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, contains('completed_at'),
          reason: 'fresh createAll must include v46 epub_books.completed_at');
    });

    test(
        'fresh DB (v36) has favorite_words.book_key + title columns (TODO-1252)',
        () async {
      final db = await _openDb();
      expect(db.schemaVersion, 71);
      final cols =
          await db.customSelect("PRAGMA table_info('favorite_words')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(<String>['book_key', 'title']),
          reason: 'fresh createAll must include TODO-1252 book_key/title');
    });

    test(
        'real v35->v36 adds favorite_words.book_key + title, preserves rows, '
        'bumps user_version (TODO-1252)', () async {
      final db = await _openV35DbWithoutFavoriteBookColumns();
      // Opening triggers from<36 addColumn(bookKey/title).
      final cols =
          await db.customSelect("PRAGMA table_info('favorite_words')").get();
      final colNames = cols.map((r) => r.data['name'] as String).toSet();
      expect(colNames, containsAll(<String>['book_key', 'title']),
          reason: 'from<36 must addColumn(favoriteWords.bookKey/.title)');
      // 既有行保留、新列 book_key 默认 NULL / title 默认空串（无损迁移）。
      final rows = await db
          .customSelect(
              "SELECT book_key, title FROM favorite_words WHERE source_type='book'")
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.data['book_key'], isNull);
      expect(rows.single.data['title'], '');
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
    });

    // BUG-1310：v64 新增 collection_scrape_meta（合集级刮削资料的宿主）。
    //
    // 纯新增表、不动任何既有表/列，所以这条只需锁两点：升级后表真的建出来了，
    // 且既有合集行**一行不少、一列不改**（升级绝不能碰用户数据）。
    test('fresh DB (v64) has collection_scrape_meta table', () async {
      final db = await _openDb();
      expect(db.schemaVersion, 71);
      final rows = await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='collection_scrape_meta'")
          .get();
      expect(rows, hasLength(1),
          reason: 'fresh createAll must include v64 collection_scrape_meta');
    });

    test(
        'real v63->v64 creates collection_scrape_meta, preserves collections, '
        'bumps user_version (BUG-1310)', () async {
      final db = await _openV63DbWithoutCollectionScrapeMeta();

      final tables = await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='collection_scrape_meta'")
          .get();
      expect(tables, hasLength(1), reason: 'from<64 分支必须建出新表');

      // 既有合集数据原样保留（升级只加表，不碰用户数据）。
      final row = await db.getMediaCollectionById(1);
      expect(row, isNotNull);
      expect(row!.name, 'Bocchi the Rock!');
      expect(row.coverPath, '/old/cover.jpg');

      // 未刮过 → 空表；写入后可读回（新表真的可用，不只是建了个壳）。
      expect(await db.getCollectionScrapeMeta(1), isNull);
      await db.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: const Value(1),
          source: 'tmdb',
          subjectId: '100',
          title: '孤独摇滚！',
          scrapedAt: DateTime(2026),
        ),
      );
      expect((await db.getCollectionScrapeMeta(1))!.title, '孤独摇滚！');

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
    });

    test('v66 -> v67 rebuilds reading_hourly_logs with format dimension',
        () async {
      final db = await _openV66DbWithLegacyReadingHourlyLogs();

      // 既有行零丢失，format 落 ''（历史未区分——写入时信息已丢，不猜身份）。
      final legacy = await db.getHourlyLogsForDate('2026-07-01');
      expect(legacy, hasLength(2));
      expect(legacy.map((l) => l.format).toSet(), {''});
      expect(legacy.singleWhere((l) => l.hour == 9).readingTimeMs, 1800000);
      expect(legacy.singleWhere((l) => l.hour == 10).readingTimeMs, 600000);

      // 新唯一键 {dateKey, hour, format}：同一小时不同写入面各自成行，与
      // 历史 '' 行共存互不冲突。
      await db.addHourlyReadingTime(
        dateKey: '2026-07-01',
        hour: 9,
        deltaMs: 300000,
        format: BookFormat.manga,
      );
      final after = await db.getHourlyLogsForDate('2026-07-01');
      expect(after, hasLength(3));
      expect(
          after
              .singleWhere((l) => l.format.isEmpty && l.hour == 9)
              .readingTimeMs,
          1800000);
      expect(
        after
            .singleWhere((l) => l.format == BookFormat.manga.dbValue)
            .readingTimeMs,
        300000,
      );

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
    });
  });
}

/// 打开一个 `user_version = 63` 的库：有 media_collections 及其数据，但**没有**
/// collection_scrape_meta，强制 HibikiDatabase 打开时跑真实的
/// `if (from < 64) createTable(collectionScrapeMeta)` 分支（BUG-1310）。
///
/// from=63 时迁移阶梯上只有 `from < 64` 这一个条件成立，因此这里只需备齐该分支
/// 触碰到的表，不必重建整个 v63 schema。
Future<HibikiDatabase> _openV63DbWithoutCollectionScrapeMeta() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('''
CREATE TABLE media_collections (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  collection_type TEXT NOT NULL DEFAULT 'collection',
  cover_source TEXT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  order_updated_at INTEGER NOT NULL DEFAULT 0,
  anilist_id INTEGER NULL,
  audio_track_id TEXT NULL,
  subtitle_delay_ms INTEGER NULL,
  cover_path TEXT NULL
);
''');
        rawDb.execute(
          'INSERT INTO media_collections (id, name, collection_type, '
          'sort_order, created_at, order_updated_at, cover_path) '
          "VALUES (1, 'Bocchi the Rock!', 'playlist', 0, 0, 0, "
          "'/old/cover.jpg')",
        );
        rawDb.execute('PRAGMA user_version = 63');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// 打开一个 `user_version = 66` 的库：reading_hourly_logs 还是旧形状（无 format
/// 列、唯一键 {date_key, hour}）且已有跨面加总过的历史行，强制 HibikiDatabase
/// 打开时跑真实的 `if (from < 67) alterTable(readingHourlyLogs)` 重建分支。
///
/// from=66 时迁移阶梯上只有 `from < 67` 这一个条件成立，因此只备齐该分支触碰
/// 的表（风格同 [_openV63DbWithoutCollectionScrapeMeta]）。
Future<HibikiDatabase> _openV66DbWithLegacyReadingHourlyLogs() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('''
CREATE TABLE reading_hourly_logs (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  date_key TEXT NOT NULL,
  hour INTEGER NOT NULL,
  reading_time_ms INTEGER NOT NULL,
  UNIQUE (date_key, hour)
);
''');
        rawDb.execute(
          'INSERT INTO reading_hourly_logs (date_key, hour, reading_time_ms) '
          "VALUES ('2026-07-01', 9, 1800000), ('2026-07-01', 10, 600000)",
        );
        rawDb.execute('PRAGMA user_version = 66');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}
