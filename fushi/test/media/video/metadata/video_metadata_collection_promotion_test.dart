import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:test/test.dart';

/// BUG-5110：单集作品长成多集合集后第一次按合集刮，挂在那一集上的作品行要
/// 「升格」成合集行（改归属不删），手填值 / 字段锁 / 锁住的封面 / 系列关系都在。
void main() {
  late FushiDatabase database;
  late VideoMetadataDatabaseStore store;
  late SourceLibraryRow source;
  late int collectionId;

  Future<VideoBookRow> addEpisode(String uid, String path) async {
    await database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(uid),
        videoPath: Value<String>(path),
        sourceId: Value<int?>(source.id),
      ),
    );
    await database.addToCollection(collectionId, MediaKind.video, uid);
    return (await database.getVideoBookByBookUid(uid))!;
  }

  VideoMetadataWork tv({
    required String title,
    required String plot,
    required String coverUrl,
  }) => VideoMetadataWork(
    provider: VideoMetadataProviderKind.tmdb,
    kind: VideoMetadataMediaKind.tv,
    title: title,
    plot: plot,
    images: <VideoMetadataImage>[
      VideoMetadataImage(
        kind: VideoMetadataImageKind.cover,
        url: coverUrl,
        provider: VideoMetadataProviderKind.tmdb,
      ),
    ],
    ids: const <VideoMetadataId>[VideoMetadataId(type: 'tmdb', value: '7')],
  );

  setUp(() async {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    store = VideoMetadataDatabaseStore(database);
    final int sourceId = await database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime',
        mediaKind: 'video',
        rootPath: 'D:/Anime',
        createdAt: 1,
      ),
    );
    source = (await database.getMediaSourceById(sourceId))!;
    collectionId = await database.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
  });

  tearDown(() => database.close());

  test('单集行手填 + 锁封面 → 加第二集按合集刮：同一行升格，手填值 / 锁 / 封面都在', () async {
    final VideoBookRow e1 = await addEpisode('e1', 'D:/Anime/Show/Show 01.mkv');
    // 合集只有一集时计划器按单集刮：作品行挂在 e1 上。
    final PersistedVideoMetadata single = await store.apply(
      VideoSourceScrapeWork(
        source: source,
        title: e1.title,
        members: <VideoBookRow>[e1],
      ),
      tv(title: '刮来的标题', plot: '刮来的简介', coverUrl: 'https://img/old.jpg'),
    );
    // 用户手填简介并锁住简介与封面。
    await (database.update(database.videoMetadataWorks)
          ..where((t) => t.id.equals(single.workId)))
        .write(const VideoMetadataWorksCompanion(overview: Value('我写的简介')));
    await database.setVideoMetadataWorkLockedFields(
      single.workId,
      encodeLockedFields(<VideoMetadataLockableField>{
        VideoMetadataLockableField.overview,
        VideoMetadataLockableField.cover,
      }),
    );
    // e1 起点的一条用户自建系列关系。
    await database
        .into(database.collectionRelations)
        .insert(
          CollectionRelationsCompanion.insert(
            bookUid: const Value<String?>('e1'),
            relationType: 'sequel',
            source: 'local',
            subjectId: 's2',
            title: '第二季',
          ),
        );

    // 下到第二集：计划器改按合集刮。
    final VideoBookRow e2 = await addEpisode('e2', 'D:/Anime/Show/Show 02.mkv');
    final MediaCollectionRow collection = (await database
        .getMediaCollectionById(collectionId))!;
    final PersistedVideoMetadata promoted = await store.apply(
      VideoSourceScrapeWork(
        source: source,
        collection: collection,
        title: collection.name,
        members: <VideoBookRow>[e1, e2],
      ),
      tv(title: '合集标题', plot: '合集简介', coverUrl: 'https://img/new.jpg'),
    );

    expect(promoted.workId, single.workId, reason: '改归属而不是删了重建');
    final VideoMetadataWorkRow row = (await database
        .getVideoMetadataWorkByCollection(collectionId))!;
    expect(row.bookUid, isNull);
    expect(row.overview, '我写的简介', reason: '锁住的手填简介还在');
    expect(row.title, '合集标题', reason: '没锁的字段按合集刮削更新');
    expect(row.lockedFields, 'overview,cover');
    expect(await database.getVideoMetadataWorkByBook('e1'), isNull);
    final List<VideoMetadataImageRow> covers =
        (await database.getVideoMetadataImages(
          workId: row.id,
        )).where((VideoMetadataImageRow r) => r.kind == 'cover').toList();
    expect(covers.map((VideoMetadataImageRow r) => r.remoteUrl), <String?>[
      'https://img/old.jpg',
    ], reason: '锁住的封面不被合集刮削换掉');
    final List<CollectionRelationRow> relations = await database
        .select(database.collectionRelations)
        .get();
    expect(relations, hasLength(1));
    expect(relations.single.collectionId, collectionId);
    expect(relations.single.bookUid, isNull);
  });

  test('多个成员各挂作品行（各自独立的作品）：不升格，照旧清掉成员行', () async {
    final VideoBookRow e1 = await addEpisode('e1', 'D:/Anime/Show/A.mkv');
    final VideoBookRow e2 = await addEpisode('e2', 'D:/Anime/Show/B.mkv');
    for (final VideoBookRow book in <VideoBookRow>[e1, e2]) {
      await store.apply(
        VideoSourceScrapeWork(
          source: source,
          title: book.title,
          members: <VideoBookRow>[book],
        ),
        tv(title: book.bookUid, plot: 'p', coverUrl: 'https://img/x.jpg'),
      );
    }
    final MediaCollectionRow collection = (await database
        .getMediaCollectionById(collectionId))!;
    await store.apply(
      VideoSourceScrapeWork(
        source: source,
        collection: collection,
        title: collection.name,
        members: <VideoBookRow>[e1, e2],
      ),
      tv(title: '合集', plot: 'p', coverUrl: 'https://img/c.jpg'),
    );
    expect(
      (await database.getVideoMetadataWorkByCollection(collectionId))!.title,
      '合集',
    );
    expect(await database.getVideoMetadataWorkByBook('e1'), isNull);
    expect(await database.getVideoMetadataWorkByBook('e2'), isNull);
  });
}
