import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v109（AniDB 对齐 Shoko，集级）：`anidb_file_identities` 加
/// `episode_aired_at`——UDP `EPISODE` 返回的集播出日（UTC 零点毫秒），供
/// AniDB 集 → TMDB 集按「播出日 + 标题」逐集链接；存量行 null，sweep 时补问回填。
/// 同一步加 FILE 掩码扩展后的 `other_episodes`（一文件多集 JSON）/
/// `is_deprecated` / `file_state`（CRC 正误、文件版本），存量行取默认值。
void main() {
  test(
    'v108 → v109 adds nullable episode_aired_at and keeps existing rows',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'anidbaired109',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';
      final FushiDatabase original = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      // drift 惰性打开：不发一条查询库文件根本不会创建。
      expect(await original.getCollectionBookAliases(), isEmpty);
      await original.close();

      // 把表退回 v108 形态（没有四列新列）并塞一行已识别的存量数据。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      for (final String column in <String>[
        'episode_aired_at',
        'other_episodes',
        'is_deprecated',
        'file_state',
      ]) {
        raw.execute('ALTER TABLE anidb_file_identities DROP COLUMN $column');
      }
      raw.execute(
        'INSERT INTO anidb_file_identities (ed2k, file_size, anidb_file_id, '
        'anidb_anime_id, anidb_episode_id, episode_number, file_path, '
        'file_modified_at, miss_attempts, resolved_at, updated_at) VALUES '
        "('7f4b11b73f63e7500b8cb0e15a249951', 1, 4213890, 19079, 313835, '04', "
        "'/v/Bleach S17E44.mkv', 1000, 0, 2000, 2000)",
      );
      raw.execute('PRAGMA user_version = 108');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 112);

      // 存量行保留，新列为 null（= 尚未取到播出日）。
      final AnidbFileIdentityRow? hit = await migrated.anidbFileIdentityByHash(
        ed2k: '7f4b11b73f63e7500b8cb0e15a249951',
        fileSize: 1,
      );
      expect(hit, isNotNull);
      expect(hit!.anidbEpisodeId, 313835);
      expect(hit.episodeNumber, '04');
      expect(hit.episodeAiredAt, isNull);
      expect(hit.otherEpisodes, '');
      expect(hit.isDeprecated, isFalse);
      expect(hit.fileState, 0);

      // 回填写得进、读得出（其余列原样）。
      await migrated.upsertAnidbFileIdentity(
        AnidbFileIdentitiesCompanion(
          ed2k: const Value('7f4b11b73f63e7500b8cb0e15a249951'),
          fileSize: const Value(1),
          anidbFileId: const Value(4213890),
          anidbAnimeId: const Value(19079),
          anidbEpisodeId: const Value(313835),
          episodeNumber: const Value('04'),
          episodeAiredAt: Value(DateTime.utc(2026, 4, 25).millisecondsSinceEpoch),
          otherEpisodes: const Value('[[313836,50]]'),
          isDeprecated: const Value(true),
          fileState: const Value(5),
          filePath: const Value('/v/Bleach S17E44.mkv'),
          resolvedAt: const Value(2000),
          updatedAt: const Value(4000),
        ),
      );
      await migrated.close();

      final FushiDatabase reopened = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(reopened.close);
      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 112);
      expect(
        probe
            .select('PRAGMA table_info(anidb_file_identities)')
            .map((row) => row['name'])
            .toList(),
        contains('episode_aired_at'),
      );
      final AnidbFileIdentityRow? filled = await reopened
          .anidbFileIdentityByHash(
            ed2k: '7f4b11b73f63e7500b8cb0e15a249951',
            fileSize: 1,
          );
      expect(
        filled?.episodeAiredAt,
        DateTime.utc(2026, 4, 25).millisecondsSinceEpoch,
      );
      expect(filled?.otherEpisodes, '[[313836,50]]');
      expect(filled?.isDeprecated, isTrue);
      expect(filled?.fileState, 5);
      expect(filled?.anidbEpisodeId, 313835, reason: '身份列不受回填影响');
    },
  );

  test(
    're-running the v109 step on an already-migrated file is idempotent',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'anidbaired109b',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';
      final FushiDatabase original = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(await original.getCollectionBookAliases(), isEmpty);
      await original.close();

      // 列已在（v109 形态），只把版本号倒回 108：升级步必须被 _columnExists
      // 短路，不能因为 duplicate column 炸掉。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute(
        'INSERT INTO anidb_file_identities (ed2k, file_size, anidb_file_id, '
        'anidb_anime_id, anidb_episode_id, episode_aired_at, file_path, '
        'resolved_at, updated_at) VALUES '
        "('7f4b11b73f63e7500b8cb0e15a249951', 1, 4213890, 19079, 313835, "
        "1777075200000, '/v/Bleach S17E44.mkv', 3000, 3000)",
      );
      raw.execute('PRAGMA user_version = 108');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(migrated.close);
      final AnidbFileIdentityRow? row = await migrated.anidbFileIdentityByHash(
        ed2k: '7f4b11b73f63e7500b8cb0e15a249951',
        fileSize: 1,
      );
      expect(row?.episodeAiredAt, 1777075200000, reason: '既有播出日原样保留');
      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 112);
      expect(
        probe
            .select('PRAGMA table_info(anidb_file_identities)')
            .where((row) => row['name'] == 'episode_aired_at')
            .length,
        1,
      );
    },
  );

  test('v109 also adds AniDB xref columns to video_metadata_episodes',
      () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'anidbxref109',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(await original.getCollectionBookAliases(), isEmpty);
    await original.close();
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    for (final String column in <String>[
      'anidb_episode_id',
      'anidb_episode_number',
      'anidb_match_rating',
    ]) {
      raw.execute('ALTER TABLE video_metadata_episodes DROP COLUMN $column');
    }
    raw.execute('PRAGMA user_version = 108');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(migrated.close);
    expect(await migrated.getCollectionBookAliases(), isEmpty);
    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 112);
    final List<Object?> columns = probe
        .select('PRAGMA table_info(video_metadata_episodes)')
        .map((row) => row['name'])
        .toList();
    expect(columns, containsAll(<String>[
      'anidb_episode_id',
      'anidb_episode_number',
      'anidb_match_rating',
    ]));
  });

  test('a fresh database creates the column as nullable', () async {
    final FushiDatabase fresh = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(fresh.close);
    await fresh.upsertAnidbFileIdentity(
      const AnidbFileIdentitiesCompanion(
        ed2k: Value('0123456789abcdef0123456789abcdef'),
        fileSize: Value(1),
        anidbFileId: Value(200),
        anidbAnimeId: Value(100),
        anidbEpisodeId: Value(300),
        filePath: Value('/v/Show.mkv'),
        resolvedAt: Value(1),
        updatedAt: Value(1),
      ),
    );
    final AnidbFileIdentityRow? row = await fresh.anidbFileIdentityByHash(
      ed2k: '0123456789abcdef0123456789abcdef',
      fileSize: 1,
    );
    expect(row?.anidbEpisodeId, 300);
    expect(row?.episodeAiredAt, isNull);
  });
}
