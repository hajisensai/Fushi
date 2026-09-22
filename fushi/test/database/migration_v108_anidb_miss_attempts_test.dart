import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v108（AniDB 对齐 Shoko）：`anidb_file_identities` 加 `miss_attempts`——
/// AniDB FILE 回 320「未收录」的连续复查次数（对齐 Shoko
/// `MaxAutoScanAttemptsPerFile`），识别成功时归零。存量行默认 0 即「尚未计数」。
void main() {
  test(
    'v107 → v108 adds miss_attempts with 0 as default and keeps existing rows',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'anidbmiss108',
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

      // 把表退回 v107 形态（没有 miss_attempts 列）并塞两行存量数据：
      // 一行已识别、一行 320 未收录。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute(
        'ALTER TABLE anidb_file_identities DROP COLUMN miss_attempts',
      );
      raw.execute(
        'INSERT INTO anidb_file_identities (ed2k, file_size, anidb_file_id, '
        'anidb_anime_id, anidb_episode_id, file_path, file_modified_at, '
        "resolved_at, updated_at) VALUES ('0123456789abcdef0123456789abcdef', "
        "1, 200, 100, 300, '/v/Show.mkv', 1000, 2000, 2000)",
      );
      raw.execute(
        'INSERT INTO anidb_file_identities (ed2k, file_size, file_path, '
        "resolved_at, updated_at) VALUES ('ffffffffffffffffffffffffffffffff', "
        "2, '/v/Unknown.mkv', 3000, 3000)",
      );
      raw.execute('PRAGMA user_version = 107');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 112);

      // 存量行保留，新列默认 0。
      final AnidbFileIdentityRow? hit = await migrated.anidbFileIdentityByHash(
        ed2k: '0123456789abcdef0123456789abcdef',
        fileSize: 1,
      );
      expect(hit, isNotNull);
      expect(hit!.anidbFileId, 200);
      expect(hit.filePath, '/v/Show.mkv');
      expect(hit.missAttempts, 0);
      final AnidbFileIdentityRow? miss = await migrated.anidbFileIdentityByHash(
        ed2k: 'ffffffffffffffffffffffffffffffff',
        fileSize: 2,
      );
      expect(miss, isNotNull);
      expect(miss!.anidbFileId, isNull);
      expect(miss.missAttempts, 0);

      // 新列写得进、读得出（未收录行计一次复查）。
      await migrated.upsertAnidbFileIdentity(
        const AnidbFileIdentitiesCompanion(
          ed2k: Value('ffffffffffffffffffffffffffffffff'),
          fileSize: Value(2),
          filePath: Value('/v/Unknown.mkv'),
          missAttempts: Value(1),
          resolvedAt: Value(4000),
          updatedAt: Value(4000),
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
        contains('miss_attempts'),
      );
      final AnidbFileIdentityRow? counted = await reopened
          .anidbFileIdentityByHash(
            ed2k: 'ffffffffffffffffffffffffffffffff',
            fileSize: 2,
          );
      expect(counted?.missAttempts, 1);
      expect(counted?.resolvedAt, 4000);
      expect(
        (await reopened.anidbFileIdentityByHash(
          ed2k: '0123456789abcdef0123456789abcdef',
          fileSize: 1,
        ))?.missAttempts,
        0,
        reason: '已识别行不受影响',
      );
    },
  );

  test(
    're-running the v108 step on an already-migrated file is idempotent',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'anidbmiss108b',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';
      final FushiDatabase original = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(await original.getCollectionBookAliases(), isEmpty);
      await original.close();

      // 列已在（v108 形态），只把版本号倒回 107：升级步必须被 _columnExists
      // 短路，不能因为 duplicate column 炸掉。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute(
        'INSERT INTO anidb_file_identities (ed2k, file_size, file_path, '
        'miss_attempts, resolved_at, updated_at) VALUES '
        "('ffffffffffffffffffffffffffffffff', 2, '/v/Unknown.mkv', 3, 3000, 3000)",
      );
      raw.execute('PRAGMA user_version = 107');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(migrated.close);
      final AnidbFileIdentityRow? row = await migrated.anidbFileIdentityByHash(
        ed2k: 'ffffffffffffffffffffffffffffffff',
        fileSize: 2,
      );
      expect(row?.missAttempts, 3, reason: '既有计数原样保留');
      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 112);
      expect(
        probe
            .select('PRAGMA table_info(anidb_file_identities)')
            .where((row) => row['name'] == 'miss_attempts')
            .length,
        1,
      );
    },
  );

  test('a fresh database creates the column with default 0', () async {
    final FushiDatabase fresh = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(fresh.close);
    await fresh.upsertAnidbFileIdentity(
      const AnidbFileIdentitiesCompanion(
        ed2k: Value('0123456789abcdef0123456789abcdef'),
        fileSize: Value(1),
        filePath: Value('/v/Unknown.mkv'),
        resolvedAt: Value(1),
        updatedAt: Value(1),
      ),
    );
    final AnidbFileIdentityRow? row = await fresh.anidbFileIdentityByHash(
      ed2k: '0123456789abcdef0123456789abcdef',
      fileSize: 1,
    );
    expect(row?.missAttempts, 0);
  });
}
