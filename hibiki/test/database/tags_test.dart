import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

Future<HibikiDatabase> _openRealDb() async {
  final dir = await Directory.systemTemp.createTemp('hibiki_tags_test_');
  addTearDown(() async {
    await dir.delete(recursive: true);
  });
  final db = HibikiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

Future<String> _insertBook(HibikiDatabase db, String title) async {
  return db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: title,
      title: title,
      epubPath: '/tmp/$title.epub',
      extractDir: '/tmp/$title',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

void main() {
  group('BookTags CRUD', () {
    test('createTag returns id and getAllTags retrieves it', () async {
      final db = await _openDb();

      await db.createTag('Fiction', 0xFF0000FF);

      final tags = await db.getAllTags();
      expect(tags, hasLength(1));
      expect(tags.single.name, 'Fiction');
      expect(tags.single.colorValue, 0xFF0000FF);
    });

    test('updateTag changes name and color', () async {
      final db = await _openDb();
      final id = await db.createTag('Old', 0xFF000000);

      await db.updateTag(id, name: 'New', colorValue: 0xFFFFFFFF);

      final tags = await db.getAllTags();
      expect(tags.single.name, 'New');
      expect(tags.single.colorValue, 0xFFFFFFFF);
    });

    test('deleteTag removes the tag', () async {
      final db = await _openDb();
      final id = await db.createTag('Temp', 0xFF000000);

      await db.deleteTag(id);

      expect(await db.getAllTags(), isEmpty);
    });

    test('reorderTags updates sort order', () async {
      final db = await _openDb();
      final id1 = await db.createTag('A', 0xFF000000);
      final id2 = await db.createTag('B', 0xFF000000);
      final id3 = await db.createTag('C', 0xFF000000);

      await db.reorderTags([id3, id1, id2]);

      final tags = await db.getAllTags();
      final sortOrders = {for (final t in tags) t.name: t.sortOrder};
      expect(sortOrders['C'], lessThan(sortOrders['A']!));
      expect(sortOrders['A'], lessThan(sortOrders['B']!));
    });
  });

  group('BookTagMappings', () {
    test('addTagToBook and getTagsForBook', () async {
      final db = await _openDb();
      final bookId = await _insertBook(db, 'Novel');
      final tagId = await db.createTag('Fiction', 0xFF000000);

      await db.addTagToBook(bookId, tagId);

      final tags = await db.getTagsForBook(bookId);
      expect(tags, hasLength(1));
      expect(tags.single.name, 'Fiction');
    });

    test('removeTagFromBook removes the mapping', () async {
      final db = await _openDb();
      final bookId = await _insertBook(db, 'Novel');
      final tagId = await db.createTag('Tag', 0xFF000000);
      await db.addTagToBook(bookId, tagId);

      await db.removeTagFromBook(bookId, tagId);

      expect(await db.getTagsForBook(bookId), isEmpty);
    });

    test('setTagsForBook replaces all tags atomically', () async {
      final db = await _openDb();
      final bookId = await _insertBook(db, 'Novel');
      final t1 = await db.createTag('Old', 0xFF000000);
      final t2 = await db.createTag('New', 0xFF000000);
      await db.addTagToBook(bookId, t1);

      await db.setTagsForBook(bookId, {t2});

      final tags = await db.getTagsForBook(bookId);
      expect(tags, hasLength(1));
      expect(tags.single.name, 'New');
    });

    test('getBookKeysForAnyTag returns books with any matching tag', () async {
      final db = await _openDb();
      final b1 = await _insertBook(db, 'A');
      final b2 = await _insertBook(db, 'B');
      final b3 = await _insertBook(db, 'C');
      final t1 = await db.createTag('T1', 0xFF000000);
      final t2 = await db.createTag('T2', 0xFF000000);
      await db.addTagToBook(b1, t1);
      await db.addTagToBook(b2, t2);

      final ids = await db.getBookKeysForAnyTag({t1, t2});
      expect(ids, containsAll([b1, b2]));
      expect(ids, isNot(contains(b3)));
    });

    test('getBookKeysForAllTags returns books with all tags', () async {
      final db = await _openDb();
      final b1 = await _insertBook(db, 'A');
      final b2 = await _insertBook(db, 'B');
      final t1 = await db.createTag('T1', 0xFF000000);
      final t2 = await db.createTag('T2', 0xFF000000);
      await db.addTagToBook(b1, t1);
      await db.addTagToBook(b1, t2);
      await db.addTagToBook(b2, t1);

      final ids = await db.getBookKeysForAllTags({t1, t2});
      expect(ids, contains(b1));
      expect(ids, isNot(contains(b2)));
    });

    test('countBooksForTag returns correct count', () async {
      final db = await _openDb();
      final b1 = await _insertBook(db, 'A');
      final b2 = await _insertBook(db, 'B');
      final tagId = await db.createTag('Pop', 0xFF000000);
      await db.addTagToBook(b1, tagId);
      await db.addTagToBook(b2, tagId);

      expect(await db.countBooksForTag(tagId), 2);
    });

    test('deleting a tag cascades to mappings', () async {
      final db = await _openRealDb();
      final bookId = await _insertBook(db, 'Novel');
      final tagId = await db.createTag('Temp', 0xFF000000);
      await db.addTagToBook(bookId, tagId);

      await db.deleteTag(tagId);

      expect(await db.getTagsForBook(bookId), isEmpty);
      expect(await db.getAllBookTagMappings(), isEmpty);
    });
  });
}
