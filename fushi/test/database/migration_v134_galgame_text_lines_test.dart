import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v134：游戏台词 `galgame_text_lines`（「我库里的例句」的游戏来源、台词唯一的持久副本，
/// 随备份 games 类别走）。迁移只建表、不动既有数据，重跑幂等；(game_id, text) 唯一；
/// 外键 cascade 跟游戏走；写入时游戏不在库里整批跳过。
void main() {
  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  Future<void> addGame(FushiDatabase db, String id) => db.upsertGalgame(
    GalgamesCompanion.insert(
      id: id,
      name: id,
      exePath: '/g/$id.exe',
      workdir: '/g',
      addedAt: 0,
    ),
  );

  test('v133 → v134 建 galgame_text_lines；重跑幂等、不清数据', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'galgame_text_lines_v134',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags();
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE galgame_text_lines');
    raw.execute('PRAGMA user_version = 133');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 139);
    await addGame(migrated, 'g1');
    expect(
      await migrated
          .insertGalgameTextLines('g1', const <({String text, int receivedAt})>[
            (text: 'hello', receivedAt: 1),
            (text: 'hello', receivedAt: 2),
            (text: '  ', receivedAt: 3),
            (text: 'world', receivedAt: 4),
          ]),
      2,
      reason: '(game_id, text) 去重、空行跳过',
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 139);
    expect(tableExists(probe, 'galgame_text_lines'), isTrue);
    expect(
      probe
          .select('PRAGMA foreign_key_list(galgame_text_lines)')
          .single['on_delete'],
      'CASCADE',
    );
    probe.execute('PRAGMA user_version = 133');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(reopened.close);
    expect(await reopened.countGalgameTextLines('g1'), 2, reason: '重跑不清数据');
    final List<GalgameTextLineChunk> chunks = await reopened
        .galgameTextLineChunks();
    expect(chunks.single.gameId, 'g1');
    expect(chunks.single.count, 2);
    expect(
      (await reopened.galgameTextLinesInChunk(
        'g1',
        chunks.single.part,
      )).map((GalgameTextLineRow r) => r.lineText),
      <String>['hello', 'world'],
    );
    // 游戏不在库里：整批跳过（不留悬空 game_id）。
    expect(
      await reopened.insertGalgameTextLines(
        'missing',
        const <({String text, int receivedAt})>[(text: 'x', receivedAt: 1)],
      ),
      0,
    );
    // 移除游戏：台词跟着删。
    await reopened.customStatement("DELETE FROM galgames WHERE id = 'g1'");
    expect(await reopened.countGalgameTextLines('g1'), 0);
  });
}
