import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Regression guard for the destructive downgrade branch in
/// HibikiDatabase.migration (database.dart `if (from > to)`): when a DB stored
/// at a HIGHER schema version than the app's current schema is opened, the
/// migration must DROP every table actually present and recreate the current
/// schema, so a future-versioned DB never leaves the app on a schema it can't
/// read.
///
/// Seeds user_version = 99 (well above the current schema) to force the
/// `from > to` downgrade path regardless of how high the real schemaVersion
/// climbs. Assertions compare against the live [HibikiDatabase.schemaVersion]
/// instead of a hard-coded number so the test never goes stale on a bump (the
/// previous revision hard-coded 16/17 and silently stopped exercising the
/// downgrade branch once schemaVersion passed 17 — that blind spot is exactly
/// how BUG-075 shipped).
///
/// Scope note: the file-backup half (copy hibiki.db -> .bak before the drop) is
/// gated on a non-empty _dbDirectory and only reachable through the real
/// `createInBackground` constructor (a background isolate, not host-test-safe),
/// so it is covered by code inspection. This test drives the in-process
/// drop+recreate that actually runs in CI via the in-memory `forTesting` path.
Future<HibikiDatabase> _openDowngradedFromFuture() async {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Seed a DB that claims to be a FUTURE version (99 > current). Only
        // epub_books is pre-created and given a row; `profiles` is deliberately
        // left absent so we can prove createAll() rebuilds the full schema.
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
        rawDb.execute(
          "INSERT INTO epub_books "
          "(book_key, title, epub_path, extract_dir, chapter_count, chapters_json, imported_at) "
          "VALUES ('stale future row', 'stale future row', '/x.epub', '/x', 0, '[]', 0)",
        );
        rawDb.execute('PRAGMA user_version = 99');
      },
    ),
  );
}

/// Reproduces BUG-075: the downgrade teardown must survive `foreign_keys = ON`.
///
/// Production opens the DB with `PRAGMA foreign_keys = ON` (see `_openDb`), but
/// the old test harness left it at SQLite's OFF default, so the FK-ordered drop
/// crash never surfaced in CI. This helper mirrors production by enabling FK
/// enforcement AND seeding a real referential chain:
///   book_tag_mappings.book_key -> epub_books.book_key   (CASCADE)
///   book_tag_mappings.tag_id   -> book_tags.id          (CASCADE)
/// matching the generated schema. With foreign_keys ON, dropping tables in
/// declaration order drops `epub_books` before `book_tags`; tearing down
/// `book_tags` then forces SQLite to validate the still-present
/// `book_tag_mappings`, whose FK references the already-dropped `epub_books`
/// -> "no such table: epub_books", aborting the migration mid-drop (and, since
/// each DROP auto-commits, leaving the DB permanently half-dropped).
Future<HibikiDatabase> _openDowngradedWithForeignKeys() async {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Mirror production: FK enforcement on for the whole connection.
        rawDb.execute('PRAGMA foreign_keys = ON');
        rawDb.execute('''
CREATE TABLE epub_books (
  book_key TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  epub_path TEXT NOT NULL,
  extract_dir TEXT NOT NULL,
  chapter_count INTEGER NOT NULL,
  chapters_json TEXT NOT NULL,
  imported_at INTEGER NOT NULL
)
''');
        rawDb.execute('''
CREATE TABLE book_tags (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL
)
''');
        // FK targets must resolve at DROP time; both references mirror the real
        // generated constraints (ON DELETE CASCADE).
        rawDb.execute('''
CREATE TABLE book_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL REFERENCES epub_books (book_key) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE
)
''');
        rawDb.execute(
          "INSERT INTO epub_books "
          "(book_key, title, epub_path, extract_dir, chapter_count, chapters_json, imported_at) "
          "VALUES ('b', 'b', '/x.epub', '/x', 0, '[]', 0)",
        );
        rawDb.execute("INSERT INTO book_tags (name) VALUES ('t')");
        rawDb.execute(
          "INSERT INTO book_tag_mappings (book_key, tag_id) VALUES ('b', 1)",
        );
        rawDb.execute('PRAGMA user_version = 99');
      },
    ),
  );
}

void main() {
  test(
      'downgrade from a future schema drops known tables and recreates current',
      () async {
    final HibikiDatabase db = await _openDowngradedFromFuture();
    addTearDown(db.close);

    // Reading forces the lazy DB to open, which triggers onUpgrade(99 -> current).
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion,
        reason: 'downgrade must land on the app current schema version');

    // The pre-seeded row must be gone: the destructive DROP+recreate ran on the
    // known epub_books table rather than leaving incompatible future data.
    final epub = await db
        .customSelect('SELECT COUNT(*) AS c FROM epub_books')
        .getSingle();
    expect(epub.read<int>('c'), 0,
        reason: 'destructive downgrade must wipe data from known tables');

    // A table that was NOT present in the seeded DB must now exist and be
    // queryable, proving createAll() rebuilt the complete current schema.
    final profiles =
        await db.customSelect('SELECT COUNT(*) AS c FROM profiles').getSingle();
    expect(profiles.read<int>('c'), 0,
        reason: 'createAll must rebuild the full schema after the drop');
  });

  test(
      'BUG-075: downgrade teardown survives foreign_keys=ON with a real FK chain',
      () async {
    final HibikiDatabase db = await _openDowngradedWithForeignKeys();
    addTearDown(db.close);

    // Forcing the open must NOT throw "no such table: epub_books" mid-drop.
    // (Pre-fix: the FK-ordered DROP aborts here.)
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion,
        reason: 'FK-on downgrade must complete and land on current schema');

    // The baseline table that the partial-drop corruption used to destroy must
    // exist again (this is the table whose absence produced the original
    // "no such table: preferences" crash on every subsequent launch).
    final prefs = await db
        .customSelect('SELECT COUNT(*) AS c FROM preferences')
        .getSingle();
    expect(prefs.read<int>('c'), 0,
        reason:
            'createAll must rebuild baseline tables (preferences) after FK-on teardown');

    // The FK chain is rebuilt empty and queryable.
    final mappings = await db
        .customSelect('SELECT COUNT(*) AS c FROM book_tag_mappings')
        .getSingle();
    expect(mappings.read<int>('c'), 0,
        reason: 'destructive downgrade wipes the rebuilt FK tables');
  });
}
