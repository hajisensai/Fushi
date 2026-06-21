import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// End-to-end guard for the video merge's schema convergence to **v20**.
///
/// The video worktree forked BEFORE develop's name-PK v16 and burned its own
/// v16-v19 numbers on `video_books`, so two lineages exist with conflicting
/// version numbers:
///
///   * develop line: v16 = name-PK (epub_books keyed by `book_key`), no
///     video_books.
///   * video line:   v16-v19 = epub_books still id-keyed + a legacy
///     autoincrement-`id` video_books.
///
/// A real user DB sits on the video line at user_version 16-19, so the from<16
/// (name-PK) and from<17 (create video_books) ladder steps never fire for it
/// (version already past them). The `from<20` convergence step must fold BOTH
/// lineages onto the unified shape — epub_books name-PK + video_books book_uid
/// PK — by probing the ACTUAL schema, losslessly for real user data. These
/// three tests cover every entry lineage. This is the load-bearing "Never break
/// userspace" check.

/// Legacy (pre-v16) epub_books DDL: id INTEGER PRIMARY KEY AUTOINCREMENT.
const String _legacyEpubBooksDdl = '''
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
''';

/// Name-PK (v16) epub_books DDL: book_key TEXT PRIMARY KEY, no id.
const String _namePkEpubBooksDdl = '''
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

/// Legacy video-line video_books DDL: autoincrement `id` PK + book_uid column.
/// The exact extra columns don't matter (the migration drop+recreates rather
/// than migrating rows), only that the PK is `id`, not `book_uid`.
const String _legacyVideoBooksDdl = '''
  CREATE TABLE video_books (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    book_uid TEXT NOT NULL,
    title TEXT NOT NULL,
    video_path TEXT NOT NULL,
    subtitle_source TEXT,
    subtitle_format TEXT,
    embedded_subtitle_track INTEGER,
    cover_path TEXT,
    last_position_ms INTEGER NOT NULL DEFAULT 0,
    playlist_json TEXT,
    current_episode INTEGER NOT NULL DEFAULT 0,
    audio_track_id TEXT,
    delay_ms INTEGER NOT NULL DEFAULT 0,
    imported_at INTEGER NOT NULL
  )
''';

void _seedThreeBooks(dynamic rawDb) {
  // Three real books; two sanitize to the SAME key so the migration's
  // deterministic dedup ('(2)') path is exercised.
  const List<List<Object?>> rows = <List<Object?>>[
    <Object?>[1, 'こころ', '夏目漱石'],
    <Object?>[2, '吾輩は猫である', '夏目漱石'],
    <Object?>[3, 'こころ', '別の著者'],
  ];
  for (final List<Object?> r in rows) {
    rawDb.execute(
      'INSERT INTO epub_books '
      '(id, title, author, cover_path, epub_path, extract_dir, '
      ' chapter_count, chapters_json, toc_json, source_metadata, imported_at) '
      "VALUES (?, ?, ?, NULL, '/abs/x.epub', '/abs/extract', 1, '[]', "
      'NULL, NULL, 0)',
      <Object?>[r[0], r[1], r[2]],
    );
  }
}

/// Asserts the post-migration DB is on the unified shape: epub_books name-PK
/// with [expectedBooks] rows preserved, video_books keyed by book_uid (no
/// legacy id), and end-to-end usable. The ladder always walks to the current
/// schemaVersion (now 23 — favorite_words / mining_statistics landed on top of
/// the v22 video watch-statistics step), so the version marker is asserted as
/// the live schema version.
Future<void> _expectUnifiedV20(HibikiDatabase db,
    {int expectedBooks = 3}) async {
  final version = await db.customSelect('PRAGMA user_version').getSingle();
  expect(version.read<int>('user_version'), db.schemaVersion);

  // epub_books name-PK: book_key present, legacy id gone, book_key is the PK.
  final epubCols =
      await db.customSelect("PRAGMA table_info('epub_books')").get();
  final Set<String> epubColNames =
      epubCols.map((r) => r.data['name'] as String).toSet();
  expect(epubColNames, contains('book_key'));
  expect(epubColNames, isNot(contains('id')));
  final epubPk = epubCols.firstWhere((r) => r.data['name'] == 'book_key');
  expect(epubPk.data['pk'], 1, reason: 'book_key must be the primary key');

  if (expectedBooks > 0) {
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books.length, expectedBooks,
        reason: 'no book dropped during convergence');
    final Set<String> keys = books.map((b) => b.bookKey).toSet();
    expect(keys.length, expectedBooks,
        reason: 'duplicate titles must dedup to unique keys');
  }

  // video_books book_uid PK, no legacy autoincrement id.
  final videoCols =
      await db.customSelect("PRAGMA table_info('video_books')").get();
  final Set<String> videoColNames =
      videoCols.map((r) => r.data['name'] as String).toSet();
  expect(videoColNames, contains('book_uid'));
  expect(videoColNames, isNot(contains('id')),
      reason: 'video_books has no autoincrement id after convergence');
  final videoPk = videoCols.firstWhere((r) => r.data['name'] == 'book_uid');
  expect(videoPk.data['pk'], 1, reason: 'book_uid must be the primary key');

  // Usable end-to-end.
  await db.upsertVideoBook(const VideoBooksCompanion(
    bookUid: Value('video/probe'),
    title: Value('Probe'),
    videoPath: Value('/abs/probe.mp4'),
  ));
  final VideoBookRow? probe = await db.getVideoBookByBookUid('video/probe');
  expect(probe, isNotNull);
  expect(probe!.title, 'Probe');
}

void main() {
  group('schema convergence to v20', () {
    test(
        'PATH A: video-line v19 (id-PK epub + legacy id-PK video_books) '
        '-> v20 name-PK + book_uid, data preserved', () async {
      // This is the lineage real user DBs are stuck on, and the one the
      // from<16/from<17 steps silently skip. The convergence must run name-PK
      // late AND rebuild the legacy video_books.
      final db =
          HibikiDatabase.forTesting(NativeDatabase.memory(setup: (rawDb) {
        rawDb.execute(_legacyEpubBooksDdl);
        _seedThreeBooks(rawDb);
        rawDb.execute(_legacyVideoBooksDdl);
        rawDb.execute(
          'INSERT INTO video_books '
          '(id, book_uid, title, video_path, imported_at) '
          "VALUES (1, 'video/old', 'Old Video', '/abs/old.mp4', 0)",
        );
        rawDb.execute('PRAGMA user_version = 19');
      }));
      addTearDown(db.close);
      await _expectUnifiedV20(db, expectedBooks: 3);
    });

    test(
        'PATH B: develop name-PK v16 (book_key epub, no video_books) '
        '-> v20 adds book_uid video_books, epub untouched', () async {
      final db =
          HibikiDatabase.forTesting(NativeDatabase.memory(setup: (rawDb) {
        rawDb.execute(_namePkEpubBooksDdl);
        // Name-PK rows: book_key directly.
        rawDb.execute(
          'INSERT INTO epub_books '
          '(book_key, title, author, cover_path, epub_path, extract_dir, '
          ' chapter_count, chapters_json, toc_json, source_metadata, imported_at) '
          "VALUES ('kokoro', 'こころ', '夏目漱石', NULL, '/abs/x.epub', "
          "'/abs/extract', 1, '[]', NULL, NULL, 0)",
        );
        rawDb.execute('PRAGMA user_version = 16');
      }));
      addTearDown(db.close);
      await _expectUnifiedV20(db, expectedBooks: 1);
    });

    test('PATH C: clean ancestor v15 (id-PK epub, no video_books) -> v20',
        () async {
      final db =
          HibikiDatabase.forTesting(NativeDatabase.memory(setup: (rawDb) {
        rawDb.execute(_legacyEpubBooksDdl);
        _seedThreeBooks(rawDb);
        rawDb.execute('PRAGMA user_version = 15');
      }));
      addTearDown(db.close);
      await _expectUnifiedV20(db, expectedBooks: 3);
    });
  });
}
