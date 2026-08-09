import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> addSource(String root) => db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: root,
          mediaKind: 'video',
          rootPath: root,
          createdAt: 1,
        ),
      );

  Future<void> addVideo(String uid, String path, int sourceId) =>
      db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(uid),
        videoPath: Value<String>(path),
        sourceId: Value<int?>(sourceId),
      ));

  test('按作品去重且混来源合集只携带当前来源成员', () async {
    final int sourceA = await addSource('D:/A');
    final int sourceB = await addSource('D:/B');
    await addVideo('a-01', 'D:/A/Show/Show S01E01.mkv', sourceA);
    await addVideo('a-02', 'D:/A/Show/Show S01E02.mkv', sourceA);
    await addVideo('b-03', 'D:/B/Show/Show S01E03.mkv', sourceB);
    await addVideo('movie-a', 'D:/A/Movie.mkv', sourceA);

    final int collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    for (final String uid in <String>['a-01', 'a-02', 'b-03']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }

    final SourceLibraryRow source = (await db.getMediaSourceById(sourceA))!;
    final List<VideoSourceScrapeWork> work =
        await VideoSourceWorkPlanner(db).plan(source);

    expect(work, hasLength(2));
    final VideoSourceScrapeWork show =
        work.singleWhere((VideoSourceScrapeWork item) => item.isEpisodic);
    expect(show.collection!.id, collectionId);
    expect(show.members.map((VideoBookRow row) => row.bookUid),
        <String>['a-01', 'a-02']);
    expect(show.members.every((VideoBookRow row) => row.sourceId == sourceA),
        isTrue);

    final VideoSourceScrapeWork movie =
        work.singleWhere((VideoSourceScrapeWork item) => !item.isEpisodic);
    expect(movie.members.single.bookUid, 'movie-a');
  });

  test('非视频来源不产生作品计划', () async {
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'books',
        mediaKind: 'book',
        rootPath: 'D:/books',
        createdAt: 1,
      ),
    );
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    expect(await VideoSourceWorkPlanner(db).plan(source), isEmpty);
  });

  test('任意多片 m3u 合集不会被误判为电视剧作品', () async {
    final int sourceId = await addSource('/movies');
    await addVideo('movie-a', '/movies/A Movie (2020).mkv', sourceId);
    await addVideo('movie-b', '/movies/B Movie (2021).mkv', sourceId);
    final int collectionId = await db.createMediaCollection(
      'Weekend playlist',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'movie-a');
    await db.addToCollection(collectionId, MediaKind.video, 'movie-b');

    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final List<VideoSourceScrapeWork> works =
        await VideoSourceWorkPlanner(db).plan(source);

    expect(works, hasLength(2));
    expect(
        works.every((VideoSourceScrapeWork work) => !work.isEpisodic), isTrue);
  });

  test('re0 方括号 PV、菜单与迷你动画不产生独立刮削作品', () async {
    final int sourceId = await addSource('D:/smb/re0');
    const String root = 'D:/smb/re0/[DBD-Raws][Re：从零开始的异世界生活 第三季]'
        '[01-16TV全集+SP][1080P][BDRip]';
    await addVideo(
      'main-01',
      '$root/[DBD-Raws][Re Zero kara Hajimeru Isekai Seikatsu S3]'
          '[01][1080P][BDRip].mkv',
      sourceId,
    );
    await addVideo(
      'main-02',
      '$root/[DBD-Raws][Re Zero kara Hajimeru Isekai Seikatsu S3]'
          '[02][1080P][BDRip].mkv',
      sourceId,
    );
    await addVideo(
      'pv-01',
      '$root/PV/[DBD-Raws][Re Zero kara Hajimeru Isekai Seikatsu S3]'
          '[PV][01][1080P][BDRip].mkv',
      sourceId,
    );
    await addVideo(
      'menu-01',
      '$root/menu/[DBD-Raws][Re Zero kara Hajimeru Isekai Seikatsu S3]'
          '[menu][01][1080P][BDRip].mkv',
      sourceId,
    );
    await addVideo(
      'short-01',
      '$root/迷你动画/[DBD-Raws][Re Zero Break Time][01].mkv',
      sourceId,
    );
    final int collectionId = await db.createMediaCollection(
      'Re Zero kara Hajimeru Isekai Seikatsu',
      collectionType: 'playlist',
    );
    for (final String uid in <String>[
      'main-01',
      'main-02',
      'pv-01',
      'menu-01',
      'short-01',
    ]) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }

    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final List<VideoSourceScrapeWork> works =
        await VideoSourceWorkPlanner(db).plan(source);

    expect(works, hasLength(1));
    expect(works.single.collection?.id, collectionId);
    expect(
      works.single.members.map((VideoBookRow row) => row.bookUid),
      <String>['main-01', 'main-02'],
    );
  });
}
