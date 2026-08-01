import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// v40 迁移（多端库联合视图 §2.3 任务1）：
///  ① media_collections 加 order_updated_at（默认 0，旧行原样保留）；
///  ② 新建 collection_member_tombstones（成员移出墓碑 + 合集级哨兵）。
///
/// 打开一个 user_version=39 的库（v39 shape：media_collections 无
/// order_updated_at、无墓碑表），触发真实 `if (from < 40)`，验证列/表可用、
/// 旧数据无损、user_version 升到当前 schemaVersion。
void main() {
  Future<HibikiDatabase> openV39Db() async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v39 shape：无 order_updated_at 列。
          rawDb.execute('''
CREATE TABLE media_collections (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  collection_type TEXT NOT NULL DEFAULT 'collection',
  cover_source TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)
''');
          rawDb.execute('''
CREATE TABLE media_collection_items (
  collection_id INTEGER NOT NULL REFERENCES media_collections (id)
    ON DELETE CASCADE,
  media_type TEXT NOT NULL,
  entry_key TEXT NOT NULL,
  sort_index INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (collection_id, media_type, entry_key)
)
''');
          rawDb.execute(
            'INSERT INTO media_collections '
            '(name, collection_type, sort_order, created_at) VALUES '
            "('旧合集', 'playlist', 0, 1000)",
          );
          rawDb.execute(
            'INSERT INTO media_collection_items '
            '(collection_id, media_type, entry_key, sort_index) VALUES '
            "(1, 'video', 'v1', 0), (1, 'video', 'v2', 1)",
          );
          rawDb.execute('PRAGMA user_version = 39');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v40：order_updated_at 补列默认 0，旧行/成员原样保留', () async {
    final HibikiDatabase db = await openV39Db();
    final List<MediaCollectionRow> cols = await db.getAllMediaCollections();
    expect(cols, hasLength(1), reason: '旧行原样保留');
    expect(cols.single.name, '旧合集');
    expect(cols.single.orderUpdatedAt, 0, reason: '补列默认 0 = 从未手动排序');

    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(cols.single.id);
    expect(items.map((m) => m.entryKey).toList(), <String>['v1', 'v2'],
        reason: '成员行原样保留');
  });

  test('v40：collection_member_tombstones 新表可写可读（成员 + 哨兵）', () async {
    final HibikiDatabase db = await openV39Db();
    await db.upsertCollectionMemberTombstone(
      collectionName: '旧合集',
      collectionType: 'playlist',
      mediaType: 'video',
      entryKey: 'v9',
      deletedAt: 1234,
    );
    await db.upsertCollectionMemberTombstone(
      collectionName: '已删合集',
      collectionType: 'collection',
      mediaType: HibikiDatabase.collectionTombstoneSentinel,
      entryKey: HibikiDatabase.collectionTombstoneSentinel,
      deletedAt: 5678,
    );
    final List<CollectionMemberTombstoneRow> rows =
        await db.getAllCollectionMemberTombstones();
    expect(rows, hasLength(2));
    final CollectionMemberTombstoneRow member =
        rows.firstWhere((r) => r.entryKey == 'v9');
    expect(member.collectionName, '旧合集');
    expect(member.deletedAt, 1234);
    final CollectionMemberTombstoneRow sentinel = rows.firstWhere(
        (r) => r.entryKey == HibikiDatabase.collectionTombstoneSentinel);
    expect(sentinel.collectionName, '已删合集');
    expect(sentinel.deletedAt, 5678);

    // upsert 幂等：同键重写刷新 deletedAt 而非报错/加行。
    await db.upsertCollectionMemberTombstone(
      collectionName: '旧合集',
      collectionType: 'playlist',
      mediaType: 'video',
      entryKey: 'v9',
      deletedAt: 9999,
    );
    final List<CollectionMemberTombstoneRow> after =
        await db.getAllCollectionMemberTombstones();
    expect(after, hasLength(2));
    expect(after.firstWhere((r) => r.entryKey == 'v9').deletedAt, 9999);
  });

  test('user_version 升到当前 schemaVersion', () async {
    final HibikiDatabase db = await openV39Db();
    await db.getAllMediaCollections(); // 触发 open/migrate。
    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 66);
  });
}
