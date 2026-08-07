import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v62 迁移（每游戏窗口超分档位）：`galgames` 加 `upscaling_mode` 列，存该游戏的
/// Magpie 超分档位（`auto` / `installed_only` / `off`）。与 v56 的 `launch_args`
/// 同型：都是「用户为该游戏设的启动期配置」，随游戏行走、由启动路径读一次。
///
/// 打开一个 user_version=59 的库（v59 shape：galgames 三表 + 标签映射表在场，
/// **无** upscaling_mode 列），触发真实的 `if (from < 60)` `addColumn`，验证：
///  ① 既有 galgames 行原样保留，新列回填**空串** = 用户没设过 = 解析层回落到关闭。
///     这条是硬要求：老用户升级后绝不能被莫名打开超分（Never break userspace）；
///  ② 新列可写可读，档位字符串原样往返；
///  ③ 迁移幂等——列已存在时守卫短路 no-op，不会撞 "duplicate column name"；
///  ④ user_version 升到当前代码 schemaVersion。
void main() {
  /// v59 shape 的建库脚本。[withUpscalingMode] 为 true 时**提前**建出新列，
  /// 用来复现「迁移在同一形状上重复跑」的幂等场景（③）。
  String galgamesDdl({required bool withUpscalingMode}) => '''
CREATE TABLE galgames (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  exe_path TEXT NOT NULL,
  workdir TEXT NOT NULL,
  launch_args TEXT NOT NULL DEFAULT '',
${withUpscalingMode ? "  upscaling_mode TEXT NOT NULL DEFAULT '',\n" : ''}  cover_path TEXT,
  added_at INTEGER NOT NULL,
  play_status INTEGER NOT NULL DEFAULT 0,
  primary_source TEXT,
  release_date TEXT,
  custom_data_json TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0
)
''';

  Future<FushiDatabase> openV59Db({bool withUpscalingMode = false}) async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v59 shape：galgames 全列在场（含 launch_args），但没有 upscaling_mode。
          rawDb.execute(galgamesDdl(withUpscalingMode: withUpscalingMode));
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
          // 共享标签池 + v59 的游戏标签映射表：真实 v59 库必有，一并造出来，
          // 确认 v62 阶梯不会连带影响它们。
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
CREATE TABLE galgame_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  game_id TEXT NOT NULL REFERENCES galgames (id) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE,
  UNIQUE (game_id, tag_id)
)
''');
          rawDb.execute(
            'INSERT INTO galgames '
            '(id, name, exe_path, workdir, launch_args, added_at, play_status, '
            'sort_order) '
            r"VALUES ('legacy_game', '旧游戏', 'Z:\vn\game.exe', 'Z:\vn', "
            "'-windowed', 1700000000000, 3, 0)",
          );
          rawDb.execute('PRAGMA user_version = 59');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v62：既有游戏行零破坏，upscaling_mode 回填空串（= 超分关闭）', () async {
    final FushiDatabase db = await openV59Db();

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 73,
        reason: 'v62 给 galgames 加 upscaling_mode（每游戏窗口超分档位）');

    // 列真的建出来了（不只是 Dart 侧读到默认值）。
    final List<QueryRow> columns =
        await db.customSelect('PRAGMA table_info(galgames)').get();
    expect(
      columns.map((QueryRow r) => r.read<String>('name')),
      contains('upscaling_mode'),
      reason: 'v62 给 galgames 加 upscaling_mode 列',
    );

    final GalgameRow? legacy = await db.getGalgame('legacy_game');
    expect(legacy, isNotNull, reason: '旧游戏行原样保留');
    expect(legacy!.name, '旧游戏');
    expect(legacy.exePath, r'Z:\vn\game.exe');
    expect(legacy.workdir, r'Z:\vn');
    expect(legacy.playStatus, 3);
    expect(legacy.launchArgs, '-windowed', reason: 'v56 的启动参数不受 v62 新列影响');

    // 关键的向后兼容断言：老行的新列是空串 = 用户没设过 = 解析层回落到关闭。
    // 老用户绝不能因为一次升级就被莫名打开超分。
    expect(legacy.upscalingMode, '',
        reason: '既有行回填空串 = 未设置 = 超分关闭 = Never break userspace');
  });

  test('v62：档位字符串原样往返，DAO 单列写入不碰其它列', () async {
    final FushiDatabase db = await openV59Db();

    await db.setGalgameUpscalingMode('legacy_game', 'installed_only');
    GalgameRow row = (await db.getGalgame('legacy_game'))!;
    expect(row.upscalingMode, 'installed_only');
    expect(row.launchArgs, '-windowed', reason: '单列写入不碰启动参数');
    expect(row.playStatus, 3, reason: '单列写入不碰游玩状态');

    await db.setGalgameUpscalingMode('legacy_game', 'auto');
    expect((await db.getGalgame('legacy_game'))!.upscalingMode, 'auto');

    // 清空 = 显式写空串（列非空，空串就是「未设置」），不是写 null。
    await db.setGalgameUpscalingMode('legacy_game', '');
    expect((await db.getGalgame('legacy_game'))!.upscalingMode, '');

    // 整行 upsert 省略该列时是 `Value.absent()`，UPDATE 分支**不碰**这一列
    // （drift 语义）。钉住它，免得有人以为「不传 = 清空」。
    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'legacy_game',
      name: '旧游戏',
      exePath: r'Z:\vn\game.exe',
      workdir: r'Z:\vn',
      upscalingMode: const Value<String>('off'),
      addedAt: 1700000000000,
    ));
    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'legacy_game',
      name: '旧游戏',
      exePath: r'Z:\vn\game.exe',
      workdir: r'Z:\vn',
      addedAt: 1700000000000,
    ));
    row = (await db.getGalgame('legacy_game'))!;
    expect(row.upscalingMode, 'off');
  });

  test('v62：迁移幂等——列已存在时守卫短路，不撞 duplicate column', () async {
    // 半升级过的库（列已在，user_version 还停在 59）：`if (from < 60)` 仍会进，
    // 但 `_columnExists` 守卫必须让 addColumn 变 no-op，否则 SQLite 会抛
    // "duplicate column name: upscaling_mode" 把整个库开不开。
    final FushiDatabase db = await openV59Db(withUpscalingMode: true);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);

    final GalgameRow legacy = (await db.getGalgame('legacy_game'))!;
    expect(legacy.upscalingMode, '', reason: '既有行仍是未设置');
    expect(legacy.launchArgs, '-windowed');

    // 列只有一份，没被建两遍。
    final List<QueryRow> columns =
        await db.customSelect('PRAGMA table_info(galgames)').get();
    expect(
      columns
          .map((QueryRow r) => r.read<String>('name'))
          .where((String name) => name == 'upscaling_mode'),
      hasLength(1),
    );
  });

  test('v62：fresh 库由 onCreate 建出 upscaling_mode，默认空串', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'fresh',
      name: 'fresh',
      exePath: r'Z:\f\f.exe',
      workdir: r'Z:\f',
      addedAt: 1700000000000,
    ));
    expect((await db.getGalgame('fresh'))!.upscalingMode, '',
        reason: 'onCreate 的 createAll 必须建出该列，且默认未设置 = 超分关闭');
  });
}
