import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('ReaderPositions table', () {
    test('upsert and retrieve by ttuBookId', () async {
      final db = await _openDb();
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookKey: 'book-42',
          sectionIndex: 3,
          normCharOffset: 1500,
          updatedAt: now,
        ),
      );

      final row = await db.getReaderPosition('book-42');
      expect(row, isNotNull);
      expect(row!.sectionIndex, 3);
      expect(row.normCharOffset, 1500);
    });

    test('getReaderPosition returns null for absent book', () async {
      final db = await _openDb();

      expect(await db.getReaderPosition('book-999'), isNull);
    });

    test('upsert replaces existing position', () async {
      final db = await _openDb();
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookKey: 'book-1',
          sectionIndex: 0,
          normCharOffset: 0,
          updatedAt: now,
        ),
      );
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookKey: 'book-1',
          sectionIndex: 5,
          normCharOffset: 3000,
          updatedAt: now + 1000,
        ),
      );

      final row = await db.getReaderPosition('book-1');
      expect(row!.sectionIndex, 5);
      expect(row.normCharOffset, 3000);
    });

    test('deleteReaderPosition removes the row', () async {
      final db = await _openDb();
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookKey: 'book-10',
          sectionIndex: 0,
          normCharOffset: 0,
          updatedAt: now,
        ),
      );

      final count = await db.deleteReaderPosition('book-10');

      expect(count, 1);
      expect(await db.getReaderPosition('book-10'), isNull);
    });

    test('ttuCharOffset defaults to -1', () async {
      final db = await _openDb();
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookKey: 'book-7',
          sectionIndex: 0,
          normCharOffset: 0,
          updatedAt: now,
        ),
      );

      final row = await db.getReaderPosition('book-7');
      expect(row!.ttuCharOffset, -1);
    });
  });

  group('Bookmarks table', () {
    test('insert bookmark via raw table and retrieve', () async {
      final db = await _openDb();
      final now = DateTime.now().millisecondsSinceEpoch;

      final bookKey = await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Novel',
          title: 'Novel',
          epubPath: '/tmp/novel.epub',
          extractDir: '/tmp/novel',
          chapterCount: 10,
          chaptersJson: '[]',
          importedAt: now,
        ),
      );

      await db.into(db.bookmarks).insert(
            BookmarksCompanion.insert(
              bookKey: bookKey,
              sectionIndex: 2,
              normCharOffset: 500,
              label: 'Important Part',
              createdAt: now,
            ),
          );

      final rows = await db.select(db.bookmarks).get();
      expect(rows, hasLength(1));
      expect(rows.single.label, 'Important Part');
      expect(rows.single.sectionIndex, 2);
    });

    test('deleting epub book cascades to bookmarks', () async {
      final db = await _openDb();
      final now = DateTime.now().millisecondsSinceEpoch;
      final bookKey = await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Book',
          title: 'Book',
          epubPath: '/p',
          extractDir: '/d',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: now,
        ),
      );
      await db.into(db.bookmarks).insert(
            BookmarksCompanion.insert(
              bookKey: bookKey,
              sectionIndex: 0,
              normCharOffset: 0,
              label: 'Mark',
              createdAt: now,
            ),
          );

      await db.deleteEpubBook(bookKey);

      final rows = await db.select(db.bookmarks).get();
      expect(rows, isEmpty);
    });
  });
}
