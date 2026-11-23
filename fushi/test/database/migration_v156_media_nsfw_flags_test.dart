import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v156：作品级「NSFW」标记表 `media_nsfw_flags`（拍板台 w04vrhUAaX）。
///
/// 迁移只建表、不动数据，重跑幂等；读写 API 的 LWW 语义（设 / 取消各推一只时钟、
/// 合并逐戳取大、相等取消胜）与私密标记同口径——互联同步只认这套。
///
/// 起点是 v155（develop 的 manga_download_jobs paused 那一步）：这张表最初在 PR 里
/// 也写成 v155，与 develop 撞号后已升到 v156；已经停在 v155 的库必须还能补上这张表。
void main() {
  Set<String> columnsOf(sqlite.Database raw, String table) => <String>{
    for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
      row['name'] as String,
  };

  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  test('v155 → v156 建 media_nsfw_flags；重跑幂等、不清数据', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'media_nsfw_v156',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE media_nsfw_flags');
    expect(tableExists(raw, 'media_nsfw_flags'), isFalse);
    raw.execute('PRAGMA user_version = 155');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 173);
    await migrated.setMediaNsfw(TagHostKind.epub, 'book-a', true, at: 10);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 173);
    expect(columnsOf(probe, 'media_nsfw_flags'), <String>{
      'media_kind',
      'entry_key',
      'nsfw_at',
      'cleared_at',
    });
    // 重跑 v156 步：表已在，不得报错、不得清数据。
    probe.execute('PRAGMA user_version = 155');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(await reopened.isMediaNsfw(TagHostKind.epub, 'book-a'), isTrue);
    await reopened.close();
  });

  group('NSFW 标记 API', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('设 / 取消各推进一只时钟，另一只原样保留', () async {
      expect(await db.isMediaNsfw(TagHostKind.srt, 's1'), isFalse);
      await db.setMediaNsfw(TagHostKind.srt, 's1', true, at: 100);
      expect(await db.isMediaNsfw(TagHostKind.srt, 's1'), isTrue);
      await db.setMediaNsfw(TagHostKind.srt, 's1', false, at: 200);
      expect(await db.isMediaNsfw(TagHostKind.srt, 's1'), isFalse);
      expect(await db.mediaNsfwClock(TagHostKind.srt, 's1'), (
        nsfwAt: 100,
        clearedAt: 200,
      ));
    });

    test('与私密标记互不影响；nsfwEntryKeys 只列当前 NSFW 的', () async {
      await db.setMediaNsfw(TagHostKind.video, 'v1', true, at: 1);
      await db.setMediaNsfw(TagHostKind.video, 'v2', true, at: 1);
      await db.setMediaNsfw(TagHostKind.video, 'v2', false, at: 2);
      expect(await db.isMediaPrivate(TagHostKind.video, 'v1'), isFalse);
      expect(await db.nsfwEntryKeys(TagHostKind.video), <String>{'v1'});
      expect(
        (await db.allNsfwClocksForKind(TagHostKind.video)).keys.toSet(),
        <String>{'v1', 'v2'},
        reason: '取消过的也要留着时钟，否则对端旧的 NSFW 戳会把它复活',
      );
    });

    test('合并逐戳取大；没变化不写库；相等取消胜', () async {
      await db.setMediaNsfw(TagHostKind.epub, 'b', true, at: 100);
      expect(
        await db.mergeRemoteNsfwClock(TagHostKind.epub, 'b', (
          nsfwAt: 50,
          clearedAt: null,
        )),
        isFalse,
      );
      expect(
        await db.mergeRemoteNsfwClock(TagHostKind.epub, 'b', (
          nsfwAt: null,
          clearedAt: 100,
        )),
        isTrue,
      );
      expect(
        await db.isMediaNsfw(TagHostKind.epub, 'b'),
        isFalse,
        reason: '设与取消同一时刻：取消胜',
      );
    });
  });
}
