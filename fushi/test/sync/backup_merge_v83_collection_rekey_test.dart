import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// v83 备份合并合集换键回归测试（data-layer-stage2-plan.md §4/§6 缺口 2）。
///
/// 雷区与 v82 四子表同形：成员表 epub 域 entry_key = 各库**自己的**
/// epub_books.uid（本机局域随机串），跨库直搬必错。`_mergeMediaCollections`
/// 的三级回落换键（src uid → src bookKey → 本库 uid；本库无书回落 **src
/// bookKey** 保持 wire 域可续接；src 也无书行照抄=透传/游离行）断了不会报错，
/// 只会静默把 src uid 插成永久孤儿。
///
/// 墓碑域契约：本地 collection_member_tombstones.entryKey 冻结在 bookKey 域，
/// src epub 成员先归一到 bookKey 再与墓碑比（防旧备份复活已移出成员）。
///
/// 变异实测（2026-08-10，临时破坏 lib 后确认转红、已还原，零 lib 残留）：
///  - fushi/lib/src/sync/backup_merge_engine.dart 的 rekeyEpubEntryKey 改成
///    恒等返回（模拟三级回落断掉）→ 换键用例红：成员集合仍含 src uid、
///    cover_source 未换键；
///  - 同文件 normalizeEpubToBookKey 改成恒等返回（模拟墓碑域归一断掉）→
///    墓碑用例红：已移出成员被旧备份复活。
void main() {
  int bookCounter = 0;

  EpubBooksCompanion book(String key, String uid) => EpubBooksCompanion.insert(
        bookKey: key,
        uid: Value(uid),
        title: key,
        epubPath: '/fake/$key.epub',
        extractDir: '/fake/$key-${bookCounter++}',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
      );

  /// 在磁盘目录建 src 库（ATTACH 需要真文件），种子回调后关闭，返回 db 路径。
  Future<String> buildSrcDb(
      Future<void> Function(FushiDatabase src) seed) async {
    final Directory srcDir = await Directory.systemTemp.createTemp('ck_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final FushiDatabase src = FushiDatabase(srcDir.path);
    await seed(src);
    await src.close();
    return p.join(srcDir.path, 'fushi.db');
  }

  Future<void> attachAndMerge(FushiDatabase target, String srcDbPath) async {
    final String safe = srcDbPath.replaceAll(r'\', '/').replaceAll("'", "''");
    await target.customStatement("ATTACH DATABASE '$safe' AS mergesrc");
    await BackupMergeEngine(target).merge();
    await target.customStatement('DETACH DATABASE mergesrc');
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

  test('同 book_key 书 uid 互异：成员三级回落换键 + 同书双行收敛去重 + cover 换键', () async {
    final String srcDbPath = await buildSrcDb((FushiDatabase src) async {
      await src.insertEpubBook(book('shared', 'src-uid-shared'));
      await src.insertEpubBook(book('src-only', 'src-only-uid'));
      final int cid =
          await src.createMediaCollection('集甲', collectionType: 'collection');
      // src 本地书 uid 行 + 同书透传 bookKey 行（脏数据/未收敛窗口）——换键后
      // 收敛为同一目标键，INSERT OR IGNORE 去重。
      await src.addToCollection(cid, MediaKind.epub, 'src-uid-shared');
      await src.addToCollection(cid, MediaKind.epub, 'shared');
      // 合并后仍不在本库的 src 书（target 有书墓碑挡插入，见下）：回落 src
      // bookKey（不是 src uid！保持 wire 域可续接，日后重导入自动收敛）。
      // 注意：没有墓碑时 _insertMissingEpubBooks 会先把 src 书插进本库，成员
      // remap 到插入后的本库 uid——「回落」只发生在书真的没落地时。
      await src.addToCollection(cid, MediaKind.epub, 'src-only-uid');
      // src 也无书行的纯透传行：照抄。
      await src.addToCollection(cid, MediaKind.epub, 'wire-ghost');
      // 非 epub 域：照抄（误换算即数据损坏）。
      await src.addToCollection(cid, MediaKind.video, 'v1');
      // cover_source 隐藏载体：epub 借用键与成员行同律换键。
      await src.updateMediaCollectionCover(cid, 'epub|src-uid-shared');
    });

    final FushiDatabase target =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(target.close);
    await target.insertEpubBook(book('shared', 'tgt-uid-shared'));
    // 'src-only' 在本机被用户删过：书墓碑挡住 _insertMissingEpubBooks 复活，
    // 其合集成员因此走「本库无书 → 回落 src bookKey」的第二级。
    await target.insertBookTombstone('src-only');

    await attachAndMerge(target, srcDbPath);

    expect(
      await memberKeysOf(target, '集甲', 'collection'),
      <String>{
        'epub|tgt-uid-shared', // src uid → src bookKey → 本库 uid（双行收敛为一）
        'epub|src-only', // 本库无书 → 回落 src bookKey
        'epub|wire-ghost', // src 无书行 → 照抄（透传）
        'video|v1', // 非 epub 域照抄
      },
      reason: '三级回落换键 + INSERT OR IGNORE 同键去重',
    );
    // 雷区总闸：src 本机局域 uid 绝不落进目标库。
    final MediaCollectionRow row =
        (await target.getMediaCollectionByNaturalKey('集甲', 'collection'))!;
    for (final MediaCollectionItemRow m
        in await target.getCollectionItems(row.id)) {
      expect(m.entryKey, isNot(anyOf('src-uid-shared', 'src-only-uid')),
          reason: 'src uid 直搬 = 永久孤儿（换键断掉的第一症状）');
    }
    expect(row.coverSource, 'epub|tgt-uid-shared',
        reason: 'cover_source 的 epub 借用键与成员行同律换键（漏了封面断链）');
  });

  test('墓碑 bookKey 域匹配防复活：src uid 成员先归一 bookKey 再比本地墓碑', () async {
    final String srcDbPath = await buildSrcDb((FushiDatabase src) async {
      await src.insertEpubBook(book('shared', 'src-uid-2'));
      final int cid =
          await src.createMediaCollection('集乙', collectionType: 'collection');
      await src.addToCollection(cid, MediaKind.epub, 'src-uid-2');
      await src.addToCollection(cid, MediaKind.video, 'v9');
    });

    final FushiDatabase target =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(target.close);
    await target.insertEpubBook(book('shared', 'tgt-uid-2'));
    // 本地墓碑（用户在本设备移出过这本书）——冻结在 bookKey 域。
    await target.upsertCollectionMemberTombstone(
      collectionName: '集乙',
      collectionType: 'collection',
      mediaType: 'epub',
      entryKey: 'shared',
      deletedAt: 5000,
    );

    await attachAndMerge(target, srcDbPath);

    expect(
      await memberKeysOf(target, '集乙', 'collection'),
      <String>{'video|v9'},
      reason: 'src 的 uid 成员归一到 bookKey 域后命中本地墓碑 → 跳过不复活；'
          '未被墓碑点名的 video 成员正常并入',
    );
  });
}
