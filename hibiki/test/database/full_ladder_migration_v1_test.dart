import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Single end-to-end guard that a **v1 baseline DB walks the WHOLE onUpgrade
/// ladder (v1 -> current) in one open** and lands on the current shape with all
/// tracked data preserved.
///
/// The existing migration tests each enter the ladder mid-way (v3, v11, v14,
/// v15, v20, v21, v22) and assert one step. None starts at v1, so no test
/// proves the earliest steps (`from<2` dictionary type column, `from<3`/`from<4`
/// column adds) compose correctly with the later re-key + drop steps. This file
/// fills that gap.
///
/// The v1 baseline DDL below is the legacy int-keyed schema (epub_books id-PK,
/// reader_positions/bookmarks/book_tag_mappings keyed by the legacy int columns)
/// — cross-checked against the historical DDL captured in
/// `srt_cue_migration_test.dart` (_openV11DbWithSrtCues) and
/// `foreign_keys_test.dart` (_openLegacyDbWithExistingSortOrder /
/// _openLegacyDbWithExistingDictionaryType). Getting the legacy columns wrong
/// would silently pass (false green), so the columns mirror those files exactly.
///
/// Version assertions use `db.schemaVersion` (never a hard-coded 24).

/// `_sanitizeBookKey` is private to database.dart; for ASCII-safe titles with no
/// reserved chars the sanitized key equals the title verbatim, so the seed below
/// uses plain titles and asserts the key == title.
const String _kTitleA = 'KokoroBook';
const String _kTitleB = 'NekoBook';

/// Seeds a faithful `user_version = 1` baseline and the rows the ladder must
/// carry through to the current schema. [startVersion] lets the same seed serve
/// the v2/v3 entry-point cases (the ladder is a superset from any lower start).
Future<HibikiDatabase> _openV1Baseline({int startVersion = 1}) async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA foreign_keys = OFF');

        // ── epub_books: legacy autoincrement id PK (pre-v16). ──
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

        // ── reader_positions: v1 had NO ttu_char_offset (added at v4) and is
        //    keyed by ttu_book_id (re-keyed to book_key at v16, then char_offset
        //    added / ttu_char_offset dropped at v24). ──
        rawDb.execute('''
CREATE TABLE reader_positions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ttu_book_id INTEGER NOT NULL UNIQUE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');

        // ── dictionary_metadata: v1 had NO `type` column (added at from<2). ──
        rawDb.execute('''
CREATE TABLE dictionary_metadata (
  name TEXT NOT NULL PRIMARY KEY,
  format_key TEXT NOT NULL,
  "order" INTEGER NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  hidden_languages_json TEXT NOT NULL DEFAULT '[]',
  collapsed_languages_json TEXT NOT NULL DEFAULT '[]'
)
''');

        // ── seed data we will track all the way to v24 ──
        rawDb.execute(
          'INSERT INTO epub_books '
          '(id, title, author, epub_path, extract_dir, chapter_count, '
          ' chapters_json, imported_at) '
          "VALUES (1, '$_kTitleA', 'AuthorA', '/abs/a.epub', '/abs/a', 2, "
          "'[]', 100)",
        );
        rawDb.execute(
          'INSERT INTO epub_books '
          '(id, title, author, epub_path, extract_dir, chapter_count, '
          ' chapters_json, imported_at) '
          "VALUES (2, '$_kTitleB', 'AuthorB', '/abs/b.epub', '/abs/b', 3, "
          "'[]', 200)",
        );
        // Two reader positions keyed by the legacy ttu_book_id (= epub id).
        rawDb.execute(
          'INSERT INTO reader_positions '
          '(ttu_book_id, section_index, norm_char_offset, updated_at) '
          'VALUES (1, 5, 3333, 1111)',
        );
        rawDb.execute(
          'INSERT INTO reader_positions '
          '(ttu_book_id, section_index, norm_char_offset, updated_at) '
          'VALUES (2, 7, 6666, 2222)',
        );
        rawDb.execute(
          'INSERT INTO dictionary_metadata (name, format_key, "order") '
          "VALUES ('JMdict', 'yomitan', 0)",
        );

        rawDb.execute('PRAGMA user_version = $startVersion');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

void main() {
  group('full ladder from v1 baseline', () {
    test('v1 -> current: every step composes, all tracked data preserved',
        () async {
      final db = await _openV1Baseline();

      // (a) Ladder walked to the live schema version.
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // (b) from<2: dictionary_metadata gained the `type` column (default
      //     'term'), the seeded row preserved.
      final dictCols = await db
          .customSelect("PRAGMA table_info('dictionary_metadata')")
          .get();
      final dictColNames =
          dictCols.map((r) => r.data['name'] as String).toSet();
      expect(dictColNames, contains('type'));
      final dictRow = await db
          .customSelect(
              "SELECT name, type FROM dictionary_metadata WHERE name='JMdict'")
          .getSingle();
      expect(dictRow.read<String>('type'), 'term',
          reason: 'from<2 addColumn default is term');

      // (c) v16 re-key: epub_books now book_key-PK (no legacy id); both books
      //     survive and their keys equal the sanitized titles (ASCII titles
      //     sanitize verbatim).
      final epubCols =
          await db.customSelect("PRAGMA table_info('epub_books')").get();
      final epubColNames =
          epubCols.map((r) => r.data['name'] as String).toSet();
      expect(epubColNames, contains('book_key'));
      expect(epubColNames, isNot(contains('id')),
          reason: 'v16 re-key drops the legacy autoincrement id');
      final books = await db.getAllEpubBooks();
      expect(books.map((b) => b.bookKey).toSet(),
          equals(<String>{_kTitleA, _kTitleB}),
          reason: 'both books survive the re-key with key == sanitized title');

      // (d) v16 row-level data-preservation for reader_positions: the two
      //     positions re-keyed from ttu_book_id -> book_key, every other column
      //     intact, reachable via the typed getReaderPosition(bookKey).
      final posA = await db.getReaderPosition(_kTitleA);
      expect(posA, isNotNull, reason: 'position for book 1 survived re-key');
      expect(posA!.sectionIndex, 5);
      expect(posA.normCharOffset, 3333);
      expect(posA.updatedAt, 1111);
      final posB = await db.getReaderPosition(_kTitleB);
      expect(posB, isNotNull, reason: 'position for book 2 survived re-key');
      expect(posB!.sectionIndex, 7);
      expect(posB.normCharOffset, 6666);

      // (e) v24: ttu_char_offset terminally dropped, char_offset present and
      //     defaulting to -1 on the carried-over rows.
      final rpCols =
          await db.customSelect("PRAGMA table_info('reader_positions')").get();
      final rpColNames = rpCols.map((r) => r.data['name'] as String).toSet();
      expect(rpColNames, contains('char_offset'));
      expect(rpColNames, isNot(contains('ttu_char_offset')),
          reason: 'v24 terminally drops ttu_char_offset');
      expect(posA.charOffset, -1,
          reason: 'rows carried through the ladder default char_offset to -1');

      // (f) Key tables all present after the full ladder (sanity that no step
      //     dropped a table). Mirrors migration_test.dart "all expected tables".
      final tables = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table' "
              "AND name NOT LIKE 'sqlite_%'")
          .get();
      final tableNames = tables.map((r) => r.data['name'] as String).toSet();
      expect(
        tableNames,
        containsAll(<String>[
          'epub_books',
          'reader_positions',
          'bookmarks',
          'dictionary_metadata',
          'sync_baselines',
          'video_books',
          'video_book_tag_mappings',
          'video_watch_statistics',
          'video_hourly_logs',
          'favorite_words',
          'mining_statistics',
        ]),
      );
    });

    test('v2 entry point also lands on the current schema (no double-add)',
        () async {
      // Same seed but the DB already declares v2 — from<2 (dictionary type) must
      // NOT re-fire and error. We add the type column up front to mirror a real
      // v2 DB.
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
  updated_at INTEGER NOT NULL
)
''');
            // v2 DB: dictionary_metadata already HAS the type column.
            rawDb.execute('''
CREATE TABLE dictionary_metadata (
  name TEXT NOT NULL PRIMARY KEY,
  format_key TEXT NOT NULL,
  "order" INTEGER NOT NULL,
  type TEXT NOT NULL DEFAULT 'term',
  metadata_json TEXT NOT NULL DEFAULT '{}',
  hidden_languages_json TEXT NOT NULL DEFAULT '[]',
  collapsed_languages_json TEXT NOT NULL DEFAULT '[]'
)
''');
            rawDb.execute(
              'INSERT INTO epub_books '
              '(id, title, epub_path, extract_dir, chapter_count, '
              ' chapters_json, imported_at) '
              "VALUES (1, '$_kTitleA', '/abs/a.epub', '/abs/a', 1, '[]', 1)",
            );
            rawDb.execute(
              'INSERT INTO reader_positions '
              '(ttu_book_id, section_index, norm_char_offset, updated_at) '
              'VALUES (1, 9, 4242, 5)',
            );
            rawDb.execute('PRAGMA user_version = 2');
          },
        ),
      );
      addTearDown(db.close);

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      // Book re-keyed, position carried through, ttu_char_offset gone.
      final pos = await db.getReaderPosition(_kTitleA);
      expect(pos, isNotNull);
      expect(pos!.sectionIndex, 9);
      expect(pos.normCharOffset, 4242);
      expect(pos.charOffset, -1);
      final rpColNames =
          (await db.customSelect("PRAGMA table_info('reader_positions')").get())
              .map((r) => r.data['name'] as String)
              .toSet();
      expect(rpColNames, isNot(contains('ttu_char_offset')));
    });
  });
}
