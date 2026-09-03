import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_folder_group_coordinator.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late VideoBookRepository repository;
  late VideoFolderGroupCoordinator coordinator;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repository = VideoBookRepository(db);
    coordinator = VideoFolderGroupCoordinator(
      database: db,
      repository: repository,
    );
  });

  tearDown(() => db.close());

  Future<int> addSource(String root) =>
      db.insertMediaSource(MediaSourcesCompanion.insert(
        label: root,
        mediaKind: 'video',
        rootPath: root,
        createdAt: 1000,
      ));

  Future<void> addVideo({
    required String uid,
    required String path,
    int? sourceId,
    int position = 0,
    String? coverPath,
    String? subtitlePath,
  }) =>
      repository.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(path.split('/').last.split('.').first),
          videoPath: Value<String>(path),
          lastPositionMs: Value<int>(position),
          coverPath: Value<String?>(coverPath),
          subtitleSource: Value<String?>(subtitlePath),
        ),
        sourceId: sourceId,
      );

  test('散装分集原地归组、只回填空来源并保持用户数据', () async {
    final int sourceId = await addSource('/library');
    final int otherSourceId = await addSource('/other');
    await addVideo(
      uid: 'show-02',
      path: '/library/Show S01E02.mkv',
      sourceId: otherSourceId,
      position: 222,
    );
    await addVideo(
      uid: 'show-01',
      path: '/library/Show S01E01.mkv',
      position: 111,
      coverPath: '/covers/e01.jpg',
      subtitlePath: '/library/Show S01E01.srt',
    );

    final VideoFolderGroupSummary summary = await coordinator.groupPaths(
      videoPaths: <String>[
        '/library/Show S01E02.mkv',
        '/library/Show S01E01.mkv',
      ],
      sourceId: sourceId,
    );

    expect(summary.createdVideoUids, isEmpty);
    expect(summary.reusedVideoUids, <String>['show-01', 'show-02']);
    expect(summary.createdCollectionIds, hasLength(1));
    final int collectionId = summary.createdCollectionIds.single;
    expect(
      (await db.getCollectionItems(collectionId))
          .map((MediaCollectionItemRow item) => item.entryKey),
      <String>['show-01', 'show-02'],
    );
    final VideoBookRow first = (await repository.getByBookUid('show-01'))!;
    final VideoBookRow second = (await repository.getByBookUid('show-02'))!;
    expect(first.sourceId, sourceId);
    expect(first.lastPositionMs, 111);
    expect(first.coverPath, '/covers/e01.jpg');
    expect(first.subtitleSource, '/library/Show S01E01.srt');
    expect(second.sourceId, otherSourceId, reason: '不得抢占其它来源的既有归属');
    expect(second.lastPositionMs, 222);
    expect((await db.getMediaCollectionById(collectionId))!.orderUpdatedAt, 0,
        reason: '机器自然排序不得伪装成用户手动排序');
  });

  test('BUG-1739 用户删除的合集不被重扫复活；显式重建后恢复归组', () async {
    final int sourceId = await addSource('/library');
    await addVideo(
      uid: 'show-01',
      path: '/library/Show S01E01.mkv',
      sourceId: sourceId,
    );
    await addVideo(
      uid: 'show-02',
      path: '/library/Show S01E02.mkv',
      sourceId: sourceId,
    );
    final List<String> paths = <String>[
      '/library/Show S01E01.mkv',
      '/library/Show S01E02.mkv',
    ];
    final VideoFolderGroupSummary first = await coordinator.groupPaths(
      videoPaths: paths,
      sourceId: sourceId,
    );
    final int collectionId = first.createdCollectionIds.single;
    final String name = (await db.getMediaCollectionById(collectionId))!.name;

    // 用户删除合集（保留条目）→ 成员文件仍在来源目录，重扫不得按自然键复活。
    // 没有这道门，deleteMediaCollection 写的墓碑会被 createMediaCollection
    // 清掉，删除永远不生效（用户报「合集无法删除」）。
    await db.deleteMediaCollection(collectionId);
    final VideoFolderGroupSummary rescan = await coordinator.groupPaths(
      videoPaths: paths,
      sourceId: sourceId,
    );
    expect(rescan.createdCollectionIds, isEmpty);
    expect(rescan.updatedCollectionIds, isEmpty);
    expect(await db.getMediaCollectionByNaturalKey(name, 'playlist'), isNull);
    expect(rescan.reusedVideoUids, <String>['show-01', 'show-02'],
        reason: '只是不再归组，成员视频本身不受影响');

    // 用户显式重建同名合集 = 撤销删除（createMediaCollection 清墓碑），之后
    // 重扫恢复自动归组，把成员补回来。
    final int recreated =
        await db.createMediaCollection(name, collectionType: 'playlist');
    await coordinator.groupPaths(videoPaths: paths, sourceId: sourceId);
    expect(
      (await db.getCollectionItems(recreated))
          .map((MediaCollectionItemRow item) => item.entryKey),
      <String>['show-01', 'show-02'],
    );
  });

  test('重扫幂等；新增与暂缺分集都复用原合集并对全集排序', () async {
    final int sourceId = await addSource('/library');
    for (final ({String uid, String path}) item in <({
      String uid,
      String path,
    })>[
      (uid: 'show-01', path: '/library/Show S01E01.mkv'),
      (uid: 'show-02', path: '/library/Show S01E02.mkv'),
    ]) {
      await addVideo(uid: item.uid, path: item.path, sourceId: sourceId);
    }
    final VideoFolderGroupSummary first = await coordinator.groupPaths(
      videoPaths: <String>[
        '/library/Show S01E01.mkv',
        '/library/Show S01E02.mkv',
      ],
      createdVideoPaths: <String>[
        '/library/Show S01E01.mkv',
        '/library/Show S01E02.mkv',
      ],
      sourceId: sourceId,
    );
    final int collectionId = first.createdCollectionIds.single;

    final VideoFolderGroupSummary unchanged = await coordinator.groupPaths(
      videoPaths: <String>[
        '/library/Show S01E02.mkv',
        '/library/Show S01E01.mkv',
      ],
      sourceId: sourceId,
    );
    expect(unchanged.createdCollectionIds, isEmpty);
    expect(unchanged.updatedCollectionIds, isEmpty);
    expect(await repository.listAll(), hasLength(2));
    expect(await db.getAllMediaCollections(), hasLength(1));

    await addVideo(
      uid: 'show-00',
      path: '/library/Show S01E00.mkv',
      sourceId: sourceId,
    );
    final VideoFolderGroupSummary expanded = await coordinator.groupPaths(
      videoPaths: <String>[
        '/library/Show S01E02.mkv',
        '/library/Show S01E00.mkv',
        '/library/Show S01E01.mkv',
      ],
      createdVideoPaths: <String>['/library/Show S01E00.mkv'],
      sourceId: sourceId,
    );
    expect(expanded.createdVideoUids, <String>['show-00']);
    expect(expanded.updatedCollectionIds, <int>[collectionId]);
    expect((await db.getMediaCollectionById(collectionId))!.orderUpdatedAt, 0,
        reason: '新增分集触发的自动重排不得 bump 手动序时钟');

    // E00/E01/E02 全部暂缺，本轮只发现 E03：仍按作品身份加入旧合集，旧成员不删。
    await addVideo(
      uid: 'show-03',
      path: '/library/Show S01E03.mkv',
      sourceId: sourceId,
    );
    await coordinator.groupPaths(
      videoPaths: <String>['/library/Show S01E03.mkv'],
      createdVideoPaths: <String>['/library/Show S01E03.mkv'],
      sourceId: sourceId,
    );

    expect(
      (await db.getCollectionItems(collectionId))
          .map((MediaCollectionItemRow item) => item.entryKey),
      <String>['show-00', 'show-01', 'show-02', 'show-03'],
    );
    expect(await repository.listAll(), hasLength(4));
    expect(await db.getAllMediaCollections(), hasLength(1));
  });

  test('全新单片保持独立，不强制创建合集', () async {
    final int sourceId = await addSource('/movies');
    await addVideo(
      uid: 'movie',
      path: '/movies/Standalone Movie.mkv',
      sourceId: sourceId,
    );

    final VideoFolderGroupSummary summary = await coordinator.groupPaths(
      videoPaths: <String>['/movies/Standalone Movie.mkv'],
      createdVideoPaths: <String>['/movies/Standalone Movie.mkv'],
      sourceId: sourceId,
    );

    expect(summary.createdVideoUids, <String>['movie']);
    expect(summary.createdCollectionIds, isEmpty);
    expect(await db.getAllMediaCollections(), isEmpty);
  });
}
