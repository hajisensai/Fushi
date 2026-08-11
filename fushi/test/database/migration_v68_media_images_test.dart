import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

/// v68 迁移专项守卫：`media_images` 建表 + 搬 `collection_scrape_meta
/// .backdrop_path` 这一步，在**外键强制打开**的连接上必须走得通。
///
/// ## 这条测试防的是什么
///
/// `media_images` 带两条外键（`collection_id` → `media_collections`、
/// `book_uid` → `video_books`）。SQLite 解析外键父表的时机是**执行 DML 时**，
/// 不是建表时：只要 `PRAGMA foreign_keys = ON`，一条 INSERT 就会去找两张父表，
/// 缺任何一张都直接抛 `no such table: main.<父表>`，把整条 `onUpgrade` 打断
/// ——库升不上去、app 打不开。抛不抛与本条 INSERT 搬几行、`book_uid` 是否恒为
/// NULL 全都无关。
///
/// 两张父表都不是「从来就有」：`video_books` 只在 `from<17` / `from<20` 建、
/// `media_collections` 只在 `from<38` 建。任何没走到那一级的库（部分迁移的旧库、
/// 阶梯测试的最小种子库）到 v68 这一步就是父表缺席。而**真实 app 恒以
/// `PRAGMA foreign_keys = ON` 打开库**（`_openWithRecovery` 的 `applyPragmas`），
/// 所以「外键开着」不是测试专属条件。
///
/// 同域的 `media_images_test.dart` 覆盖不到这条：它的 v67 种子用
/// `NativeDatabase.memory()` 默认关外键，父表缺不缺都不会报——那正是本仓反复记过
/// 的「memory DB 默认关外键 = cascade/FK 用例假绿」同一个坑。本文件所有用例一律
/// **显式指定**外键状态。
///
/// ## 锁四件事
///  1. 父表缺席 + 外键开着，v67→v68 不抛，背景图照样搬进 `media_images`；
///  2. 父表齐全（真实旧库形态）搬运结果正确，且升级完外键仍是真强制；
///  3. 调用方进来时外键是关的，升级完仍是关的（v68 只按原值恢复，不无条件置 ON）；
///  4. `media_images` 已存在的库重复升级不重插。
void main() {
  /// v67 时代 `collection_scrape_meta` 的形状。刻意**不带** REFERENCES——与当前
  /// Dart 表定义一致（该表本来就没有 FK 到 media_collections），种子行才能在外键
  /// 开着时插进一个没有 media_collections 的库。
  const String scrapeMetaDdl = '''
CREATE TABLE collection_scrape_meta (
  collection_id INTEGER NOT NULL PRIMARY KEY,
  source TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  title TEXT NOT NULL,
  original_title TEXT,
  summary TEXT,
  air_date TEXT,
  rating REAL,
  rating_count INTEGER,
  episode_count INTEGER,
  tags_json TEXT,
  infobox_json TEXT,
  backdrop_path TEXT,
  detail_url TEXT,
  scraped_at INTEGER NOT NULL
)
''';

  const String mediaCollectionsDdl = '''
CREATE TABLE media_collections (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  collection_type TEXT NOT NULL DEFAULT 'collection',
  cover_source TEXT,
  cover_path TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  order_updated_at INTEGER NOT NULL DEFAULT 0
)
''';

  const String videoBooksDdl = '''
CREATE TABLE video_books (
  book_uid TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  video_path TEXT NOT NULL
)
''';

  const String legacyMediaImagesDdl = '''
CREATE TABLE media_images (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  collection_id INTEGER,
  book_uid TEXT,
  kind TEXT NOT NULL,
  position INTEGER NOT NULL DEFAULT 0,
  path TEXT NOT NULL,
  source_url TEXT
)
''';

  /// 打开一个 `user_version = 67` 的种子库。[withParentTables] 控制两张外键父表
  /// 在不在场，[foreignKeys] 控制连接进入迁移时的外键强制状态。
  Future<FushiDatabase> openV67Db({
    required bool withParentTables,
    required bool foreignKeys,
    bool withMediaImages = false,
  }) async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase rawDb) {
          // 建表/塞种子期间先关外键：这一步模拟的是「库已经长成这样」，不是测约束。
          rawDb.execute('PRAGMA foreign_keys = OFF');
          if (withParentTables) {
            rawDb.execute(mediaCollectionsDdl);
            rawDb.execute(videoBooksDdl);
            rawDb.execute(
                "INSERT INTO media_collections (id, name) VALUES (5, 'c5')");
            rawDb.execute(
                "INSERT INTO media_collections (id, name) VALUES (6, 'c6')");
          }
          rawDb.execute(scrapeMetaDdl);
          rawDb.execute(
            'INSERT INTO collection_scrape_meta '
            '(collection_id, source, subject_id, title, backdrop_path, '
            ' scraped_at) '
            "VALUES (5, 'tmdb', '100', 't5', "
            "'/covers/collections/5_backdrop.jpg', 0)",
          );
          // 无背景行：不得被搬成 path='' 的垃圾行。
          rawDb.execute(
            'INSERT INTO collection_scrape_meta '
            '(collection_id, source, subject_id, title, scraped_at) '
            "VALUES (6, 'bangumi', '200', 't6', 0)",
          );
          if (withMediaImages) {
            // 「表已经建出来但 user_version 还停在 67」的形态（升级中途断电 /
            // 手工修过的库）：重复升级必须靠 _tableExists 短路，不得再搬一遍。
            rawDb.execute(legacyMediaImagesDdl);
            rawDb.execute(
              'INSERT INTO media_images (collection_id, kind, position, path) '
              "VALUES (5, 'backdrop', 0, '/covers/collections/5_backdrop.jpg')",
            );
          }
          rawDb.execute('PRAGMA user_version = 67');
          // 真实 app 恒以外键强制打开库（_openWithRecovery 的 applyPragmas），
          // 迁移就是在这个状态下跑的。
          rawDb.execute(foreignKeys
              ? 'PRAGMA foreign_keys = ON'
              : 'PRAGMA foreign_keys = OFF');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  Future<int> userVersionOf(FushiDatabase db) async =>
      (await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');

  Future<bool> foreignKeysOf(FushiDatabase db) async =>
      (await db.customSelect('PRAGMA foreign_keys').getSingle())
          .read<int>('foreign_keys') ==
      1;

  test('外键开着 + 两张父表都缺席：v67 升 v68 不抛，背景图照搬', () async {
    // 修复前这里抛 SqliteException(1): no such table: main.media_collections，
    // 整条 onUpgrade 中断——用户侧就是 app 打不开。
    final FushiDatabase db =
        await openV67Db(withParentTables: false, foreignKeys: true);

    expect(await userVersionOf(db), db.schemaVersion,
        reason: '迁移必须跑完并落 user_version');

    final List<MediaImageRow> rows = await db.getAllMediaImages();
    expect(rows, hasLength(1), reason: 'NULL backdrop_path 不得搬出垃圾行');
    expect(rows.single.collectionId, 5);
    expect(rows.single.kind, MediaImageKind.backdrop.dbValue);
    expect(rows.single.position, 0);
    expect(rows.single.path, '/covers/collections/5_backdrop.jpg');
    expect(rows.single.bookUid, isNull);

    expect(await foreignKeysOf(db), isTrue, reason: '进来时外键是开的，迁移收尾必须恢复回开');
  });

  test('外键开着 + 父表齐全（真实旧库形态）：搬运正确且外键仍是真强制', () async {
    final FushiDatabase db =
        await openV67Db(withParentTables: true, foreignKeys: true);

    expect(await userVersionOf(db), db.schemaVersion);

    final List<MediaImageRow> rows = await db.getAllMediaImages();
    expect(rows, hasLength(1));
    expect(rows.single.collectionId, 5);
    expect(rows.single.path, '/covers/collections/5_backdrop.jpg');

    expect(await foreignKeysOf(db), isTrue);

    // 外键真的在生效：删掉合集，cascade 清掉它的图组行。只断言 PRAGMA 值会被
    // 「写回去但没生效」骗过。
    await db.customStatement('DELETE FROM media_collections WHERE id = 5');
    expect(await db.getAllMediaImages(), isEmpty, reason: '恢复后的外键必须是真强制');
  });

  test('进来时外键是关的：v68 按原值恢复，不无条件置 ON', () async {
    final FushiDatabase db =
        await openV67Db(withParentTables: true, foreignKeys: false);

    expect(await userVersionOf(db), db.schemaVersion);
    expect(await db.getAllMediaImages(), hasLength(1));
    expect(await foreignKeysOf(db), isFalse, reason: 'v68 不得把调用方显式关掉的外键悄悄打开');
  });

  test('media_images 已在场：重复升级不重插', () async {
    final FushiDatabase db = await openV67Db(
      withParentTables: true,
      foreignKeys: true,
      withMediaImages: true,
    );

    expect(await userVersionOf(db), db.schemaVersion);
    final List<MediaImageRow> rows = await db.getAllMediaImages();
    expect(rows, hasLength(1), reason: '_tableExists 短路，绝不重插');
    expect(rows.single.path, '/covers/collections/5_backdrop.jpg');
  });
}
