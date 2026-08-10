import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v83 墓碑键域契约（端到端）：成员行 epub 键 = 本机 uid，而成员移出墓碑
/// **冻结在 bookKey 域**（= wire 域，跨端可比）。写墓碑经
/// `_tombstoneEntryKeyOf` 反查归一；清墓碑（重新加入）同键域。
/// 缺口血统：Stage 2 初版 removeFromCollectionRaw 直落 uid 域墓碑 → 本机
/// uid 泄漏出 wire、对端匹配不上（移出不传播 + 本端下轮并集复活）。
///
/// 变异实测（2026-08-10）：把 `_tombstoneEntryKeyOf` 改为恒等返回 entryKey
/// → 本文件两用例齐红（墓碑键 = uid 域）；还原后绿。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('移出 uid 键 epub 成员 → 墓碑落 bookKey 域；重新加入按同域清除', () async {
    const String bookKey = 'my book';
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: 'My Book',
      epubPath: '/x/my-book.epub',
      extractDir: '/x/my-book',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1000,
    ));
    final String uid = (await db.resolveEpubBookUid(bookKey))!;
    final int cid = await db.createMediaCollection('C');
    await db.addToCollection(cid, MediaKind.epub, uid);

    await db.removeFromCollection(cid, MediaKind.epub, uid);

    final List<CollectionMemberTombstoneRow> tombs =
        await db.getAllCollectionMemberTombstones();
    final CollectionMemberTombstoneRow memberTomb = tombs
        .singleWhere((CollectionMemberTombstoneRow t) => t.entryKey.isNotEmpty);
    expect(memberTomb.entryKey, bookKey,
        reason: '墓碑必须落 bookKey 域（wire 可比），不得泄漏本机 uid');
    expect(memberTomb.entryKey, isNot(uid));

    // 重新加入（uid 键）→ 同域归一清墓碑，防「加回来了墓碑还在」误删。
    final int cid2 = await db.createMediaCollection('C');
    await db.addToCollection(cid2, MediaKind.epub, uid);
    final List<CollectionMemberTombstoneRow> after =
        await db.getAllCollectionMemberTombstones();
    expect(
      after.where((CollectionMemberTombstoneRow t) =>
          t.entryKey == bookKey && t.collectionName == 'C'),
      isEmpty,
      reason: '重新加入必须按 bookKey 域清掉墓碑',
    );
  });

  test('透传行（本地无书）移出 → 墓碑照抄原键；非 epub 域键原样', () async {
    final int cid = await db.createMediaCollection('D');
    // 透传行：对端 bookKey,本地无 epub 行。
    await db.addToCollection(cid, MediaKind.epub, 'remote only book');
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/v1'),
      title: const Value('V1'),
      videoPath: const Value('/v/v1.mkv'),
    ));
    await db.addToCollection(cid, MediaKind.video, 'video/v1');

    await db.removeFromCollection(cid, MediaKind.epub, 'remote only book');
    await db.removeFromCollection(cid, MediaKind.video, 'video/v1');

    final Set<String> keys = (await db.getAllCollectionMemberTombstones())
        .map((CollectionMemberTombstoneRow t) => t.entryKey)
        .toSet();
    expect(keys, containsAll(<String>{'remote only book', 'video/v1'}),
        reason: '透传 epub 键与 video 键都原样落墓碑（反查不上/非 epub 不换算）');
  });
}
