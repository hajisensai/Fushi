import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Regression test for HBK-AUDIT-001: the v12 orphan cleanup must NOT wipe
/// audio_cues owned by srt_books (standalone SRT subtitle books have no row in
/// the audiobooks table). It must still delete cues orphaned from BOTH owners.
Future<HibikiDatabase> _openV11DbWithSrtCues() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA foreign_keys = ON');
        // ── v1 baseline tables touched by the from<12 cleanup ──
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
        rawDb.execute('''
CREATE TABLE audiobooks (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_uid TEXT NOT NULL UNIQUE,
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
  ttu_book_id INTEGER NOT NULL DEFAULT 0
)
''');
        rawDb.execute('''
CREATE TABLE audio_cues (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_uid TEXT NOT NULL,
  chapter_href TEXT NOT NULL,
  sentence_index INTEGER NOT NULL,
  text_fragment_id TEXT NOT NULL,
  cue_text TEXT NOT NULL,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  audio_file_index INTEGER NOT NULL
)
''');

        // ── seed data ──
        // Standalone SRT book (no audiobooks row) with 3 cues.
        rawDb.execute(
          'INSERT INTO srt_books (uid, title, srt_path, imported_at, ttu_book_id) '
          "VALUES ('srtbook_keep', 'SRT Book', '/x.srt', 0, 0)",
        );
        // An audiobook-owned book with 2 cues.
        rawDb.execute(
          'INSERT INTO audiobooks (book_uid, alignment_format, alignment_path) '
          "VALUES ('audiobook_keep', 'srt', '/a.srt')",
        );
        for (int i = 0; i < 3; i++) {
          rawDb.execute(
            'INSERT INTO audio_cues (book_uid, chapter_href, sentence_index, '
            'text_fragment_id, cue_text, start_ms, end_ms, audio_file_index) '
            "VALUES ('srtbook_keep', 'c.xhtml', $i, 'f$i', 't$i', 0, 1, 0)",
          );
        }
        for (int i = 0; i < 2; i++) {
          rawDb.execute(
            'INSERT INTO audio_cues (book_uid, chapter_href, sentence_index, '
            'text_fragment_id, cue_text, start_ms, end_ms, audio_file_index) '
            "VALUES ('audiobook_keep', 'c.xhtml', $i, 'f$i', 't$i', 0, 1, 0)",
          );
        }
        // A truly-orphaned cue: book_uid in neither audiobooks nor srt_books.
        rawDb.execute(
          'INSERT INTO audio_cues (book_uid, chapter_href, sentence_index, '
          'text_fragment_id, cue_text, start_ms, end_ms, audio_file_index) '
          "VALUES ('ghost', 'c.xhtml', 0, 'f', 't', 0, 1, 0)",
        );

        rawDb.execute('PRAGMA user_version = 11');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

Future<int> _cueCount(HibikiDatabase db, String bookUid) async {
  // bookUid is a test-controlled literal; safe to interpolate.
  final row = await db
      .customSelect('SELECT COUNT(*) AS c FROM audio_cues '
          "WHERE book_uid = '$bookUid'")
      .getSingle();
  return row.read<int>('c');
}

void main() {
  test(
      'v11->v14 migration preserves SRT-owned and audiobook-owned cues, '
      'deletes only doubly-orphaned cues', () async {
    final db = await _openV11DbWithSrtCues();

    // Force the migration to run.
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 14);

    // SRT book cues must survive (the bug deleted all of these).
    expect(await _cueCount(db, 'srtbook_keep'), 3);
    // Audiobook cues must survive.
    expect(await _cueCount(db, 'audiobook_keep'), 2);
    // Cue orphaned from BOTH owners must be deleted.
    expect(await _cueCount(db, 'ghost'), 0);
  });
}
