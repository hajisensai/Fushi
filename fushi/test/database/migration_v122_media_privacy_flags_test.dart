import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v122：作品级「私密」标记表 `media_privacy_flags`（不上传排行榜、不推 Bangumi）。
///
/// 迁移只建表、不动数据，重跑幂等；读写 API 的 LWW 语义（设 / 取消各推一只时钟、
/// 合并逐戳取大、相等取消胜）在这里钉死——互联同步与排行榜过滤都只认这套口径。
void main() {
  Set<String> columnsOf(sqlite.Database raw, String table) => <String>{
    for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
      row['name'] as String,
  };

  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  test('v121 → v122 建 media_privacy_flags；重跑幂等、不清数据', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'media_privacy_v122',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE media_privacy_flags');
    expect(tableExists(raw, 'media_privacy_flags'), isFalse);
    raw.execute('PRAGMA user_version = 121');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 136);
    await migrated.setMediaPrivate(TagHostKind.epub, 'book-a', true, at: 10);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 136);
    expect(columnsOf(probe, 'media_privacy_flags'), <String>{
      'media_kind',
      'entry_key',
      'private_at',
      'cleared_at',
    });
    final List<sqlite.Row> pk = probe
        .select("PRAGMA table_info('media_privacy_flags')")
        .where((sqlite.Row r) => (r['pk'] as int) > 0)
        .toList();
    expect(pk.map((sqlite.Row r) => r['name']), <String>[
      'media_kind',
      'entry_key',
    ]);
    // 重跑 v122 步：表已在，不得报错、不得清数据。
    probe.execute('PRAGMA user_version = 121');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(await reopened.isMediaPrivate(TagHostKind.epub, 'book-a'), isTrue);
    await reopened.close();
  });

  group('私密标记 API', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('设 / 取消各推进一只时钟，另一只原样保留', () async {
      expect(await db.isMediaPrivate(TagHostKind.video, 'v1'), isFalse);
      await db.setMediaPrivate(TagHostKind.video, 'v1', true, at: 100);
      expect(await db.isMediaPrivate(TagHostKind.video, 'v1'), isTrue);
      await db.setMediaPrivate(TagHostKind.video, 'v1', false, at: 200);
      expect(await db.isMediaPrivate(TagHostKind.video, 'v1'), isFalse);
      expect(await db.mediaPrivacyClock(TagHostKind.video, 'v1'), (
        privateAt: 100,
        clearedAt: 200,
      ));
      await db.setMediaPrivate(TagHostKind.video, 'v1', true, at: 300);
      expect(await db.isMediaPrivate(TagHostKind.video, 'v1'), isTrue);
      expect(await db.mediaPrivacyClock(TagHostKind.video, 'v1'), (
        privateAt: 300,
        clearedAt: 200,
      ));
    });

    test('按宿主种类隔离；privateEntryKeys 只列当前私密的', () async {
      await db.setMediaPrivate(TagHostKind.epub, 'same', true, at: 1);
      await db.setMediaPrivate(TagHostKind.game, 'g1', true, at: 1);
      await db.setMediaPrivate(TagHostKind.game, 'g2', true, at: 1);
      await db.setMediaPrivate(TagHostKind.game, 'g2', false, at: 2);
      expect(await db.isMediaPrivate(TagHostKind.video, 'same'), isFalse);
      expect(await db.privateEntryKeys(TagHostKind.game), <String>{'g1'});
      expect(
        (await db.allPrivacyClocksForKind(TagHostKind.game)).keys.toSet(),
        <String>{'g1', 'g2'},
        reason: '取消过的也要留着时钟，否则对端旧的私密戳会把它复活',
      );
    });

    test('合并逐戳取大；没变化不写库；相等取消胜', () async {
      await db.setMediaPrivate(TagHostKind.epub, 'b', true, at: 100);
      expect(
        await db.mergeRemotePrivacyClock(TagHostKind.epub, 'b', (
          privateAt: 50,
          clearedAt: null,
        )),
        isFalse,
        reason: '对端知识更旧：不写库（否则表变更观察者会自激）',
      );
      expect(
        await db.mergeRemotePrivacyClock(TagHostKind.epub, 'b', (
          privateAt: null,
          clearedAt: 150,
        )),
        isTrue,
      );
      expect(await db.isMediaPrivate(TagHostKind.epub, 'b'), isFalse);
      expect(
        await db.mergeRemotePrivacyClock(TagHostKind.epub, 'b', (
          privateAt: 150,
          clearedAt: null,
        )),
        isTrue,
      );
      expect(
        await db.isMediaPrivate(TagHostKind.epub, 'b'),
        isFalse,
        reason: '设与取消同一时刻：取消胜（与标签墓碑同口径）',
      );
      expect(
        mergePrivacyClocks(
          (privateAt: 1, clearedAt: 9),
          (privateAt: 5, clearedAt: null),
        ),
        (privateAt: 5, clearedAt: 9),
      );
      expect(isPrivateByClock((privateAt: null, clearedAt: null)), isFalse);
    });
  });
}
