import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/media/video/video_library_scrape_maps.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

/// 拍板 design-nmv-video16-scrape-refresh ②：库页刮削展示映射改增量刷新。
///
/// 钉死：每一步写入之后，「旧映射 + 日志增量」与「整表重读」逐项相同；没被增量
/// 点名的映射保持原对象（下游按 identity 判变的不白重建）。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase raw) => raw.execute('PRAGMA foreign_keys = ON'),
      ),
    );
  });
  tearDown(() => db.close());

  Future<void> video(String uid) => db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: uid,
      title: uid,
      videoPath: 'D:/Videos/$uid.mkv',
    ),
  );

  Future<int> collectionWork(int collectionId) => db.upsertVideoMetadataWork(
    VideoMetadataWorksCompanion.insert(
      collectionId: Value<int?>(collectionId),
      mediaType: 'tv',
      title: 'series $collectionId',
      updatedAt: 1,
    ),
  );

  Future<int> season(int workId, int number) => db
      .into(db.videoMetadataSeasons)
      .insert(
        VideoMetadataSeasonsCompanion.insert(
          workId: workId,
          seasonNumber: number,
          updatedAt: 1,
        ),
      );

  Future<int> episode(int seasonId, String uid, int number, {int? minutes}) =>
      db
          .into(db.videoMetadataEpisodes)
          .insert(
            VideoMetadataEpisodesCompanion.insert(
              seasonId: seasonId,
              bookUid: Value<String?>(uid),
              episodeNumber: number,
              runtimeMinutes: Value<int?>(minutes),
              updatedAt: 1,
            ),
          );

  Future<int> still(int episodeId) => db
      .into(db.videoMetadataImages)
      .insert(
        VideoMetadataImagesCompanion.insert(
          episodeId: Value<int?>(episodeId),
          provider: 'tmdb',
          kind: 'still',
          remoteUrl: 'https://images.example/still-$episodeId.jpg',
          updatedAt: 1,
        ),
      );

  Future<int> poster(int workId) => db
      .into(db.videoMetadataImages)
      .insert(
        VideoMetadataImagesCompanion.insert(
          workId: Value<int?>(workId),
          provider: 'anidb',
          kind: 'poster',
          remoteUrl: 'https://images.example/poster-$workId.jpg',
          updatedAt: 1,
        ),
      );

  Future<void> scrapeMeta(String uid, String airDate) =>
      db.upsertVideoScrapeMeta(
        VideoScrapeMetaCompanion.insert(
          bookUid: uid,
          source: 'anidb',
          subjectId: uid,
          title: uid,
          airDate: Value<String?>(airDate),
          scrapedAt: DateTime.utc(2026),
        ),
      );

  /// 每一步：增量刷新后的映射必须与整表重读逐项相同。
  Future<(VideoLibraryScrapeMaps, VideoScrapeJournalCursor)> step(
    VideoLibraryScrapeMaps maps,
    VideoScrapeJournalCursor cursor,
    String what,
  ) async {
    final VideoScrapePresentationDelta? delta = await db
        .readVideoScrapePresentationDelta(cursor);
    expect(delta, isNotNull, reason: what);
    final VideoLibraryScrapeMaps patched = maps.patched(
      delta!,
      await db.getVideoScrapePresentationRows(delta),
    );
    final VideoLibraryScrapeMaps full = await VideoLibraryScrapeMaps.load(db);
    expect(_normalize(patched), _normalize(full), reason: what);
    return (patched, delta.cursor);
  }

  test('每一步写入后，增量刷新与整表重读逐项相同', () async {
    for (final String uid in <String>['a1', 'a2', 'b1', 'loose']) {
      await video(uid);
    }
    final int cidA = await db.createMediaCollection(
      'A',
      collectionType: 'playlist',
    );
    final int cidB = await db.createMediaCollection(
      'B',
      collectionType: 'playlist',
    );
    final int workA = await collectionWork(cidA);
    final int seasonA = await season(workA, 1);
    final int epA1 = await episode(seasonA, 'a1', 1, minutes: 24);
    await episode(seasonA, 'a2', 2, minutes: 24);
    await still(epA1);
    await poster(workA);
    await scrapeMeta('loose', '2019-01-01');

    VideoScrapeJournalCursor cursor = await db
        .videoScrapePresentationJournalCursor();
    VideoLibraryScrapeMaps maps = await VideoLibraryScrapeMaps.load(db);
    expect(maps.fileEpisodesByBook.keys, <String>['a1']);

    // 1. 新作品整套落库（批次里最常见的一步）。
    final int workB = await collectionWork(cidB);
    final int seasonB = await season(workB, 1);
    final int epB1 = await episode(seasonB, 'b1', 1, minutes: 30);
    await still(epB1);
    await poster(workB);
    await scrapeMeta('b1', '2021-04-01');
    (maps, cursor) = await step(maps, cursor, '新作品落库');

    // 只写合集刮削资料：按视频 uid / 作品分桶的映射一个都不换对象。
    await db.upsertCollectionScrapeMeta(
      CollectionScrapeMetaCompanion.insert(
        collectionId: Value<int>(cidB),
        source: 'anidb',
        subjectId: 'B',
        title: 'B',
        scrapedAt: DateTime.utc(2026),
      ),
    );
    final VideoLibraryScrapeMaps beforeMetaOnly = maps;
    (maps, cursor) = await step(maps, cursor, '只写合集刮削资料');
    expect(
      identical(maps.airYearByUid, beforeMetaOnly.airYearByUid) &&
          identical(
            maps.fileEpisodesByBook,
            beforeMetaOnly.fileEpisodesByBook,
          ) &&
          identical(
            maps.localExtraBookUids,
            beforeMetaOnly.localExtraBookUids,
          ) &&
          identical(
            maps.metadataImagesByWork,
            beforeMetaOnly.metadataImagesByWork,
          ),
      isTrue,
      reason: '没被点名的映射保持原对象',
    );
    expect(
      identical(
        maps.collectionScrapeMetaById,
        beforeMetaOnly.collectionScrapeMetaById,
      ),
      isFalse,
    );

    // 2. 原来没有剧照的那集补上剧照 → 进表；季号变了 → 两集都要重算。
    final int epA2 = (await db.getAllVideoMetadataEpisodes())
        .firstWhere((VideoMetadataEpisodeRow e) => e.bookUid == 'a2')
        .id;
    await still(epA2);
    await db.customStatement(
      'UPDATE video_metadata_seasons SET season_number = 2 WHERE id = ?',
      <Object>[seasonA],
    );
    (maps, cursor) = await step(maps, cursor, '补剧照 + 改季号');

    // 3. 删掉 a1 的剧照 → 出表；分集改绑到 loose。
    await db.customStatement(
      'DELETE FROM video_metadata_images WHERE episode_id = ?',
      <Object>[epA1],
    );
    await db.customStatement(
      "UPDATE video_metadata_episodes SET book_uid = 'loose' WHERE id = ?",
      <Object>[epA2],
    );
    (maps, cursor) = await step(maps, cursor, '删剧照 + 分集改绑');

    // 4. 作品换合集、特典、媒体图组、合集刮削资料。
    await db.customStatement(
      'UPDATE video_metadata_works SET collection_id = NULL, '
      "book_uid = 'loose' WHERE id = ?",
      <Object>[workB],
    );
    await db.upsertVideoMetadataExtra(
      VideoMetadataExtrasCompanion.insert(
        extraKey: 'local:a2',
        workId: workA,
        bookUid: const Value<String?>('a2'),
        kind: 'trailer',
        sourceKind: 'local',
        title: 'extra',
        updatedAt: 1,
      ),
    );
    await db.replaceMediaImagesForCollection(cidA, <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        collectionId: Value<int?>(cidA),
        kind: MediaImageKind.backdrop.dbValue,
        path: 'D:/generated/a-backdrop.jpg',
      ),
    ]);
    await db.replaceMediaImagesForBook('loose', <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        bookUid: const Value<String?>('loose'),
        kind: MediaImageKind.logo.dbValue,
        path: 'D:/generated/loose-logo.png',
      ),
    ]);
    await db.upsertCollectionScrapeMeta(
      CollectionScrapeMetaCompanion.insert(
        collectionId: Value<int>(cidA),
        source: 'anidb',
        subjectId: 'A',
        title: 'A',
        scrapedAt: DateTime.utc(2026),
      ),
    );
    (maps, cursor) = await step(maps, cursor, '换归属 + 特典 + 图组 + 合集资料');

    // 5. 删作品（外键级联季 / 分集 / 图片 / 特典）。
    await db.customStatement(
      'DELETE FROM video_metadata_works WHERE id = ?',
      <Object>[workA],
    );
    (maps, cursor) = await step(maps, cursor, '删作品级联');

    // 6. 全量清理刮削记录。
    await db.clearAllVideoScrapeRecords();
    (maps, cursor) = await step(maps, cursor, '全量清理');
    expect(maps.metadataWorkByCollection, isEmpty);
    expect(maps.airYearByUid, isEmpty);
  });

  test('书架行合并：只换点名的行，不存在的删掉，顺序不动', () async {
    for (final String uid in <String>['a', 'b', 'c']) {
      await video(uid);
    }
    final List<VideoBookRow> base = await VideoBookRepository(db).listForShelf()
      ..sort(
        (VideoBookRow x, VideoBookRow y) => x.bookUid.compareTo(y.bookUid),
      );
    await db.updateVideoBookTitle('b', 'B2');
    await db.customStatement("DELETE FROM video_books WHERE book_uid = 'c'");
    final List<VideoBookRow> fresh = await VideoBookRepository(
      db,
    ).listForShelfByUids(<String>{'b', 'c'});
    final List<VideoBookRow> merged = mergeVideoShelfRows(base, fresh, <String>{
      'b',
      'c',
    });
    expect(merged.map((VideoBookRow r) => r.bookUid), <String>['a', 'b']);
    expect(merged[1].title, 'B2');
    expect(identical(merged[0], base[0]), isTrue);
  });
}

/// 把映射展开成可比较的纯值（[VideoFileEpisodeStills] 没有值相等）。
Map<String, Object?> _normalize(VideoLibraryScrapeMaps maps) =>
    <String, Object?>{
      'airYear': maps.airYearByUid,
      'collectionMeta': maps.collectionScrapeMetaById,
      'workByCollection': maps.metadataWorkByCollection,
      'workByBook': maps.metadataWorkByBook,
      'imagesByWork': maps.metadataImagesByWork,
      'fileEpisodes': <String, Object?>{
        for (final MapEntry<String, List<VideoFileEpisodeStills>> e
            in maps.fileEpisodesByBook.entries)
          e.key: <Object?>[
            for (final VideoFileEpisodeStills ep in e.value)
              <Object?>[
                ep.episodeId,
                ep.seasonNumber,
                ep.episodeNumber,
                ep.runtimeMinutes,
                ep.stills,
              ],
          ],
      },
      'runtime': maps.runtimeMinutesByBookUid,
      'extras': maps.localExtraBookUids,
      'mediaByCollection': maps.mediaImagesByCollection,
      'mediaByBook': maps.mediaImagesByBookUid,
    };
