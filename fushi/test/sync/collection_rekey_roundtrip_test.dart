import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';
import 'package:fushi_core/fushi_core.dart';

/// v83 合集同步换算口 roundtrip 测试（data-layer-stage2-plan.md §5/§6 缺口 3）。
///
/// wire 冻结面：清单里 epub 成员 entryKey **恒为 bookKey**；成员表本地面貌
/// v83 起是 epub_books.uid（本地书）/ 对端 bookKey 照抄（透传行）。换算只许
/// 出现在两个口：
///  - 发布 [loadLocalCollectionManifest]：uid → bookKey（查不上照抄=透传行闭环）；
///  - 落地 [applyCollectionLocalChanges]：bookKey → uid（查不上**照抄透传绝不
///    丢弃**——清单是跨端 union，本机没这本书也要替对端转发其归属）。
/// 引擎纯函数 [CollectionSyncEngine.merge] 保持纯 wire 域，对键值不解引用。
///
/// 变异实测（2026-08-10，临时破坏 lib 后确认转红、已还原，零 lib 残留）：
///  - packages/fushi_engine/lib/sync/collection_sync_engine.dart 发布口 wireEntryKey 改成
///    恒等透传（丢 uid→bookKey 换算）→ 发布用例红：wire 出现 uid、bookKey 缺席；
///  - 同文件落地口 localEntryKey 改成恒等透传（丢 bookKey→uid 换算）→ 落地
///    用例红（成员落成 bookKey 行）+ 收敛用例红（bookKey 行不收敛成 uid 行）。
void main() {
  FushiDatabase memDb() {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Future<String> insertBook(FushiDatabase db, String bookKey) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: '/tmp/$bookKey.epub',
        extractDir: '/tmp/$bookKey',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
      ),
    );
    return (await db.resolveEpubBookUid(bookKey))!;
  }

  Future<Set<String>> memberKeysOf(
    FushiDatabase db,
    String name,
    String type,
  ) async {
    final MediaCollectionRow? row = await db.getMediaCollectionByNaturalKey(
      name,
      type,
    );
    if (row == null) return const <String>{};
    return (await db.getCollectionItems(row.id))
        .map((MediaCollectionItemRow m) => '${m.mediaType}|${m.entryKey}')
        .toSet();
  }

  test('发布口：本地 uid 成员出 wire 变 bookKey；透传行照抄；墓碑 bookKey 域零换算直发', () async {
    final FushiDatabase db = memDb();
    final String uid = await insertBook(db, 'booka-key');
    final int cid = await db.createMediaCollection(
      'C',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.epub, uid); // 本地书 = uid 行
    await db.addToCollection(cid, MediaKind.epub, 'remote-only-key'); // 透传行
    await db.addToCollection(cid, MediaKind.srt, 's1'); // 非 epub 域
    // 墓碑冻结在 bookKey 域（= wire 域）：按拍板契约直接以 bookKey 落墓碑行。
    await db.upsertCollectionMemberTombstone(
      collectionName: 'C',
      collectionType: 'playlist',
      mediaType: 'epub',
      entryKey: 'removed-book-key',
      deletedAt: 111,
    );

    final CollectionManifest manifest = await loadLocalCollectionManifest(db);
    final CollectionManifestEntry entry = manifest.collections.singleWhere(
      (CollectionManifestEntry e) => e.name == 'C',
    );

    expect(
      entry.members
          .map((CollectionManifestMember m) => '${m.mediaType}|${m.entryKey}')
          .toList(),
      <String>['epub|booka-key', 'epub|remote-only-key', 'srt|s1'],
      reason: 'wire 冻结面：本地 uid 行出 wire 换回 bookKey；透传行/srt 照抄',
    );
    expect(
      entry.members.any((CollectionManifestMember m) => m.entryKey == uid),
      isFalse,
      reason: '本机局域 uid 绝不泄漏进 wire（对端无法解引用）',
    );
    expect(
      entry.memberTombstones
          .map((CollectionMemberTombstone t) => t.entryKey)
          .toList(),
      <String>['removed-book-key'],
      reason: '墓碑 entryKey 冻结在 bookKey 域，出 wire 零换算',
    );
  });

  test('落地口：wire bookKey 进来换 uid；本地无书照抄透传（绝不丢弃）', () async {
    final FushiDatabase db = memDb();
    final String uidB = await insertBook(db, 'bookb-key');

    const CollectionManifestEntry entry = CollectionManifestEntry(
      name: 'C',
      collectionType: 'playlist',
      orderUpdatedAt: 10,
      members: <CollectionManifestMember>[
        CollectionManifestMember(
          mediaType: 'epub',
          entryKey: 'bookb-key',
          sortIndex: 0,
        ),
        CollectionManifestMember(
          mediaType: 'epub',
          entryKey: 'nolocal-key',
          sortIndex: 1,
        ),
        CollectionManifestMember(
          mediaType: 'srt',
          entryKey: 's2',
          sortIndex: 2,
        ),
      ],
    );
    await applyCollectionLocalChanges(
      db,
      const CollectionLocalChanges(<CollectionManifestEntry>[entry]),
    );

    expect(
      await memberKeysOf(db, 'C', 'playlist'),
      <String>{'epub|$uidB', 'epub|nolocal-key', 'srt|s2'},
      reason:
          '本地有书 → uid 行；本地无书 → 照抄 wire bookKey 的透传行'
          '（union 语义：替对端转发本机没有的书的归属，不得丢弃）',
    );
  });

  test('收敛：书下载落地后，下一轮 apply 把透传 bookKey 行 diff 成 uid 行', () async {
    final FushiDatabase db = memDb();
    final String uidB = await insertBook(db, 'bookb-key');
    // 第一轮落地：'nolocal-key' 当时无本地书 → 透传行。
    const CollectionManifestEntry round1 = CollectionManifestEntry(
      name: 'C',
      collectionType: 'playlist',
      orderUpdatedAt: 10,
      members: <CollectionManifestMember>[
        CollectionManifestMember(
          mediaType: 'epub',
          entryKey: 'bookb-key',
          sortIndex: 0,
        ),
        CollectionManifestMember(
          mediaType: 'epub',
          entryKey: 'nolocal-key',
          sortIndex: 1,
        ),
      ],
    );
    await applyCollectionLocalChanges(
      db,
      const CollectionLocalChanges(<CollectionManifestEntry>[round1]),
    );
    expect(await memberKeysOf(db, 'C', 'playlist'), <String>{
      'epub|$uidB',
      'epub|nolocal-key',
    });

    // 「下载落地」：这本书现在有本地行（新 uid）。
    final String uidN = await insertBook(db, 'nolocal-key');

    // 下一轮真实路径：发布本地快照（透传行照抄出 wire）→ 与远端合并（远端多一个
    // srt 成员触发 reconcile；没有差异就没有 apply，收敛发生在下一次真实调和时，
    // 这正是「diff 收敛、无需专用改键」的机制语义）→ 落地。
    final CollectionManifest local = await loadLocalCollectionManifest(db);
    const CollectionManifest remote = CollectionManifest(
      collections: <CollectionManifestEntry>[
        CollectionManifestEntry(
          name: 'C',
          collectionType: 'playlist',
          orderUpdatedAt: 10,
          members: <CollectionManifestMember>[
            CollectionManifestMember(
              mediaType: 'epub',
              entryKey: 'bookb-key',
              sortIndex: 0,
            ),
            CollectionManifestMember(
              mediaType: 'epub',
              entryKey: 'nolocal-key',
              sortIndex: 1,
            ),
            CollectionManifestMember(
              mediaType: 'srt',
              entryKey: 's3',
              sortIndex: 2,
            ),
          ],
        ),
      ],
    );
    final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
      local: local,
      remote: remote,
      lastSyncedAtMs: 0,
    );
    expect(outcome.changes.isEmpty, isFalse, reason: '远端新增成员触发本地调和（收敛的载体）');
    await applyCollectionLocalChanges(db, outcome.changes);

    expect(
      await memberKeysOf(db, 'C', 'playlist'),
      <String>{'epub|$uidB', 'epub|$uidN', 'srt|s3'},
      reason:
          'bookKey 可解析后 desiredKeys 变 uid：diff 删透传 bookKey 行、'
          '插 uid 行，归属收敛（透传行不残留）',
    );
  });

  test('合集先到书后到：insertEpubBook 立即把透传 bookKey 与 cover_source 升格为 uid', () async {
    final FushiDatabase db = memDb();
    const CollectionManifestEntry initial = CollectionManifestEntry(
      name: '川端康成',
      collectionType: 'collection',
      members: <CollectionManifestMember>[
        CollectionManifestMember(
          mediaType: 'epub',
          entryKey: '雪国',
          sortIndex: 0,
          pinned: true,
        ),
        CollectionManifestMember(
          mediaType: 'epub',
          entryKey: '古都',
          sortIndex: 1,
          pinned: false,
        ),
      ],
    );
    await applyCollectionLocalChanges(
      db,
      const CollectionLocalChanges(<CollectionManifestEntry>[initial]),
    );
    final int cid = (await db.getMediaCollectionByNaturalKey(
      '川端康成',
      'collection',
    ))!.id;
    await db.updateMediaCollectionCover(cid, 'epub|雪国');

    // 书籍后到：不再触发下一轮合集变更，仅插入书。
    final String uidYukiguni = await insertBook(db, '雪国');
    final String uidKoto = await insertBook(db, '古都');

    final List<MediaCollectionItemRow> items = await db.getCollectionItems(cid);
    expect(
      items.map((MediaCollectionItemRow m) => m.entryKey).toList(),
      <String>[uidYukiguni, uidKoto],
    );
    expect(
      items.map((MediaCollectionItemRow m) => m.pinnedByUser).toList(),
      <bool>[true, false],
    );
    expect(
      (await db.getMediaCollectionById(cid))!.coverSource,
      'epub|$uidYukiguni',
    );

    final Map<String, int> primary = await db.getPrimaryCollectionIdByEntry();
    expect(primary['epub|$uidYukiguni'], cid);
    expect(primary['epub|$uidKoto'], cid);

    final CollectionManifest manifest = await loadLocalCollectionManifest(db);
    final CollectionManifestEntry exported = manifest.collections.singleWhere(
      (CollectionManifestEntry e) => e.name == '川端康成',
    );
    expect(
      exported.members.map((CollectionManifestMember m) => m.entryKey).toList(),
      <String>['雪国', '古都'],
    );
    expect(
      exported.members.map((CollectionManifestMember m) => m.pinned).toList(),
      <bool>[true, false],
    );
  });

  test('reconcileEpubCollectionMemberKeys 收敛存量滞留透传行与双行重复并保持幂等', () async {
    final FushiDatabase db = memDb();
    final String uid1 = await insertBook(db, '巻１');
    final String uid2 = await insertBook(db, '巻２');
    final int cid = await db.createMediaCollection(
      '全集',
      collectionType: 'playlist',
    );
    // 刻意构造升级前存量脏态：巻１ 同时有 uid 与 bookKey（且 pinned 在旧行上），
    // 巻２ 只有滞留 bookKey，另含本机不存在的远端透传行。
    await db.addToCollection(cid, MediaKind.epub, uid1, userIntent: false);
    await db.addToCollection(cid, MediaKind.epub, '巻１', userIntent: true);
    await db.addToCollection(cid, MediaKind.epub, '巻２', userIntent: false);
    await db.addToCollection(
      cid,
      MediaKind.epub,
      'remote-only-key',
      userIntent: false,
    );
    await db.updateMediaCollectionCover(cid, 'epub|巻２');

    final int repaired = await db.reconcileEpubCollectionMemberKeys();
    expect(repaired, 2);

    final List<MediaCollectionItemRow> items = await db.getCollectionItems(cid);
    expect(
      items.map((MediaCollectionItemRow m) => m.entryKey).toSet(),
      <String>{uid1, uid2, 'remote-only-key'},
    );
    expect(items, hasLength(3));
    expect(
      items
          .firstWhere((MediaCollectionItemRow m) => m.entryKey == uid1)
          .pinnedByUser,
      isTrue,
    );
    expect((await db.getMediaCollectionById(cid))!.coverSource, 'epub|$uid2');

    // 稳态幂等：再跑返回 0。
    expect(await db.reconcileEpubCollectionMemberKeys(), 0);
  });

  test('addToCollection 用 uid 加书时吸收同合集内的旧 bookKey 透传行，不产生重复', () async {
    final FushiDatabase db = memDb();
    final String uid = await insertBook(db, '特典');
    final int cid = await db.createMediaCollection(
      'あそびのかんけい',
      collectionType: 'collection',
    );
    await db.addToCollection(cid, MediaKind.epub, '特典', userIntent: true);

    await db.addToCollection(cid, MediaKind.epub, uid, userIntent: false);

    final List<MediaCollectionItemRow> items = await db.getCollectionItems(cid);
    expect(
      items.map((MediaCollectionItemRow m) => m.entryKey).toList(),
      <String>[uid],
    );
    expect(items.single.pinnedByUser, isTrue);
  });

  test('setCollectionBookAlias 落地远端键别名时立即升格合集内对应透传行', () async {
    final FushiDatabase db = memDb();
    const CollectionManifestEntry entry = CollectionManifestEntry(
      name: 'C',
      collectionType: 'collection',
      members: <CollectionManifestMember>[
        CollectionManifestMember(
          mediaType: 'epub',
          entryKey: 'RemoteKey(2)',
          sortIndex: 0,
          pinned: true,
        ),
      ],
    );
    await applyCollectionLocalChanges(
      db,
      const CollectionLocalChanges(<CollectionManifestEntry>[entry]),
    );
    final String uid = await insertBook(db, 'RemoteKey');
    await db.setCollectionBookAlias(uid, 'RemoteKey(2)');

    final List<MediaCollectionItemRow> items = await db.getCollectionItems(
      (await db.getMediaCollectionByNaturalKey('C', 'collection'))!.id,
    );
    expect(
      items.map((MediaCollectionItemRow m) => m.entryKey).toList(),
      <String>[uid],
    );
    expect(items.single.pinnedByUser, isTrue);
  });
}
