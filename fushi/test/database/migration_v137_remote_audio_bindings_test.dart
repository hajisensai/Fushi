import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v137：字幕书与远端（流式）音频的绑定表 `remote_audio_bindings`（设备本地）。
///
/// 迁移只做 `createTable`，`_tableExists` 守卫幂等：v135 库升级后表存在且列形状
/// 正确；表已存在（mid-ladder / 重复升级）时既有行原样保留、不抛异常。
void main() {
  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    // 触发 onCreate，建出当前 schema。
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  Map<String, sqlite.Row> columnsOf(sqlite.Database raw) {
    return <String, sqlite.Row>{
      for (final sqlite.Row row in raw.select(
        "PRAGMA table_info('remote_audio_bindings')",
      ))
        row['name'] as String: row,
    };
  }

  test(
    'v136 → v137 creates remote_audio_bindings with the expected columns',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'remoteaudio137',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);

      // 退回 v135 形态：没有这张表。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute('DROP TABLE remote_audio_bindings');
      raw.execute('PRAGMA user_version = 135');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 137);
      await migrated
          .into(migrated.remoteAudioBindings)
          .insert(
            RemoteAudioBindingsCompanion.insert(
              srtBookUid: 'srtbook_1',
              provider: 'audiobookshelf',
              serverConfigId: 'srv',
              itemId: 'item_1',
              tracksJson: '[]',
              createdAt: 1,
              updatedAt: 2,
            ),
          );
      final RemoteAudioBindingRow row = await migrated
          .select(migrated.remoteAudioBindings)
          .getSingle();
      expect(row.episodeId, isNull);
      expect(row.subtitleOrigin, 'local', reason: '默认是用户选的本机字幕文件');
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 137);
      final Map<String, sqlite.Row> columns = columnsOf(probe);
      expect(columns.keys.toSet(), <String>{
        'srt_book_uid',
        'provider',
        'server_config_id',
        'item_id',
        'episode_id',
        'tracks_json',
        'subtitle_origin',
        'created_at',
        'updated_at',
      });
      expect(columns['srt_book_uid']!['pk'], 1);
      expect(columns['srt_book_uid']!['type'], 'TEXT');
      expect(columns['episode_id']!['notnull'], 0);
      expect(columns['tracks_json']!['notnull'], 1);
      expect(columns['subtitle_origin']!['notnull'], 1);
    },
  );

  test(
    'v137 step is idempotent when remote_audio_bindings already exists',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'remoteaudio137idem',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);

      // 表已在（fresh createAll / 重复升级），只把版本号退回 135。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute(
        'INSERT INTO remote_audio_bindings (srt_book_uid, provider, '
        'server_config_id, item_id, tracks_json, subtitle_origin, created_at, '
        "updated_at) VALUES ('keep', 'audiobookshelf', 'srv', 'item_9', '[]', "
        "'server:20', 5, 6)",
      );
      raw.execute('PRAGMA user_version = 135');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      final RemoteAudioBindingRow row = await migrated
          .select(migrated.remoteAudioBindings)
          .getSingle();
      expect(row.srtBookUid, 'keep');
      expect(row.subtitleOrigin, 'server:20');
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 137);
    },
  );
}
