import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

/// 备份合并尊重合集成员/合集墓碑（多端库联合视图 §2.3 任务7）。
///
/// `BackupMergeEngine._mergeMediaCollections` 把备份合集成员 INSERT OR IGNORE 进
/// target 前，必须跳过命中本地 `collection_member_tombstones` 的成员（防旧备份复活
/// 用户已移出的成员）与命中合集级删除哨兵墓碑的整个合集（防复活已删合集）；同时不
/// 影响未被墓碑标记的新成员/新合集正常合入。备份是（更旧的）无时间证据快照，故本地
/// 墓碑直接生效——与书删除墓碑（TODO-1195 part B）同一律。
void main() {
  Future<Directory> tempDir(String prefix) =>
      Directory.systemTemp.createTemp(prefix);

  /// 读某合集（自然键）当前成员的 entryKey 列表；合集不存在返回 null。
  Future<List<String>?> membersOf(
      HibikiDatabase db, String name, String type) async {
    final MediaCollectionRow? row =
        await db.getMediaCollectionByNaturalKey(name, type);
    if (row == null) return null;
    return (await db.getCollectionItems(row.id))
        .map((MediaCollectionItemRow m) => m.entryKey)
        .toList();
  }

  test('合并尊重成员移出墓碑 + 合集删除墓碑，同时正常合入新合集/新成员', () async {
    // ── target（当前设备）：制造两类墓碑 ─────────────────────────────────────
    final Directory curDir = await tempDir('mg_tomb_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final HibikiDatabase cur = HibikiDatabase(curDir.path);

    // Keep 合集：曾有 [a, b]，用户移出 b → 留成员墓碑 {Keep, epub, b}。
    final int keep = await cur.createMediaCollection('Keep');
    await cur.addToCollection(keep, 'epub', 'a');
    await cur.addToCollection(keep, 'epub', 'b');
    await cur.removeFromCollection(keep, 'epub', 'b');
    // Gone 合集：曾存在，用户删除 → 留合集级删除哨兵墓碑 {Gone}。
    final int gone = await cur.createMediaCollection('Gone');
    await cur.addToCollection(gone, 'epub', 'g');
    await cur.deleteMediaCollection(gone);
    await cur.close();

    // ── src（备份，更旧快照）：含被移出成员 + 已删合集 + 全新合集/成员 ─────────
    final Directory srcDir = await tempDir('mg_tomb_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final HibikiDatabase src = HibikiDatabase(srcDir.path);
    // Keep：备份仍有 b（应被墓碑挡下）+ 新成员 c（无墓碑，应正常合入）。
    final int sKeep = await src.createMediaCollection('Keep');
    await src.addToCollection(sKeep, 'epub', 'a');
    await src.addToCollection(sKeep, 'epub', 'b');
    await src.addToCollection(sKeep, 'epub', 'c');
    // Gone：备份仍有该合集（应整个被删除墓碑挡下）。
    final int sGone = await src.createMediaCollection('Gone');
    await src.addToCollection(sGone, 'epub', 'g');
    // New：全新合集（应照常合入）。
    final int sNew = await src.createMediaCollection('New');
    await src.addToCollection(sNew, 'epub', 'n');

    final Directory zipDir = await tempDir('mg_tomb_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final String zip = p.join(zipDir.path, 'b.zip');
    await BackupService(db: src, dbDirectory: srcDir.path, appVersion: '2.0.0')
        .exportBackup(zip);
    await src.close();

    // ── 合并导入 ──────────────────────────────────────────────────────────────
    await BackupService.mergeImportBackupFiles(
      dbDirectory: curDir.path,
      zipPath: zip,
    );

    // ── 断言 ──────────────────────────────────────────────────────────────────
    final HibikiDatabase after = HibikiDatabase(curDir.path);
    addTearDown(after.close);

    // Keep：b 被成员墓碑挡下不复活；a 保留；c（无墓碑）正常合入。
    final List<String>? keepMembers =
        await membersOf(after, 'Keep', 'collection');
    expect(keepMembers, isNotNull);
    expect(keepMembers!.toSet(), <String>{'a', 'c'},
        reason: '已移出成员 b 不复活；未标记的新成员 c 正常合入');

    // Gone：合集级删除墓碑挡下整个合集（不复活合集，也不合入其成员）。
    expect(await membersOf(after, 'Gone', 'collection'), isNull,
        reason: '已删合集被删除墓碑挡下，不复活');

    // New：无墓碑，照常合入（回归既有并集语义）。
    expect(await membersOf(after, 'New', 'collection'), <String>['n'],
        reason: '全新合集正常合入');
  });
}
