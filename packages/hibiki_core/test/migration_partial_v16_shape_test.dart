import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Safety-net for the per-table column guards in the v15->v16 book-key
/// migration (HibikiDatabase._runBookKeyMigrationBodyV16), the boundary fixed
/// by 7adf38353 ("v16 migration robust to v16-shaped/partial pre-v16 schemas").
///
/// The existing migration_book_key_test seeds a FULLY legacy v15 DB (every
/// relation table still int/uid shaped) and proves a clean re-key. This test
/// covers the OTHER half 7adf38353 added: a PARTIAL pre-v16 DB where some
/// relation tables already arrived in the current v16 `book_key` shape (they
/// were created fresh earlier in the onUpgrade ladder via m.createTable, which
/// uses the current generated schema), while others still carry their legacy
/// int/uid columns.
///
/// For each such already-v16 table the migration MUST be a no-op (rebuilding it
/// would JOIN `_id_key_map` on a non-existent legacy column and throw "no such
/// column", rolling back the whole upgrade). The legacy-shaped tables must
/// still re-key correctly through `_id_key_map`, and the final
/// `PRAGMA foreign_key_check` integrity gate must pass.
///
/// Seed mix (user_version = 15 -> drives the real from<16 onUpgrade step):
///   epub_books          : LEGACY int id PK            -> re-keyed (drives map)
///   reader_positions    : ALREADY v16 `book_key` (FK-free) -> no-op, data kept
///   book_tag_mappings   : ALREADY v16 `book_key` (FK), empty -> no-op, usable
///   bookmarks           : LEGACY `ttu_book_id`        -> re-keyed
///   audiobooks          : LEGACY `book_uid`           -> re-keyed
///
/// Note on the empty already-v16 `book_tag_mappings`: its `book_key` FK targets
/// epub_books(book_key), which doesn't exist yet while epub_books is still
/// int-id shaped, so under `foreign_keys = ON` it cannot legitimately hold rows
/// pre-migration — the realistic state is a freshly-created EMPTY table (built
/// earlier in the ladder via m.createTable). reader_positions has no FK, so it
/// can carry a real row to prove the no-op preserves data.
HibikiDatabase _openPartialV16Shaped() {
  // The re-keyed book lands on this key. 'Mixed Book' has no sanitized chars,
  // so sanitizeTtuFilename(title) == the title itself.
  const String kBookKey = 'Mixed Book';
  const String kLegacyUid = 'reader_ttu/hoshi://book/1';

  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('PRAGMA foreign_keys = ON');

        // ── epub_books: LEGACY int id PK (drives the re-key map) ──────────
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
          "VALUES (1, '$kBookKey', '/m.epub', '/books/1', 2, '[]', 100)",
        );

        // ── reader_positions: ALREADY v16 (`book_key`, no ttu_book_id) ────
        // The from<16 step must SKIP it (column guard) and leave the row as-is.
        raw.execute('''
CREATE TABLE reader_positions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL UNIQUE,
  section_index INTEGER NOT NULL,
  norm_char_offset INTEGER NOT NULL,
  ttu_char_offset INTEGER NOT NULL DEFAULT -1,
  updated_at INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO reader_positions "
          "(book_key, section_index, norm_char_offset, ttu_char_offset, updated_at) "
          "VALUES ('$kBookKey', 3, 4242, 9, 111)",
        );

        // ── bookmarks: LEGACY `ttu_book_id` FK -> must re-key to book_key ─
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
          "VALUES (1, 0, 100, 'bm1', 10)",
        );

        // ── book_tags + book_tag_mappings: mappings ALREADY v16 ──────────
        raw.execute('''
CREATE TABLE book_tags (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  color_value INTEGER NOT NULL DEFAULT 10395294,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO book_tags (id, name, created_at) VALUES (1, 'fav', 1)",
        );
        // ALREADY v16 (`book_key`, no book_id), EMPTY. The from<16 step must
        // SKIP it (column guard) — rebuilding would JOIN on the absent legacy
        // `book_id`. Empty because its FK parent epub_books(book_key) doesn't
        // exist until the re-key runs (see header note).
        raw.execute('''
CREATE TABLE book_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL REFERENCES epub_books (book_key) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE,
  UNIQUE (book_key, tag_id)
)''');

        // ── audiobooks: LEGACY `book_uid` -> must re-key to book_key ─────
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
          "INSERT INTO audiobooks (book_uid, alignment_format, alignment_path) "
          "VALUES ('$kLegacyUid', 'srt', '/a1.srt')",
        );

        // ── audio_cues: LEGACY `book_uid` owned by the audiobook above ───
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
        raw.execute(
          "INSERT INTO audio_cues "
          "(book_uid, chapter_href, sentence_index, text_fragment_id, cue_text, start_ms, end_ms, audio_file_index) "
          "VALUES ('$kLegacyUid', 'c1.xhtml', 0, 'f0', 'hello', 0, 1000, 0)",
        );

        // ── srt_books: ALREADY v16 (`book_key`), empty ──────────────────
        // Present (empty) so deleteEpubBook's srt cascade has a table to scan;
        // its column guard makes the v16 step a no-op on it.
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
  book_key TEXT NOT NULL DEFAULT ''
)''');

        // ── profiles + book_profiles: LEGACY `book_uid` PK -> re-key ─────
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
          "VALUES ('$kLegacyUid', 1)",
        );

        // preferences present so the prefs re-key step has a table to scan.
        raw.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)''');

        raw.execute('PRAGMA user_version = 15');
      },
    ),
  );
}

void main() {
  test('partial pre-v16 schema: already-v16 tables no-op, legacy tables re-key',
      () async {
    final HibikiDatabase db = _openPartialV16Shaped();
    addTearDown(db.close);

    // Opening forces onUpgrade(15 -> current); the partial-shape guards (run in
    // the from<16 step) must not throw "no such column" on the already-v16
    // tables. Compare against the live schemaVersion so this never goes stale.
    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion,
        reason: 'mixed-shape DB lands on the current schema');

    const String kBookKey = 'Mixed Book';

    // ── epub_books re-keyed (drives the map) ─────────────────────────────
    final books = await db.getAllEpubBooks();
    expect(books.length, 1);
    expect(books.single.bookKey, kBookKey,
        reason: 'legacy int id epub_books re-keyed to sanitized title');

    // ── reader_positions: ALREADY v16 -> untouched, original data kept ───
    final pos = await db.getReaderPosition(kBookKey);
    expect(pos, isNotNull);
    expect(pos!.normCharOffset, 4242,
        reason: 'already-v16 reader_positions skipped (no JOIN), data intact');
    expect(pos.ttuCharOffset, 9);

    // ── book_tag_mappings: ALREADY v16 (empty) -> skipped, still usable ──
    // It was skipped (no JOIN on the absent legacy book_id), and survives as a
    // working v16 table: inserting a mapping against the now-migrated bookKey
    // succeeds and reads back.
    expect(await db.getTagsForBook(kBookKey), isEmpty,
        reason: 'empty already-v16 book_tag_mappings skipped, stays empty');
    await db.setTagsForBook(kBookKey, <int>{1});
    final tags = await db.getTagsForBook(kBookKey);
    expect(tags.map((t) => t.name).toSet(), <String>{'fav'},
        reason:
            'skipped v16 book_tag_mappings is a usable table post-migration');

    // ── bookmarks: LEGACY ttu_book_id -> re-keyed to book_key ────────────
    final QueryRow bm = await db.customSelect(
      "SELECT label FROM bookmarks WHERE book_key = ?",
      variables: [Variable<String>(kBookKey)],
    ).getSingle();
    expect(bm.read<String>('label'), 'bm1',
        reason: 'legacy ttu_book_id bookmark re-keyed to book_key');

    // ── audiobooks + cues: LEGACY book_uid -> re-keyed to book_key ───────
    expect(await db.getAudiobookByBookKey(kBookKey), isNotNull,
        reason: 'legacy book_uid audiobook re-keyed');
    final cues = await db.getCuesForBook(kBookKey);
    expect(cues.length, 1, reason: 'legacy book_uid cues re-keyed to book_key');

    // ── book_profiles: LEGACY book_uid PK -> re-keyed ───────────────────
    expect(await db.getBookProfile(kBookKey), isNotNull,
        reason: 'legacy book_uid book_profiles re-keyed');

    // ── final integrity gate held: no dangling FK across mixed shapes ────
    final List<QueryRow> violations =
        await db.customSelect('PRAGMA foreign_key_check').get();
    expect(violations, isEmpty,
        reason: 'mixed-shape re-key left a consistent FK graph');

    // ── cascade still wired after the mixed re-key ──────────────────────
    await db.deleteEpubBook(kBookKey);
    expect(await db.getReaderPosition(kBookKey), isNull);
    expect(await db.getTagsForBook(kBookKey), isEmpty,
        reason: 'cascade reaches the preserved already-v16 mapping too');
    expect(await db.getAudiobookByBookKey(kBookKey), isNull);
  });
}
