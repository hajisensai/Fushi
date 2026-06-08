import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Regression guard for the DOWNGRADE-PROTECTION branch in
/// HibikiDatabase.migration (database.dart `if (from > to)`).
///
/// History: an earlier build DROPPED every table and recreated the current
/// schema whenever a DB stored at a HIGHER schema version was opened. That
/// "destructive downgrade" wiped users' libraries twice (BUG-075 family), so the
/// behaviour was deliberately replaced: opening a future-versioned DB now THROWS
/// [HibikiDatabaseDowngradeException] from the earliest migration hook, BEFORE
/// any DROP / migration / rebuild runs, leaving the DB byte-for-byte intact. The
/// app layer catches it and shows an "update your app" notice.
///
/// These tests therefore assert the OPPOSITE of the old ones: the open must be
/// REFUSED (throw), never silently rebuilt. Seeds user_version = 99 (well above
/// the current schema) to force the `from > to` path regardless of how high the
/// real [HibikiDatabase.schemaVersion] climbs, so the guard never goes stale on a
/// schema bump.
Future<HibikiDatabase> _openDowngradedFromFuture() async {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Seed a DB that claims to be a FUTURE version (99 > current) with a
        // real row, so a destructive rebuild (if it ever regressed back) would
        // be observable as data loss.
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

/// Same future-version seed but with `PRAGMA foreign_keys = ON` and a real
/// referential chain (mirrors production `_openDb`). The old destructive path
/// crashed mid-drop under FK enforcement (BUG-075); the protection path must
/// refuse cleanly regardless of FK state and never touch the data.
Future<HibikiDatabase> _openDowngradedWithForeignKeys() async {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
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
  test('opening a future-version DB is refused, not destructively rebuilt',
      () async {
    final HibikiDatabase db = await _openDowngradedFromFuture();
    addTearDown(db.close);

    // Reading forces the lazy DB to open, which triggers onUpgrade(99 -> current)
    // and must throw the protection exception instead of dropping/rebuilding.
    await expectLater(
      db.customSelect('PRAGMA user_version').getSingle(),
      throwsA(isA<HibikiDatabaseDowngradeException>()
          .having((HibikiDatabaseDowngradeException e) => e.dbVersion,
              'dbVersion', 99)
          .having((HibikiDatabaseDowngradeException e) => e.appSchemaVersion,
              'appSchemaVersion', db.schemaVersion)),
      reason: 'a newer-schema DB must be refused to protect user data, '
          'never silently dropped and recreated',
    );
  });

  test('BUG-075: future-version refusal is clean under foreign_keys=ON',
      () async {
    final HibikiDatabase db = await _openDowngradedWithForeignKeys();
    addTearDown(db.close);

    // Pre-fix this FK-ordered teardown crashed mid-drop; the protection path
    // throws before any DROP runs, so FK state is irrelevant and no table is
    // ever touched.
    await expectLater(
      db.customSelect('PRAGMA user_version').getSingle(),
      throwsA(isA<HibikiDatabaseDowngradeException>()),
      reason: 'FK-on downgrade must be refused cleanly, not crash mid-drop',
    );
  });
}
