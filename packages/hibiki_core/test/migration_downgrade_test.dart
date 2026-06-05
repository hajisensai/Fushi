import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Regression guard for the destructive downgrade branch in
/// HibikiDatabase.migration (database.dart `if (from > to)`): when a DB stored
/// at a HIGHER schema version than the app's current schema is opened, the
/// migration must DROP every known table and recreate the current schema, so a
/// future-versioned DB never leaves the app on a schema it can't read.
///
/// Seeds user_version = 17 (one above the current 16) to force the `from > to`
/// downgrade path. The post-v16 epub_books uses bookKey as PK (no autoincrement
/// id).
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
        // Seed a DB that claims to be a FUTURE version (17 > current 16). Only
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
        rawDb.execute('PRAGMA user_version = 17');
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

    // Reading forces the lazy DB to open, which triggers onUpgrade(17 -> 16).
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 16,
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
}
