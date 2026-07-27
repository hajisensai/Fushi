import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

/// 备份合并把 src 库的合集标签按【合集自然键 + 标签名】并集进 target（合集打标签 §5.3
/// 任务10）。`BackupMergeEngine._mergeCollectionTags` 在 `_mergeMediaCollections`（已建
/// 好目标合集）和 `_mergeTagsAndMappings`（已并齐 book_tags 池）之后，把
/// src.collection_tag_mappings 的 collection_id 经 media_collections (name,
/// collection_type) 自然键 remap、tag_id 经 book_tags.name remap 后插入 target；JOIN
/// 不命中（target 无同名合集、被墓碑跳过）的行天然不插——尊重墓碑是 JOIN 的副产品。
void main() {
  Future<Directory> tempDir(String prefix) =>
      Directory.systemTemp.createTemp(prefix);

  test('合并把 src 合集标签按名并集进 target 同名合集', () async {
    // ── target（当前设备）：已有同名合集 C，尚无标签 ───────────────────────────
    final Directory curDir = await tempDir('mg_ctag_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final HibikiDatabase cur = HibikiDatabase(curDir.path);
    final int targetCid =
        await cur.createMediaCollection('C', collectionType: 'collection');
    await cur.close();

    // ── src（备份）：合集 C + 标签 '日语' + 映射；另有全新合集 D 带标签 N1 ───────
    // C 命中 target 同名合集（按自然键 remap）；D 是全新合集，会被
    // `_mergeMediaCollections` 建到 target，其标签也应随 `_mergeCollectionTags` 并入。
    final Directory srcDir = await tempDir('mg_ctag_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final HibikiDatabase src = HibikiDatabase(srcDir.path);
    final int sC =
        await src.createMediaCollection('C', collectionType: 'collection');
    final int sTag = await src.createTag('日语', 0xFF0000FF);
    await src.addTagToCollection(sC, sTag);
    final int sD =
        await src.createMediaCollection('D', collectionType: 'collection');
    final int sTagD = await src.createTag('N1', 0xFF00FF00);
    await src.addTagToCollection(sD, sTagD);

    final Directory zipDir = await tempDir('mg_ctag_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final String zip = p.join(zipDir.path, 'b.zip');
    await BackupService(db: src, dbDirectory: srcDir.path, appVersion: '2.0.0')
        .createBackup(zip);
    await src.close();

    // ── 合并导入 ──────────────────────────────────────────────────────────────
    await BackupService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
    );

    // ── 断言 ──────────────────────────────────────────────────────────────────
    final HibikiDatabase after = HibikiDatabase(curDir.path);
    addTearDown(after.close);

    final List<BookTagRow> tags = await after.getTagsForCollection(targetCid);
    expect(tags.map((BookTagRow t) => t.name), contains('日语'),
        reason: 'src 合集 C 的标签「日语」应按自然键 remap 后挂到 target 的 C');

    // D：全新合集连同标签 N1 一并合入（新建合集的标签也透传）。
    final MediaCollectionRow? d =
        await after.getMediaCollectionByNaturalKey('D', 'collection');
    expect(d, isNotNull, reason: '全新合集 D 应被 _mergeMediaCollections 建入 target');
    final List<BookTagRow> dTags = await after.getTagsForCollection(d!.id);
    expect(dTags.map((BookTagRow t) => t.name), contains('N1'),
        reason: '新建合集 D 的标签 N1 也应随 _mergeCollectionTags 并入');
  });
}
