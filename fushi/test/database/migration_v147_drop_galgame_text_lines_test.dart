import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v147：删游戏台词表 `galgame_text_lines`（v134 建）。它唯一的读者「我库里的例句」
/// 按反馈 4S2_J80DfK 下架，app 也不再写入；表与存量台词一并删掉。迁移幂等：
/// 从没建过这张表的库（v134 之前升上来 / 新装）照常升级，重跑不报错，别的数据不动。
void main() {
  /// v134 当时的建表语句（外键 cascade 挂 galgames、(game_id, text) 唯一）。
  const String v134Ddl =
      'CREATE TABLE "galgame_text_lines" ('
      '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      '"game_id" TEXT NOT NULL REFERENCES galgames (id) ON DELETE CASCADE, '
      '"text" TEXT NOT NULL, '
      '"received_at" INTEGER NOT NULL, '
      'UNIQUE ("game_id", "text"))';

  bool hasTable(sqlite.Database raw) => raw
      .select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' "
        "AND name = 'galgame_text_lines'",
      )
      .isNotEmpty;

  int userVersion(sqlite.Database raw) =>
      raw.select('PRAGMA user_version').first.values.first as int;

  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'g1',
        name: 'Game g1',
        exePath: '/g/g1.exe',
        workdir: '/g',
        addedAt: 0,
      ),
    );
    await db.close();
    return path;
  }

  Future<void> reopen(String path) async {
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    try {
      expect(db.schemaVersion, 148);
      expect(await db.getGalgame('g1'), isNotNull, reason: '游戏本身不受影响');
    } finally {
      await db.close();
    }
  }

  test('新装库不建 galgame_text_lines', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'gtl_v147_fresh',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    addTearDown(raw.dispose);
    expect(hasTable(raw), isFalse);
    expect(userVersion(raw), 148);
  });

  test('v146 → v147：带存量台词的表连数据一起删掉；重跑幂等', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'gtl_v147_drop',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute(v134Ddl);
    raw.execute(
      'INSERT INTO galgame_text_lines (game_id, text, received_at) VALUES '
      "('g1', 'The night is long', 10), ('g1', 'Run to the sea', 20)",
    );
    raw.execute('PRAGMA user_version = 146');
    raw.dispose();

    await reopen(path);

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(hasTable(probe), isFalse, reason: '表与存量台词一并删掉');
    expect(userVersion(probe), 148);
    // 表已经不在时重跑这一步（IF EXISTS）不报错。
    probe.execute('PRAGMA user_version = 146');
    probe.dispose();

    await reopen(path);
    final sqlite.Database again = sqlite.sqlite3.open(path);
    addTearDown(again.dispose);
    expect(hasTable(again), isFalse);
    expect(userVersion(again), 148);
  });

  test('v133 → v147：v134 之前的库从没建过这张表，照常升级', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'gtl_v147_pre134',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 133');
    raw.dispose();

    await reopen(path);
    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(hasTable(probe), isFalse, reason: 'v134 步不再建，v147 也不必删');
    expect(userVersion(probe), 148);
  });
}
