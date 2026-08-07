import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<FushiDatabase> _openDb() async {
  final db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

Future<FushiDatabase> _openRealDb() async {
  final dir = await Directory.systemTemp.createTemp('hibiki_tags_test_');
  addTearDown(() async {
    await dir.delete(recursive: true);
  });
  final db = FushiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

Future<String> _insertBook(FushiDatabase db, String title) async {
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

    test(
        'countBooksForTag sums EPUB + SRT + video (BUG: 标签管理器对有声书/视频'
        '标签显示 0——旧实现只 COUNT EPUB 一张映射表)', () async {
      final db = await _openDb();
      final tagId = await db.createTag('Finished', 0xFF000000);

      // EPUB 书打标签。
      final epub = await _insertBook(db, 'Novel');
      await db.addTagToBook(epub, tagId);

      // 有声书（SRT）打标签——旧实现漏计。
      await db.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srt/1',
        title: 'Audiobook',
        srtPath: '/tmp/a.srt',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final SrtBookRow? srtRow = await db.getSrtBookByUid('srt/1');
      await db.addTagToSrtBook(srtRow!.id, tagId);

      // 视频打标签——旧实现同样漏计。
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: const Value('video/1'),
        title: const Value('Video'),
        videoPath: const Value('/abs/v.mp4'),
      ));
      await db.addTagToVideoBook('video/1', tagId);

      // 三种媒体共享同一标签池，计数必须是 3（修复前只返回 1 = EPUB）。
      expect(await db.countBooksForTag(tagId), 3);
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
