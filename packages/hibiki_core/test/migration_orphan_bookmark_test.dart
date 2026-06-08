import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Safety-net for the orphan-bookmark skip in
/// HibikiDatabase.migrateLegacyBookmarkPreferences() (database.dart ~468-549),
/// re-establishing the coverage that the milestone-2 cleanup deleted
/// (HBK-AUDIT-007).
///
/// The drainer migrates legacy `bookmarks_<int>` PREFERENCES (the production
/// source — it reads getAllPrefs(), NOT a legacy bookmarks table) into the
/// `bookmarks` table while that table still carries its pre-v16 `ttu_book_id`
/// column. `bookmarks.ttu_book_id` is an FK to `epub_books(id)`, so a legacy
/// pref entry whose `ttuBookId` has no imported epub is an ORPHAN: a plain
/// INSERT would raise an FK violation and abort the ENTIRE upgrade transaction
/// (the user's DB would refuse to open). Production guards this with a
/// `bookExists` pre-check + `continue` (database.dart ~520-524).
///
/// This test seeds a pre-v16-shaped DB (int-id epub_books + `ttu_book_id`
/// bookmarks + legacy `bookmarks_<int>` prefs) with `foreign_keys = ON`, then
/// invokes the public drainer directly (user_version = 16 so onUpgrade does NOT
/// run — the method is self-guarded by table/column probes and is the unit
/// under test). Seed follows the migration_downgrade_test raw-DB pattern.
late HibikiDatabase _orphanDb;

HibikiDatabase _openPreV16WithLegacyBookmarkPrefs() {
  // book 1 keeps two bookmarks (one orphan ttuBookId mixed in); book 999 is a
  // pure-orphan pref (no matching epub at all). Real entries must land; orphans
  // must be skipped; every legacy key must be cleared.
  final String book1Prefs = jsonEncode(<Map<String, dynamic>>[
    <String, dynamic>{
      'sectionIndex': 0,
      'normCharOffset': 100,
      'label': 'real-bm',
      'createdAt': '2026-01-01T00:00:00.000Z',
      'ttuBookId': 1,
    },
    <String, dynamic>{
      // Orphan row INSIDE an otherwise-real pref: ttuBookId 999 has no epub.
      'sectionIndex': 1,
      'normCharOffset': 200,
      'label': 'orphan-bm',
      'createdAt': '2026-01-02T00:00:00.000Z',
      'ttuBookId': 999,
    },
  ]);
  final String orphanOnlyPrefs = jsonEncode(<Map<String, dynamic>>[
    <String, dynamic>{
      'sectionIndex': 0,
      'normCharOffset': 50,
      'label': 'orphan-only',
      'createdAt': '2026-01-03T00:00:00.000Z',
      'ttuBookId': 999,
    },
  ]);

  _orphanDb = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        // FK enforcement ON, mirroring production _openDb. Without it the
        // orphan-skip assertion would be vacuous (the bad INSERT would silently
        // succeed instead of being the abort hazard the guard defends against).
        raw.execute('PRAGMA foreign_keys = ON');

        // epub_books in PRE-v16 shape (int id PK). Only book 1 exists.
        raw.execute('''
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
)''');
        raw.execute(
          "INSERT INTO epub_books "
          "(id, title, epub_path, extract_dir, chapter_count, chapters_json, imported_at) "
          "VALUES (1, 'Real Book', '/r.epub', '/books/1', 1, '[]', 100)",
        );

        // bookmarks in PRE-v16 shape (ttu_book_id int FK). Empty so the drainer
        // takes the JSON-import branch (it only imports when the table has no
        // rows for that ttu_book_id). FK declared so an orphan INSERT really
        // would abort if the guard regressed.
        raw.execute('''
CREATE TABLE bookmarks (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ttu_book_id INTEGER NOT NULL REFERENCES epub_books (id) ON DELETE CASCADE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  label TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  book_title TEXT,
  page_in_chapter INTEGER,
  total_pages_in_chapter INTEGER
)''');

        // preferences: the legacy `bookmarks_<int>` source the drainer reads.
        raw.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''');
        raw.execute(
          "INSERT INTO preferences (key, value) VALUES (?, ?), (?, ?), (?, ?)",
          <Object?>[
            'bookmarks_1', book1Prefs, //
            'bookmarks_999', orphanOnlyPrefs,
            // An unrelated pref must be left completely alone.
            'reader_font_size', '18',
          ],
        );

        // Seed as the CURRENT schema version so onUpgrade does NOT run; the
        // drainer is invoked explicitly below and gates itself on the table /
        // column probes, exercising exactly the pre-v16 orphan path. Use the
        // live schemaVersion (not a hard-coded 16) so a schema bump can't let
        // onUpgrade(16 -> current) fire and pre-drain/reshape the seed.
        raw.execute('PRAGMA user_version = ${_orphanDb.schemaVersion}');
      },
    ),
  );
  return _orphanDb;
}

void main() {
  test('orphan legacy bookmark prefs are skipped, not aborting the upgrade',
      () async {
    final HibikiDatabase db = _openPreV16WithLegacyBookmarkPrefs();
    addTearDown(db.close);

    // Must NOT throw on the orphan FK target (the regression this guards).
    await db.migrateLegacyBookmarkPreferences();

    // ── real bookmark imported, orphan rows skipped ──────────────────────
    final QueryRow total = await db
        .customSelect('SELECT COUNT(*) AS c FROM bookmarks')
        .getSingle();
    expect(total.read<int>('c'), 1,
        reason: 'only the real (ttuBookId=1) bookmark imports; both '
            'ttuBookId=999 orphans are skipped');

    final QueryRow real = await db
        .customSelect(
          "SELECT label, ttu_book_id FROM bookmarks WHERE ttu_book_id = 1",
        )
        .getSingle();
    expect(real.read<String>('label'), 'real-bm');

    final QueryRow orphanCount = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM bookmarks WHERE ttu_book_id = 999',
        )
        .getSingle();
    expect(orphanCount.read<int>('c'), 0,
        reason: 'orphan ttu_book_id never inserted');

    // ── every legacy bookmarks_<int> key drained, unrelated pref kept ────
    expect(await db.getPref('bookmarks_1'), isNull,
        reason: 'drained legacy key removed');
    expect(await db.getPref('bookmarks_999'), isNull,
        reason: 'pure-orphan legacy key still removed (not left dangling)');
    expect(await db.getPref('reader_font_size'), '18',
        reason: 'unrelated prefs untouched');

    // ── FK integrity intact: the skip kept the relation graph consistent ──
    final List<QueryRow> violations =
        await db.customSelect('PRAGMA foreign_key_check').get();
    expect(violations, isEmpty,
        reason: 'no dangling bookmark FK after the orphan skip');
  });
}
