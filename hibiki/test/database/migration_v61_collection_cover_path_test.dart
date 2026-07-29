import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// v61 迁移（BUG-1211「改的是合集封面，不是每一集的封面」）：`media_collections`
/// 加 `cover_path` 列 = 合集**自有**封面图的绝对路径。
///
/// 打开一个 user_version=60 的库（v60 shape：media_collections 无 cover_path），
/// 触发真实的 `if (from < 61)` ADD COLUMN，验证：
///  ① 既有合集行零破坏：name / collection_type / cover_source / sort_order /
///     created_at / anilist_id 一字不改；
///  ② 新列对既有行全 NULL = 「没设过自有封面」= 渲染继续走成员借用链 = 与旧版
///     逐像素一致（Never break userspace）；
///  ③ 新列可写可读可清；
///  ④ user_version 升到当前代码 schemaVersion。
void main() {
  Future<HibikiDatabase> openV60Db() async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v60 shape：media_collections 全列在场，**没有** cover_path。
          rawDb.execute('''
CREATE TABLE media_collections (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  collection_type TEXT NOT NULL DEFAULT 'collection',
  cover_source TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  order_updated_at INTEGER NOT NULL DEFAULT 0,
  anilist_id INTEGER,
  audio_track_id TEXT,
  subtitle_delay_ms INTEGER
)
''');
          rawDb.execute('''
CREATE TABLE media_collection_items (
  collection_id INTEGER NOT NULL,
  media_type TEXT NOT NULL,
  entry_key TEXT NOT NULL,
  sort_index INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (collection_id, media_type, entry_key)
)
''');
          rawDb.execute(
            'INSERT INTO media_collections '
            '(id, name, collection_type, cover_source, sort_order, created_at, '
            'order_updated_at, anilist_id) '
            "VALUES (7, '旧合集', 'playlist', 'video|video/ep1', 3, "
            '1700000000000, 1700000001000, 12345)',
          );
          rawDb.execute(
            'INSERT INTO media_collection_items '
            '(collection_id, media_type, entry_key, sort_index) '
            "VALUES (7, 'video', 'video/ep1', 0)",
          );
          rawDb.execute('PRAGMA user_version = 60');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v61：media_collections 加 cover_path，既有合集行零破坏且新列全 NULL', () async {
    final HibikiDatabase db = await openV60Db();

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 63,
        reason: 'v61 给 media_collections 加合集自有封面列（BUG-1211）');

    final MediaCollectionRow? legacy = await db.getMediaCollectionById(7);
    expect(legacy, isNotNull, reason: '旧合集行原样保留');
    expect(legacy!.name, '旧合集');
    expect(legacy.collectionType, 'playlist');
    expect(legacy.coverSource, 'video|video/ep1', reason: '成员引用列不受影响');
    expect(legacy.sortOrder, 3);
    expect(legacy.createdAt, 1700000000000);
    expect(legacy.orderUpdatedAt, 1700000001000);
    expect(legacy.anilistId, 12345);
    expect(legacy.coverPath, isNull,
        reason: '新列对既有行必须是 NULL = 渲染继续借成员封面，老合集封面不变白');

    // 成员引用行零破坏。
    final List<MediaCollectionItemRow> items = await db.getCollectionItems(7);
    expect(items.map((MediaCollectionItemRow m) => m.entryKey),
        <String>['video/ep1']);
  });

  test('v61：新列可写可读可清', () async {
    final HibikiDatabase db = await openV60Db();

    await db.updateMediaCollectionCoverPath(7, r'D:\covers\collections\7.jpg');
    expect((await db.getMediaCollectionById(7))?.coverPath,
        r'D:\covers\collections\7.jpg');

    // 写自有封面绝不动 cover_source（两列正交）。
    expect(
        (await db.getMediaCollectionById(7))?.coverSource, 'video|video/ep1');

    await db.updateMediaCollectionCoverPath(7, null);
    expect((await db.getMediaCollectionById(7))?.coverPath, isNull);
  });
}
