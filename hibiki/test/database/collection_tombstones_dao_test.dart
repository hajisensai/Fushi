import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// 合集墓碑 + 手动序时间戳 DAO 测试（多端库联合视图 §2.3 任务2）：
///  - reorderCollectionItems 同事务 bump orderUpdatedAt = now；
///  - removeFromCollection 写成员移出墓碑（自然键）；
///  - addToCollection 清同键墓碑（重加撤销移出）；
///  - deleteMediaCollection 写合集级哨兵墓碑 + 清残留成员墓碑；
///  - createMediaCollection 清同自然键的合集级墓碑（重建撤销删除）；
///  - 同步应用端原语不产生用户路径的副作用（不写 now 墓碑/时间戳）。
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// 某合集自然键下的全部墓碑行。
Future<List<CollectionMemberTombstoneRow>> _tombsFor(
    HibikiDatabase db, String name, String type) async {
  return (await db.getAllCollectionMemberTombstones())
      .where((r) => r.collectionName == name && r.collectionType == type)
      .toList();
}

void main() {
  test('reorderCollectionItems 同事务 bump orderUpdatedAt', () async {
    final HibikiDatabase db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addToCollection(c, MediaKind.video, 'v2');
    expect((await db.getMediaCollectionById(c))!.orderUpdatedAt, 0,
        reason: '加成员不 bump（只有真实拖序才算手动排序）');

    final int before = DateTime.now().millisecondsSinceEpoch;
    await db.reorderCollectionItems(c, <({String mediaType, String entryKey})>[
      (mediaType: 'video', entryKey: 'v2'),
      (mediaType: 'video', entryKey: 'v1'),
    ]);
    final MediaCollectionRow row = (await db.getMediaCollectionById(c))!;
    expect(row.orderUpdatedAt, greaterThanOrEqualTo(before),
        reason: '拖序落盘必须 bump 为 now（跨端 LWW 比较键）');
    expect((await db.getCollectionItems(c)).map((m) => m.entryKey).toList(),
        <String>['v2', 'v1']);
  });

  test('removeFromCollection 写成员墓碑；addToCollection 清同键墓碑', () async {
    final HibikiDatabase db = await _openDb();
    final int c =
        await db.createMediaCollection('C', collectionType: 'playlist');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addToCollection(c, MediaKind.video, 'v2');

    final int before = DateTime.now().millisecondsSinceEpoch;
    await db.removeFromCollection(c, MediaKind.video, 'v1');
    final List<CollectionMemberTombstoneRow> tombs =
        await _tombsFor(db, 'C', 'playlist');
    expect(tombs, hasLength(1), reason: '移出必须留墓碑，否则对端并集复活');
    expect(tombs.single.mediaType, 'video');
    expect(tombs.single.entryKey, 'v1');
    expect(tombs.single.deletedAt, greaterThanOrEqualTo(before));

    // 重新加入 → 同键墓碑清除（允许重加，防复活不变成禁重加）。
    await db.addToCollection(c, MediaKind.video, 'v1');
    expect(await _tombsFor(db, 'C', 'playlist'), isEmpty);
    expect((await db.getCollectionItems(c)).map((m) => m.entryKey),
        containsAll(<String>['v1', 'v2']));
  });

  test('移空自删只留成员墓碑，不写合集级哨兵', () async {
    final HibikiDatabase db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.removeFromCollection(c, MediaKind.video, 'v1');
    expect(await db.getMediaCollectionById(c), isNull, reason: '移空自删');
    final List<CollectionMemberTombstoneRow> tombs =
        await _tombsFor(db, 'C', 'collection');
    expect(tombs, hasLength(1));
    expect(tombs.single.entryKey, 'v1', reason: '只有成员墓碑');
    expect(
      tombs.any((r) =>
          r.entryKey == HibikiDatabase.collectionTombstoneSentinel &&
          r.mediaType == HibikiDatabase.collectionTombstoneSentinel),
      isFalse,
      reason: '用户意图是移出成员而非删合集，合集在对端应可继续存在',
    );
  });

  test('deleteMediaCollection 写合集级哨兵 + 清残留成员墓碑', () async {
    final HibikiDatabase db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addToCollection(c, MediaKind.video, 'v2');
    await db.removeFromCollection(c, MediaKind.video, 'v1'); // 留一条成员墓碑。

    final int before = DateTime.now().millisecondsSinceEpoch;
    await db.deleteMediaCollection(c);
    expect(await db.getMediaCollectionById(c), isNull);
    final List<CollectionMemberTombstoneRow> tombs =
        await _tombsFor(db, 'C', 'collection');
    expect(tombs, hasLength(1), reason: '只剩哨兵——残留成员墓碑一并清除');
    expect(tombs.single.mediaType, HibikiDatabase.collectionTombstoneSentinel);
    expect(tombs.single.entryKey, HibikiDatabase.collectionTombstoneSentinel);
    expect(tombs.single.deletedAt, greaterThanOrEqualTo(before));
  });

  test('createMediaCollection 清同自然键合集级墓碑（重建撤销删除）', () async {
    final HibikiDatabase db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.deleteMediaCollection(c);
    expect(await _tombsFor(db, 'C', 'collection'), hasLength(1));

    final int c2 = await db.createMediaCollection('C');
    expect(c2, isNot(c));
    expect(await _tombsFor(db, 'C', 'collection'), isEmpty,
        reason: '重建 = 撤销删除，仿插书清书墓碑');
    // 不同 collectionType 是不同自然键：playlist 的墓碑不受 collection 重建影响。
    final int p =
        await db.createMediaCollection('P', collectionType: 'playlist');
    await db.addToCollection(p, MediaKind.video, 'v1');
    await db.deleteMediaCollection(p);
    await db.createMediaCollection('P'); // 默认 collection 类型 ≠ playlist。
    expect(await _tombsFor(db, 'P', 'playlist'), hasLength(1),
        reason: '自然键含 collectionType，异类型重名不清墓碑');
  });

  test('同步应用端原语：镜像时间戳/成员，不产生用户路径副作用', () async {
    final HibikiDatabase db = await _openDb();
    final int c = await db.createMediaCollection('C');
    // upsertCollectionItemAt 显式 sortIndex，不走尾插。
    await db.upsertCollectionItemAt(c, 'video', 'v1', 5);
    await db.upsertCollectionItemAt(c, 'video', 'v2', 3);
    expect((await db.getCollectionItems(c)).map((m) => m.entryKey).toList(),
        <String>['v2', 'v1']);

    // setCollectionOrderUpdatedAt 镜像清单值而非 now。
    await db.setCollectionOrderUpdatedAt(c, 42);
    expect((await db.getMediaCollectionById(c))!.orderUpdatedAt, 42);

    // deleteCollectionItemRaw 不写墓碑、不触发移空自删。
    await db.deleteCollectionItemRaw(c, 'video', 'v1');
    await db.deleteCollectionItemRaw(c, 'video', 'v2');
    expect(await db.getMediaCollectionById(c), isNotNull,
        reason: 'raw 删除不自删空合集（空壳收尾由同步应用端统一决定）');
    expect(await _tombsFor(db, 'C', 'collection'), isEmpty);

    // deleteMediaCollectionRaw 删行不写哨兵。
    await db.deleteMediaCollectionRaw(c);
    expect(await db.getMediaCollectionById(c), isNull);
    expect(await _tombsFor(db, 'C', 'collection'), isEmpty);

    // replaceCollectionTombstonesFor 整体镜像。
    await db.replaceCollectionTombstonesFor(
      'C',
      'collection',
      <CollectionMemberTombstonesCompanion>[
        CollectionMemberTombstonesCompanion.insert(
          collectionName: 'C',
          collectionType: 'collection',
          mediaType: 'video',
          entryKey: 'v1',
          deletedAt: 7,
        ),
      ],
    );
    expect((await _tombsFor(db, 'C', 'collection')).single.deletedAt, 7);
    await db.replaceCollectionTombstonesFor(
        'C', 'collection', const <CollectionMemberTombstonesCompanion>[]);
    expect(await _tombsFor(db, 'C', 'collection'), isEmpty);
  });
}
