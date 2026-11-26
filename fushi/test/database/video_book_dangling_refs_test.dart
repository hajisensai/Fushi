import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// BUG-5545：用户库里 79 部作品、148 条刮削快照、1 条本地花絮的 `book_uid` 指向已经
/// 不存在的 `video_books`（页级撕裂留下的孤儿，外键当时没管上）。库管家 ⑤ 的系列
/// 关系补填拿孤儿作品当 owner 往 `collection_relations` 插行，撞外键（787）。这里钉死
/// [FushiDatabase.purgeDanglingVideoBookRefs] 按外键语义清孤儿、不碰活数据，以及 v182
/// 迁移跑一次后 `foreign_key_check` 为空。
void main() {
  test('v181 → v182：孤儿作品子树 / 刮削快照 / 本地花絮清掉，活视频与合集作品不动；幂等', () async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'video_dangling_v182',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/live'),
        title: Value<String>('live'),
        videoPath: Value<String>('D:/live.mkv'),
      ),
    );
    final int collection = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    final int liveWork = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: const Value<String?>('video/live'),
        mediaType: 'movie',
        title: 'Live',
        updatedAt: 1,
      ),
    );
    final int showWork = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collection),
        mediaType: 'tv',
        title: 'Show',
        updatedAt: 1,
      ),
    );
    await db.close();

    // 父行没了、子树还在：外键关着的原生连接直接写库模拟（与用户库同形）。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute(
      'INSERT INTO video_metadata_works (id, book_uid, media_type, title, '
      "updated_at) VALUES (900, 'video/ghost', 'tv', 'Ghost', 2)",
    );
    raw.execute(
      'INSERT INTO video_metadata_seasons (work_id, season_number, updated_at) '
      'VALUES (900, 1, 2)',
    );
    raw.execute(
      'INSERT INTO video_metadata_provider_identities (identity_key, work_id, '
      "provider, external_id, is_primary, updated_at) VALUES ('ghost:anidb', "
      "900, 'anidb', '42', 1, 2)",
    );
    raw.execute(
      'INSERT INTO video_scrape_meta (book_uid, source, subject_id, title, '
      "scraped_at) VALUES ('video/ghost', 'bangumi', '7', 'Ghost', 2)",
    );
    raw.execute(
      'INSERT INTO video_scrape_meta (book_uid, source, subject_id, title, '
      "scraped_at) VALUES ('video/live', 'bangumi', '8', 'Live', 2)",
    );
    // 挂在活合集作品下、指向已不存在视频的本地花絮（用户库里那一条）。
    raw.execute(
      'INSERT INTO video_metadata_extras (extra_key, work_id, book_uid, kind, '
      "source_kind, title, updated_at) VALUES ('local:video/ghost-ed', "
      "$showWork, 'video/ghost-ed', 'clip', 'local', 'NCED', 2)",
    );
    expect(raw.select('PRAGMA foreign_key_check'), hasLength(3));
    raw.execute('PRAGMA user_version = 181');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, kFushiDbSchemaVersion);
    expect(
      await migrated.customSelect('PRAGMA foreign_key_check').get(),
      isEmpty,
    );
    Future<List<Object?>> column(String sql) async => <Object?>[
      for (final QueryRow row in await migrated.customSelect(sql).get())
        row.data.values.first,
    ];
    expect(
      await column('SELECT id FROM video_metadata_works ORDER BY id'),
      <Object?>[liveWork, showWork],
    );
    expect(
      await column('SELECT COUNT(*) FROM video_metadata_seasons'),
      <Object?>[0],
      reason: '孤儿作品的季随作品级联',
    );
    expect(
      await column('SELECT COUNT(*) FROM video_metadata_provider_identities'),
      <Object?>[0],
    );
    expect(await column('SELECT book_uid FROM video_scrape_meta'), <Object?>[
      'video/live',
    ]);
    expect(
      await column('SELECT COUNT(*) FROM video_metadata_extras'),
      <Object?>[0],
    );
    expect(await migrated.purgeDanglingVideoBookRefs(), 0, reason: '幂等');
    await migrated.close();
  });
}
