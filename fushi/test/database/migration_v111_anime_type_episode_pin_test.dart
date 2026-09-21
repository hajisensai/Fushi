import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/anidb_file_identity_store.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v111（AniDB 对齐 Shoko）：① `anidb_file_identities.anime_type`——FILE amask
/// 取回的动画类型（Shoko 的作品形态来源）；② `video_episode_binding_overrides`
/// ——用户手动钉死的文件 → 季集绑定（Shoko UserVerified），刮削时最高优先级。
void main() {
  test('v110 → v111 adds anime_type and the episode pin table, keeps rows',
      () async {
    final Directory directory =
        Directory.systemTemp.createTempSync('animetype111');
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase original =
        FushiDatabase.atFile(path, isMainProcess: false);
    expect(await original.getCollectionBookAliases(), isEmpty);
    await original.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE anidb_file_identities DROP COLUMN anime_type');
    raw.execute('DROP TABLE video_episode_binding_overrides');
    raw.execute(
      'INSERT INTO anidb_file_identities (ed2k, file_size, anidb_file_id, '
      'anidb_anime_id, anidb_episode_id, episode_number, file_path, '
      'file_modified_at, miss_attempts, resolved_at, updated_at) VALUES '
      "('7f4b11b73f63e7500b8cb0e15a249951', 1, 4213890, 19079, 313835, '04', "
      "'/v/Bleach S17E44.mkv', 1000, 0, 2000, 2000)",
    );
    raw.execute('PRAGMA user_version = 110');
    raw.dispose();

    final FushiDatabase migrated =
        FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(migrated.close);
    expect(migrated.schemaVersion, 112);
    final AnidbFileIdentityRow? hit = await migrated.anidbFileIdentityByHash(
      ed2k: '7f4b11b73f63e7500b8cb0e15a249951',
      fileSize: 1,
    );
    expect(hit, isNotNull);
    expect(hit!.animeType, '', reason: '存量行没类型，下次 FILE 命中时补');
    expect(await migrated.getVideoEpisodeBindingOverride('nope'), isNull,
        reason: '新表建出来、可查询');

    // 持久层写读动画类型。
    final AnidbFileIdentityDatabaseStore store =
        AnidbFileIdentityDatabaseStore(migrated);
    await store.save(AnidbFileIdentityRecord(
      ed2k: '7f4b11b73f63e7500b8cb0e15a249951',
      size: 1,
      identity: const AnidbFileIdentity(
        fileId: 4213890,
        animeId: 19079,
        episodeId: 313835,
        episodeNumber: '04',
        romajiTitle: 'Bleach',
        kanjiTitle: '',
        englishTitle: '',
        episodeTitle: '',
        episodeRomajiTitle: '',
        episodeKanjiTitle: '',
        animeType: 'TV Series',
      ),
      filePath: '/v/Bleach S17E44.mkv',
      fileModifiedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      resolvedAt: DateTime.fromMillisecondsSinceEpoch(2000),
    ));
    final AnidbFileIdentityRecord? back = await store.findByHash(
      ed2k: '7f4b11b73f63e7500b8cb0e15a249951',
      size: 1,
    );
    expect(back?.identity?.animeType, 'TV Series');
    expect(back?.identity?.isMovieType, isFalse);
  });

  test('episode pin (UserVerified) rebinds the file immediately and survives',
      () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // 内存库默认不开外键；最后一段要验 FK 级联。
    await db.customStatement('PRAGMA foreign_keys = ON');
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value<String>('f'),
      title: Value<String>('Show 03'),
      videoPath: Value<String>('D:/Show/Show 03.mkv'),
    ));
    final int collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    await db.addToCollection(collectionId, MediaKind.video, 'f');
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Show',
        updatedAt: 1,
      ),
    );
    final int seasonId = await db.upsertVideoMetadataSeason(
      VideoMetadataSeasonsCompanion.insert(
          workId: workId, seasonNumber: 1, updatedAt: 1),
    );
    for (int n = 1; n <= 3; n++) {
      await db.upsertVideoMetadataEpisode(VideoMetadataEpisodesCompanion.insert(
        seasonId: seasonId,
        episodeNumber: n,
        bookUid: Value<String?>(n == 3 ? 'f' : null),
        anidbEpisodeId: Value<int?>(n == 3 ? 303 : null),
        anidbEpisodeNumber: Value<String?>(n == 3 ? '03' : null),
        anidbMatchRating: Value<String?>(n == 3 ? 'title' : null),
        updatedAt: 1,
      ));
    }

    // 用户说这文件其实是第 2 集。
    await db.setVideoEpisodeBindingOverride('f',
        seasonNumber: 1, episodeNumber: 2);
    expect(
      await db.rebindVideoEpisodeToBook(
          workId: workId, bookUid: 'f', seasonNumber: 1, episodeNumber: 2),
      isTrue,
    );
    final Map<int, VideoMetadataEpisodeRow> rows =
        <int, VideoMetadataEpisodeRow>{
      for (final VideoMetadataEpisodeRow row
          in await db.getVideoMetadataEpisodes(seasonId))
        row.episodeNumber: row,
    };
    expect(rows[3]!.bookUid, isNull, reason: '原行解绑');
    expect(rows[3]!.anidbEpisodeId, isNull);
    expect(rows[2]!.bookUid, 'f');
    expect(rows[2]!.anidbEpisodeId, 303, reason: '文件的 AniDB 身份跟着文件走');
    expect(rows[2]!.anidbEpisodeNumber, '03');
    expect(rows[2]!.anidbMatchRating, 'userVerified');
    expect((await db.getVideoEpisodeBindingOverrides(<String>['f', 'x']))['f']
        ?.episodeNumber, 2);

    // 目标集不存在 → false，不动任何行。
    expect(
      await db.rebindVideoEpisodeToBook(
          workId: workId, bookUid: 'f', seasonNumber: 1, episodeNumber: 9),
      isFalse,
    );
    expect((await db.getVideoMetadataEpisodesByBook('f')).single.episodeNumber,
        2);

    // 清除手动指定。
    await db.clearVideoEpisodeBindingOverride('f');
    expect(await db.getVideoEpisodeBindingOverride('f'), isNull);

    // 删文件随 FK 清掉手动指定。
    await db.setVideoEpisodeBindingOverride('f',
        seasonNumber: 1, episodeNumber: 1);
    await db.deleteVideoBook('f');
    expect(await db.getVideoEpisodeBindingOverride('f'), isNull);
  });
}
