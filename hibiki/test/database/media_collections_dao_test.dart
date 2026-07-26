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
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addToCollection(c, MediaKind.video, 'v2');
    await db.addToCollection(c, MediaKind.epub, 'b1');
    // 重复加同成员 → 幂等（不新增、不改序）。
    await db.addToCollection(c, MediaKind.video, 'v1');

    final items = await db.getCollectionItems(c);
    expect(items.map((m) => m.entryKey).toList(), <String>['v1', 'v2', 'b1']);
    expect(items.map((m) => m.sortIndex).toList(), <int>[0, 1, 2]);
  });

  test('deleteMediaCollection cascade 删成员引用', () async {
    final db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.deleteMediaCollection(c);
    expect(await db.getCollectionItems(c), isEmpty);
  });

  test('getPrimaryCollectionIdByEntry 返回最小 collectionId（折叠归属）', () async {
    final db = await _openDb();
    final int c1 = await db.createMediaCollection('C1');
    final int c2 = await db.createMediaCollection('C2');
    // 同一条目 v1 属于 c1 与 c2 → 折叠归 min(c1,c2)=c1。
    await db.addToCollection(c1, MediaKind.video, 'v1');
    await db.addToCollection(c2, MediaKind.video, 'v1');
    await db.addToCollection(c2, MediaKind.video, 'v2');

    final map = await db.getPrimaryCollectionIdByEntry();
    expect(map['video|v1'], c1);
    expect(map['video|v2'], c2);
  });

  test('removeFromCollection 移空后自动删合集', () async {
    final db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addToCollection(c, MediaKind.video, 'v2');

    await db.removeFromCollection(c, MediaKind.video, 'v1');
    expect((await db.getCollectionItems(c)).map((m) => m.entryKey),
        <String>['v2']);
    expect(await db.getMediaCollectionById(c), isNotNull);

    // 移出最后一个 → 合集自删。
    await db.removeFromCollection(c, MediaKind.video, 'v2');
    expect(await db.getMediaCollectionById(c), isNull);
  });

  test('reorderCollectionItems 回写 sortIndex', () async {
    final db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addToCollection(c, MediaKind.video, 'v2');
    await db.addToCollection(c, MediaKind.video, 'v3');

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
    await db.addToCollection(c1, MediaKind.video, 'v1');
    await db.addToCollection(c2, MediaKind.video, 'v1');
    await db.addToCollection(c2, MediaKind.video, 'v2'); // c2 保留 v2 → 不删

    await db.removeEntryFromAllCollections(MediaKind.video, 'v1');
    // c1 只有 v1 → 清空自删；c2 还有 v2 → 保留。
    expect(await db.getMediaCollectionById(c1), isNull);
    expect((await db.getCollectionItems(c2)).map((m) => m.entryKey),
        <String>['v2']);
  });

  test(
      'getAllCollectionItems 覆盖全部合集全部成员，按 collectionId 分组逐组等于 '
      'getCollectionItems（BUG-959 消除 N+1）', () async {
    final db = await _openDb();
    final int c1 = await db.createMediaCollection('C1');
    final int c2 = await db.createMediaCollection('C2');
    await db.addToCollection(c1, MediaKind.video, 'v1');
    await db.addToCollection(c1, MediaKind.video, 'v2');
    await db.addToCollection(c2, MediaKind.epub, 'b1');
    await db.addToCollection(c2, MediaKind.video, 'v1'); // v1 同属 c1、c2

    final List<MediaCollectionItemRow> all = await db.getAllCollectionItems();
    // 4 条：c1 的 v1/v2 + c2 的 b1/v1。
    expect(all.length, 4);

    final Map<int, List<MediaCollectionItemRow>> grouped =
        <int, List<MediaCollectionItemRow>>{};
    for (final MediaCollectionItemRow m in all) {
      grouped
          .putIfAbsent(m.collectionId, () => <MediaCollectionItemRow>[])
          .add(m);
    }
    // 每组（同序）必须等于逐合集查询结果——保证内存分组可替代 N+1。
    for (final int cid in <int>[c1, c2]) {
      final List<MediaCollectionItemRow> per = await db.getCollectionItems(cid);
      expect(
        grouped[cid]!
            .map((MediaCollectionItemRow m) =>
                '${m.mediaType}|${m.entryKey}#${m.sortIndex}')
            .toList(),
        per
            .map((MediaCollectionItemRow m) =>
                '${m.mediaType}|${m.entryKey}#${m.sortIndex}')
            .toList(),
      );
    }
  });

  test('memberSortIndex 内存分组（primaryMap[key]==m.collectionId）与旧逐合集逻辑等价',
      () async {
    final db = await _openDb();
    final int c1 = await db.createMediaCollection('C1');
    final int c2 = await db.createMediaCollection('C2');
    await db.addToCollection(c1, MediaKind.video, 'v1'); // c1 内 sortIndex 0
    await db.addToCollection(c1, MediaKind.video, 'v2'); // c1 内 sortIndex 1
    await db.addToCollection(c2, MediaKind.video, 'v1'); // c2 内 sortIndex 0
    await db.addToCollection(c2, MediaKind.video, 'v3'); // c2 内 sortIndex 1

    final Map<String, int> primaryMap =
        await db.getPrimaryCollectionIdByEntry();

    // 新实现：一次 getAllCollectionItems + 内存分组。
    final Map<String, int> newMap = <String, int>{};
    for (final MediaCollectionItemRow m in await db.getAllCollectionItems()) {
      final String key = '${m.mediaType}|${m.entryKey}';
      if (primaryMap[key] == m.collectionId) newMap[key] = m.sortIndex;
    }

    // 旧实现：逐合集 getCollectionItems（判据 == c.id）。
    final Map<String, int> oldMap = <String, int>{};
    for (final MediaCollectionRow c in await db.getAllMediaCollections()) {
      for (final MediaCollectionItemRow m
          in await db.getCollectionItems(c.id)) {
        final String key = '${m.mediaType}|${m.entryKey}';
        if (primaryMap[key] == c.id) oldMap[key] = m.sortIndex;
      }
    }

    expect(newMap, oldMap);
    // v1 折叠归 c1(min)，取 c1 内 sortIndex 0；v2→1；v3 在 c2 内 1。
    expect(newMap['video|v1'], 0);
    expect(newMap['video|v2'], 1);
    expect(newMap['video|v3'], 1);
  });

  // P5 未知种类透传：合集成员行值可能是**对端未来新增的种类**（同步引擎原样
  // 透传，不经 tryParse 过滤）。详情页移出走 `removeFromCollectionRaw`
  // （media_collection_grid_detail_page._removeMember 的明文契约），否则
  // tryParse 丢弃会让这条成员**永远移不掉**——用户点「移出合集」毫无反应。
  test('removeFromCollectionRaw 能移出未知种类成员（typed 入口覆盖不到的行值）', () async {
    final HibikiDatabase db = await _openDb();
    final int c = await db.createMediaCollection('C');
    // 'manga' 不在 MediaKind 值域内 —— 模拟对端新增种类同步进来的成员行。
    const String unknownKind = 'manga';
    expect(MediaKind.tryParse(unknownKind), isNull, reason: '前提：确实是未知种类');

    await db.addToCollectionRaw(c, unknownKind, 'm1');
    await db.addToCollection(c, MediaKind.video, 'v1');
    expect((await db.getCollectionItems(c)).map((m) => m.mediaType).toList(),
        <String>[unknownKind, 'video'],
        reason: 'raw 入口原样落库未知种类，不被静默丢弃');

    await db.removeFromCollectionRaw(c, unknownKind, 'm1');
    final List<MediaCollectionItemRow> after = await db.getCollectionItems(c);
    expect(after.map((m) => m.entryKey).toList(), <String>['v1'],
        reason: '未知种类成员必须移得掉');

    // 同时写出成员移出墓碑（否则跨端并集会把它复活）——墓碑里也是原样种类串。
    final List<CollectionMemberTombstoneRow> tombs =
        (await db.getAllCollectionMemberTombstones())
            .where((r) => r.collectionName == 'C')
            .toList();
    expect(
      tombs.where((r) => r.mediaType == unknownKind && r.entryKey == 'm1'),
      isNotEmpty,
      reason: '未知种类的移出墓碑同样要写，且种类串原样保留',
    );
  });

  test('removeFromCollection typed 入口与 raw 入口对已知种类等价', () async {
    final HibikiDatabase db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addToCollection(c, MediaKind.epub, 'b1');

    await db.removeFromCollectionRaw(c, MediaKind.video.dbValue, 'v1');
    expect((await db.getCollectionItems(c)).map((m) => m.entryKey).toList(),
        <String>['b1']);
  });
}
