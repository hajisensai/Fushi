import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' show Database;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-809 self-healing backfill migration (v25 -> v26) guard.
///
/// Heals audiobook rows whose `book_key` mismatches `epub_books.book_key`
/// (caused, pre-BUG-414, by sync/import recomputing the key via
/// `sanitizeTtuFilename(title)` instead of writing the host's real key). It maps
/// each mismatched audiobook through its companion SRT row's title to a UNIQUE
/// `epub_books.title` match, then rewrites the key consistently across all three
/// tables (audiobooks / srt_books / audio_cues) so the bookshelf headphone badge
/// (`audiobooks.book_key == epub_books.book_key`) matches again.
///
/// Logic: `database.dart` `if (from < 26)` -> `backfillMismatchedAudiobookKeysV26`.
/// Safety: only rewrite on a UNIQUE safe match (COUNT(epub_books.title) == 1 and
/// target key not already taken). Orphan (0 match) / ambiguous (>1 match) /
/// already-taken rows stay untouched. Single transaction, idempotent.
///
/// Version asserts always use `db.schemaVersion` (never a hard-coded 26).
Future<HibikiDatabase> _openV25(void Function(Database db) seed) async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute(_kEpubBooksSql);
        rawDb.execute(_kAudiobooksSql);
        rawDb.execute(_kSrtBooksSql);
        rawDb.execute(_kAudioCuesSql);
        seed(rawDb);
        rawDb.execute('PRAGMA user_version = 25');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

const String _kEpubBooksSql = '''
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
''';

const String _kAudiobooksSql = '''
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
''';

const String _kSrtBooksSql = '''
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
''';

const String _kAudioCuesSql = '''
CREATE TABLE audio_cues (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  book_key TEXT NOT NULL,
  chapter_href TEXT NOT NULL,
  sentence_index INTEGER NOT NULL,
  text_fragment_id TEXT NOT NULL,
  cue_text TEXT NOT NULL,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  audio_file_index INTEGER NOT NULL
)
''';

void _insertEpub(Database db, String bookKey, String title) {
  db.execute(
    'INSERT INTO epub_books (book_key, title, epub_path, extract_dir, '
    'chapter_count, chapters_json, imported_at) '
    "VALUES (?, ?, '/x.epub', '/x', 1, '[]', 0)",
    <Object?>[bookKey, title],
  );
}

void _insertAudiobook(Database db, String bookKey) {
  db.execute(
    'INSERT INTO audiobooks (book_key, alignment_format, alignment_path) '
    "VALUES (?, 'srt', '/a.srt')",
    <Object?>[bookKey],
  );
}

void _insertSrt(Database db, String uid, String title, String bookKey) {
  db.execute(
    'INSERT INTO srt_books (uid, title, srt_path, imported_at, book_key) '
    'VALUES (?, ?, ?, 0, ?)',
    <Object?>[uid, title, '/$uid.srt', bookKey],
  );
}

void _insertCue(Database db, String bookKey, int i) {
  db.execute(
    'INSERT INTO audio_cues (book_key, chapter_href, sentence_index, '
    'text_fragment_id, cue_text, start_ms, end_ms, audio_file_index) '
    "VALUES (?, 'c.xhtml', ?, ?, ?, 0, 1, 0)",
    <Object?>[bookKey, i, 'f$i', 't$i'],
  );
}

Future<List<String>> _bookKeys(HibikiDatabase db, String table) async {
  final rows =
      await db.customSelect('SELECT book_key FROM $table ORDER BY id').get();
  return rows.map((r) => r.read<String>('book_key')).toList();
}

void main() {
  group('TODO-809 audiobook book_key backfill (v25 -> v26)', () {
    test(
        'bad DB heals: mismatched key rewritten via unique SRT-title match, '
        'all three tables consistent, badge query matches', () async {
      final db = await _openV25((raw) {
        _insertEpub(raw, 'real-epub-key', 'Kokoro');
        _insertAudiobook(raw, 'sanitized-kokoro');
        _insertSrt(raw, 'srt-1', 'Kokoro', 'sanitized-kokoro');
        _insertCue(raw, 'sanitized-kokoro', 0);
        _insertCue(raw, 'sanitized-kokoro', 1);
      });

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      expect(await _bookKeys(db, 'audiobooks'), <String>['real-epub-key']);
      expect(await _bookKeys(db, 'srt_books'), <String>['real-epub-key']);
      expect(await _bookKeys(db, 'audio_cues'),
          <String>['real-epub-key', 'real-epub-key']);

      final match = await db
          .customSelect('SELECT COUNT(*) AS c FROM audiobooks a '
              'WHERE a.book_key IN (SELECT book_key FROM epub_books)')
          .getSingle();
      expect(match.read<int>('c'), 1,
          reason: 'after backfill the row matches epub_books, badge shows');
    });

    test('healthy DB is a no-op: already-matching key untouched', () async {
      final db = await _openV25((raw) {
        _insertEpub(raw, 'real-epub-key', 'Kokoro');
        _insertAudiobook(raw, 'real-epub-key');
        _insertSrt(raw, 'srt-1', 'Kokoro', 'real-epub-key');
        _insertCue(raw, 'real-epub-key', 0);
      });

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      expect(await _bookKeys(db, 'audiobooks'), <String>['real-epub-key']);
      expect(await _bookKeys(db, 'srt_books'), <String>['real-epub-key']);
      expect(await _bookKeys(db, 'audio_cues'), <String>['real-epub-key']);
    });

    test('ambiguous (>1 match) and orphan (0 match) rows are left untouched',
        () async {
      final db = await _openV25((raw) {
        _insertEpub(raw, 'dup-key-a', 'DupTitle');
        _insertEpub(raw, 'dup-key-b', 'DupTitle');
        _insertAudiobook(raw, 'sanitized-dup');
        _insertSrt(raw, 'srt-dup', 'DupTitle', 'sanitized-dup');
        _insertCue(raw, 'sanitized-dup', 0);

        _insertAudiobook(raw, 'sanitized-orphan');
        _insertSrt(raw, 'srt-orphan', 'NoSuchTitle', 'sanitized-orphan');
        _insertCue(raw, 'sanitized-orphan', 0);
      });

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      final abKeys = await _bookKeys(db, 'audiobooks');
      expect(
          abKeys, containsAll(<String>['sanitized-dup', 'sanitized-orphan']));
      expect(abKeys, hasLength(2));
      final cueKeys = await _bookKeys(db, 'audio_cues');
      expect(
          cueKeys, containsAll(<String>['sanitized-dup', 'sanitized-orphan']));
    });

    test('idempotent: re-running the backfill after heal changes nothing',
        () async {
      final db = await _openV25((raw) {
        _insertEpub(raw, 'real-epub-key', 'Kokoro');
        _insertAudiobook(raw, 'sanitized-kokoro');
        _insertSrt(raw, 'srt-1', 'Kokoro', 'sanitized-kokoro');
        _insertCue(raw, 'sanitized-kokoro', 0);
      });
      // Migration already ran on open. Run again: candidate set is now empty
      // (all matched), so it must be a no-op.
      await db.backfillMismatchedAudiobookKeysV26();

      expect(await _bookKeys(db, 'audiobooks'), <String>['real-epub-key']);
      expect(await _bookKeys(db, 'srt_books'), <String>['real-epub-key']);
      expect(await _bookKeys(db, 'audio_cues'), <String>['real-epub-key']);
    });

    test(
        'target key already owned by another audiobook is skipped '
        '(no UNIQUE clash, mismatched row left as-is)', () async {
      final db = await _openV25((raw) {
        _insertEpub(raw, 'real-epub-key', 'Kokoro');
        _insertAudiobook(raw, 'real-epub-key');
        _insertSrt(raw, 'srt-good', 'Kokoro', 'real-epub-key');
        _insertAudiobook(raw, 'sanitized-kokoro');
        _insertSrt(raw, 'srt-bad', 'Kokoro', 'sanitized-kokoro');
      });

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);

      final abKeys = await _bookKeys(db, 'audiobooks');
      expect(
          abKeys, containsAll(<String>['real-epub-key', 'sanitized-kokoro']));
      expect(abKeys, hasLength(2));
    });

    test('partial DB without srt_books/epub_books does not throw', () async {
      final db = HibikiDatabase.forTesting(
        NativeDatabase.memory(
          setup: (rawDb) {
            rawDb.execute(_kAudiobooksSql);
            rawDb.execute('PRAGMA user_version = 25');
          },
        ),
      );
      addTearDown(db.close);

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion,
          reason: 'missing-table guard skips, migration completes');
    });
  });
}
