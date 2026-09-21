import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v106（AniDB 文件级身份持久化，BUG-2586）：新表 `anidb_file_identities`，键是
/// `(ed2k, file_size)`（对齐 Shoko），路径 / mtime 只是免重算哈希的附属提示；
/// `anidb_file_id` 为空表示 AniDB 未收录（FILE 320），`resolved_at` 供到期复查。
void main() {
  test(
    'v105 → v106 creates anidb_file_identities and rows round-trip',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'anidb106',
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
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute('DROP TABLE anidb_file_identities');
      raw.execute('PRAGMA user_version = 105');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 112);
      expect(
        await migrated.anidbFileIdentityByHash(
          ed2k: '0123456789abcdef0123456789abcdef',
          fileSize: 1,
        ),
        isNull,
      );
      await migrated.upsertAnidbFileIdentity(
        const AnidbFileIdentitiesCompanion(
          ed2k: Value('0123456789ABCDEF0123456789abcdef'),
          fileSize: Value(1),
          anidbFileId: Value(200),
          anidbAnimeId: Value(100),
          anidbEpisodeId: Value(300),
          episodeNumber: Value('S1'),
          romajiTitle: Value('Show'),
          filePath: Value('/v/Show.mkv'),
          fileModifiedAt: Value(1000),
          resolvedAt: Value(2000),
          updatedAt: Value(2000),
        ),
      );
      // 未收录（320）也落行：三个 AniDB id 同时为空。
      await migrated.upsertAnidbFileIdentity(
        const AnidbFileIdentitiesCompanion(
          ed2k: Value('ffffffffffffffffffffffffffffffff'),
          fileSize: Value(2),
          filePath: Value('/v/Unknown.mkv'),
          resolvedAt: Value(3000),
          updatedAt: Value(3000),
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
            .select(
              "SELECT name FROM sqlite_master WHERE type='index' "
              "AND tbl_name='anidb_file_identities'",
            )
            .map((row) => row['name'])
            .toSet(),
        containsAll(<String>[
          'idx_anidb_file_identities_path',
          'idx_anidb_file_identities_anime',
        ]),
      );
      final AnidbFileIdentityRow? byHash =
          await reopened.anidbFileIdentityByHash(
        ed2k: '0123456789ABCDEF0123456789ABCDEF',
        fileSize: 1,
      );
      expect(byHash?.anidbFileId, 200, reason: '按内容键查不分大小写');
      expect(
        byHash?.ed2k,
        '0123456789abcdef0123456789abcdef',
        reason: '写侧归一化成小写，读侧按小写查',
      );
      final AnidbFileIdentityRow? byPath = await reopened
          .anidbFileIdentityByPath(filePath: '/v/Show.mkv', fileSize: 1);
      expect(byPath?.anidbAnimeId, 100);
      expect(byPath?.fileModifiedAt, 1000);
      final AnidbFileIdentityRow? miss = await reopened.anidbFileIdentityByHash(
        ed2k: 'ffffffffffffffffffffffffffffffff',
        fileSize: 2,
      );
      expect(miss, isNotNull);
      expect(miss!.anidbFileId, isNull);
      expect(miss.resolvedAt, 3000);
      expect(
        await reopened.anidbFileIdentityPaths(<String>[
          '/v/Show.mkv',
          '/v/Unknown.mkv',
          '/v/New.mkv',
        ]),
        <String>{'/v/Show.mkv', '/v/Unknown.mkv'},
      );
    },
  );

  test('half-filled AniDB ids are rejected by the CHECK constraint', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await expectLater(
      db.upsertAnidbFileIdentity(
        const AnidbFileIdentitiesCompanion(
          ed2k: Value('0123456789abcdef0123456789abcdef'),
          fileSize: Value(1),
          anidbFileId: Value(200),
          resolvedAt: Value(1),
          updatedAt: Value(1),
        ),
      ),
      throwsA(anything),
    );
  });
}
