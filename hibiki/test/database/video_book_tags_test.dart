import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// FK cascade（foreign_keys=ON）只在真实库 PRAGMA 下生效，与 tags_test 一致。
Future<HibikiDatabase> _openRealDb() async {
  final dir = await Directory.systemTemp.createTemp('hibiki_video_tags_test_');
  addTearDown(() async {
    await dir.delete(recursive: true);
  });
  final db = HibikiDatabase(dir.path);
  addTearDown(db.close);
  return db;
}

Future<String> _insertVideoBook(HibikiDatabase db, String uid) async {
  await db.upsertVideoBook(VideoBooksCompanion(
    bookUid: Value(uid),
    title: Value(uid),
    videoPath: Value('/abs/$uid.mp4'),
  ));
  return uid;
}

void main() {
  group('VideoBookTagMappings — shares the BookTags pool', () {
    test('addTagToVideoBook and getTagsForVideoBook', () async {
      final db = await _openDb();
      final uid = await _insertVideoBook(db, 'video/1');
      final tagId = await db.createTag('Anime', 0xFF00FF00);

      await db.addTagToVideoBook(uid, tagId);

      final tags = await db.getTagsForVideoBook(uid);
      expect(tags, hasLength(1));
      expect(tags.single.name, 'Anime');
    });

    test('addTagToVideoBook is idempotent (insertOrIgnore on unique key)',
        () async {
      final db = await _openDb();
      final uid = await _insertVideoBook(db, 'video/1');
      final tagId = await db.createTag('Anime', 0xFF00FF00);

      await db.addTagToVideoBook(uid, tagId);
      await db.addTagToVideoBook(uid, tagId);

      expect(await db.getTagsForVideoBook(uid), hasLength(1));
    });

    test('removeTagFromVideoBook removes the mapping', () async {
      final db = await _openDb();
      final uid = await _insertVideoBook(db, 'video/1');
      final tagId = await db.createTag('Tag', 0xFF000000);
      await db.addTagToVideoBook(uid, tagId);

      await db.removeTagFromVideoBook(uid, tagId);

      expect(await db.getTagsForVideoBook(uid), isEmpty);
    });

    test('setTagsForVideoBook replaces all tags atomically', () async {
      final db = await _openDb();
      final uid = await _insertVideoBook(db, 'video/1');
      final t1 = await db.createTag('Old', 0xFF000000);
      final t2 = await db.createTag('New', 0xFF000000);
      await db.addTagToVideoBook(uid, t1);

      await db.setTagsForVideoBook(uid, {t2});

      final tags = await db.getTagsForVideoBook(uid);
      expect(tags, hasLength(1));
      expect(tags.single.name, 'New');
    });

    test('getVideoBookUidsForAllTags returns videos with all tags', () async {
      final db = await _openDb();
      final v1 = await _insertVideoBook(db, 'video/1');
      final v2 = await _insertVideoBook(db, 'video/2');
      final t1 = await db.createTag('T1', 0xFF000000);
      final t2 = await db.createTag('T2', 0xFF000000);
      await db.addTagToVideoBook(v1, t1);
      await db.addTagToVideoBook(v1, t2);
      await db.addTagToVideoBook(v2, t1);

      final uids = await db.getVideoBookUidsForAllTags({t1, t2});
      expect(uids, contains(v1));
      expect(uids, isNot(contains(v2)));
    });

    test('getAllVideoBookTagMappings returns every mapping', () async {
      final db = await _openDb();
      final v1 = await _insertVideoBook(db, 'video/1');
      final v2 = await _insertVideoBook(db, 'video/2');
      final tagId = await db.createTag('T', 0xFF000000);
      await db.addTagToVideoBook(v1, tagId);
      await db.addTagToVideoBook(v2, tagId);

      expect(await db.getAllVideoBookTagMappings(), hasLength(2));
    });

    test('video and EPUB share the same BookTags row', () async {
      final db = await _openDb();
      final uid = await _insertVideoBook(db, 'video/1');
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'novel',
        title: 'Novel',
        epubPath: '/tmp/n.epub',
        extractDir: '/tmp/n',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final tagId = await db.createTag('Shared', 0xFF123456);

      await db.addTagToVideoBook(uid, tagId);
      await db.addTagToBook('novel', tagId);

      // 同一标签 id 同时挂在视频与 EPUB 上 —— 共用一个标签池。
      expect((await db.getTagsForVideoBook(uid)).single.id, tagId);
      expect((await db.getTagsForBook('novel')).single.id, tagId);
      expect(await db.getAllTags(), hasLength(1));
    });

    test('deleting a video book cascades to its tag mappings', () async {
      final db = await _openRealDb();
      final uid = await _insertVideoBook(db, 'video/1');
      final tagId = await db.createTag('Temp', 0xFF000000);
      await db.addTagToVideoBook(uid, tagId);

      await db.deleteVideoBook(uid);

      expect(await db.getAllVideoBookTagMappings(), isEmpty);
      // 标签本身（共享池）不被删除。
      expect(await db.getAllTags(), hasLength(1));
    });

    test('deleting a tag cascades to video mappings', () async {
      final db = await _openRealDb();
      final uid = await _insertVideoBook(db, 'video/1');
      final tagId = await db.createTag('Temp', 0xFF000000);
      await db.addTagToVideoBook(uid, tagId);

      await db.deleteTag(tagId);

      expect(await db.getTagsForVideoBook(uid), isEmpty);
      expect(await db.getAllVideoBookTagMappings(), isEmpty);
    });
  });

  group('VideoBooks delete + cover', () {
    test('updateVideoBookCover writes through', () async {
      final db = await _openDb();
      final uid = await _insertVideoBook(db, 'video/1');
      await db.updateVideoBookCover(uid, '/abs/cover.jpg');
      final row = await db.getVideoBookByBookUid(uid);
      expect(row!.coverPath, '/abs/cover.jpg');
    });

    test('deleteVideoBook removes the row', () async {
      final db = await _openDb();
      final uid = await _insertVideoBook(db, 'video/1');
      await db.deleteVideoBook(uid);
      expect(await db.getVideoBookByBookUid(uid), isNull);
    });
  });
}
