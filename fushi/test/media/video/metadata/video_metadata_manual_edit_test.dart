import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart'
    show hasCanonicalVideoMetadataIdentity;
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_manual_edit.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';

/// BUG-5082：刮削全失败的作品手填资料——落库、上锁、重刮不覆盖、清空回到刮削值。
void main() {
  late FushiDatabase database;
  late VideoMetadataDatabaseStore store;
  late SourceLibraryRow source;

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
  });

  tearDown(() => database.close());

  Future<VideoBookRow> addBook(String uid, String path) async {
    await database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(uid),
        videoPath: Value<String>(path),
        sourceId: Value<int?>(source.id),
      ),
    );
    return (await database.getVideoBookByBookUid(uid))!;
  }

  Future<int> addCollection(String name, List<String> members) async {
    final int id = await database
        .into(database.mediaCollections)
        .insert(MediaCollectionsCompanion.insert(name: name, createdAt: 1));
    for (int i = 0; i < members.length; i++) {
      await database
          .into(database.mediaCollectionItems)
          .insert(
            MediaCollectionItemsCompanion.insert(
              collectionId: id,
              mediaType: 'video',
              entryKey: members[i],
              sortIndex: Value<int>(i),
            ),
          );
    }
    return id;
  }

  VideoMetadataWork scraped({
    String title = '刮到的标题',
    String? plot = '刮到的简介',
    String? tagline = '刮到的标语',
    int? year = 2001,
    double? rating = 8.0,
    List<String> genres = const <String>['Drama'],
    List<String> countries = const <String>['JP'],
    VideoMetadataMediaKind kind = VideoMetadataMediaKind.movie,
  }) => VideoMetadataWork(
    provider: VideoMetadataProviderKind.tmdb,
    kind: kind,
    title: title,
    plot: plot,
    tagline: tagline,
    year: year,
    rating: rating,
    genres: genres,
    countries: countries,
    ids: const <VideoMetadataId>[VideoMetadataId(type: 'tmdb', value: '7')],
  );

  Future<Map<String, List<String>>> termsOf(int workId) async {
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final VideoMetadataTermRow row
        in await database.getVideoMetadataTermsForWork(workId)) {
      out.putIfAbsent(row.kind, () => <String>[]).add(row.name);
    }
    return out;
  }

  group('刮削全失败：没有作品行时手填', () {
    late VideoBookRow book;
    late VideoSourceScrapeWork localWork;

    setUp(() async {
      book = await addBook('movie-1', 'D:/Anime/冷门剧场版.mkv');
      localWork = VideoSourceScrapeWork(
        source: source,
        title: book.title,
        members: <VideoBookRow>[book],
      );
    });

    test('新建作品行、改过的字段上锁，但不写 provider 身份（照常进补刮）', () async {
      expect(await database.getVideoMetadataWorkByBook(book.bookUid), isNull);
      final VideoWorkManualTarget target = await videoWorkManualTargetForBook(
        database,
        book.bookUid,
      );
      expect(target, isA<VideoWorkManualTargetBook>());

      final int workId = await store.applyManualEdit(
        target,
        const VideoWorkManualEdit(
          title: '  冷门剧场版  ',
          overview: '手填简介',
          year: 1999,
          genres: <String>['Mecha', ' Mecha ', ''],
        ),
        fallbackTitle: book.title,
      );

      final VideoMetadataWorkRow row = (await database.getVideoMetadataWorkById(
        workId,
      ))!;
      expect(row.bookUid, book.bookUid);
      expect(row.collectionId, isNull);
      expect(row.mediaType, 'movie');
      expect(row.title, '冷门剧场版');
      expect(row.overview, '手填简介');
      expect(row.year, 1999);
      expect(row.tagline, isNull);
      expect(parseLockedFields(row.lockedFields), <VideoMetadataLockableField>{
        VideoMetadataLockableField.title,
        VideoMetadataLockableField.overview,
        VideoMetadataLockableField.year,
        VideoMetadataLockableField.genres,
      });
      expect((await termsOf(workId))['genre'], <String>['Mecha']);
      expect(
        await database.getVideoMetadataProviderIdentities(workId: workId),
        isEmpty,
      );
      expect(
        await hasCanonicalVideoMetadataIdentity(database, localWork),
        isFalse,
        reason: '手填不算识别：自动补刮 / 待确认照常去找主源',
      );
    });

    test('之后刮削成功：手填字段保留，未填字段照常落刮削值', () async {
      final int workId = await store.applyManualEdit(
        await videoWorkManualTargetForBook(database, book.bookUid),
        const VideoWorkManualEdit(
          title: 'movie-1',
          overview: '手填简介',
          year: 1999,
          genres: <String>['Mecha'],
        ),
        fallbackTitle: book.title,
      );

      final PersistedVideoMetadata persisted = await store.apply(
        localWork,
        scraped(),
      );

      expect(persisted.workId, workId, reason: '刮削写回同一行');
      final VideoMetadataWorkRow row = (await database.getVideoMetadataWorkById(
        workId,
      ))!;
      expect(row.overview, '手填简介');
      expect(row.year, 1999);
      expect(row.title, '刮到的标题', reason: '标题没改过（等于视频名），不上锁');
      expect(row.tagline, '刮到的标语');
      expect(row.rating, 8.0);
      final Map<String, List<String>> terms = await termsOf(workId);
      expect(terms['genre'], <String>['Mecha']);
      expect(terms['country'], <String>['JP']);
    });

    test('清空手填字段 = 解锁，下次刮削回填刮削值', () async {
      final VideoWorkManualTarget target = await videoWorkManualTargetForBook(
        database,
        book.bookUid,
      );
      await store.applyManualEdit(
        target,
        const VideoWorkManualEdit(
          title: 'movie-1',
          overview: '手填简介',
          year: 1999,
        ),
        fallbackTitle: book.title,
      );
      final int workId = await store.applyManualEdit(
        await videoWorkManualTargetForBook(database, book.bookUid),
        const VideoWorkManualEdit(
          title: 'movie-1',
          overview: '   ',
          year: 1999,
        ),
        fallbackTitle: book.title,
      );
      VideoMetadataWorkRow row = (await database.getVideoMetadataWorkById(
        workId,
      ))!;
      expect(row.overview, isNull);
      expect(parseLockedFields(row.lockedFields), <VideoMetadataLockableField>{
        VideoMetadataLockableField.year,
      });

      await store.apply(localWork, scraped());
      row = (await database.getVideoMetadataWorkById(workId))!;
      expect(row.overview, '刮到的简介');
      expect(row.year, 1999, reason: '年份仍是手填，仍锁着');
    });

    test('对话框开着时补刮落库：没碰过的字段保留刮削值、不上锁（以初值为基准）', () async {
      final VideoWorkManualTarget target = await videoWorkManualTargetForBook(
        database,
        book.bookUid,
      );
      final VideoWorkManualEdit initial = await store.currentManualEdit(
        target,
        fallbackTitle: book.title,
      );
      expect(initial.overview, isNull);

      // 用户还在填，自动补刮先一步落库。
      final PersistedVideoMetadata persisted = await store.apply(
        localWork,
        scraped(),
      );

      final int workId = await store.applyManualEdit(
        target,
        VideoWorkManualEdit(
          title: initial.title,
          originalTitle: initial.originalTitle,
          overview: initial.overview,
          tagline: initial.tagline,
          year: 1999,
          genres: initial.genres,
          studios: initial.studios,
        ),
        fallbackTitle: book.title,
        baseline: initial,
      );

      expect(workId, persisted.workId);
      final VideoMetadataWorkRow row = (await database.getVideoMetadataWorkById(
        workId,
      ))!;
      expect(row.year, 1999);
      expect(row.overview, '刮到的简介', reason: '用户没碰简介，不能被旧初值清空');
      expect(row.tagline, '刮到的标语');
      expect(row.title, '刮到的标题');
      expect(parseLockedFields(row.lockedFields), <VideoMetadataLockableField>{
        VideoMetadataLockableField.year,
      });
      expect((await termsOf(workId))['genre'], <String>['Drama']);
    });
  });

  group('已刮过的作品：只锁改过的字段', () {
    test('没改的字段不上锁、原有的锁不丢；词条只换 genre，country 保留', () async {
      final VideoBookRow book = await addBook('movie-2', 'D:/Anime/某片.mkv');
      final VideoSourceScrapeWork localWork = VideoSourceScrapeWork(
        source: source,
        title: book.title,
        members: <VideoBookRow>[book],
      );
      final PersistedVideoMetadata first = await store.apply(
        localWork,
        scraped(),
      );
      await database.setVideoMetadataWorkLockedFields(
        first.workId,
        encodeLockedFields(<VideoMetadataLockableField>{
          VideoMetadataLockableField.cover,
        }),
      );
      final VideoWorkManualTarget target = await videoWorkManualTargetForBook(
        database,
        book.bookUid,
      );
      final VideoWorkManualEdit current = await store.currentManualEdit(
        target,
        fallbackTitle: book.title,
      );
      expect(current.overview, '刮到的简介');
      expect(current.genres, <String>['Drama']);

      await store.applyManualEdit(
        target,
        VideoWorkManualEdit(
          title: current.title,
          originalTitle: current.originalTitle,
          overview: current.overview,
          tagline: current.tagline,
          year: 2002,
          genres: const <String>['Drama', 'Sci-Fi'],
          studios: current.studios,
        ),
        fallbackTitle: book.title,
      );

      final VideoMetadataWorkRow row = (await database.getVideoMetadataWorkById(
        first.workId,
      ))!;
      expect(parseLockedFields(row.lockedFields), <VideoMetadataLockableField>{
        VideoMetadataLockableField.year,
        VideoMetadataLockableField.genres,
        VideoMetadataLockableField.cover,
      });
      final Map<String, List<String>> terms = await termsOf(first.workId);
      expect(terms['genre'], <String>['Drama', 'Sci-Fi']);
      expect(terms['country'], <String>['JP']);

      await store.apply(localWork, scraped(year: 2010, plot: '新简介'));
      final VideoMetadataWorkRow after = (await database
          .getVideoMetadataWorkById(first.workId))!;
      expect(after.year, 2002);
      expect(after.overview, '新简介', reason: '简介没改过，照常跟刮削');
    });
  });

  group('合集归属与刮削计划器一致', () {
    test('多集合集：挂在合集上，合集刮削保留手填', () async {
      final VideoBookRow e1 = await addBook('ep-1', 'D:/Anime/某番/某番 01.mkv');
      final VideoBookRow e2 = await addBook('ep-2', 'D:/Anime/某番/某番 02.mkv');
      final int collectionId = await addCollection('某番', <String>[
        e1.bookUid,
        e2.bookUid,
      ]);
      final VideoWorkManualTarget? target =
          await videoWorkManualTargetForCollection(database, collectionId);
      expect(target, isA<VideoWorkManualTargetCollection>());

      final int workId = await store.applyManualEdit(
        target!,
        const VideoWorkManualEdit(title: '某番', overview: '手填', year: 1987),
        fallbackTitle: '某番',
      );
      final VideoMetadataWorkRow manual = (await database
          .getVideoMetadataWorkById(workId))!;
      expect(manual.collectionId, collectionId);
      expect(manual.mediaType, 'tv');
      expect(
        (await database.resolveVideoMetadataWorkForCollection(
          collectionId,
        ))?.id,
        workId,
        reason: '详情页读到的就是手填行',
      );

      final MediaCollectionRow collection =
          (await database.getAllMediaCollections()).singleWhere(
            (MediaCollectionRow row) => row.id == collectionId,
          );
      final PersistedVideoMetadata persisted = await store.apply(
        VideoSourceScrapeWork(
          source: source,
          collection: collection,
          title: collection.name,
          members: <VideoBookRow>[e1, e2],
        ),
        scraped(kind: VideoMetadataMediaKind.tv),
      );
      expect(persisted.workId, workId);
      final VideoMetadataWorkRow row = (await database.getVideoMetadataWorkById(
        workId,
      ))!;
      expect(row.overview, '手填');
      expect(row.year, 1987);
      expect(row.title, '刮到的标题');
    });

    test('单成员合集按单集刮：挂在那一集上', () async {
      final VideoBookRow only = await addBook('solo', 'D:/Anime/单集.mkv');
      final int collectionId = await addCollection('单集', <String>[
        only.bookUid,
      ]);
      final VideoWorkManualTarget? target =
          await videoWorkManualTargetForCollection(database, collectionId);
      expect(target, isA<VideoWorkManualTargetBook>());
      expect((target! as VideoWorkManualTargetBook).bookUid, only.bookUid);
    });

    test('互联客户端：唯一成员只在对端（本机没有视频行）时挂合集，不按单集建行', () async {
      // 合集清单跨端 union：entryKey 是 host 侧 bookUid、本机没有 video_books 行
      // （collection_episode_slot.dart）。按单集建行会撞 book_uid 外键。
      final int collectionId = await addCollection('对端单集', <String>[
        'host-only-uid',
      ]);
      final VideoWorkManualTarget? target =
          await videoWorkManualTargetForCollection(database, collectionId);
      expect(target, isA<VideoWorkManualTargetCollection>());
      final int workId = await store.applyManualEdit(
        target!,
        const VideoWorkManualEdit(title: '对端单集', overview: '手填'),
        fallbackTitle: '对端单集',
      );
      expect(
        (await database.resolveVideoMetadataWorkForCollection(
          collectionId,
        ))?.id,
        workId,
      );
    });

    test('已有行：合集行优先；成员上恰好一条就是它；多条不猜', () async {
      final VideoBookRow a = await addBook('a', 'D:/Anime/A/a.mkv');
      final VideoBookRow b = await addBook('b', 'D:/Anime/B/b.mkv');
      final int collectionId = await addCollection('清单', <String>[
        a.bookUid,
        b.bookUid,
      ]);
      Future<void> scrapeBook(VideoBookRow book) => store.apply(
        VideoSourceScrapeWork(
          source: source,
          title: book.title,
          members: <VideoBookRow>[book],
        ),
        scraped(),
      );

      await scrapeBook(a);
      final VideoWorkManualTarget? one =
          await videoWorkManualTargetForCollection(database, collectionId);
      expect(one, isA<VideoWorkManualTargetExisting>());
      expect((one! as VideoWorkManualTargetExisting).work.bookUid, 'a');

      await scrapeBook(b);
      expect(
        await videoWorkManualTargetForCollection(database, collectionId),
        isNull,
        reason: '各集各自识别的清单没有唯一作品，不猜',
      );
    });
  });

  test('splitManualTerms：逗号 / 全角逗号 / 顿号 / 换行都分隔，去空去重', () {
    expect(splitManualTerms('机战, 科幻，机战、 \n热血,'), <String>['机战', '科幻', '热血']);
  });
}
