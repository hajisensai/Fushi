import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v75 迁移（每游戏日语区域档位，BUG-1477）：`galgames` 加 `japanese_locale_mode`
/// 列，存 `auto` / `on` / `off`。与 v62 的 `upscaling_mode`、v56 的 `launch_args`
/// 同型：都是「用户为该游戏设的启动期配置」。
///
/// 关键的向后兼容点与 v62 **相反**，必须逐条守住：老行回填空串，而空串在解析层
/// 回落的是 **auto** 而不是 off。转区是用户明确要过的功能（BUG-1038），加了开关
/// 就把老用户默默关掉才是破坏用户空间。
void main() {
  String galgamesDdl({required bool withLocaleMode}) => '''
CREATE TABLE galgames (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  exe_path TEXT NOT NULL,
  workdir TEXT NOT NULL,
  launch_args TEXT NOT NULL DEFAULT '',
  upscaling_mode TEXT NOT NULL DEFAULT '',
${withLocaleMode ? "  japanese_locale_mode TEXT NOT NULL DEFAULT '',\n" : ''}  cover_path TEXT,
  added_at INTEGER NOT NULL,
  play_status INTEGER NOT NULL DEFAULT 0,
  primary_source TEXT,
  release_date TEXT,
  custom_data_json TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0
)
''';

  Future<FushiDatabase> openV74Db({bool withLocaleMode = false}) async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          rawDb.execute(galgamesDdl(withLocaleMode: withLocaleMode));
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
            '(id, name, exe_path, workdir, launch_args, upscaling_mode, '
            'added_at, play_status, sort_order) '
            r"VALUES ('legacy_game', '汉化版旧游戏', 'Z:\vn\game.exe', 'Z:\vn', "
            "'-windowed', 'off', 1700000000000, 3, 0)",
          );
          rawDb.execute('PRAGMA user_version = 74');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v75：既有游戏行零破坏，japanese_locale_mode 回填空串（= auto）', () async {
    final FushiDatabase db = await openV74Db();

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 85,
        reason: 'v75 给 galgames 加 japanese_locale_mode（每游戏转区档位）');

    final List<QueryRow> columns =
        await db.customSelect('PRAGMA table_info(galgames)').get();
    expect(
      columns.map((QueryRow r) => r.read<String>('name')),
      contains('japanese_locale_mode'),
    );

    final GalgameRow? legacy = await db.getGalgame('legacy_game');
    expect(legacy, isNotNull, reason: '旧游戏行原样保留');
    expect(legacy!.name, '汉化版旧游戏');
    expect(legacy.launchArgs, '-windowed', reason: 'v56 的启动参数不受新列影响');
    expect(legacy.upscalingMode, 'off', reason: 'v62 的超分档不受新列影响');
    expect(legacy.japaneseLocaleMode, '',
        reason: '既有行回填空串 = 未设置 = 解析层回落 auto（保住 BUG-1038 的既有行为）');
  });

  test('v75：档位字符串原样往返，DAO 单列写入不碰其它列', () async {
    final FushiDatabase db = await openV74Db();

    await db.setGalgameJapaneseLocaleMode('legacy_game', 'off');
    GalgameRow row = (await db.getGalgame('legacy_game'))!;
    expect(row.japaneseLocaleMode, 'off');
    expect(row.launchArgs, '-windowed', reason: '单列写入不碰启动参数');
    expect(row.upscalingMode, 'off', reason: '单列写入不碰超分档');
    expect(row.playStatus, 3, reason: '单列写入不碰游玩状态');

    await db.setGalgameJapaneseLocaleMode('legacy_game', 'on');
    expect((await db.getGalgame('legacy_game'))!.japaneseLocaleMode, 'on');

    // 清空 = 显式写空串（列非空），不是写 null。
    await db.setGalgameJapaneseLocaleMode('legacy_game', '');
    expect((await db.getGalgame('legacy_game'))!.japaneseLocaleMode, '');

    // 整行 upsert 省略该列时是 Value.absent()，UPDATE 分支不碰这一列。
    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'legacy_game',
      name: '汉化版旧游戏',
      exePath: r'Z:\vn\game.exe',
      workdir: r'Z:\vn',
      japaneseLocaleMode: const Value<String>('off'),
      addedAt: 1700000000000,
    ));
    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'legacy_game',
      name: '汉化版旧游戏',
      exePath: r'Z:\vn\game.exe',
      workdir: r'Z:\vn',
      addedAt: 1700000000000,
    ));
    row = (await db.getGalgame('legacy_game'))!;
    expect(row.japaneseLocaleMode, 'off',
        reason: '不传 ≠ 清空——用户为汉化版设的「关闭」不能被一次整行 upsert 抹掉');
  });

  test('v75：迁移幂等——列已存在时守卫短路，不撞 duplicate column', () async {
    final FushiDatabase db = await openV74Db(withLocaleMode: true);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);

    final List<QueryRow> columns =
        await db.customSelect('PRAGMA table_info(galgames)').get();
    expect(
      columns
          .map((QueryRow r) => r.read<String>('name'))
          .where((String name) => name == 'japanese_locale_mode'),
      hasLength(1),
    );
  });

  test('v75：fresh 库由 onCreate 建出该列，默认空串', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'fresh',
      name: 'fresh',
      exePath: r'Z:\f\f.exe',
      workdir: r'Z:\f',
      addedAt: 1700000000000,
    ));
    expect((await db.getGalgame('fresh'))!.japaneseLocaleMode, '');
  });
}
