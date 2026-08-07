import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<HibikiDatabase> _openDb() async {
  // 生产连接经 applyPragmas 开启 foreign_keys；forTesting 直接吃传入 executor 不套
  // 那层 pragma，故此处显式开启（同 foreign_keys_test.dart），否则 cascade 不生效。
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(db.close);
  return db;
}

void main() {
  group('collection tag mappings', () {
    test('add/get/remove round-trips and dedups', () async {
      final db = await _openDb();
      final int cid =
          await db.createMediaCollection('C1', collectionType: 'collection');
      final int t1 = await db.createTag('日语', 0xFF0000FF);
      final int t2 = await db.createTag('N1', 0xFF00FF00);

      await db.addTagToCollection(cid, t1);
      await db.addTagToCollection(cid, t2);
      await db.addTagToCollection(cid, t1); // 幂等（INSERT OR IGNORE）

      final tags = await db.getTagsForCollection(cid);
      expect(tags.map((t) => t.id).toSet(), {t1, t2});

      await db.removeTagFromCollection(cid, t1);
      final after = await db.getTagsForCollection(cid);
      expect(after.map((t) => t.id).toSet(), {t2});
    });

    test('getCollectionIdsForAllTags is AND-semantics', () async {
      final db = await _openDb();
      final int c1 =
          await db.createMediaCollection('C1', collectionType: 'collection');
      final int c2 =
          await db.createMediaCollection('C2', collectionType: 'playlist');
      final int t1 = await db.createTag('a', 0xFF000001);
      final int t2 = await db.createTag('b', 0xFF000002);
      await db.addTagToCollection(c1, t1);
      await db.addTagToCollection(c1, t2);
      await db.addTagToCollection(c2, t1);

      expect(await db.getCollectionIdsForAllTags({t1}), {c1, c2});
      expect(await db.getCollectionIdsForAllTags({t1, t2}), {c1});
      expect(await db.getCollectionIdsForAllTags({}), <int>{});
    });

    test('deleting collection cascades its tag mappings', () async {
      final db = await _openDb();
      final int cid =
          await db.createMediaCollection('C1', collectionType: 'collection');
      final int t1 = await db.createTag('x', 0xFF000003);
      await db.addTagToCollection(cid, t1);
      await db.deleteMediaCollectionRaw(cid);
      expect(await db.getCollectionIdsForAllTags({t1}), <int>{});
    });

    test('deleting tag cascades its collection mappings', () async {
      final db = await _openDb();
      final int cid =
          await db.createMediaCollection('C1', collectionType: 'collection');
      final int t1 = await db.createTag('x', 0xFF000004);
      await db.addTagToCollection(cid, t1);
      // 删标签靠 BookTags→collection_tag_mappings 的 tagId FK cascade 自动清映射
      // （deleteTag 是纯 delete(bookTags)，不手动清映射；设计 §7 显式要求覆盖此路）。
      await db.deleteTag(t1);
      expect(await db.getTagsForCollection(cid), isEmpty);
    });
  });
}
