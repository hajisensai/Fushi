import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v146：新表 `music_resume_points`（音乐逐曲断点续播，反馈 QAondMh4M5）。纯新增：
/// 升级建表、不碰存量数据；建过的库幂等跳过。
void main() {
  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  bool hasTable(sqlite.Database raw) => raw
      .select(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='music_resume_points'",
      )
      .isNotEmpty;

  test('v145 → v146：建出断点表，存量播放流原样，读写删可用', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'musresumev146',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE music_resume_points');
    raw.execute(
      'INSERT INTO music_play_events (track_uid, started_at) '
      "VALUES ('t1', 5)",
    );
    raw.execute('PRAGMA user_version = 145');
    expect(hasTable(raw), isFalse);
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 147);
    await migrated.upsertMusicResumePoint(
      't1',
      positionMs: 1000,
      durationMs: 60000,
      updatedAt: 1,
    );
    // 同一首再写一次是覆盖，不是第二行。
    await migrated.upsertMusicResumePoint(
      't1',
      positionMs: 2000,
      durationMs: null,
      updatedAt: 2,
    );
    final MusicResumePointRow? row = await migrated.getMusicResumePoint('t1');
    expect(row?.positionMs, 2000);
    expect(row?.durationMs, isNull);
    expect(row?.updatedAt, 2);
    expect(await migrated.getMusicResumePoint('t2'), isNull);
    await migrated.deleteMusicResumePoint('t1');
    expect(await migrated.getMusicResumePoint('t1'), isNull);
    expect(
      (await migrated
              .customSelect('SELECT COUNT(*) AS c FROM music_play_events')
              .getSingle())
          .read<int>('c'),
      1,
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 147);
    expect(hasTable(probe), isTrue);
  });

  test('v146 步幂等：表已在时跳过，已有行不丢', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'musresumev146idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.upsertMusicResumePoint('t1', positionMs: 7000, updatedAt: 7);
    await seeded.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 145');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect((await migrated.getMusicResumePoint('t1'))?.positionMs, 7000);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 147);
  });

  test('listMusicResumePoints 按块查，超过 SQLite 变量上限也能一次拿齐', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (int i = 0; i < 1203; i += 3) {
      await db.upsertMusicResumePoint('u$i', positionMs: i + 1, updatedAt: 1);
    }
    final Map<String, MusicResumePointRow> got = await db.listMusicResumePoints(
      <String>[for (int i = 0; i < 1203; i++) 'u$i'],
    );
    expect(got, hasLength(401));
    expect(got['u600']?.positionMs, 601);
    expect(got.containsKey('u1'), isFalse);
  });
}
