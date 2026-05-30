import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Regression guard for the destructive downgrade branch in
/// HibikiDatabase.migration (database.dart `if (from > to)`): when a DB stored
/// at a HIGHER schema version than the app's current schema (14) is opened, the
/// migration must DROP every known table and recreate the current v14 schema,
/// so a future-versioned DB never leaves the app on a schema it can't read.
///
/// Scope note: the file-backup half (copy hibiki.db -> .bak before the drop) is
/// gated on a non-empty _dbDirectory and only reachable through the real
/// `createInBackground` constructor (a background isolate, not host-test-safe),
/// so it is covered by code inspection. This test drives the in-process
/// drop+recreate that actually runs in CI via the in-memory `forTesting` path.
Future<HibikiDatabase> _openDowngradedFromV15() async {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Seed a DB that claims to be a FUTURE version (15 > current 14). Only
        // epub_books is pre-created and given a row; `profiles` is deliberately
        // left absent so we can prove createAll() rebuilds the full v14 schema.
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
        rawDb.execute(
          "INSERT INTO epub_books "
          "(title, epub_path, extract_dir, chapter_count, chapters_json, imported_at) "
          "VALUES ('stale future row', '/x.epub', '/x', 0, '[]', 0)",
        );
        rawDb.execute('PRAGMA user_version = 15');
      },
    ),
  );
}

void main() {
  test('downgrade from a future schema drops known tables and recreates v14',
      () async {
    final HibikiDatabase db = await _openDowngradedFromV15();
    addTearDown(db.close);

    // Reading forces the lazy DB to open, which triggers onUpgrade(15 -> 14).
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 14,
        reason: 'downgrade must land on the app current schema version');

    // The pre-seeded row must be gone: the destructive DROP+recreate ran on the
    // known epub_books table rather than leaving incompatible future data.
    final epub = await db
        .customSelect('SELECT COUNT(*) AS c FROM epub_books')
        .getSingle();
    expect(epub.read<int>('c'), 0,
        reason: 'destructive downgrade must wipe data from known tables');

    // A v14 table that was NOT present in the seeded DB must now exist and be
    // queryable, proving createAll() rebuilt the complete current schema.
    final profiles = await db
        .customSelect('SELECT COUNT(*) AS c FROM profiles')
        .getSingle();
    expect(profiles.read<int>('c'), 0,
        reason: 'createAll must rebuild the full v14 schema after the drop');
  });
}
