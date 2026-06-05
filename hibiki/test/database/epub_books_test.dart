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
    bookKey: title,
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
    test('insertEpubBook returns the bookKey', () async {
      final db = await _openDb();

      final key = await db.insertEpubBook(_book(title: 'My Novel'));

      expect(key, 'My Novel');
    });

    test('getEpubBook retrieves by bookKey', () async {
      final db = await _openDb();
      final key = await db.insertEpubBook(_book(title: 'My Novel'));

      final row = await db.getEpubBook(key);

      expect(row, isNotNull);
      expect(row!.title, 'My Novel');
      expect(row.chapterCount, 3);
    });

    test('getEpubBook returns null for absent key', () async {
      final db = await _openDb();

      expect(await db.getEpubBook('nope'), isNull);
    });

    test('getAllEpubBooks returns all inserted books', () async {
      final db = await _openDb();
      await db.insertEpubBook(_book(title: 'A'));
      await db.insertEpubBook(_book(title: 'B'));

      final all = await db.getAllEpubBooks();

      expect(all, hasLength(2));
    });

    test('updateEpubBookTitle is unsupported (rename = re-key)', () async {
      final db = await _openDb();
      final key = await db.insertEpubBook(_book(title: 'Old'));

      expect(() => db.updateEpubBookTitle(key, 'New'),
          throwsA(isA<UnsupportedError>()));
    });

    test('updateEpubBookPath changes the epub path', () async {
      final db = await _openDb();
      final key = await db.insertEpubBook(_book());

      await db.updateEpubBookPath(key, '/new/path.epub');

      final row = await db.getEpubBook(key);
      expect(row!.epubPath, '/new/path.epub');
    });

    test('deleteEpubBook removes the row', () async {
      final db = await _openDb();
      final key = await db.insertEpubBook(_book());

      final deleted = await db.deleteEpubBook(key);

      expect(deleted, 1);
      expect(await db.getEpubBook(key), isNull);
    });

    test('insertEpubBookOrIgnore silently ignores duplicate key', () async {
      final db = await _openDb();
      await db.insertEpubBook(_book(title: 'Unique'));

      // Same bookKey → ignored, no throw.
      await db.insertEpubBookOrIgnore(_book(title: 'Unique'));

      final all = await db.getAllEpubBooks();
      expect(all, hasLength(1));
    });
  });
}
