import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Losslessness proof for the v15 -> v16 book-key migration
/// (HibikiDatabase._migrateBookKeyV16). Seeds a raw v15 schema with the
/// autoincrement int id and every relation table, then opens it through
/// `forTesting` to trigger onUpgrade, and asserts every reading-data row is
/// still reachable by its new bookKey = sanitizeTtuFilename(title).
///
/// Seed follows the migration_downgrade_test seed-raw-DB pattern: hand-written
/// CREATE/INSERT of the v15 column shapes (NOT the current drift schema) so the
/// migration is exercised against real legacy data.
HibikiDatabase _openMigratedFromV15() {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        // Mirror the production _openDb setup: FK enforcement ON. Without this
        // the memory DB runs FK-OFF by default, so any FK assertion below
        // (cascade-on-delete, foreign_key_check) would be vacuous. The seed
        // INSERTs respect FK order (parents before children).
        raw.execute('PRAGMA foreign_keys = ON');
        // ── epub_books (v15: int id PK) ──────────────────────────────
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
        // id=1 'Book A', id=2 'Book A' → sanitize collision → dedup to
        // 'Book A' and 'Book A (2)'. id=3 'Solo*Book' exercises a sanitized
        // char (* → ~ttu-star~).
        raw.execute(
          "INSERT INTO epub_books "
          "(id, title, epub_path, extract_dir, chapter_count, chapters_json, imported_at) "
          "VALUES "
          "(1, 'Book A', '/a.epub', '/books/1', 3, '[]', 100),"
          "(2, 'Book A', '/a2.epub', '/books/2', 2, '[]', 200),"
          "(3, 'Solo*Book', '/s.epub', '/books/3', 1, '[]', 300)",
        );

        // ── reader_positions (v15: ttu_book_id int unique) ────────────
        raw.execute('''
CREATE TABLE reader_positions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  ttu_book_id INTEGER NOT NULL UNIQUE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  ttu_char_offset INTEGER NOT NULL DEFAULT -1,
  updated_at INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO reader_positions "
          "(ttu_book_id, section_index, norm_char_offset, ttu_char_offset, updated_at) "
          "VALUES (1, 2, 5000, -1, 111), (2, 1, 2500, 7, 222)",
        );

        // ── bookmarks (v15: ttu_book_id int FK) ───────────────────────
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
        raw.execute(
          "INSERT INTO bookmarks "
          "(ttu_book_id, section_index, norm_char_offset, label, created_at) "
          "VALUES (1, 0, 100, 'bm1', 10), (1, 1, 200, 'bm2', 20), "
          "(2, 0, 300, 'bm3', 30)",
        );

        // ── book_tags + book_tag_mappings (v15: book_id int FK) ───────
        raw.execute('''
CREATE TABLE book_tags (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  color_value INTEGER NOT NULL DEFAULT 10395294,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO book_tags (id, name, created_at) "
          "VALUES (1, 'fav', 1), (2, 'todo', 2)",
        );
        raw.execute('''
CREATE TABLE book_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_id INTEGER NOT NULL REFERENCES epub_books (id) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE,
  UNIQUE (book_id, tag_id)
)''');
        raw.execute(
          "INSERT INTO book_tag_mappings (book_id, tag_id) "
          "VALUES (1, 1), (1, 2), (2, 1)",
        );

        // ── srt_books (v15: ttu_book_id int default 0; 0 = standalone) ─
        raw.execute('''
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
)''');
        // One linked to book 1, one standalone (ttu_book_id=0).
        raw.execute(
          "INSERT INTO srt_books "
          "(uid, title, srt_path, imported_at, ttu_book_id) "
          "VALUES ('srt-linked', 'Linked Srt', '/l.srt', 1, 1), "
          "('srt-standalone', 'Standalone Srt', '/s.srt', 2, 0)",
        );

        // ── audiobooks (v15: book_uid = legacy uid string) ────────────
        raw.execute('''
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
)''');
        raw.execute(
          "INSERT INTO audiobooks "
          "(book_uid, alignment_format, alignment_path) "
          "VALUES ('reader_ttu/hoshi://book/1', 'srt', '/al1.srt'), "
          "('reader_ttu/hoshi://book/2', 'srt', '/al2.srt')",
        );

        // ── audio_cues (v15: book_uid owns audiobook uid OR srt uid) ──
        raw.execute('''
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
)''');
        // 2 cues owned by audiobook 1, 1 cue owned by the standalone srt uid.
        raw.execute(
          "INSERT INTO audio_cues "
          "(book_uid, chapter_href, sentence_index, text_fragment_id, cue_text, start_ms, end_ms, audio_file_index) "
          "VALUES "
          "('reader_ttu/hoshi://book/1', 'c1.xhtml', 0, 'f0', 'hello', 0, 1000, 0),"
          "('reader_ttu/hoshi://book/1', 'c1.xhtml', 1, 'f1', 'world', 1000, 2000, 0),"
          "('srt-standalone', 's.xhtml', 0, 'sf0', 'subs', 0, 500, 0)",
        );

        // ── profiles + book_profiles (v15: book_uid PK = legacy uid) ──
        raw.execute('''
CREATE TABLE profiles (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO profiles (id, name, created_at, updated_at) "
          "VALUES (1, 'Default', 1, 1)",
        );
        raw.execute('''
CREATE TABLE book_profiles (
  book_uid TEXT NOT NULL PRIMARY KEY,
  profile_id INTEGER NOT NULL REFERENCES profiles (id) ON DELETE CASCADE
)''');
        raw.execute(
          "INSERT INTO book_profiles (book_uid, profile_id) "
          "VALUES ('reader_ttu/hoshi://book/2', 1)",
        );

        // ── media_items (identifier hoshi://book/<id>) ────────────────
        raw.execute('''
CREATE TABLE media_items (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  media_identifier TEXT NOT NULL,
  title TEXT NOT NULL,
  media_type_identifier TEXT NOT NULL,
  media_source_identifier TEXT NOT NULL,
  unique_key TEXT NOT NULL UNIQUE,
  base64_image TEXT,
  image_url TEXT,
  audio_url TEXT,
  author TEXT,
  author_identifier TEXT,
  extra_url TEXT,
  extra TEXT,
  source_metadata TEXT,
  position INTEGER NOT NULL,
  duration INTEGER NOT NULL,
  can_delete INTEGER NOT NULL,
  can_edit INTEGER NOT NULL,
  imported_at INTEGER NOT NULL DEFAULT 0
)''');
        raw.execute(
          "INSERT INTO media_items "
          "(media_identifier, title, media_type_identifier, media_source_identifier, unique_key, position, duration, can_delete, can_edit) "
          "VALUES "
          "('hoshi://book/1', 'Book A', 'reader', 'reader_hibiki', 'hoshi://book/1', 0, 0, 1, 1),"
          "('hoshi://book/2', 'Book A', 'reader', 'reader_hibiki', 'hoshi://book/2', 0, 0, 1, 1)",
        );

        // ── preferences (two audiobook_pos key spaces + others) ───────
        raw.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''');
        // book 1: int-style says 1000, uid-style (live player) says 2000 →
        // uid must win after merge.
        raw.execute(
          "INSERT INTO preferences (key, value) VALUES "
          "('audiobook_pos_1', '1000'), "
          "('audiobook_pos_reader_ttu/hoshi://book/1', '2000'), "
          // book 2: only int-style present → carries over.
          "('audiobook_pos_2', '3000'), "
          // uid-suffix prefixes for book 1.
          "('audiobook_follow_reader_ttu/hoshi://book/1', 'true'), "
          "('audiobook_speed_reader_ttu/hoshi://book/1', '1.5')",
        );

        // ── reading_statistics (bare title; collision merges on sanitize) ─
        raw.execute('''
CREATE TABLE reading_statistics (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  date_key TEXT NOT NULL,
  characters_read INTEGER NOT NULL,
  reading_time_ms INTEGER NOT NULL,
  last_statistic_modified INTEGER NOT NULL,
  UNIQUE (title, date_key)
)''');
        // 'Solo*Book' → sanitized key 'Solo~ttu-star~Book' (sanitize-char
        // coverage). The next two rows have DIFFERENT bare titles that
        // sanitize to the SAME key on the SAME date_key, so the migration
        // merges them additively:
        //   'Book A.'            → 'Book A~ttu-dend~' (trailing-dot sentinel)
        //   'Book A~ttu-dend~'   → 'Book A~ttu-dend~' (already-sentinel literal)
        // (% transcoding is reversible and never collides, so the trailing
        // dot/space sentinels are the realistic merge trigger.) The seed
        // UNIQUE(title, date_key) is on the BARE title, so these two coexist
        // pre-migration; only the sanitized key collides. A third row with the
        // same sanitized key but a DIFFERENT date_key stays a separate row —
        // merge is strictly per (sanitized title, date_key).
        raw.execute(
          "INSERT INTO reading_statistics "
          "(title, date_key, characters_read, reading_time_ms, last_statistic_modified) "
          "VALUES "
          "('Solo*Book', '2026-01-01', 500, 60000, 5),"
          "('Book A.', '2026-01-02', 100, 10000, 11),"
          "('Book A~ttu-dend~', '2026-01-02', 200, 20000, 9),"
          "('Book A.', '2026-01-03', 50, 5000, 7)",
        );

        // Other v1-baseline tables not present in this seed are rebuilt by
        // createAll on first open — but they are NOT created here because the
        // upgrade path (from=15) does NOT call createAll. The migration only
        // touches the tables seeded above, which is exactly the scope under
        // test. (Tables like sync_baselines were added at v15 and already
        // exist conceptually; the migration never reads them.)
        raw.execute('PRAGMA user_version = 15');
      },
    ),
  );
}

void main() {
  test('v15->v16 re-keys all reading data to bookKey losslessly', () async {
    final HibikiDatabase db = _openMigratedFromV15();
    addTearDown(db.close);

    // Opening forces the lazy DB to run onUpgrade(15 -> current). The v16
    // re-key step runs as part of that ladder; later steps only add tables and
    // never undo the re-keying, so the losslessness assertions below still hold
    // at the current schema. Compare against the live schemaVersion so this
    // never goes stale on a bump.
    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion,
        reason: 'migration must land on the current schema version');

    // ── books: dedup of collided sanitize keys ────────────────────────
    final books = await db.getAllEpubBooks();
    final Set<String> keys = books.map((b) => b.bookKey).toSet();
    expect(keys,
        containsAll(<String>['Book A', 'Book A (2)', 'Solo~ttu-star~Book']),
        reason: 'collision dedup + sanitized char');
    expect(books.length, 3);
    // The first imported (id=1, oldest importedAt=100) keeps the bare key.
    final EpubBookRow bookA = books.firstWhere((b) => b.bookKey == 'Book A');
    expect(bookA.extractDir, '/books/1');
    final EpubBookRow bookA2 =
        books.firstWhere((b) => b.bookKey == 'Book A (2)');
    expect(bookA2.extractDir, '/books/2');

    // ── reader positions by bookKey ───────────────────────────────────
    final p1 = await db.getReaderPosition('Book A');
    expect(p1, isNotNull);
    expect(p1!.normCharOffset, 5000);
    final p2 = await db.getReaderPosition('Book A (2)');
    expect(p2, isNotNull);
    expect(p2!.ttuCharOffset, 7);

    // ── bookmarks by bookKey ──────────────────────────────────────────
    final bmA = await db
        .customSelect(
          "SELECT COUNT(*) AS c FROM bookmarks WHERE book_key = 'Book A'",
        )
        .getSingle();
    expect(bmA.read<int>('c'), 2);
    final bmA2 = await db
        .customSelect(
          "SELECT COUNT(*) AS c FROM bookmarks WHERE book_key = 'Book A (2)'",
        )
        .getSingle();
    expect(bmA2.read<int>('c'), 1);

    // ── tags by bookKey ───────────────────────────────────────────────
    final tagsA = await db.getTagsForBook('Book A');
    expect(tagsA.map((t) => t.name).toSet(), <String>{'fav', 'todo'});
    final tagsA2 = await db.getTagsForBook('Book A (2)');
    expect(tagsA2.map((t) => t.name).toSet(), <String>{'fav'});

    // ── audiobooks by bookKey ─────────────────────────────────────────
    expect(await db.getAudiobookByBookKey('Book A'), isNotNull);
    expect(await db.getAudiobookByBookKey('Book A (2)'), isNotNull);

    // ── audio cues: audiobook-owned re-keyed, srt-owned untouched ─────
    final cuesA = await db.getCuesForBook('Book A');
    expect(cuesA.length, 2, reason: 'audiobook cues re-keyed to bookKey');
    final cuesSrt = await db.getCuesForBook('srt-standalone');
    expect(cuesSrt.length, 1, reason: 'srt-owned cues keep their srt uid');

    // ── srt books: linked got bookKey, standalone kept '' ─────────────
    final linked = await db.getSrtBookByBookKey('Book A');
    expect(linked, isNotNull);
    expect(linked!.uid, 'srt-linked');
    final standalone = await db.getSrtBookByBookKey('');
    expect(standalone, isNotNull);
    expect(standalone!.uid, 'srt-standalone');

    // ── book profiles by bookKey ──────────────────────────────────────
    expect(await db.getBookProfile('Book A (2)'), isNotNull);

    // ── prefs: two audiobook_pos spaces merged, uid wins ──────────────
    expect(await db.getPrefTyped<int>('audiobook_pos_Book A', 0), 2000,
        reason: 'uid-style live write wins over int-style on merge');
    expect(await db.getPrefTyped<int>('audiobook_pos_Book A (2)', 0), 3000);
    expect(await db.getPref('audiobook_pos_1'), isNull,
        reason: 'old int-style key removed');
    expect(await db.getPref('audiobook_pos_reader_ttu/hoshi://book/1'), isNull,
        reason: 'old uid-style key removed');
    expect(await db.getPrefTyped<bool>('audiobook_follow_Book A', false), true);
    expect(await db.getPref('audiobook_speed_Book A'), '1.5');

    // ── media_items identifier rewritten ──────────────────────────────
    final mi = await db
        .customSelect(
          "SELECT media_identifier, unique_key FROM media_items "
          "ORDER BY id",
        )
        .get();
    expect(mi.map((r) => r.read<String>('media_identifier')).toSet(),
        <String>{'hoshi://book/Book A', 'hoshi://book/Book A (2)'});
    expect(mi.first.read<String>('unique_key'), 'hoshi://book/Book A');

    // ── reading_statistics title aligned to sanitized key + merged ────
    // 'Solo*Book' → 'Solo~ttu-star~Book' (untouched). The two 2026-01-02 rows
    // whose bare titles sanitize to the SAME key merge additively
    // (100+200=300); the 2026-01-03 row stays separate (merge is strictly per
    // (sanitized title, date_key)).
    final stats = await db.getAllReadingStatistics();
    expect(stats.length, 3);
    final solo = stats.firstWhere((s) => s.title == 'Solo~ttu-star~Book');
    expect(solo.charactersRead, 500);
    final merged0102 = stats.firstWhere(
        (s) => s.title == 'Book A~ttu-dend~' && s.dateKey == '2026-01-02');
    expect(merged0102.charactersRead, 300);
    expect(merged0102.readingTimeMs, 30000);
    expect(merged0102.lastStatisticModified, 11);
    final separate0103 = stats.firstWhere(
        (s) => s.title == 'Book A~ttu-dend~' && s.dateKey == '2026-01-03');
    expect(separate0103.charactersRead, 50);

    // ── FK cascade: deleting a book clears its reading data ───────────
    await db.deleteEpubBook('Book A');
    expect(await db.getReaderPosition('Book A'), isNull);
    expect(await db.getAudiobookByBookKey('Book A'), isNull);
    expect(await db.getCuesForBook('Book A'), isEmpty);
    final bmAfter = await db
        .customSelect(
          "SELECT COUNT(*) AS c FROM bookmarks WHERE book_key = 'Book A'",
        )
        .getSingle();
    expect(bmAfter.read<int>('c'), 0);
    expect((await db.getTagsForBook('Book A')), isEmpty);
    // The other book is untouched.
    expect(await db.getReaderPosition('Book A (2)'), isNotNull);
  });
}
