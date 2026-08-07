import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/collection_manifest.dart';
import 'package:fushi/src/sync/collection_sync_engine.dart';
import 'package:fushi_core/fushi_core.dart';

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
    await a.db.addToCollection(c, MediaKind.video, 'v1');
    await a.db.addToCollection(c, MediaKind.video, 'v2');
    await a.db.addToCollection(c, MediaKind.video, 'v3');
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
    await a.db.removeFromCollection(cA, MediaKind.video, 'v2');
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
    await a.db.removeFromCollection(cA, MediaKind.video, 'v2');
    await tick();
    await a.sync(cloud);
    await b.sync(cloud);
    expect(await orderOf(b.db, 'S'), <String>['v1', 'v3']);

    // B 重加 v2（addToCollection 清 B 本地镜像的墓碑）→ 互推。
    await tick();
    final int cB =
        (await b.db.getMediaCollectionByNaturalKey('S', 'playlist'))!.id;
    await b.db.addToCollection(cB, MediaKind.video, 'v2');
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
    await a.db.addToCollection(cA, MediaKind.epub, 'x');
    final int cB = await b.db.createMediaCollection('Fav');
    await b.db.addToCollection(cB, MediaKind.epub, 'y');
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
    await b.db.addToCollection(cB, MediaKind.video, 'v9');
    await tick();
    await b.sync(cloud);
    await a.sync(cloud);
    expect(await orderOf(a.db, 'S'), <String>['v9'],
        reason: '重建胜过已发布的旧删除墓碑，只带重建后的成员');
  });

  test('移空自删的移出知识进清单：对端不复活刚移出的最后一个成员', () async {
    // A 只有单成员合集；B 端同合集有两个成员。
    final int cA = await a.db.createMediaCollection('Solo');
    await a.db.addToCollection(cA, MediaKind.epub, 'x');
    await tick();
    await a.sync(cloud);
    await b.sync(cloud);
    final int cB =
        (await b.db.getMediaCollectionByNaturalKey('Solo', 'collection'))!.id;
    await b.db.addToCollection(cB, MediaKind.epub, 'y');
    await tick();
    await b.sync(cloud);
    await a.sync(cloud); // A 收敛到 {x, y}。
    expect(await orderOf(a.db, 'Solo', 'collection'), <String>['x', 'y']);

    // A 移出 x、再移出 y → 移空自删（本地无行，只剩成员墓碑知识）。
    await tick();
    final int cA2 =
        (await a.db.getMediaCollectionByNaturalKey('Solo', 'collection'))!.id;
    await a.db.removeFromCollection(cA2, MediaKind.epub, 'x');
    await a.db.removeFromCollection(cA2, MediaKind.epub, 'y');
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

  // ── finding 2：对端墓碑用 publishedAt（非 removedAt）对比本端基线判新旧 ──────
  test('finding2 因果修复：对端上线后发布的旧 removedAt 墓碑仍是新闻，成员不复活', () {
    // 本端 B：成员 M 活着，基线=150（B 在 t=150 同步过一轮）。
    final CollectionManifest bLocal = CollectionManifest(
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'S',
          collectionType: 'playlist',
          members: <CollectionManifestMember>[
            CollectionManifestMember(
                mediaType: 'video', entryKey: 'M', sortIndex: 0),
          ],
        ),
      ],
    );
    // 对端 A 离线时于 t1=100 移出 M（removedAt=100），上线后于 t=200 才发布
    // （publishedAt=200）——removedAt 早于 B 基线 150，但 publishedAt 晚于 150。
    final CollectionManifest sharedPublished = CollectionManifest(
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'S',
          collectionType: 'playlist',
          memberTombstones: <CollectionMemberTombstone>[
            CollectionMemberTombstone(
                mediaType: 'video',
                entryKey: 'M',
                removedAt: 100,
                publishedAt: 200),
          ],
        ),
      ],
    );

    // 修复后：对端用 publishedAt=200 > 基线150 ⇒ 新闻 ⇒ M 移出（不复活）。
    final CollectionSyncOutcome fixed = CollectionSyncEngine.merge(
        local: bLocal, remote: sharedPublished, lastSyncedAtMs: 150);
    expect(fixed.merged.collections.single.members, isEmpty,
        reason: 'publishedAt 判新旧：上线后发布的墓碑对 B 是新闻，M 不复活');
    expect(fixed.merged.collections.single.memberTombstones, hasLength(1));

    // 旧清单兼容：无 publishedAt 时回退 removedAt=100 <= 基线150 ⇒ 旧闻 ⇒ 保留旧行为。
    final CollectionManifest sharedLegacy = CollectionManifest(
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'S',
          collectionType: 'playlist',
          memberTombstones: <CollectionMemberTombstone>[
            CollectionMemberTombstone(
                mediaType: 'video', entryKey: 'M', removedAt: 100),
          ],
        ),
      ],
    );
    final CollectionSyncOutcome legacy = CollectionSyncEngine.merge(
        local: bLocal, remote: sharedLegacy, lastSyncedAtMs: 150);
    expect(legacy.merged.collections.single.members, hasLength(1),
        reason: '旧清单无 publishedAt 回退 removedAt，行为不变（向后兼容）');

    // 已见过的发布（publishedAt=100 <= 基线150）：真·旧闻 ⇒ 成员是之后重加 ⇒ 保留。
    final CollectionManifest seen = CollectionManifest(
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'S',
          collectionType: 'playlist',
          memberTombstones: <CollectionMemberTombstone>[
            CollectionMemberTombstone(
                mediaType: 'video',
                entryKey: 'M',
                removedAt: 80,
                publishedAt: 100),
          ],
        ),
      ],
    );
    final CollectionSyncOutcome seenOutcome = CollectionSyncEngine.merge(
        local: bLocal, remote: seen, lastSyncedAtMs: 150);
    expect(seenOutcome.merged.collections.single.members, hasLength(1),
        reason: 'publishedAt<=基线：本端已见过，成员在=重加胜');
  });

  test('finding2 发布盖戳：本端新造墓碑写进合并结果时盖 publishedAt=now', () {
    final CollectionManifest local = CollectionManifest(
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'S',
          collectionType: 'playlist',
          memberTombstones: <CollectionMemberTombstone>[
            CollectionMemberTombstone(
                mediaType: 'video', entryKey: 'M', removedAt: 500),
          ],
        ),
      ],
    );
    final CollectionSyncOutcome out = CollectionSyncEngine.merge(
      local: local,
      remote: CollectionManifest.empty,
      lastSyncedAtMs: 0,
      nowMs: 9999,
    );
    expect(
        out.merged.collections.single.memberTombstones.single.publishedAt, 9999,
        reason: '远端清单不含该墓碑 → 本端首次发布 → 盖 now');
    // 幂等：把发布结果当远端再合，publishedAt 保持 9999，不重盖。
    final CollectionSyncOutcome again = CollectionSyncEngine.merge(
      local: local,
      remote: out.merged,
      lastSyncedAtMs: 0,
      nowMs: 12345,
    );
    expect(again.merged.collections.single.memberTombstones.single.publishedAt,
        9999,
        reason: '已发布戳保真，不被后续 now 重盖（幂等）');
  });

  // ── finding 12：负 removedAt 参与 max 比较不崩（历史 `(lt ?? -1)!` 空断言崩溃）──
  test('finding12 两侧同键墓碑 + 一侧极端值：merge 不抛（显式 null 展开）', () {
    final CollectionManifest a = CollectionManifest(
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'S',
          collectionType: 'playlist',
          memberTombstones: <CollectionMemberTombstone>[
            CollectionMemberTombstone(
                mediaType: 'video', entryKey: 'M', removedAt: 0),
          ],
        ),
      ],
    );
    final CollectionManifest b = CollectionManifest(
      collections: <CollectionManifestEntry>[
        const CollectionManifestEntry(
          name: 'S',
          collectionType: 'playlist',
          memberTombstones: <CollectionMemberTombstone>[
            CollectionMemberTombstone(
                mediaType: 'video', entryKey: 'M', removedAt: 10),
          ],
        ),
      ],
    );
    // 两侧都无成员、都有 M 墓碑 → 走 _mergeTomb（历史 `(lt ?? -1) > (rt ?? -1) ? lt! : rt!`
    // 在一侧墓碑缺失 + 另一侧值 <= -1 时 `!` 崩）。这里断言合并正常、removedAt 取较大。
    final CollectionSyncOutcome out =
        CollectionSyncEngine.merge(local: a, remote: b, lastSyncedAtMs: 0);
    expect(out.merged.collections.single.memberTombstones.single.removedAt, 10);
  });

  // ── finding 3：改名后双库互推不产生旧名副本 ───────────────────────────────
  test('finding3 改名：旧名写删除墓碑跨端生效，全网不留旧名副本', () async {
    await seedConverged(); // A/B 收敛于 playlist S{v1,v2,v3}。

    // A 把 S 改名为 S2。
    final int cA =
        (await a.db.getMediaCollectionByNaturalKey('S', 'playlist'))!.id;
    await a.db.renameMediaCollection(cA, 'S2');
    await tick();
    await a.sync(cloud);
    await b.sync(cloud);

    // B 端：旧名 S 被删除墓碑清掉，新名 S2 带原成员。
    expect(await b.db.getMediaCollectionByNaturalKey('S', 'playlist'), isNull,
        reason: '旧名副本被合集级墓碑跨端删除');
    expect(await orderOf(b.db, 'S2'), <String>['v1', 'v2', 'v3'],
        reason: '新名带原成员');

    // 多轮互推：旧名绝不复活（这就是给旧自然键写墓碑的意义）。
    await tick();
    await b.sync(cloud);
    await a.sync(cloud);
    await b.sync(cloud);
    expect(await a.db.getMediaCollectionByNaturalKey('S', 'playlist'), isNull);
    expect(await b.db.getMediaCollectionByNaturalKey('S', 'playlist'), isNull);
    expect(await orderOf(a.db, 'S2'), <String>['v1', 'v2', 'v3']);
  });

  // ── finding 6：createMediaCollection 自然键幂等，不造重复行 ─────────────────
  test('finding6 createMediaCollection 同名复用已有行（不造重复自然键行）', () async {
    final int id1 = await a.db.createMediaCollection('Dup');
    final int id2 = await a.db.createMediaCollection('Dup');
    expect(id2, id1, reason: '同 (name,type) 复用已有 id');
    expect(
        (await a.db.getAllMediaCollections())
            .where((c) => c.name == 'Dup')
            .length,
        1,
        reason: '绝不再造重复自然键行');
    // 不同 collectionType 不算重复。
    final int id3 =
        await a.db.createMediaCollection('Dup', collectionType: 'playlist');
    expect(id3, isNot(id1));
  });

  // ── finding 1：combinePeers 折叠按文件级 lastWrittenAt 裁决墓碑（非本端基线）─────
  group('finding1 combinePeers uses file lastWrittenAt', () {
    CollectionManifest tombFile(int lwt, {int pub = 100}) => CollectionManifest(
          lastWrittenAt: lwt,
          collections: <CollectionManifestEntry>[
            CollectionManifestEntry(
              name: 'S',
              collectionType: 'playlist',
              memberTombstones: <CollectionMemberTombstone>[
                CollectionMemberTombstone(
                    mediaType: 'video',
                    entryKey: 'm',
                    removedAt: pub,
                    publishedAt: pub),
              ],
            ),
          ],
        );
    CollectionManifest aliveFile(int lwt) => CollectionManifest(
          lastWrittenAt: lwt,
          collections: <CollectionManifestEntry>[
            const CollectionManifestEntry(
              name: 'S',
              collectionType: 'playlist',
              members: <CollectionManifestMember>[
                CollectionManifestMember(
                    mediaType: 'video', entryKey: 'm', sortIndex: 0),
              ],
            ),
          ],
        );

    test('stale peer alive member loses to a newer published tombstone', () {
      // 墓碑文件 pub=100/lwt=100；活成员文件更旧（lwt=50）——陈旧，墓碑默认获胜。
      final CollectionManifest union =
          CollectionSyncEngine.combinePeers(<CollectionManifest>[
        tombFile(100),
        aliveFile(50),
      ]);
      final CollectionManifestEntry e = union.collections.single;
      expect(e.members, isEmpty,
          reason: '陈旧文件(lwt=50)的活成员输给已发布墓碑(pub=100)——不复活');
      expect(e.memberTombstones, hasLength(1));
    });

    test('fresher peer alive member (re-add after tombstone) wins', () {
      // 活成员文件 lwt=200 > 墓碑 pub=100 ⇒「看过墓碑后的有意重加」，成员胜、墓碑清。
      final CollectionManifest union =
          CollectionSyncEngine.combinePeers(<CollectionManifest>[
        tombFile(100),
        aliveFile(200),
      ]);
      final CollectionManifestEntry e = union.collections.single;
      expect(e.members.map((CollectionManifestMember m) => m.entryKey).toList(),
          <String>['m'],
          reason: '文件晚于墓碑 = 有意重加胜');
      expect(e.memberTombstones, isEmpty);
    });

    test('legacy file (no lastWrittenAt = 0) alive member is always stale', () {
      // 旧文件缺 lastWrittenAt 解码为 0：其活成员恒陈旧，输给任何已发布墓碑。
      final CollectionManifest legacyAlive = CollectionManifest(
        // 不设 lastWrittenAt → 默认 0。
        collections: <CollectionManifestEntry>[
          const CollectionManifestEntry(
            name: 'S',
            collectionType: 'playlist',
            members: <CollectionManifestMember>[
              CollectionManifestMember(
                  mediaType: 'video', entryKey: 'm', sortIndex: 0),
            ],
          ),
        ],
      );
      final CollectionManifest union = CollectionSyncEngine.combinePeers(
          <CollectionManifest>[tombFile(1), legacyAlive]);
      expect(union.collections.single.members, isEmpty,
          reason: '旧文件(lwt=0)活成员恒陈旧，墓碑胜');
    });

    test(
        'fold is order-independent (max/min aggregation + canonical tie-break)',
        () {
      final CollectionManifest ab =
          CollectionSyncEngine.combinePeers(<CollectionManifest>[
        tombFile(100),
        aliveFile(200),
      ]);
      final CollectionManifest ba =
          CollectionSyncEngine.combinePeers(<CollectionManifest>[
        aliveFile(200),
        tombFile(100),
      ]);
      expect(ab.canonicalJson(), ba.canonicalJson(), reason: '折叠对顺序不变（收敛前提）');
    });
  });

  // ── collection-tags Task 8：tagNames 全触点透传 + 双活并集（只增不删）──────────
  test('tagNames union across two devices (add-only)', () {
    const CollectionManifest local =
        CollectionManifest(collections: <CollectionManifestEntry>[
      CollectionManifestEntry(
        name: 'C',
        collectionType: 'collection',
        members: <CollectionManifestMember>[
          CollectionManifestMember(
              mediaType: 'video', entryKey: 'u1', sortIndex: 0),
        ],
        tagNames: <String>['a'],
      ),
    ]);
    const CollectionManifest remote =
        CollectionManifest(collections: <CollectionManifestEntry>[
      CollectionManifestEntry(
        name: 'C',
        collectionType: 'collection',
        members: <CollectionManifestMember>[
          CollectionManifestMember(
              mediaType: 'video', entryKey: 'u1', sortIndex: 0),
        ],
        tagNames: <String>['b'],
      ),
    ]);
    final CollectionSyncOutcome out = CollectionSyncEngine.merge(
      local: local,
      remote: remote,
      lastSyncedAtMs: 0,
      nowMs: 1000,
    );
    final CollectionManifestEntry merged = out.merged.collections.single;
    expect(merged.tagNames, <String>['a', 'b'], reason: '双活分支两端标签并集（确定性排序）');
  });

  test('combinePeers unions tagNames across folded peer files', () {
    const CollectionManifest peerA = CollectionManifest(
        lastWrittenAt: 100,
        collections: <CollectionManifestEntry>[
          CollectionManifestEntry(
            name: 'C',
            collectionType: 'collection',
            members: <CollectionManifestMember>[
              CollectionManifestMember(
                  mediaType: 'video', entryKey: 'u1', sortIndex: 0),
            ],
            tagNames: <String>['alpha', 'zebra'],
          ),
        ]);
    const CollectionManifest peerB = CollectionManifest(
        lastWrittenAt: 200,
        collections: <CollectionManifestEntry>[
          CollectionManifestEntry(
            name: 'C',
            collectionType: 'collection',
            members: <CollectionManifestMember>[
              CollectionManifestMember(
                  mediaType: 'video', entryKey: 'u1', sortIndex: 0),
            ],
            tagNames: <String>['mid'],
          ),
        ]);
    final CollectionManifest union =
        CollectionSyncEngine.combinePeers(<CollectionManifest>[peerA, peerB]);
    expect(union.collections.single.tagNames, <String>['alpha', 'mid', 'zebra'],
        reason: '折叠多端清单时活分支标签并集');
  });

  test('tagNames survive _stampEntry rebuild when stamping tombstones', () {
    // 单侧活条目：带标签 + 未发布成员墓碑 → merge 走 l.toEntry() 再经 _stampEntry
    // 盖 publishedAt。_stampEntry 重建整个 entry，必须透传 tagNames（否则丢标签）。
    const CollectionManifest local =
        CollectionManifest(collections: <CollectionManifestEntry>[
      CollectionManifestEntry(
        name: 'C',
        collectionType: 'collection',
        members: <CollectionManifestMember>[
          CollectionManifestMember(
              mediaType: 'video', entryKey: 'u1', sortIndex: 0),
        ],
        memberTombstones: <CollectionMemberTombstone>[
          CollectionMemberTombstone(
              mediaType: 'video', entryKey: 'gone', removedAt: 500),
        ],
        tagNames: <String>['keepme'],
      ),
    ]);
    final CollectionSyncOutcome out = CollectionSyncEngine.merge(
      local: local,
      remote: CollectionManifest.empty,
      lastSyncedAtMs: 0,
      nowMs: 9999,
    );
    final CollectionManifestEntry merged = out.merged.collections.single;
    expect(merged.memberTombstones.single.publishedAt, 9999,
        reason: '未发布墓碑经 _stampEntry 盖 now');
    expect(merged.tagNames, <String>['keepme'],
        reason: '_stampEntry 重建 entry 时透传 tagNames，不丢标签');
  });

  // ── collection-tags Task 9：DB ↔ 清单标签物化（load 读标签 / apply 写标签）──────
  test('load reads collection tags; apply materializes them', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int cid =
        await db.createMediaCollection('C', collectionType: 'collection');
    await db.addToCollection(cid, MediaKind.video, 'u1');
    final int t = await db.createTag('日语', 0xFF0000FF);
    await db.addTagToCollection(cid, t);

    final CollectionManifest manifest = await loadLocalCollectionManifest(db);
    expect(manifest.collections.single.tagNames, <String>['日语'],
        reason: 'load 从 DB 读合集标签进清单');

    // 反向：清单里带一个本地没有的标签，apply 应物化到 DB。
    final HibikiDatabase db2 =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    final int cid2 =
        await db2.createMediaCollection('C', collectionType: 'collection');
    await db2.addToCollection(cid2, MediaKind.video, 'u1');
    await applyCollectionLocalChanges(
      db2,
      const CollectionLocalChanges(<CollectionManifestEntry>[
        CollectionManifestEntry(
          name: 'C',
          collectionType: 'collection',
          members: <CollectionManifestMember>[
            CollectionManifestMember(
                mediaType: 'video', entryKey: 'u1', sortIndex: 0),
          ],
          tagNames: <String>['N1'],
        ),
      ]),
    );
    final List<BookTagRow> tags = await db2.getTagsForCollection(cid2);
    expect(tags.map((BookTagRow t) => t.name), contains('N1'),
        reason: 'apply 把清单标签物化到 DB（getOrCreate + addTagToCollection）');
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
