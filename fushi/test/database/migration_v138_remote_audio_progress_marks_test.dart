import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v138：`remote_audio_bindings` 加进度同步的两个基线时刻 `server_progress_at`
/// （服务器时钟）/ `progress_synced_at`（本机时钟），让 ABS 续播判定不跨两台机器的
/// 时钟比较。纯加列、存量行 NULL；列已存在（v137 步按当前定义建的表）时跳过。
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

  Set<String> columnsOf(sqlite.Database raw) => <String>{
    for (final sqlite.Row row in raw.select(
      "PRAGMA table_info('remote_audio_bindings')",
    ))
      row['name'] as String,
  };

  test(
    'v137 → v138 adds the two progress marks; existing rows keep NULL',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'remoteaudio138',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);

      // 退回 v137 形态：没有这两列，已有一行带本机写入时间。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute(
        'ALTER TABLE remote_audio_bindings DROP COLUMN server_progress_at',
      );
      raw.execute(
        'ALTER TABLE remote_audio_bindings DROP COLUMN progress_synced_at',
      );
      raw.execute(
        'INSERT INTO remote_audio_bindings (srt_book_uid, provider, '
        'server_config_id, item_id, tracks_json, subtitle_origin, created_at, '
        "updated_at, local_progress_at) VALUES ('keep', 'audiobookshelf', "
        "'srv', 'item_9', '[]', 'local', 5, 6, 7)",
      );
      raw.execute('PRAGMA user_version = 137');
      expect(columnsOf(raw), isNot(contains('server_progress_at')));
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 141);
      final RemoteAudioBindingRow row = await migrated
          .select(migrated.remoteAudioBindings)
          .getSingle();
      expect(row.localProgressAt, 7);
      expect(row.serverProgressAt, isNull, reason: '存量行 = 从没对齐过');
      expect(row.progressSyncedAt, isNull);

      // 只写时刻列：不动其它列，也不互相覆盖。
      await migrated.updateRemoteAudioProgressMarks(
        'keep',
        serverProgressAt: 100,
        progressSyncedAt: 200,
      );
      await migrated.updateRemoteAudioProgressMarks(
        'keep',
        localProgressAt: 300,
      );
      final RemoteAudioBindingRow marked = await migrated
          .select(migrated.remoteAudioBindings)
          .getSingle();
      expect(marked.localProgressAt, 300);
      expect(marked.serverProgressAt, 100);
      expect(marked.progressSyncedAt, 200);
      expect(marked.updatedAt, 6);
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 141);
      expect(
        columnsOf(probe),
        containsAll(<String>['server_progress_at', 'progress_synced_at']),
      );
    },
  );

  test('v138 step is idempotent when the columns already exist', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'remoteaudio138idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 137');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await migrated.customSelect('SELECT 1').get();
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 141);
  });
}
