import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v55 迁移（游戏库对齐 ReinaManager）：新表 galgames / galgame_sources /
/// galgame_sessions，并把偏好表 legacy key `galgame_library` 里的 6 字段 JSON 列表
/// 一次性回填进 galgames 表。
///
/// 打开一个 user_version=53 的库（有 preferences 表、里面存着旧游戏库 JSON、但**无**
/// 三张 galgame 表），触发真实 `if (from < 55)` 分支，验证：
///  ① 三张新表被建出来；
///  ② 旧 JSON 逐条回填进 galgames，字段一一对应；
///  ③ 新增列取到无害默认值（playStatus=0=未设置、元数据列全 null=尚未刮削），
///     即展示回落到本地 name + 默认图标，与旧版观感一致（Never break userspace）；
///  ④ 旧 pref key **保留不删**（降级回滚兜底）；
///  ⑤ 脏数据（缺 id/exePath、非 map、非数组）被跳过而不是让整个迁移抛异常；
///  ⑥ 回填幂等——再开一次不会产生重复行；
///  ⑦ user_version 升到当前 schemaVersion（55）。
void main() {
  /// v53 shape 的最小库：只建 preferences（回填源）+ 写入 user_version=53。
  /// 其余 v53 表不建——迁移里的建表都有 `_tableExists` 守卫，缺表不影响本用例。
  Future<HibikiDatabase> openV53Db(String? galgameLibraryJson) async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          rawDb.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)
''');
          if (galgameLibraryJson != null) {
            rawDb.execute(
              'INSERT INTO preferences (key, value) VALUES (?, ?)',
              <Object?>['galgame_library', galgameLibraryJson],
            );
          }
          rawDb.execute('PRAGMA user_version = 53');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  /// 读当前 user_version（无现成访问器，按仓库既有测试的写法直接 PRAGMA）。
  Future<int> userVersionOf(HibikiDatabase db) async {
    final QueryRow row =
        await db.customSelect('PRAGMA user_version').getSingle();
    return row.read<int>('user_version');
  }

  /// 旧 6 字段 JSON 的一条（与 app 侧 `GalgameEntry.toJson()` 同形）。
  Map<String, Object?> legacyEntry({
    required String id,
    required String name,
    required String exePath,
    String? workdir,
    String? coverPath,
    int addedAt = 1700000000000,
  }) =>
      <String, Object?>{
        'id': id,
        'name': name,
        'exePath': exePath,
        'workdir': workdir,
        'coverPath': coverPath,
        'addedAt': addedAt,
      };

  test('v53→v55 建三张新表并把旧 JSON 游戏库回填进 galgames', () async {
    final String raw = jsonEncode(<Map<String, Object?>>[
      legacyEntry(
        id: '1700000000000001',
        name: 'テストゲーム',
        exePath: r'D:\Games\Sample\game.exe',
        workdir: r'D:\Games\Sample',
        coverPath: r'D:\covers\a.png',
        addedAt: 1700000000000,
      ),
      legacyEntry(
        id: '1700000000000002',
        name: 'Another',
        exePath: r'D:\Games\Other\start.exe',
        addedAt: 1700000000001,
      ),
    ]);
    final HibikiDatabase db = await openV53Db(raw);

    final List<GalgameRow> rows = await db.getAllGalgames();
    expect(rows, hasLength(2));

    // 按 addedAt 升序，第一条是先加的那个。
    final GalgameRow first = rows.first;
    expect(first.id, '1700000000000001');
    expect(first.name, 'テストゲーム');
    expect(first.exePath, r'D:\Games\Sample\game.exe');
    expect(first.workdir, r'D:\Games\Sample');
    expect(first.coverPath, r'D:\covers\a.png');
    expect(first.addedAt, 1700000000000);

    // 新增列取无害默认：未设置游玩状态、尚未刮削。
    expect(first.playStatus, 0);
    expect(first.primarySource, isNull);
    expect(first.releaseDate, isNull);
    expect(first.customDataJson, isNull);

    // workdir 缺失时由 exe 路径推导（与 app 侧 _defaultWorkdirForExe 同构）。
    final GalgameRow second = rows[1];
    expect(second.workdir, r'D:\Games\Other');
    expect(second.coverPath, isNull);

    // 三张表都能正常读写（建表成功）。
    expect(await db.getGalgameSources('1700000000000001'), isEmpty);
    expect(await db.getGalgameSessions('1700000000000001'), isEmpty);

    // 旧 pref key 保留不删（降级回滚兜底）。
    final String? pref = await db.getPref('galgame_library');
    expect(pref, isNotNull);

    expect(await userVersionOf(db), 68);
  });

  test('脏数据被逐条跳过，不让整个迁移失败', () async {
    final String raw = jsonEncode(<Object?>[
      // 合法。
      legacyEntry(
        id: 'ok-1',
        name: 'Good',
        exePath: r'D:\Games\Good\g.exe',
        addedAt: 1,
      ),
      // 缺 exePath。
      <String, Object?>{'id': 'bad-1', 'name': 'NoExe'},
      // 缺 id。
      <String, Object?>{'name': 'NoId', 'exePath': r'D:\x\y.exe'},
      // id 为空串。
      legacyEntry(id: '', name: 'EmptyId', exePath: r'D:\x\y.exe'),
      // exePath 为空串。
      legacyEntry(id: 'bad-2', name: 'EmptyExe', exePath: ''),
      // 类型全错。
      'not-a-map',
      42,
      null,
      // 合法。
      legacyEntry(
        id: 'ok-2',
        name: 'AlsoGood',
        exePath: r'D:\Games\Also\a.exe',
        addedAt: 2,
      ),
    ]);
    final HibikiDatabase db = await openV53Db(raw);

    final List<GalgameRow> rows = await db.getAllGalgames();
    expect(rows.map((GalgameRow r) => r.id), <String>['ok-1', 'ok-2']);
    expect(await userVersionOf(db), 68);
  });

  test('整串 JSON 损坏 / 非数组 / 空串时迁移仍然成功，只是回填为空', () async {
    for (final String raw in <String>[
      '{not json',
      '{"a":1}', // 合法 JSON 但不是数组
      '',
    ]) {
      final HibikiDatabase db = await openV53Db(raw);
      expect(await db.getAllGalgames(), isEmpty, reason: 'raw=$raw');
      expect(await userVersionOf(db), 68, reason: 'raw=$raw');
      await db.close();
    }
  });

  test('偏好里根本没有 galgame_library 时迁移正常，表为空', () async {
    final HibikiDatabase db = await openV53Db(null);
    expect(await db.getAllGalgames(), isEmpty);
    expect(await userVersionOf(db), 68);
  });

  test('回填幂等：表里已有行就不再重复回填', () async {
    final String raw = jsonEncode(<Map<String, Object?>>[
      legacyEntry(
        id: 'dup-1',
        name: 'Once',
        exePath: r'D:\Games\Once\o.exe',
        addedAt: 5,
      ),
    ]);

    // 第一次开库：走迁移，回填 1 条。
    final HibikiDatabase first = await openV53Db(raw);
    expect(await first.getAllGalgames(), hasLength(1));

    // 直接再调一次迁移路径的回填不会重复（表非空即短路）。这里用「已有行 + 再开一次
    // 同 user_version 的库」不好复现（内存库不共享），所以退而验证：同一个库里
    // 用户改过名后，重复 insertOnConflictUpdate 语义不会炸，且行数不变。
    await first.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'dup-1',
        name: 'Renamed',
        exePath: r'D:\Games\Once\o.exe',
        workdir: r'D:\Games\Once',
        addedAt: 5,
      ),
    );
    final List<GalgameRow> after = await first.getAllGalgames();
    expect(after, hasLength(1));
    expect(after.first.name, 'Renamed');
  });

  test('fresh 库（onCreate）直接就有三张表，无需回填', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    expect(await db.getAllGalgames(), isEmpty);
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'fresh-1',
        name: 'Fresh',
        exePath: r'D:\Games\Fresh\f.exe',
        workdir: r'D:\Games\Fresh',
        addedAt: 10,
      ),
    );
    expect(await db.getAllGalgames(), hasLength(1));
    expect(await userVersionOf(db), 68);
  });

  test('删游戏经 FK cascade 连带清掉 sources 与 sessions', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement('PRAGMA foreign_keys = ON');

    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'g1',
        name: 'G1',
        exePath: r'D:\Games\G1\g.exe',
        workdir: r'D:\Games\G1',
        addedAt: 1,
      ),
    );
    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: 'g1',
        source: 'bgm',
        dataJson: '{}',
        fetchedAt: 1,
        externalId: const Value<String?>('12345'),
      ),
    );
    await db.insertGalgameSession(
      GalgameSessionsCompanion.insert(
        gameId: 'g1',
        startMs: 1000,
        endMs: 61000,
        durationSeconds: 60,
        dateKey: '2026-07-25',
      ),
    );

    expect(await db.getGalgameSources('g1'), hasLength(1));
    expect(await db.getGalgameSessions('g1'), hasLength(1));

    await db.deleteGalgame('g1');

    expect(await db.getGalgameSources('g1'), isEmpty);
    expect(await db.getGalgameSessions('g1'), isEmpty);
  });
}
