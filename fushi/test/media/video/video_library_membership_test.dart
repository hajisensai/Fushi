import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi/src/media/video/video_continue_watching.dart';
import 'package:fushi/src/media/video/video_folder_collection_policy.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_folder_group_coordinator.dart';
import 'package:test/test.dart';

/// BUG-5589：视频库页、首页继续观看、伴屏的折叠归属不再搬整张成员表。
///
/// [resolveVideoLibraryMembership] 只吃「每条目一行的主合集 + 组内序」和「本机视频
/// 自己的成员行」，这里钉住它在视频键上与旧管线（整表主归属 + 整表成员 + 目录合集
/// 策略 + [buildVideoMemberSortIndex]）逐条相同：目录模式 / 作品模式来源、目录合集
/// 抢主归属、远端主机的视频（不在本机库）、多合集成员、书条目混编都在里面。
void main() {
  late FushiDatabase db;
  late VideoBookRepository repository;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repository = VideoBookRepository(db);
  });
  tearDown(() => db.close());

  Future<int> addSource(String root, String mode) => db.insertMediaSource(
    MediaSourcesCompanion.insert(
      label: root,
      mediaKind: 'video',
      rootPath: root,
      createdAt: 1000,
      videoGroupingMode: Value<String>(mode),
    ),
  );

  Future<void> addVideo(String uid, String path, int sourceId) =>
      repository.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(uid),
          videoPath: Value<String>(path),
        ),
        sourceId: sourceId,
      );

  Future<({Map<String, int> primary, Map<String, int> sortIndex})>
  oldPipeline() async {
    final Map<String, int> primary = applyVideoFolderCollectionPolicy(
      primary: await db.getPrimaryCollectionIdByEntry(),
      collections: await db.getAllMediaCollections(),
      items: await db.getAllCollectionItems(),
      books: await db.allVideoBooks(),
      sources: await db.getMediaSourcesByKind('video'),
    );
    final Map<String, int> sortIndex = buildVideoMemberSortIndex(
      primaryCollectionByEntry: primary,
      items: await db.getAllCollectionItems(),
    );
    bool video(String k) => k.startsWith('video|');
    return (
      primary: <String, int>{
        for (final MapEntry<String, int> e in primary.entries)
          if (video(e.key)) e.key: e.value,
      },
      sortIndex: <String, int>{
        for (final MapEntry<String, int> e in sortIndex.entries)
          if (video(e.key)) e.key: e.value,
      },
    );
  }

  Future<VideoLibraryMembership> newPipeline() async =>
      resolveVideoLibraryMembership(
        rawPrimary: await db.getPrimaryCollectionMembershipOfKind(
          MediaKind.video,
        ),
        libraryVideoItems: await db.getLibraryVideoMemberRows(),
        collections: await db.getAllMediaCollections(),
        books: await db.allVideoBooks(),
        sources: await db.getMediaSourcesByKind('video'),
      );

  test('与整表管线逐条相同（目录 / 作品模式、远端视频、多合集、混编）', () async {
    // 作品模式来源里手动加进播放列表的视频，排在一个先建的大合集之后。
    final int series = await addSource('/anime', 'series');
    final int folder = await addSource('/lessons', 'folder');
    for (int i = 0; i < 4; i++) {
      await addVideo('s$i', '/anime/show/ep$i.mkv', series);
      await addVideo('f$i', '/lessons/level/clip$i.mp4', folder);
    }
    final int big = await db.createMediaCollection(
      '大合集',
      collectionType: 'playlist',
    );
    final int show = await db.createMediaCollection(
      '作品',
      collectionType: 'playlist',
    );
    for (int i = 3; i >= 0; i--) {
      await db.addToCollection(show, MediaKind.video, 's$i');
    }
    await db.addToCollection(big, MediaKind.video, 's1');
    await db.addToCollection(big, MediaKind.video, 'f2');
    // 远端主机的视频（本机没有 video_books 行），与本机视频同在一个合集里。
    final int mirrored = await db.createMediaCollection(
      '镜像',
      collectionType: 'playlist',
    );
    for (int i = 0; i < 5; i++) {
      await db.addToCollection(mirrored, MediaKind.video, 'remote-$i');
    }
    await db.addToCollection(mirrored, MediaKind.video, 's2');
    await db.addToCollection(mirrored, MediaKind.epub, 'book-uid');
    // 目录合集：目录模式来源的视频由它抢主归属，作品模式来源的视频不让它抢。
    await VideoFolderGroupCoordinator(
      database: db,
      repository: repository,
    ).groupPaths(
      videoPaths: <String>[
        for (int i = 0; i < 4; i++) '/lessons/level/clip$i.mp4',
      ],
      sourceId: folder,
      groupingMode: 'folder',
      sourceRoot: '/lessons',
    );

    final ({Map<String, int> primary, Map<String, int> sortIndex}) expected =
        await oldPipeline();
    final VideoLibraryMembership actual = await newPipeline();
    expect(actual.primary, expected.primary);
    expect(actual.memberSortIndex, expected.sortIndex);
    // 确有目录合集改写了主归属、远端视频也有归属，比较不是空对空。
    expect(expected.primary['video|f2'], isNot(big));
    expect(expected.primary['video|remote-3'], mirrored);
    expect(expected.sortIndex['video|remote-3'], isNotNull);

    // 生产路径：后台 isolate 里读库套策略，结果与调用方 isolate 里的相同。
    final bool inline = debugVideoMembershipInline;
    debugVideoMembershipInline = false;
    addTearDown(() => debugVideoMembershipInline = inline);
    final VideoLibraryMembership off = await loadVideoLibraryMembership(
      db,
      books: await db.allVideoBooks(),
    );
    expect(off.primary, expected.primary);
    expect(off.memberSortIndex, expected.sortIndex);
  });

  test('本机视频自己的成员行：不含合集里别的成员', () async {
    final int s = await addSource('/a', 'series');
    await addVideo('v', '/a/v.mkv', s);
    final int c = await db.createMediaCollection(
      'c',
      collectionType: 'playlist',
    );
    await db.addToCollection(c, MediaKind.video, 'v');
    await db.addToCollection(c, MediaKind.video, 'remote');
    await db.addToCollection(c, MediaKind.epub, 'v');
    expect(
      (await db.getLibraryVideoMemberRows()).map(
        (MediaCollectionItemRow r) => (r.collectionId, r.mediaType, r.entryKey),
      ),
      <(int, String, String)>[(c, 'video', 'v')],
    );
    expect(await repository.memberRowsOfVideo('v'), hasLength(1));
    expect(await repository.memberRowsOfVideo('remote'), hasLength(1));
    expect(await repository.memberRowsOfVideo('nobody'), isEmpty);
  });
}
