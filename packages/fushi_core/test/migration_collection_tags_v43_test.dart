import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// 合集打标签 阶段1：建表迁移 collection_tag_mappings（v42 -> v43）的守护测试。
///
/// 覆盖：
/// ① v42 -> v43 升级：建出 collection_tag_mappings，且旧库既有 media_collections
///    行零丢（Never break userspace，无损迁移）。
/// ② fresh DB：onCreate 的 createAll 已含新表，无 onUpgrade 也可用（下界断言）。
///
/// 迁移测试沿用 migration_paired_peers_v31_test 的「手写旧 schema raw seed」范式：
/// 只建 v42 时已存在的 media_collections 表并写真实行，PRAGMA user_version = 42，
/// 开库触发 onUpgrade(42 -> 当前)。因为 from=42 会跳过所有 from<42 的 ladder 步，
/// 只有 `if (from < 43)` 分支 createTable(collectionTagMappings) 会跑，故最小 seed
/// 只需一张 media_collections 表即可让迁移打开不炸。

/// 手写一个 v42 库：media_collections（含一条真实合集行）+ user_version=42。
/// 开库触发 onUpgrade(42 -> 当前)，只有 from<43 步会 createTable(collectionTagMappings)。
HibikiDatabase _openMigratedFromV42() {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('PRAGMA foreign_keys = ON');
        // v42 形态的 media_collections（列名与生成 schema 一致：v40 已带
        // order_updated_at，v43 不改本表）。
        raw.execute('''
CREATE TABLE media_collections (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  collection_type TEXT NOT NULL DEFAULT 'collection',
  cover_source TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  order_updated_at INTEGER NOT NULL DEFAULT 0
)''');
        raw.execute(
          "INSERT INTO media_collections "
          "(name, collection_type, created_at) "
          "VALUES ('Existing', 'collection', 42)",
        );
        raw.execute('PRAGMA user_version = 42');
      },
    ),
  );
}

void main() {
  test('v42 -> v43 creates collection_tag_mappings with zero loss of old rows',
      () async {
    final HibikiDatabase db = _openMigratedFromV42();
    addTearDown(db.close);

    // Opening runs onUpgrade(42 -> current). Compare to the live schemaVersion
    // so this never goes stale on a future bump.
    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion,
        reason: 'migration must land on the current schema version');
    // collection_tag_mappings 自 v43（合集打标签 阶段1）引入；断言下界而非瞬时值，
    // 使后续 schema bump 不会把这个迁移守护测试拖 stale。
    expect(db.schemaVersion, greaterThanOrEqualTo(43),
        reason: 'collection_tag_mappings 自 v43 引入，schema 版本不应回退到其之前');

    // Old media_collections row survived the upgrade untouched (Never break
    // userspace).
    final List<MediaCollectionRow> cols = await db.getAllMediaCollections();
    expect(cols.map((MediaCollectionRow c) => c.name), contains('Existing'),
        reason: '旧合集行必须在无损迁移后原样存活');

    // The new table now exists and is usable (empty), proving the from<43
    // createTable(collectionTagMappings) ran without throwing.
    expect(await db.getCollectionIdsForAllTags(<int>{1}), <int>{},
        reason: '空表 = 无合集标签 = 行为与旧版一致（sync 零命中）');
  });

  test('fresh DB has collection_tag_mappings from createAll (no onUpgrade)',
      () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // onCreate's createAll must include the new table; querying it proves it
    // exists without any onUpgrade running.
    expect(db.schemaVersion, greaterThanOrEqualTo(43));
    expect(await db.getCollectionIdsForAllTags(<int>{1}), <int>{});
  });
}
