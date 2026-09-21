import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v110（AniDB 对齐 Shoko，一文件多集）：`video_metadata_episodes.book_uid`
/// 去掉列级 UNIQUE——AniDB FILE 的 other episodes（`01-02` 合集文件）要把同一
/// 个文件绑到两条分集行（Shoko `CrossRef_File_Episode`）。列级 UNIQUE 是内联
/// 约束，迁移走 alterTable 重建表：既有行（含 id、绑定）原样保留、子表引用不
/// 悬空、旧唯一自动索引消失、补一条普通 book_uid 索引。
void main() {
  test(
    'v109 → v110 drops the book_uid UNIQUE, keeps rows and allows a second '
    'binding for the same file',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'epmulti110',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';
      final FushiDatabase original = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      await original.upsertVideoBook(
        const VideoBooksCompanion(
          bookUid: Value<String>('show-e1e2'),
          title: Value<String>('Show 01-02'),
          videoPath: Value<String>('D:/Show/Show 01-02.mkv'),
        ),
      );
      final int collectionId = await original.createMediaCollection(
        'Show',
        collectionType: 'playlist',
      );
      final int workId = await original.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          collectionId: Value<int?>(collectionId),
          mediaType: 'tv',
          title: 'Show',
          updatedAt: 1,
        ),
      );
      final int seasonId = await original.upsertVideoMetadataSeason(
        VideoMetadataSeasonsCompanion.insert(
          workId: workId,
          seasonNumber: 1,
          updatedAt: 1,
        ),
      );
      await original.upsertVideoMetadataEpisode(
        VideoMetadataEpisodesCompanion.insert(
          seasonId: seasonId,
          bookUid: const Value<String?>('show-e1e2'),
          episodeNumber: 1,
          title: const Value<String?>('E1'),
          anidbEpisodeId: const Value<int?>(301),
          updatedAt: 1,
        ),
      );
      final VideoMetadataEpisodeRow first =
          (await original.getVideoMetadataEpisodes(seasonId)).single;
      await original.upsertVideoMetadataEpisode(
        VideoMetadataEpisodesCompanion.insert(
          seasonId: seasonId,
          episodeNumber: 2,
          title: const Value<String?>('E2'),
          updatedAt: 1,
        ),
      );
      // 子表以 id 引用分集行：重建后必须还指着同一行。
      await original.replaceVideoMetadataProviderIdentities(
        episodeId: first.id,
        identities: <VideoMetadataProviderIdentitiesCompanion>[
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'episode:${first.id}:tmdb',
            provider: 'tmdb',
            externalId: 'ep-1',
            updatedAt: 1,
          ),
        ],
      );
      await original.close();

      // 把表退回 v109 形态：book_uid 带列级 UNIQUE。读 fresh 建表语句原文，
      // 只在 book_uid 列上插回 UNIQUE，其余列/约束与旧版本逐字一致。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      final String createSql = raw
          .select(
            "SELECT sql FROM sqlite_master WHERE type = 'table' "
            "AND name = 'video_metadata_episodes'",
          )
          .single['sql'] as String;
      const String bookColumn = '"book_uid" TEXT NULL REFERENCES';
      expect(createSql, contains(bookColumn));
      raw.execute('PRAGMA foreign_keys = OFF');
      raw.execute(
        createSql
            .replaceFirst('CREATE TABLE "video_metadata_episodes"',
                'CREATE TABLE "video_metadata_episodes_v109"')
            .replaceFirst(bookColumn, '"book_uid" TEXT NULL UNIQUE REFERENCES'),
      );
      raw.execute(
        'INSERT INTO video_metadata_episodes_v109 '
        'SELECT * FROM video_metadata_episodes',
      );
      raw.execute('DROP TABLE video_metadata_episodes');
      raw.execute(
        'ALTER TABLE video_metadata_episodes_v109 '
        'RENAME TO video_metadata_episodes',
      );
      raw.execute('DROP INDEX IF EXISTS idx_video_metadata_episodes_book');
      // 旧形态下第二次绑定同一文件确实会撞 UNIQUE（这就是 v110 要去掉的东西）。
      expect(
        () => raw.execute(
          "UPDATE video_metadata_episodes SET book_uid = 'show-e1e2' "
          'WHERE episode_number = 2',
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
      raw.execute('PRAGMA user_version = 109');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 112);

      // 既有行与 id、绑定、子表引用原样。
      final List<VideoMetadataEpisodeRow> episodes =
          await migrated.getVideoMetadataEpisodes(seasonId);
      expect(episodes.map((VideoMetadataEpisodeRow e) => e.episodeNumber),
          <int>[1, 2]);
      expect(episodes[0].id, first.id);
      expect(episodes[0].bookUid, 'show-e1e2');
      expect(episodes[0].anidbEpisodeId, 301);
      expect(episodes[1].bookUid, isNull);
      final List<VideoMetadataProviderIdentityRow> identities =
          await migrated.getVideoMetadataProviderIdentities(
        episodeId: first.id,
      );
      expect(identities.map((VideoMetadataProviderIdentityRow i) => i.externalId),
          <String>['ep-1']);

      // 同一文件再绑第二集：不再撞唯一约束，两条行都指向这个文件。
      await migrated.upsertVideoMetadataEpisode(
        VideoMetadataEpisodesCompanion.insert(
          seasonId: seasonId,
          bookUid: const Value<String?>('show-e1e2'),
          episodeNumber: 2,
          title: const Value<String?>('E2'),
          anidbEpisodeId: const Value<int?>(302),
          updatedAt: 2,
        ),
      );
      final List<VideoMetadataEpisodeRow> bound =
          await migrated.getVideoMetadataEpisodesByBook('show-e1e2');
      expect(bound.map((VideoMetadataEpisodeRow e) => e.episodeNumber),
          <int>[1, 2]);
      expect(bound.map((VideoMetadataEpisodeRow e) => e.anidbEpisodeId),
          <int>[301, 302]);

      // 唯一自动索引没了、普通反查索引在。
      final sqlite.Database check = sqlite.sqlite3.open(path);
      final List<Map<String, Object?>> indexes =
          check.select('PRAGMA index_list(video_metadata_episodes)').toList();
      for (final Map<String, Object?> index in indexes) {
        if (index['unique'] != 1) continue;
        final List<Map<String, Object?>> columns = check
            .select('PRAGMA index_info("${index['name']}")')
            .toList();
        expect(
          columns.length == 1 && columns.single['name'] == 'book_uid',
          isFalse,
          reason: 'book_uid 上不该再有唯一索引：${index['name']}',
        );
      }
      expect(
        indexes.map((Map<String, Object?> i) => i['name']),
        contains('idx_video_metadata_episodes_book'),
      );
      check.dispose();
      await migrated.close();
    },
  );

  test('fresh database allows one file bound to two episode rows', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('b'),
        title: Value<String>('01-02'),
        videoPath: Value<String>('D:/x/01-02.mkv'),
      ),
    );
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: const Value<String?>('b'),
        mediaType: 'tv',
        title: 'X',
        updatedAt: 1,
      ),
    );
    final int seasonId = await db.upsertVideoMetadataSeason(
      VideoMetadataSeasonsCompanion.insert(
        workId: workId,
        seasonNumber: 1,
        updatedAt: 1,
      ),
    );
    for (int n = 1; n <= 2; n++) {
      await db.upsertVideoMetadataEpisode(
        VideoMetadataEpisodesCompanion.insert(
          seasonId: seasonId,
          bookUid: const Value<String?>('b'),
          episodeNumber: n,
          updatedAt: 1,
        ),
      );
    }
    final List<VideoMetadataEpisodeRow> bound =
        await db.getVideoMetadataEpisodesByBook('b');
    expect(bound.map((VideoMetadataEpisodeRow e) => e.episodeNumber),
        <int>[1, 2]);
  });
}
