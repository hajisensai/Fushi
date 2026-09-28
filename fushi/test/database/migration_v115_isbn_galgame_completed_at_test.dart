import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v115（排行榜的两个本地事实）：
///  ① `epub_books.isbn`（可空）——迁移只加列，存量回填走引擎侧 `backfillEpubIsbns`；
///  ② `galgames.completed_at`（可空毫秒）——存量「玩过」(play_status=2) 用该游戏
///     最后一次游玩会话的 `end_ms` 回填（跨 Profile 取最大），没有会话留 NULL；
///     非「玩过」一律 NULL。
void main() {
  test('v113 → v115 adds both columns and backfills completed_at', () async {
    final Directory directory = Directory.systemTemp.createTempSync('v115');
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';

    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    Future<void> game(String id, int status) => original.upsertGalgame(
      GalgamesCompanion.insert(
        id: id,
        name: id,
        exePath: '/g/$id.exe',
        workdir: '/g',
        addedAt: 0,
        playStatus: Value<int>(status),
      ),
    );
    Future<void> session(String gameId, int endMs, int profileId) =>
        original.insertGalgameSession(
          GalgameSessionsCompanion.insert(
            gameId: gameId,
            startMs: endMs - 1000,
            endMs: endMs,
            durationSeconds: 1,
            dateKey: '2026-09-01',
            profileId: Value<int>(profileId),
          ),
        );
    await game('played', 2);
    await game('played_no_sessions', 2);
    await game('playing', 3);
    await session('played', 5000, 1);
    await session('played', 9000, 2);
    await session('played', 7000, 1);
    await session('playing', 8000, 1);
    await original.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'b1',
        title: 'b1',
        epubPath: 'b1.epub',
        extractDir: '/books/b1',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
      ),
    );
    await original.close();

    // 退回 v113 形态：两列都不存在。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE epub_books DROP COLUMN isbn');
    raw.execute('ALTER TABLE galgames DROP COLUMN completed_at');
    raw.execute('PRAGMA user_version = 113');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(migrated.close);
    expect(migrated.schemaVersion, 115);
    final QueryRow version = await migrated
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(version.read<int>('user_version'), 115);

    Future<Set<String>> columnsOf(String table) async => <String>{
      for (final QueryRow row
          in await migrated.customSelect("PRAGMA table_info('$table')").get())
        row.read<String>('name'),
    };
    expect(await columnsOf('epub_books'), contains('isbn'));
    expect(await columnsOf('galgames'), contains('completed_at'));

    expect(
      (await migrated.getGalgame('played'))!.completedAt,
      9000,
      reason: '最后一次会话（跨 Profile）的结束时刻',
    );
    expect(
      (await migrated.getGalgame('played_no_sessions'))!.completedAt,
      isNull,
      reason: '没有会话 = 日期未知',
    );
    expect(
      (await migrated.getGalgame('playing'))!.completedAt,
      isNull,
      reason: '非「玩过」不回填',
    );
    expect(
      (await migrated.getEpubBook('b1'))!.isbn,
      isNull,
      reason: '迁移不读文件，ISBN 由 backfillEpubIsbns 回填',
    );
    expect(await migrated.getEpubBooksMissingIsbn(), hasLength(1));
  });

  test('fresh v115 schema has both columns', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(db.schemaVersion, 115);
    final Set<String> epubCols = <String>{
      for (final QueryRow row
          in await db.customSelect("PRAGMA table_info('epub_books')").get())
        row.read<String>('name'),
    };
    final Set<String> gameCols = <String>{
      for (final QueryRow row
          in await db.customSelect("PRAGMA table_info('galgames')").get())
        row.read<String>('name'),
    };
    expect(epubCols, contains('isbn'));
    expect(gameCols, contains('completed_at'));
  });
}
