import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/collection_manifest.dart';
import 'package:hibiki/src/sync/collection_sync_engine.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 合集同步引擎收敛性测试（多端库联合视图 §2.3 任务4，spec 任务表「引擎级单测
/// （双库互推收敛）」）。
///
/// 用两个真实内存 [HibikiDatabase]（A/B）+ 一份共享云清单模拟编排器的
/// 读-合并-应用-写循环：`sync(dev)` = loadLocal → merge(基线) → apply → 推清单
/// → 推进基线。全链路覆盖 DAO 墓碑写清、清单构建、引擎裁决、应用端镜像。
void main() {
  late _Device a;
  late _Device b;
  late _Cloud cloud;

  setUp(() {
    a = _Device(HibikiDatabase.forTesting(NativeDatabase.memory()));
    b = _Device(HibikiDatabase.forTesting(NativeDatabase.memory()));
    cloud = _Cloud();
    addTearDown(() async {
      await a.db.close();
      await b.db.close();
    });
  });

  /// 让墙钟前进：基线/墓碑裁决按毫秒比较，步骤之间隔开避免同毫秒歧义。
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 3));

  Future<List<String>> orderOf(HibikiDatabase db, String name,
      [String type = 'playlist']) async {
    final MediaCollectionRow? row =
        await db.getMediaCollectionByNaturalKey(name, type);
    if (row == null) return const <String>[];
    return (await db.getCollectionItems(row.id))
        .map((MediaCollectionItemRow m) => m.entryKey)
        .toList();
  }

  /// 初始收敛态：A 建 playlist S{v1,v2,v3}，双端互推一轮。
  Future<void> seedConverged() async {
    final int c =
        await a.db.createMediaCollection('S', collectionType: 'playlist');
    await a.db.addToCollection(c, 'video', 'v1');
    await a.db.addToCollection(c, 'video', 'v2');
    await a.db.addToCollection(c, 'video', 'v3');
    await tick();
    await a.sync(cloud);
    await b.sync(cloud);
    await tick();
    expect(await orderOf(b.db, 'S'), <String>['v1', 'v2', 'v3']);
  }

  test('A 拖序 B 未动 → B 采 A 序（手动序整合集 LWW）', () async {
    await seedConverged();

    await a.db.reorderCollectionItems(
      (await a.db.getMediaCollectionByNaturalKey('S', 'playlist'))!.id,
      <({String mediaType, String entryKey})>[
        (mediaType: 'video', entryKey: 'v3'),
        (mediaType: 'video', entryKey: 'v1'),
        (mediaType: 'video', entryKey: 'v2'),
      ],
    );
    await tick();
    await a.sync(cloud);
    final int applied = await b.sync(cloud);
    expect(applied, 1, reason: 'B 恰好应用一个合集的变更');
    expect(await orderOf(b.db, 'S'), <String>['v3', 'v1', 'v2'],
        reason: 'orderUpdatedAt 新者整表覆盖 sortIndex');

    // 两端 orderUpdatedAt 镜像一致（B 不得写 now 伪装人为改序）。
    final int atA =
        (await a.db.getMediaCollectionByNaturalKey('S', 'playlist'))!
            .orderUpdatedAt;
    final int atB =
        (await b.db.getMediaCollectionByNaturalKey('S', 'playlist'))!
            .orderUpdatedAt;
    expect(atB, atA);

    // 幂等：再互推一轮，双方零变更、清单字节不变。
    await tick();
    final String before = cloud.manifest.canonicalJson();
    expect(await a.sync(cloud), 0);
    expect(await b.sync(cloud), 0);
    expect(cloud.manifest.canonicalJson(), before);
  });

  test('A 移出成员 → B 不复活（成员墓碑跨端生效）', () async {
    await seedConverged();

    final int cA =
        (await a.db.getMediaCollectionByNaturalKey('S', 'playlist'))!.id;
    await a.db.removeFromCollection(cA, 'video', 'v2');
    await tick();
    await a.sync(cloud);
    await b.sync(cloud);
    expect(await orderOf(b.db, 'S'), <String>['v1', 'v3'],
        reason: 'B 应用移出，不靠 B 自己删');

    // 多轮互推：B 端并集绝不把 v2 加回来（无墓碑就会复活——这就是墓碑存在意义）。
    await tick();
    await b.sync(cloud);
    await a.sync(cloud);
    await b.sync(cloud);
    expect(await orderOf(a.db, 'S'), <String>['v1', 'v3']);
    expect(await orderOf(b.db, 'S'), <String>['v1', 'v3']);
  });

  test('B 重加 → 墓碑清除、成员两端都在', () async {
    await seedConverged();

    // A 移出 v2 并传播到 B。
    final int cA =
        (await a.db.getMediaCollectionByNaturalKey('S', 'playlist'))!.id;
    await a.db.removeFromCollection(cA, 'video', 'v2');
    await tick();
    await a.sync(cloud);
    await b.sync(cloud);
    expect(await orderOf(b.db, 'S'), <String>['v1', 'v3']);

    // B 重加 v2（addToCollection 清 B 本地镜像的墓碑）→ 互推。
    await tick();
    final int cB =
        (await b.db.getMediaCollectionByNaturalKey('S', 'playlist'))!.id;
    await b.db.addToCollection(cB, 'video', 'v2');
    await tick();
    await b.sync(cloud);
    await a.sync(cloud);

    expect(await orderOf(a.db, 'S'), <String>['v1', 'v3', 'v2'],
        reason: 'A 端成员复归（重加胜过已发布的旧墓碑）');
    expect(await orderOf(b.db, 'S'), <String>['v1', 'v3', 'v2']);
    // 墓碑两端 + 云清单全清。
    expect(await a.db.getAllCollectionMemberTombstones(), isEmpty);
    expect(await b.db.getAllCollectionMemberTombstones(), isEmpty);
    final CollectionManifestEntry entry = cloud.manifest.collections
        .firstWhere((CollectionManifestEntry e) => e.name == 'S');
    expect(entry.memberTombstones, isEmpty);
  });

  test('两端各自新建同名合集 → 自然键合一（成员并集，同序收敛）', () async {
    final int cA = await a.db.createMediaCollection('Fav');
    await a.db.addToCollection(cA, 'epub', 'x');
    final int cB = await b.db.createMediaCollection('Fav');
    await b.db.addToCollection(cB, 'epub', 'y');
    await tick();

    await a.sync(cloud);
    await b.sync(cloud);
    await a.sync(cloud);

    expect(await orderOf(a.db, 'Fav', 'collection'), <String>['x', 'y']);
    expect(await orderOf(b.db, 'Fav', 'collection'), <String>['x', 'y'],
        reason: '同名同类型对齐成一个合集，成员并集且两端同序');
    // 各端仍只有一个 Fav。
    expect(
        (await a.db.getAllMediaCollections())
            .where((c) => c.name == 'Fav')
            .length,
        1);
    expect(
        (await b.db.getAllMediaCollections())
            .where((c) => c.name == 'Fav')
            .length,
        1);
  });

  test('合集删除防复活 + 对端重建传播回来', () async {
    await seedConverged();

    // A 删除合集 → 传播到 B（B 端不复活）。
    final int cA =
        (await a.db.getMediaCollectionByNaturalKey('S', 'playlist'))!.id;
    await a.db.deleteMediaCollection(cA);
    await tick();
    await a.sync(cloud);
    await b.sync(cloud);
    expect(await b.db.getMediaCollectionByNaturalKey('S', 'playlist'), isNull,
        reason: '合集级墓碑跨端生效');
    // 多轮互推不复活。
    await tick();
    await b.sync(cloud);
    await a.sync(cloud);
    expect(await a.db.getMediaCollectionByNaturalKey('S', 'playlist'), isNull);

    // B 重建同名合集（createMediaCollection 清本地哨兵）→ 传播回 A。
    await tick();
    final int cB =
        await b.db.createMediaCollection('S', collectionType: 'playlist');
    await b.db.addToCollection(cB, 'video', 'v9');
    await tick();
    await b.sync(cloud);
    await a.sync(cloud);
    expect(await orderOf(a.db, 'S'), <String>['v9'],
        reason: '重建胜过已发布的旧删除墓碑，只带重建后的成员');
  });

  test('移空自删的移出知识进清单：对端不复活刚移出的最后一个成员', () async {
    // A 只有单成员合集；B 端同合集有两个成员。
    final int cA = await a.db.createMediaCollection('Solo');
    await a.db.addToCollection(cA, 'epub', 'x');
    await tick();
    await a.sync(cloud);
    await b.sync(cloud);
    final int cB =
        (await b.db.getMediaCollectionByNaturalKey('Solo', 'collection'))!.id;
    await b.db.addToCollection(cB, 'epub', 'y');
    await tick();
    await b.sync(cloud);
    await a.sync(cloud); // A 收敛到 {x, y}。
    expect(await orderOf(a.db, 'Solo', 'collection'), <String>['x', 'y']);

    // A 移出 x、再移出 y → 移空自删（本地无行，只剩成员墓碑知识）。
    await tick();
    final int cA2 =
        (await a.db.getMediaCollectionByNaturalKey('Solo', 'collection'))!.id;
    await a.db.removeFromCollection(cA2, 'epub', 'x');
    await a.db.removeFromCollection(cA2, 'epub', 'y');
    expect(await a.db.getMediaCollectionByNaturalKey('Solo', 'collection'),
        isNull);
    await tick();
    await a.sync(cloud);
    await b.sync(cloud);
    expect(
        await b.db.getMediaCollectionByNaturalKey('Solo', 'collection'), isNull,
        reason: '两个成员的移出墓碑都传播，B 端合集移空后按本地语义自删');
  });

  test('纯引擎：首次同步（基线 0）一切墓碑皆新闻；旧闻墓碑输给在册成员', () {
    final CollectionManifest local = CollectionManifest(
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'S',
          collectionType: 'playlist',
          members: <CollectionManifestMember>[
            CollectionManifestMember(
                mediaType: 'video', entryKey: 'v1', sortIndex: 0),
          ],
        ),
      ],
    );
    final CollectionManifest remote = CollectionManifest(
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'S',
          collectionType: 'playlist',
          memberTombstones: <CollectionMemberTombstone>[
            CollectionMemberTombstone(
                mediaType: 'video', entryKey: 'v1', removedAt: 500),
          ],
        ),
      ],
    );

    // 基线 0：removedAt=500 是没见过的新闻 → 移出生效。
    final CollectionSyncOutcome fresh = CollectionSyncEngine.merge(
        local: local, remote: remote, lastSyncedAtMs: 0);
    expect(fresh.merged.collections.single.members, isEmpty);
    expect(fresh.merged.collections.single.memberTombstones, hasLength(1));

    // 基线 1000 > 500：本端见过并裁决过，成员仍在 = 之后重加 → 成员胜、墓碑清。
    final CollectionSyncOutcome seen = CollectionSyncEngine.merge(
        local: local, remote: remote, lastSyncedAtMs: 1000);
    expect(seen.merged.collections.single.members, hasLength(1));
    expect(seen.merged.collections.single.memberTombstones, isEmpty);
    expect(seen.changes.isEmpty, isTrue, reason: '本地已是目标态，零变更');
  });
}

/// 共享云清单（模拟 `__collections__/collections.json`）。
class _Cloud {
  CollectionManifest manifest = CollectionManifest.empty;
}

/// 模拟一台设备：真实内存 DB + 因果基线，[sync] 复刻编排器的合集阶段。
class _Device {
  _Device(this.db);

  final HibikiDatabase db;
  int baselineMs = 0;

  /// 读本地 → 合并 → 应用本地变更 → 推合并清单 → 推进基线。返回应用的合集数。
  Future<int> sync(_Cloud cloud) async {
    final CollectionManifest local = await loadLocalCollectionManifest(db);
    final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
      local: local,
      remote: cloud.manifest,
      lastSyncedAtMs: baselineMs,
    );
    final int applied = await applyCollectionLocalChanges(db, outcome.changes);
    cloud.manifest = outcome.merged;
    baselineMs = DateTime.now().millisecondsSinceEpoch;
    return applied;
  }
}
