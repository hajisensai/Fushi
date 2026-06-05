import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// End-to-end guard for the video merge's schema unification (Phase 1): a real
/// v15 user DB (epub_books with the legacy autoincrement `id` primary key, plus
/// actual book rows) must upgrade monotonically to v17 such that
///
///   1. develop's name-PK v16 migration runs first and converts epub_books to a
///      `book_key`-keyed table WITHOUT losing any book data, and
///   2. the rebased v16->v17 step then creates `video_books` with a `book_uid`
///      primary key (no leftover autoincrement `id`).
///
/// This is the load-bearing "Never break userspace" check: develop users sit on
/// the v15/v16 line with real reading data, and the merge must not corrupt or
/// drop it while folding the video tables on top.
///
/// Seeds a v15 epub_books table in the exact pre-v16 shape that
/// `_runBookKeyMigrationBodyV16` reads (`SELECT id, title FROM epub_books`) and
/// rebuilds. We only need epub_books populated to exercise the re-key; the other
/// relation tables are column-guarded in the migration and a partial seed is a
/// supported input (each rebuild is skipped when its legacy column is absent).
Future<HibikiDatabase> _openV15DbWithRealEpubBooks() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Legacy (pre-v16) epub_books: id INTEGER PRIMARY KEY AUTOINCREMENT.
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
        // Three real books, including two that sanitize to the SAME key so the
        // migration's deterministic dedup ('(2)') path is exercised.
        const List<List<Object?>> rows = <List<Object?>>[
          <Object?>[1, 'こころ', '夏目漱石'],
          <Object?>[2, '吾輩は猫である', '夏目漱石'],
          <Object?>[3, 'こころ', '別の著者'], // same title -> deduped key
        ];
        for (final List<Object?> r in rows) {
          rawDb.execute(
            'INSERT INTO epub_books '
            '(id, title, author, cover_path, epub_path, extract_dir, '
            ' chapter_count, chapters_json, toc_json, source_metadata, '
            ' imported_at) '
            "VALUES (?, ?, ?, NULL, '/abs/x.epub', '/abs/extract', 1, '[]', "
            'NULL, NULL, 0)',
            <Object?>[r[0], r[1], r[2]],
          );
        }
        rawDb.execute('PRAGMA user_version = 15');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

void main() {
  group('v15 -> v17 video merge migration', () {
    test('upgrades to v17 and preserves epub_books data under name-PK',
        () async {
      final HibikiDatabase db = await _openV15DbWithRealEpubBooks();

      // Forces the lazy DB open + full onUpgrade ladder (v15 -> v16 name-PK ->
      // v17 video_books).
      final version =
          await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 17);

      // epub_books is now name-PK: book_key column present, legacy id gone.
      final epubCols =
          await db.customSelect("PRAGMA table_info('epub_books')").get();
      final Set<String> epubColNames =
          epubCols.map((r) => r.data['name'] as String).toSet();
      expect(epubColNames, contains('book_key'));
      expect(epubColNames, isNot(contains('id')));
      final epubPk = epubCols.firstWhere((r) => r.data['name'] == 'book_key');
      expect(epubPk.data['pk'], 1, reason: 'book_key must be the primary key');

      // All three books survive the re-key (no data loss).
      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books.length, 3, reason: 'no book dropped during name-PK migration');
      final Set<String> titles = books.map((b) => b.title).toSet();
      expect(titles, containsAll(<String>['こころ', '吾輩は猫である']));
      // The two same-titled books get distinct deduped keys.
      final Set<String> keys = books.map((b) => b.bookKey).toSet();
      expect(keys.length, 3, reason: 'duplicate titles must dedup to unique keys');

      // video_books exists with book_uid PK (rebased v16->v17 createTable).
      final videoCols =
          await db.customSelect("PRAGMA table_info('video_books')").get();
      final Set<String> videoColNames =
          videoCols.map((r) => r.data['name'] as String).toSet();
      expect(videoColNames, contains('book_uid'));
      expect(videoColNames, isNot(contains('id')),
          reason: 'VideoBooks has no autoincrement id after the merge');
      final videoPk =
          videoCols.firstWhere((r) => r.data['name'] == 'book_uid');
      expect(videoPk.data['pk'], 1, reason: 'book_uid must be the primary key');

      // The migrated video_books table is usable end-to-end.
      await db.upsertVideoBook(const VideoBooksCompanion(
        bookUid: Value('video/probe'),
        title: Value('Probe'),
        videoPath: Value('/abs/probe.mp4'),
      ));
      final VideoBookRow? probe = await db.getVideoBookByBookUid('video/probe');
      expect(probe, isNotNull);
      expect(probe!.title, 'Probe');
    });
  });
}
