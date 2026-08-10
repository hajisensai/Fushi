import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/collection_manifest.dart';
import 'package:fushi/src/sync/collection_sync_engine.dart';
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
///  - fushi/lib/src/sync/collection_sync_engine.dart 发布口 wireEntryKey 改成
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
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: '/tmp/$bookKey.epub',
      extractDir: '/tmp/$bookKey',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1000,
    ));
    return (await db.resolveEpubBookUid(bookKey))!;
  }

  Future<Set<String>> memberKeysOf(
      FushiDatabase db, String name, String type) async {
    final MediaCollectionRow? row =
        await db.getMediaCollectionByNaturalKey(name, type);
    if (row == null) return const <String>{};
    return (await db.getCollectionItems(row.id))
        .map((MediaCollectionItemRow m) => '${m.mediaType}|${m.entryKey}')
        .toSet();
  }

  test('发布口：本地 uid 成员出 wire 变 bookKey；透传行照抄；墓碑 bookKey 域零换算直发', () async {
    final FushiDatabase db = memDb();
    final String uid = await insertBook(db, 'booka-key');
    final int cid =
        await db.createMediaCollection('C', collectionType: 'playlist');
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
    final CollectionManifestEntry entry = manifest.collections
        .singleWhere((CollectionManifestEntry e) => e.name == 'C');

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
            mediaType: 'epub', entryKey: 'bookb-key', sortIndex: 0),
        CollectionManifestMember(
            mediaType: 'epub', entryKey: 'nolocal-key', sortIndex: 1),
        CollectionManifestMember(
            mediaType: 'srt', entryKey: 's2', sortIndex: 2),
      ],
    );
    await applyCollectionLocalChanges(
        db, const CollectionLocalChanges(<CollectionManifestEntry>[entry]));

    expect(
      await memberKeysOf(db, 'C', 'playlist'),
      <String>{'epub|$uidB', 'epub|nolocal-key', 'srt|s2'},
      reason: '本地有书 → uid 行；本地无书 → 照抄 wire bookKey 的透传行'
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
            mediaType: 'epub', entryKey: 'bookb-key', sortIndex: 0),
        CollectionManifestMember(
            mediaType: 'epub', entryKey: 'nolocal-key', sortIndex: 1),
      ],
    );
    await applyCollectionLocalChanges(
        db, const CollectionLocalChanges(<CollectionManifestEntry>[round1]));
    expect(await memberKeysOf(db, 'C', 'playlist'),
        <String>{'epub|$uidB', 'epub|nolocal-key'});

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
                mediaType: 'epub', entryKey: 'bookb-key', sortIndex: 0),
            CollectionManifestMember(
                mediaType: 'epub', entryKey: 'nolocal-key', sortIndex: 1),
            CollectionManifestMember(
                mediaType: 'srt', entryKey: 's3', sortIndex: 2),
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
      reason: 'bookKey 可解析后 desiredKeys 变 uid：diff 删透传 bookKey 行、'
          '插 uid 行，归属收敛（透传行不残留）',
    );
  });
}
