import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// [MediaCollections] / [MediaCollectionItems] DAO 测试（统一合集 Phase 1）。
Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  test('create/getAll/getById/rename/sortOrder/cover/delete', () async {
    final db = await _openDb();
    final int a = await db.createMediaCollection('A');
    final int b =
        await db.createMediaCollection('B', collectionType: 'playlist');

    final all = await db.getAllMediaCollections();
    expect(all.map((c) => c.name), containsAll(<String>['A', 'B']));
    // sortOrder 递增（A=0, B=1），排序稳定。
    expect(all.first.name, 'A');

    final rowB = await db.getMediaCollectionById(b);
    expect(rowB!.collectionType, 'playlist');

    await db.renameMediaCollection(a, 'A2');
    expect((await db.getMediaCollectionById(a))!.name, 'A2');

    await db.updateMediaCollectionSortOrder(a, 99);
    expect((await db.getMediaCollectionById(a))!.sortOrder, 99);

    await db.updateMediaCollectionCover(a, 'video|x');
    expect((await db.getMediaCollectionById(a))!.coverSource, 'video|x');
    await db.updateMediaCollectionCover(a, null);
    expect((await db.getMediaCollectionById(a))!.coverSource, isNull);

    await db.deleteMediaCollection(b);
    expect(await db.getMediaCollectionById(b), isNull);
  });

  test('addToCollection 尾插 + insertOrIgnore 幂等；getCollectionItems 有序',
      () async {
    final db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, 'video', 'v1');
    await db.addToCollection(c, 'video', 'v2');
    await db.addToCollection(c, 'epub', 'b1');
    // 重复加同成员 → 幂等（不新增、不改序）。
    await db.addToCollection(c, 'video', 'v1');

    final items = await db.getCollectionItems(c);
    expect(items.map((m) => m.entryKey).toList(), <String>['v1', 'v2', 'b1']);
    expect(items.map((m) => m.sortIndex).toList(), <int>[0, 1, 2]);
  });

  test('deleteMediaCollection cascade 删成员引用', () async {
    final db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, 'video', 'v1');
    await db.deleteMediaCollection(c);
    expect(await db.getCollectionItems(c), isEmpty);
  });

  test('getPrimaryCollectionIdByEntry 返回最小 collectionId（折叠归属）', () async {
    final db = await _openDb();
    final int c1 = await db.createMediaCollection('C1');
    final int c2 = await db.createMediaCollection('C2');
    // 同一条目 v1 属于 c1 与 c2 → 折叠归 min(c1,c2)=c1。
    await db.addToCollection(c1, 'video', 'v1');
    await db.addToCollection(c2, 'video', 'v1');
    await db.addToCollection(c2, 'video', 'v2');

    final map = await db.getPrimaryCollectionIdByEntry();
    expect(map['video|v1'], c1);
    expect(map['video|v2'], c2);
  });

  test('removeFromCollection 移空后自动删合集', () async {
    final db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, 'video', 'v1');
    await db.addToCollection(c, 'video', 'v2');

    await db.removeFromCollection(c, 'video', 'v1');
    expect((await db.getCollectionItems(c)).map((m) => m.entryKey),
        <String>['v2']);
    expect(await db.getMediaCollectionById(c), isNotNull);

    // 移出最后一个 → 合集自删。
    await db.removeFromCollection(c, 'video', 'v2');
    expect(await db.getMediaCollectionById(c), isNull);
  });

  test('reorderCollectionItems 回写 sortIndex', () async {
    final db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, 'video', 'v1');
    await db.addToCollection(c, 'video', 'v2');
    await db.addToCollection(c, 'video', 'v3');

    await db.reorderCollectionItems(c, <({String mediaType, String entryKey})>[
      (mediaType: 'video', entryKey: 'v3'),
      (mediaType: 'video', entryKey: 'v1'),
      (mediaType: 'video', entryKey: 'v2'),
    ]);
    expect(
      (await db.getCollectionItems(c)).map((m) => m.entryKey).toList(),
      <String>['v3', 'v1', 'v2'],
    );
  });

  test('removeEntryFromAllCollections 清全部引用 + 删空合集', () async {
    final db = await _openDb();
    final int c1 = await db.createMediaCollection('C1');
    final int c2 = await db.createMediaCollection('C2');
    await db.addToCollection(c1, 'video', 'v1');
    await db.addToCollection(c2, 'video', 'v1');
    await db.addToCollection(c2, 'video', 'v2'); // c2 保留 v2 → 不删

    await db.removeEntryFromAllCollections('video', 'v1');
    // c1 只有 v1 → 清空自删；c2 还有 v2 → 保留。
    expect(await db.getMediaCollectionById(c1), isNull);
    expect((await db.getCollectionItems(c2)).map((m) => m.entryKey),
        <String>['v2']);
  });
}
