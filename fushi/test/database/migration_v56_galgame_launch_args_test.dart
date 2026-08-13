import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v56 迁移（可配置游戏启动参数）：`galgames` 加 `launch_args` 列，存用户为该游戏配置
/// 的整行命令行参数；启动时按 Windows 规则拆成 argv，逐个经 injector 的 `--arg` 透传。
///
/// 打开一个 user_version=55 的库（v55 shape：galgames 三表在场，**无** launch_args
/// 列），触发真实的 `if (from < 56)` `addColumn`，验证：
///  ① 既有 galgames 行原样保留，新列回填空串 = 不带任何参数 = 与旧版逐字节相同的启动
///     命令行（Never break userspace）；
///  ② 新列可写可读，含空格与引号的整行原样往返（不能被 DB 层擅自转义/裁剪）；
///  ③ user_version 升到当前 schemaVersion。
void main() {
  Future<FushiDatabase> openV55Db() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v55 shape：galgames 全列在场，但没有 launch_args。
          rawDb.execute('''
CREATE TABLE galgames (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  exe_path TEXT NOT NULL,
  workdir TEXT NOT NULL,
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
  subject_id TEXT,
  data_json TEXT NOT NULL,
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
            '(id, name, exe_path, workdir, added_at, play_status, sort_order) '
            r"VALUES ('legacy_game', '旧游戏', 'Z:\vn\game.exe', 'Z:\vn', "
            '1700000000000, 3, 0)',
          );
          rawDb.execute('PRAGMA user_version = 55');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v56：既有游戏行零破坏，launch_args 回填空串（= 旧启动命令行）', () async {
    final FushiDatabase db = await openV55Db();

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 86,
        reason: 'v56 给 galgames 加 launch_args（可配置游戏启动参数）');

    final GalgameRow? legacy = await db.getGalgame('legacy_game');
    expect(legacy, isNotNull, reason: '旧游戏行原样保留');
    expect(legacy!.name, '旧游戏');
    expect(legacy.exePath, r'Z:\vn\game.exe');
    expect(legacy.workdir, r'Z:\vn', reason: 'workdir 不受新列影响');
    expect(legacy.playStatus, 3);
    // 关键的向后兼容断言：老游戏升级后不带任何参数，启动命令行与旧版逐字节相同。
    expect(legacy.launchArgs, '',
        reason: '既有行回填空串 = 不发 --arg = Never break userspace');
  });

  test('v56：整行参数原样往返，含空格与引号不被 DB 层改写', () async {
    final FushiDatabase db = await openV55Db();

    const String raw = r'-windowed --save="Z:\My Saves\slot 1" -lang ja';
    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'legacy_game',
      name: '旧游戏',
      exePath: r'Z:\vn\game.exe',
      workdir: r'Z:\vn',
      launchArgs: const Value<String>(raw),
      addedAt: 1700000000000,
    ));

    expect((await db.getGalgame('legacy_game'))!.launchArgs, raw);

    // 清空 = 显式写空串（列非空，空串就是「没配置」），不是写 null。真实写路径
    // `galgamesCompanionFromEntry` 永远显式带上这一列，所以用户删光输入框能真清掉。
    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'legacy_game',
      name: '旧游戏',
      exePath: r'Z:\vn\game.exe',
      workdir: r'Z:\vn',
      launchArgs: const Value<String>(''),
      addedAt: 1700000000000,
    ));
    expect((await db.getGalgame('legacy_game'))!.launchArgs, '');

    // 反面：companion 省略该列时是 `Value.absent()`，upsert 的 UPDATE 分支**不碰**
    // 这一列（drift 语义）。钉住它，免得有人以为「不传 = 清空」而写出静默保留旧值的
    // 局部更新路径。
    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'legacy_game',
      name: '旧游戏',
      exePath: r'Z:\vn\game.exe',
      workdir: r'Z:\vn',
      launchArgs: const Value<String>('-kept'),
      addedAt: 1700000000000,
    ));
    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'legacy_game',
      name: '旧游戏',
      exePath: r'Z:\vn\game.exe',
      workdir: r'Z:\vn',
      addedAt: 1700000000000,
    ));
    expect((await db.getGalgame('legacy_game'))!.launchArgs, '-kept');
  });

  test('v56：fresh 库由 onCreate 建出 launch_args，默认空串', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.upsertGalgame(GalgamesCompanion.insert(
      id: 'fresh',
      name: 'fresh',
      exePath: r'Z:\f\f.exe',
      workdir: r'Z:\f',
      addedAt: 1700000000000,
    ));
    expect((await db.getGalgame('fresh'))!.launchArgs, '');
    expect(await db.getAllGalgames(), hasLength(1));
  });
}
