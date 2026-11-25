import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:test/test.dart';

/// 拍板 design-nmv-video16-scrape-refresh：刮削展示层的「变了哪些作品」日志。
/// 库页靠它只重读变了的作品，日志漏记任何一条写入路径都会让库页停在旧值。
FushiDatabase _freshDatabase() => FushiDatabase.forTesting(
  NativeDatabase.memory(
    setup: (CommonDatabase raw) {
      raw.execute('PRAGMA foreign_keys = ON');
    },
  ),
);

Future<void> _insertVideo(FushiDatabase db, String bookUid) =>
    db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: bookUid,
        title: bookUid,
        videoPath: 'D:/Videos/$bookUid.mkv',
      ),
    );

Future<int> _insertCollectionWork(FushiDatabase db, int collectionId) =>
    db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'series $collectionId',
        updatedAt: 1,
      ),
    );

Future<int> _insertSeason(FushiDatabase db, int workId) async {
  await db.replaceVideoMetadataSeasons(workId, <VideoMetadataSeasonsCompanion>[
    VideoMetadataSeasonsCompanion.insert(
      workId: workId,
      seasonNumber: 1,
      updatedAt: 1,
    ),
  ]);
  return (await db.getVideoMetadataSeasons(workId)).single.id;
}

Future<int> _insertEpisode(
  FushiDatabase db,
  int seasonId,
  String bookUid,
  int number,
) => db
    .into(db.videoMetadataEpisodes)
    .insert(
      VideoMetadataEpisodesCompanion.insert(
        seasonId: seasonId,
        bookUid: Value<String?>(bookUid),
        episodeNumber: number,
        updatedAt: 1,
      ),
    );

Future<VideoScrapePresentationDelta> _delta(
  FushiDatabase db,
  VideoScrapeJournalCursor since,
) async {
  final VideoScrapePresentationDelta? delta = await db
      .readVideoScrapePresentationDelta(since);
  expect(delta, isNotNull, reason: '同一份日志、未被裁掉，增量必须完整可读');
  return delta!;
}

void main() {
  late FushiDatabase db;

  setUp(() => db = _freshDatabase());
  tearDown(() => db.close());

  test('没人要游标时不安装；要了之后条目刮削资料写入记成视频 uid', () async {
    expect(await db.videoScrapeJournalInstalled(), isFalse);
    await _insertVideo(db, 'b1');
    final VideoScrapeJournalCursor start = await db
        .videoScrapePresentationJournalCursor();
    expect(await db.videoScrapeJournalInstalled(), isTrue);

    await db.upsertVideoScrapeMeta(
      VideoScrapeMetaCompanion.insert(
        bookUid: 'b1',
        source: 'anidb',
        subjectId: '1',
        title: 'b1',
        airDate: const Value<String?>('2020-04-01'),
        scrapedAt: DateTime.utc(2026),
      ),
    );
    final VideoScrapePresentationDelta delta = await _delta(db, start);
    expect(delta.bookUids, <String>{'b1'});
    expect(delta.collectionIds, isEmpty);
    expect(delta.cursor.seq, greaterThan(start.seq));
    expect(delta.cursor.epoch, start.epoch);

    final VideoScrapePresentationDelta again = await _delta(db, delta.cursor);
    expect(again.isEmpty, isTrue, reason: '读过的部分不再出现');
    expect(again.cursor, delta.cursor);
  });

  test('作品 / 季 / 分集 / 图片 / 特典 / 媒体图组都记到归属键上', () async {
    await _insertVideo(db, 'ep1');
    await _insertVideo(db, 'ep2');
    final int cid = await db.createMediaCollection(
      'series',
      collectionType: 'playlist',
    );
    final VideoScrapeJournalCursor start = await db
        .videoScrapePresentationJournalCursor();

    final int workId = await _insertCollectionWork(db, cid);
    final int seasonId = await _insertSeason(db, workId);
    final int episodeId = await _insertEpisode(db, seasonId, 'ep1', 1);
    VideoScrapePresentationDelta delta = await _delta(db, start);
    expect(delta.collectionIds, <int>{cid});
    expect(delta.workIds, <int>{workId});
    expect(delta.bookUids, <String>{'ep1'});

    // 分集图只带 episode_id：解析到分集绑定的视频上。
    VideoScrapeJournalCursor cursor = delta.cursor;
    await db
        .into(db.videoMetadataImages)
        .insert(
          VideoMetadataImagesCompanion.insert(
            episodeId: Value<int?>(episodeId),
            provider: 'tmdb',
            kind: 'still',
            remoteUrl: 'https://images.example/still.jpg',
            updatedAt: 1,
          ),
        );
    delta = await _delta(db, cursor);
    expect(delta.bookUids, <String>{'ep1'});
    expect(delta.workIds, isEmpty);

    // 季号变了：落到这一季全部分集的视频上。
    cursor = delta.cursor;
    await _insertEpisode(db, seasonId, 'ep2', 2);
    delta = await _delta(db, cursor);
    cursor = delta.cursor;
    await db.customStatement(
      'UPDATE video_metadata_seasons SET season_number = 2 WHERE id = ?',
      <Object>[seasonId],
    );
    delta = await _delta(db, cursor);
    expect(delta.bookUids, <String>{'ep1', 'ep2'});

    // 作品级图片、特典、合集媒体图组、合集刮削资料。
    cursor = delta.cursor;
    await db.replaceVideoMetadataImages(
      workId: workId,
      images: <VideoMetadataImagesCompanion>[
        VideoMetadataImagesCompanion.insert(
          provider: 'anidb',
          kind: 'poster',
          remoteUrl: 'https://images.example/poster.jpg',
          updatedAt: 1,
        ),
      ],
    );
    await db.upsertVideoMetadataExtra(
      VideoMetadataExtrasCompanion.insert(
        extraKey: 'local:ep2',
        workId: workId,
        bookUid: const Value<String?>('ep2'),
        kind: 'trailer',
        sourceKind: 'local',
        title: 'extra',
        updatedAt: 1,
      ),
    );
    await db.replaceMediaImagesForCollection(cid, <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        collectionId: Value<int?>(cid),
        kind: MediaImageKind.backdrop.dbValue,
        path: 'D:/generated/backdrop.jpg',
      ),
    ]);
    await db.upsertCollectionScrapeMeta(
      CollectionScrapeMetaCompanion.insert(
        collectionId: Value<int>(cid),
        source: 'anidb',
        subjectId: '9',
        title: 'series',
        scrapedAt: DateTime.utc(2026),
      ),
    );
    delta = await _delta(db, cursor);
    expect(delta.workIds, contains(workId));
    expect(delta.bookUids, contains('ep2'));
    expect(delta.collectionIds, <int>{cid});
  });

  test('分集改绑记新旧两个视频；删作品经外键级联记下全部旧归属', () async {
    await _insertVideo(db, 'old');
    await _insertVideo(db, 'new');
    final int cid = await db.createMediaCollection(
      'series',
      collectionType: 'playlist',
    );
    final int workId = await _insertCollectionWork(db, cid);
    final int seasonId = await _insertSeason(db, workId);
    final int episodeId = await _insertEpisode(db, seasonId, 'old', 1);
    VideoScrapeJournalCursor cursor = await db
        .videoScrapePresentationJournalCursor();

    await db.customStatement(
      "UPDATE video_metadata_episodes SET book_uid = 'new' WHERE id = ?",
      <Object>[episodeId],
    );
    VideoScrapePresentationDelta delta = await _delta(db, cursor);
    expect(delta.bookUids, <String>{'old', 'new'});

    cursor = delta.cursor;
    await db.customStatement(
      'DELETE FROM video_metadata_works WHERE id = ?',
      <Object>[workId],
    );
    delta = await _delta(db, cursor);
    expect(delta.collectionIds, <int>{cid});
    expect(delta.workIds, <int>{workId});
    expect(delta.bookUids, <String>{'new'}, reason: '季 → 分集级联删除也要记下分集原来绑定的视频');
  });

  test('全量清理刮削记录：所有归属都进增量', () async {
    await _insertVideo(db, 'b1');
    final int cid = await db.createMediaCollection(
      'series',
      collectionType: 'playlist',
    );
    final int workId = await _insertCollectionWork(db, cid);
    await _insertEpisode(db, await _insertSeason(db, workId), 'b1', 1);
    await db.upsertVideoScrapeMeta(
      VideoScrapeMetaCompanion.insert(
        bookUid: 'b1',
        source: 'anidb',
        subjectId: '1',
        title: 'b1',
        scrapedAt: DateTime.utc(2026),
      ),
    );
    final VideoScrapeJournalCursor cursor = await db
        .videoScrapePresentationJournalCursor();

    await db.clearAllVideoScrapeRecords();
    final VideoScrapePresentationDelta delta = await _delta(db, cursor);
    expect(delta.collectionIds, contains(cid));
    expect(delta.workIds, contains(workId));
    expect(delta.bookUids, contains('b1'));
  });

  test('书架行只记标题 / 封面改动，其余列不记', () async {
    await _insertVideo(db, 'b1');
    VideoScrapeJournalCursor cursor = await db
        .videoScrapePresentationJournalCursor();

    await db.customStatement(
      "UPDATE video_books SET video_path = 'D:/moved.mkv' WHERE book_uid = 'b1'",
    );
    VideoScrapePresentationDelta delta = await _delta(db, cursor);
    expect(delta.isEmpty, isTrue);

    cursor = delta.cursor;
    await db.updateVideoBookTitle('b1', 'Episode title');
    await db.updateVideoBookCover('b1', 'D:/covers/b1.jpg');
    delta = await _delta(db, cursor);
    expect(delta.shelfBookUids, <String>{'b1'});
    expect(delta.bookUids, isEmpty);
  });

  test('别的日志（epoch 不符）的游标读到 null：消费方必须整表重读', () async {
    final VideoScrapeJournalCursor cursor = await db
        .videoScrapePresentationJournalCursor();
    expect(
      await db.readVideoScrapePresentationDelta(
        VideoScrapeJournalCursor(epoch: cursor.epoch + 1, seq: cursor.seq),
      ),
      isNull,
    );
  });

  test('按增量重读只取相关的行', () async {
    await _insertVideo(db, 'a');
    await _insertVideo(db, 'b');
    final int cidA = await db.createMediaCollection(
      'A',
      collectionType: 'playlist',
    );
    final int cidB = await db.createMediaCollection(
      'B',
      collectionType: 'playlist',
    );
    final int workB = await _insertCollectionWork(db, cidB);
    await _insertEpisode(db, await _insertSeason(db, workB), 'b', 1);
    final VideoScrapeJournalCursor cursor = await db
        .videoScrapePresentationJournalCursor();

    final int workA = await _insertCollectionWork(db, cidA);
    final int episodeA = await _insertEpisode(
      db,
      await _insertSeason(db, workA),
      'a',
      1,
    );
    final VideoScrapePresentationDelta delta = await _delta(db, cursor);
    final VideoScrapePresentationRows rows = await db
        .getVideoScrapePresentationRows(delta);
    expect(rows.works.map((VideoMetadataWorkRow w) => w.id), <int>[workA]);
    expect(rows.episodes.map((VideoMetadataEpisodeRow e) => e.id), <int>[
      episodeA,
    ]);
    expect(rows.seasons.single.workId, workA);
  });

  test('按文件批量取分集 / 季 / 分集图，只取点名文件的行（拍板 GLMHiavo0y）', () async {
    await _insertVideo(db, 'a');
    await _insertVideo(db, 'b');
    final int cid = await db.createMediaCollection(
      'S',
      collectionType: 'playlist',
    );
    final int seasonId = await _insertSeason(
      db,
      await _insertCollectionWork(db, cid),
    );
    final int episodeA2 = await _insertEpisode(db, seasonId, 'a', 2);
    final int episodeA1 = await _insertEpisode(db, seasonId, 'a', 1);
    final int episodeB = await _insertEpisode(db, seasonId, 'b', 3);
    Future<int> still(int episodeId) => db
        .into(db.videoMetadataImages)
        .insert(
          VideoMetadataImagesCompanion.insert(
            episodeId: Value<int?>(episodeId),
            provider: 'tmdb',
            kind: 'thumb',
            remoteUrl: 'https://images.example/$episodeId.jpg',
            updatedAt: 1,
          ),
        );
    final int stillA2 = await still(episodeA2);
    final int stillA1 = await still(episodeA1);
    await still(episodeB);

    final VideoFileEpisodeRows rows = await db.getVideoFileEpisodeRows(<String>[
      'a',
      'a',
    ]);
    expect(rows.episodes.map((VideoMetadataEpisodeRow e) => e.id), <int>[
      episodeA1,
      episodeA2,
    ], reason: '分集按 (季, 集号) 排，与全表读取同一口径；重复 uid 不重复取');
    expect(rows.seasons.map((VideoMetadataSeasonRow s) => s.id), <int>[
      seasonId,
    ]);
    expect(rows.episodeImages.map((VideoMetadataImageRow i) => i.id), <int>[
      stillA2,
      stillA1,
    ], reason: '分集图按 id 升序，不含别的文件的图');
    expect(
      (await db.getVideoFileEpisodeRows(const <String>[])).episodes,
      isEmpty,
    );
  });
}
