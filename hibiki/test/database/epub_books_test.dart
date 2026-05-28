import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

EpubBooksCompanion _book({
  String title = 'Test Book',
}) {
  return EpubBooksCompanion.insert(
    title: title,
    epubPath: '/tmp/$title.epub',
    extractDir: '/tmp/$title',
    chapterCount: 3,
    chaptersJson: '["ch1","ch2","ch3"]',
    importedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

void main() {
  group('EpubBooks table', () {
    test('insertEpubBook returns auto-incremented id', () async {
      final db = await _openDb();

      final id = await db.insertEpubBook(_book());

      expect(id, greaterThan(0));
    });

    test('getEpubBook retrieves by id', () async {
      final db = await _openDb();
      final id = await db.insertEpubBook(_book(title: 'My Novel'));

      final row = await db.getEpubBook(id);

      expect(row, isNotNull);
      expect(row!.title, 'My Novel');
      expect(row.chapterCount, 3);
    });

    test('getEpubBook returns null for absent id', () async {
      final db = await _openDb();

      expect(await db.getEpubBook(999), isNull);
    });

    test('getAllEpubBooks returns all inserted books', () async {
      final db = await _openDb();
      await db.insertEpubBook(_book(title: 'A'));
      await db.insertEpubBook(_book(title: 'B'));

      final all = await db.getAllEpubBooks();

      expect(all, hasLength(2));
    });

    test('updateEpubBookTitle changes only the title', () async {
      final db = await _openDb();
      final id = await db.insertEpubBook(_book(title: 'Old'));

      await db.updateEpubBookTitle(id, 'New');

      final row = await db.getEpubBook(id);
      expect(row!.title, 'New');
      expect(row.chapterCount, 3);
    });

    test('updateEpubBookPath changes the epub path', () async {
      final db = await _openDb();
      final id = await db.insertEpubBook(_book());

      await db.updateEpubBookPath(id, '/new/path.epub');

      final row = await db.getEpubBook(id);
      expect(row!.epubPath, '/new/path.epub');
    });

    test('deleteEpubBook removes the row', () async {
      final db = await _openDb();
      final id = await db.insertEpubBook(_book());

      final deleted = await db.deleteEpubBook(id);

      expect(deleted, 1);
      expect(await db.getEpubBook(id), isNull);
    });

    test('insertEpubBookOrIgnore silently ignores duplicate', () async {
      final db = await _openDb();
      await db.insertEpubBook(_book(title: 'Unique'));

      final id2 = await db.insertEpubBookOrIgnore(_book(title: 'Unique2'));

      expect(id2, greaterThan(0));
    });
  });
}
