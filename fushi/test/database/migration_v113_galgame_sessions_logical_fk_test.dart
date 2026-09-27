import 'dart:io';

import 'package:drift/drift.dart' show QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v113（PR #1697 审查阻断 1，所有者 2026-09-27 拍板「保留会话」）：
/// `galgame_sessions.game_id` 去掉 `REFERENCES galgames ON DELETE CASCADE`，
/// 改逻辑外键，并加 `game_title` 快照列。v112 形态下从库移除游戏会经 cascade 删光
/// 它在所有 Profile 下的游玩会话——不勾「同时删除统计数据」也丢游玩时长。
///
/// 迁移走 alterTable 重建：既有行（含自增 id）原样保留、FK 消失、索引补回；迁移后
/// 删游戏，会话仍在。
void main() {
  test(
    'v112 → v113 drops the cascade FK; removing a game keeps its sessions',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'galsess113',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';

      final FushiDatabase original = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      await original.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'Game One',
          exePath: '/g/one.exe',
          workdir: '/g',
          addedAt: 0,
        ),
      );
      await original.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g2',
          name: 'Game Two',
          exePath: '/g/two.exe',
          workdir: '/g',
          addedAt: 0,
        ),
      );
      final int keptId = await original.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: 1000,
          endMs: 61000,
          durationSeconds: 60,
          dateKey: '2026-09-01',
        ),
      );
      await original.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g2',
          startMs: 2000,
          endMs: 122000,
          durationSeconds: 120,
          dateKey: '2026-09-02',
        ),
      );
      await original.close();

      // 把表退回 v112 形态：game_id 带 FK cascade、没有 game_title。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute('PRAGMA foreign_keys = OFF');
      raw.execute(
        'CREATE TABLE "galgame_sessions_v112" ('
        '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
        '"game_id" TEXT NOT NULL REFERENCES galgames (id) ON DELETE CASCADE, '
        '"start_ms" INTEGER NOT NULL, "end_ms" INTEGER NOT NULL, '
        '"duration_seconds" INTEGER NOT NULL, "date_key" TEXT NOT NULL, '
        '"profile_id" INTEGER NOT NULL DEFAULT 0)',
      );
      raw.execute(
        'INSERT INTO galgame_sessions_v112 '
        '(id, game_id, start_ms, end_ms, duration_seconds, date_key, profile_id) '
        'SELECT id, game_id, start_ms, end_ms, duration_seconds, date_key, '
        'profile_id FROM galgame_sessions',
      );
      raw.execute('DROP TABLE galgame_sessions');
      raw.execute(
        'ALTER TABLE galgame_sessions_v112 RENAME TO galgame_sessions',
      );
      // 旧库上的索引（v105 profile_date 等）必须随重建原样保留。
      raw.execute(
        'CREATE INDEX idx_galgame_sessions_game_start '
        'ON galgame_sessions (game_id, start_ms DESC)',
      );
      raw.execute(
        'CREATE INDEX idx_galgame_sessions_date ON galgame_sessions (date_key)',
      );
      raw.execute(
        'CREATE INDEX idx_galgame_sessions_profile_date '
        'ON galgame_sessions (profile_id, date_key)',
      );
      expect(
        raw.select('PRAGMA foreign_key_list(galgame_sessions)'),
        isNotEmpty,
      );
      // 旧形态下删游戏确实会 cascade 掉会话（这就是 v113 要修的东西）。
      raw.execute('PRAGMA foreign_keys = ON');
      raw.execute('BEGIN');
      raw.execute("DELETE FROM galgames WHERE id = 'g2'");
      expect(
        raw.select("SELECT 1 FROM galgame_sessions WHERE game_id = 'g2'"),
        isEmpty,
      );
      raw.execute('ROLLBACK');
      raw.execute('PRAGMA user_version = 112');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(migrated.close);
      expect(migrated.schemaVersion, 113);

      expect(
        await migrated
            .customSelect('PRAGMA foreign_key_list(galgame_sessions)')
            .get(),
        isEmpty,
      );
      final List<String> indexes = <String>[
        for (final QueryRow row
            in await migrated
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE type = 'index' "
                  "AND tbl_name = 'galgame_sessions'",
                )
                .get())
          row.read<String>('name'),
      ];
      expect(
        indexes,
        containsAll(<String>[
          'idx_galgame_sessions_game_start',
          'idx_galgame_sessions_date',
          'idx_galgame_sessions_profile_date',
        ]),
      );

      // 既有行与自增 id 原样，game_title 取默认空串。
      final GalgameSessionRow kept = (await migrated.getGalgameSessions(
        'g1',
      )).single;
      expect(kept.id, keptId);
      expect(kept.durationSeconds, 60);
      expect(kept.gameTitle, isEmpty);

      // 迁移后从库移除游戏：会话仍在，显示名快照写进会话行。
      await migrated.deleteGalgame('g1');
      expect(await migrated.getGalgame('g1'), isNull);
      final GalgameSessionRow orphan = (await migrated.getGalgameSessions(
        'g1',
      )).single;
      expect(orphan.id, keptId);
      expect(orphan.gameTitle, 'Game One');
      expect(await migrated.getGalgameSessions('g2'), hasLength(1));
    },
  );

  test('fresh v113 schema has no FK on galgame_sessions', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(
      await db.customSelect('PRAGMA foreign_key_list(galgame_sessions)').get(),
      isEmpty,
    );
  });
}
