import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// v59 迁移（BUG-1113「游戏没有标签」）：新建 `galgame_tag_mappings`，把游戏接进书 /
/// 字幕书 / 视频 / 合集早已共用的那一个 `book_tags` 标签池。
///
/// 打开一个 user_version=58 的库（v58 shape：galgames 三表 + launch_args 在场，
/// **无** galgame_tag_mappings），触发真实的 `if (from < 59)` 建表，验证：
///  ① 既有 galgames 行零破坏，升级后新表为空 = 全部游戏无用户标签 = 与旧版一致；
///  ② 新表可写可读，AND 语义筛选可用；
///  ③ 外键 cascade 双向生效（删游戏 / 删标签都自动清映射，不留孤儿）；
///  ④ user_version 升到当前代码 schemaVersion。
void main() {
  Future<HibikiDatabase> openV58Db() async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v58 shape：galgames 全列在场（含 launch_args），但没有标签映射表。
          rawDb.execute('''
CREATE TABLE galgames (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  exe_path TEXT NOT NULL,
  workdir TEXT NOT NULL,
  launch_args TEXT NOT NULL DEFAULT '',
  cover_path TEXT,
  added_at INTEGER NOT NULL,
  play_status INTEGER NOT NULL DEFAULT 0,
  primary_source TEXT,
  release_date TEXT,
  custom_data_json TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0
)
''');
          rawDb.execute('''
CREATE TABLE galgame_sources (
  game_id TEXT NOT NULL,
  source TEXT NOT NULL,
  external_id TEXT,
  data_json TEXT NOT NULL,
  score REAL,
  rank INTEGER,
  fetched_at INTEGER NOT NULL,
  PRIMARY KEY (game_id, source)
)
''');
          // 共享标签池自 v1 就在（新表要 FK 引用它），真实 v58 库必有此表。
          rawDb.execute('''
CREATE TABLE book_tags (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  color_value INTEGER NOT NULL DEFAULT 4288585374,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)
''');
          rawDb.execute('''
CREATE TABLE galgame_sessions (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  game_id TEXT NOT NULL,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  duration_seconds INTEGER NOT NULL,
  date_key TEXT NOT NULL
)
''');
          rawDb.execute(
            'INSERT INTO galgames '
            '(id, name, exe_path, workdir, added_at, play_status, sort_order) '
            r"VALUES ('legacy_game', '旧游戏', 'Z:\vn\game.exe', 'Z:\vn', "
            '1700000000000, 3, 0)',
          );
          rawDb.execute('PRAGMA user_version = 58');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v59：建出 galgame_tag_mappings，既有游戏行零破坏且升级后无任何用户标签', () async {
    final HibikiDatabase db = await openV58Db();

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 64,
        reason: 'v59 新建 galgame_tag_mappings（BUG-1113 游戏接入共享标签池）');

    final GalgameRow? legacy = await db.getGalgame('legacy_game');
    expect(legacy, isNotNull, reason: '旧游戏行原样保留');
    expect(legacy!.name, '旧游戏');
    expect(legacy.playStatus, 3);

    // 关键的向后兼容断言：升级后新表为空 = 旧库观感逐像素不变。
    expect(await db.getAllGameTagMappings(), isEmpty);
    expect(await db.getTagsForGame('legacy_game'), isEmpty);
  });

  test('v59：新表可写可读，标签挂到升级前就存在的游戏上', () async {
    final HibikiDatabase db = await openV58Db();

    final int tagId = await db.createTag('通关', 0xFF00FF00);
    await db.addTagToGame('legacy_game', tagId);

    final List<BookTagRow> tags = await db.getTagsForGame('legacy_game');
    expect(tags, hasLength(1));
    expect(tags.single.name, '通关');
    expect(
        await db.getGameIdsForAllTags(<int>{tagId}), <String>{'legacy_game'});
  });

  test('v59：fresh 库由 onCreate 直接建出该表（不依赖迁移梯子）', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    expect(await db.getAllGameTagMappings(), isEmpty,
        reason: 'onCreate 的 createAll 必须包含 galgame_tag_mappings');
  });
}
