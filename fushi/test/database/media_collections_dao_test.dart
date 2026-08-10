import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// [MediaCollections] / [MediaCollectionItems] DAO 测试（统一合集 Phase 1）。
Future<FushiDatabase> _openDb() async {
  final db = FushiDatabase.forTesting(NativeDatabase.memory());
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

    await db.reorderCollectionItems(c, <CollectionMemberKey>[
      (mediaType: 'video', entryKey: 'v3'),
      (mediaType: 'video', entryKey: 'v1'),
      (mediaType: 'video', entryKey: 'v2'),
    ]);
    expect(
      (await db.getCollectionItems(c)).map((m) => m.entryKey).toList(),
      <String>['v3', 'v1', 'v2'],
    );
  });

  // ── BUG-1194 根因守卫：reorderCollectionItems 的**子集**契约 ──────────────
  // 合集详情页天然只渲染成员子集（视频详情页只显示 video；网格详情页按标签过滤），
  // 所以「传子集」是合法用法。不变量必须由 DAO 自己守住，页面漏做保序合并不该再能
  // 造出碰撞 sortIndex——旧实现按 ordered 下标直写，未点名成员留旧值与新写的致密
  // 0..n-1 碰撞，getCollectionItems 平手退化按 entryKey 排，跨种类手排序被打乱。
  group('reorderCollectionItems 子集契约（BUG-1194 根因）', () {
    /// 交错基线：video/g1/video/e1/video —— 非 video 成员夹在 video 之间，只回写
    /// 可见 video 键时它们的相对位置必然被打乱。
    Future<int> seedMixed(FushiDatabase db) async {
      final int c = await db.createMediaCollection('Mixed');
      await db.addToCollection(c, MediaKind.video, 'v1');
      await db.addToCollection(c, MediaKind.game, 'g1');
      await db.addToCollection(c, MediaKind.video, 'v2');
      await db.addToCollection(c, MediaKind.epub, 'e1');
      await db.addToCollection(c, MediaKind.video, 'v3');
      return c;
    }

    Future<List<String>> members(FushiDatabase db, int c) async => <String>[
          for (final MediaCollectionItemRow r in await db.getCollectionItems(c))
            '${r.mediaType}|${r.entryKey}',
        ];

    Future<List<int>> indices(FushiDatabase db, int c) async => <int>[
          for (final MediaCollectionItemRow r in await db.getCollectionItems(c))
            r.sortIndex,
        ];

    test('只传可见 video 子集：非 video 成员留原槽位，全表致密无碰撞', () async {
      final db = await _openDb();
      final int c = await seedMixed(db);

      // 视频详情页把可见的三个 video 倒排后落盘（**只传 video 子集**）。
      await db.reorderCollectionItems(c, <CollectionMemberKey>[
        (mediaType: 'video', entryKey: 'v3'),
        (mediaType: 'video', entryKey: 'v2'),
        (mediaType: 'video', entryKey: 'v1'),
      ]);

      expect(
        await members(db, c),
        <String>['video|v3', 'game|g1', 'video|v2', 'epub|e1', 'video|v1'],
        reason: 'video 依次填回原来的三个 video 槽位（0/2/4），g1/e1 留在 1/3 不被挤走',
      );
      expect(await indices(db, c), <int>[0, 1, 2, 3, 4],
          reason: 'sortIndex 必须致密 0..n-1；有重复即说明漏写了未点名成员');
    });

    test('历史遗留的碰撞 sortIndex：任何一次重排都自愈成致密序，相对顺序不变', () async {
      final db = await _openDb();
      final int c = await seedMixed(db);
      // 种一份旧版（只回写可见 video 子集）留下的碰撞现场：v1/v2/v3 被写成 0/1/2，
      // g1/e1 留着旧的 1/3 → sortIndex 1 上有 g1 与 v2 两行。upsertCollectionItemAt
      // 是同步应用端的显式 sortIndex 写入口，这里借它复现旧数据。
      await db.upsertCollectionItemAt(c, 'video', 'v1', 0);
      await db.upsertCollectionItemAt(c, 'video', 'v2', 1);
      await db.upsertCollectionItemAt(c, 'video', 'v3', 2);
      await db.upsertCollectionItemAt(c, 'game', 'g1', 1);
      await db.upsertCollectionItemAt(c, 'epub', 'e1', 3);
      expect(await indices(db, c), <int>[0, 1, 1, 2, 3],
          reason: '前置条件：现场确实有碰撞（sortIndex 1 两行）');

      // 碰撞下 getCollectionItems 平手退化按 entryKey 排 —— 这就是用户此刻看到的序。
      final List<String> before = await members(db, c);
      await db.reorderCollectionItems(c, const <CollectionMemberKey>[]);

      expect(await members(db, c), before, reason: '没点名任何成员 → 相对顺序零变化');
      expect(await indices(db, c), <int>[0, 1, 2, 3, 4],
          reason: '重排把全表写成致密序，历史碰撞就此消除（不再依赖 entryKey 兜底）');
    });

    test('sortIndex 碰撞时按 entryKey 定序，并被一次重排冻结成致密序', () async {
      // reorderCollectionItems 把 getCollectionItems 的结果**冻结**成永久致密序，
      // 所以那个读的定序规则是本 PR 的地基。这里守的是**可观测**的那一段：
      // sortIndex 全碰撞时按 entryKey 升序，且冻结后不再依赖任何并列兜底。
      //
      // 诚实标注：getCollectionItems 的 ORDER BY 末位还有一段 mediaType（补全序，
      // 见该方法注释）。当前 SQLite 计划走复合主键索引扫描、本就是 mediaType 升序，
      // 删掉那一段**行为不变**，故此处不为它写断言——写了也是永远绿的假守卫。
      final db = await _openDb();
      final int c = await db.createMediaCollection('Collided');
      // 全部塞进 sortIndex 0，且**刻意让 entryKey 序与 mediaType 序相反**
      // （entryKey aa<mm<zz 给出 video,game,epub；mediaType epub<game<video 给出
      // 相反序），否则两段谁在起作用分不出来——换成同向数据这条断言就永远绿。
      // 插入序也与期望序不同，顺带排除"恰好等于写入顺序"。
      await db.upsertCollectionItemAt(c, 'game', 'mm', 0);
      await db.upsertCollectionItemAt(c, 'epub', 'zz', 0);
      await db.upsertCollectionItemAt(c, 'video', 'aa', 0);

      expect(
        await members(db, c),
        <String>['video|aa', 'game|mm', 'epub|zz'],
        reason: 'sortIndex 全碰撞 → 按 entryKey 升序（aa < mm < zz），'
            '与插入序、与 mediaType 序都无关',
      );

      await db.reorderCollectionItems(c, const <CollectionMemberKey>[]);
      expect(await members(db, c), <String>['video|aa', 'game|mm', 'epub|zz'],
          reason: '冻结不改相对顺序');
      expect(await indices(db, c), <int>[0, 1, 2],
          reason: '冻结后 sortIndex 致密，展示序不再依赖并列兜底');
    });

    test('点名了已被并发移出的成员：丢弃该键，其余成员照常重排不越界', () async {
      final db = await _openDb();
      final int c = await seedMixed(db);
      // 页面持有的快照里还有 v2，但 DB 侧已被别处移出。
      await db.removeFromCollection(c, MediaKind.video, 'v2');

      await db.reorderCollectionItems(c, <CollectionMemberKey>[
        (mediaType: 'video', entryKey: 'v3'),
        (mediaType: 'video', entryKey: 'v2'), // 已不在 DB → 丢弃
        (mediaType: 'video', entryKey: 'v1'),
      ]);

      expect(await members(db, c),
          <String>['video|v3', 'game|g1', 'epub|e1', 'video|v1']);
      expect(await indices(db, c), <int>[0, 1, 2, 3]);
    });
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
      'getCollectionItems（BUG-1489 消除 N+1）', () async {
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
    final FushiDatabase db = await _openDb();
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
    final FushiDatabase db = await _openDb();
    final int c = await db.createMediaCollection('C');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addToCollection(c, MediaKind.epub, 'b1');

    await db.removeFromCollectionRaw(c, MediaKind.video.dbValue, 'v1');
    expect((await db.getCollectionItems(c)).map((m) => m.entryKey).toList(),
        <String>['b1']);
  });
}
