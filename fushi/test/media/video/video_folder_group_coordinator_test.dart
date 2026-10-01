import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_folder_group_coordinator.dart';
import 'package:fushi/src/media/video/video_folder_collection_policy.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
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

  test('一级难度目录的 1500 个不相关文件保持三个合集，重扫幂等且不生成刮削计划', () async {
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Lessons',
        mediaKind: 'video',
        rootPath: '/lessons',
        createdAt: 1000,
        videoGroupingMode: const Value('folder'),
      ),
    );
    final List<String> paths = <String>[];
    await db.transaction(() async {
      for (int folder = 0; folder < 3; folder++) {
        for (int index = 0; index < 500; index++) {
          final String path =
              '/lessons/level-$folder/${index.isEven ? 'nested/' : ''}clip-$index.mp4';
          paths.add(path);
          await addVideo(uid: '$folder-$index', path: path, sourceId: sourceId);
        }
      }
    });
    final VideoFolderGroupSummary first = await coordinator.groupPaths(
      videoPaths: paths,
      sourceId: sourceId,
      groupingMode: 'folder',
      sourceRoot: '/lessons',
    );
    expect(first.createdCollectionIds, hasLength(3));
    for (final int id in first.createdCollectionIds) {
      expect(await db.getCollectionItems(id), hasLength(500));
      expect(
        (await db.getMediaCollectionById(id))!.collectionType,
        'collection',
      );
    }
    final VideoFolderGroupSummary second = await coordinator.groupPaths(
      videoPaths: paths.reversed.toList(),
      sourceId: sourceId,
      groupingMode: 'folder',
      sourceRoot: '/lessons',
    );
    expect(second.createdCollectionIds, isEmpty);
    expect(second.updatedCollectionIds, isEmpty);
    expect(
      await VideoSourceWorkPlanner(
        db,
      ).plan((await db.getMediaSourceById(sourceId))!),
      isEmpty,
    );
  });

  test('目录名碰撞不认领手动合集，根直属文件也创建合集，展示优先目录归属', () async {
    final int manual = await db.createMediaCollection('easy');
    final int sourceId = await addSource('/lessons');
    await (db.update(db.mediaSources)..where((tbl) => tbl.id.equals(sourceId)))
        .write(const MediaSourcesCompanion(videoGroupingMode: Value('folder')));
    await addVideo(uid: 'one', path: '/lessons/easy/a.mp4', sourceId: sourceId);
    await addVideo(uid: 'root', path: '/lessons/b.mp4', sourceId: sourceId);
    await db.addToCollection(manual, MediaKind.video, 'one');
    final VideoFolderGroupSummary result = await coordinator.groupPaths(
      videoPaths: <String>['/lessons/easy/a.mp4', '/lessons/b.mp4'],
      sourceId: sourceId,
      groupingMode: 'folder',
      sourceRoot: '/lessons',
    );
    expect(result.createdCollectionIds, hasLength(2));
    expect((await db.getMediaCollectionById(manual))!.sourceFolderPath, isNull);
    final Map<String, int> display = applyVideoFolderCollectionPolicy(
      primary: await db.getPrimaryCollectionIdByEntry(),
      collections: await db.getAllMediaCollections(),
      items: await db.getAllCollectionItems(),
      books: await db.allVideoBooks(),
      sources: await db.getMediaSourcesByKind('video'),
    );
    expect(display['video|one'], isNot(manual));
    await (db.update(db.mediaSources)..where((tbl) => tbl.id.equals(sourceId)))
        .write(const MediaSourcesCompanion(videoGroupingMode: Value('series')));
    final Map<String, int> restored = applyVideoFolderCollectionPolicy(
      primary: await db.getPrimaryCollectionIdByEntry(),
      collections: await db.getAllMediaCollections(),
      items: await db.getAllCollectionItems(),
      books: await db.allVideoBooks(),
      sources: await db.getMediaSourcesByKind('video'),
    );
    expect(restored['video|one'], manual);
    expect(restored.containsKey('video|root'), isFalse);
    expect(
      videoSourceFolderPath(r'C:\Lessons\easy\deep\a.mp4', r'C:\Lessons'),
      'c:/lessons/easy',
    );
    expect(
      () => videoSourceFolderPath('/else/a.mp4', '/lessons'),
      throwsArgumentError,
    );
  });

  test('目录重扫保留用户移出墓碑且Windows根大小写不改变合集身份', () async {
    final int sourceId = await addSource('D:/Lessons');
    final List<String> paths = <String>[
      'D:/Lessons/Easy/one.mp4',
      'D:/Lessons/Easy/two.mp4'
    ];
    await addVideo(uid: 'one', path: paths[0], sourceId: sourceId);
    await addVideo(uid: 'two', path: paths[1], sourceId: sourceId);
    final VideoFolderGroupSummary first = await coordinator.groupPaths(
      videoPaths: paths,
      sourceId: sourceId,
      groupingMode: 'folder',
      sourceRoot: 'd:/lessons',
    );
    final int collectionId = first.createdCollectionIds.single;
    expect((await db.getMediaCollectionById(collectionId))!.name, 'Easy');
    expect((await db.getMediaCollectionById(collectionId))!.sourceFolderPath,
        'd:/lessons/easy');
    await db.removeFromCollection(collectionId, MediaKind.video, 'one');
    final VideoFolderGroupSummary second = await coordinator.groupPaths(
      videoPaths: paths,
      sourceId: sourceId,
      groupingMode: 'folder',
      sourceRoot: 'D:/LESSONS',
    );
    expect(second.createdCollectionIds, isEmpty);
    expect(
        (await db.getCollectionItems(collectionId))
            .map((MediaCollectionItemRow row) => row.entryKey),
        <String>['two']);
    expect(
        (await db.getAllCollectionMemberTombstones())
            .any((CollectionMemberTombstoneRow row) => row.entryKey == 'one'),
        isTrue);
    await db.removeFromCollection(collectionId, MediaKind.video, 'two');
    final VideoFolderGroupSummary third = await coordinator.groupPaths(
      videoPaths: paths,
      sourceId: sourceId,
      groupingMode: 'folder',
      sourceRoot: 'D:/Lessons',
    );
    expect(third.createdCollectionIds, isEmpty, reason: '移空合集后不重新建立空容器或复活成员');
    expect(await db.getAllMediaCollections(), isEmpty);
    expect(
        videoSourceFolderPath(
            r'\\Server\Share\Root\Easy\one.mp4', r'\\server\share\root'),
        '//server/share/root/easy');
    expect(videoSourceFolderPath('/Library/Easy/a.mp4', '/Library'),
        '/Library/Easy');
    expect(() => videoSourceFolderPath('/library/Easy/a.mp4', '/Library'),
        throwsArgumentError);
  });

  test('截图 Fate 的 VCB 文件名当前解析合为同作品并保留集号', () {
    final List<VideoGroup> groups = groupVideosIntoPlaylists(<String>[
      for (int index = 0; index < 3; index++)
        '/anime/[VCB-Studio] Fate stay night Unlimited Blade Works [0$index][Ma10p_1080p][x265_flac].mkv',
    ]);
    expect(groups, hasLength(1));
    expect(
      groups.single.episodes.map((VideoEpisode episode) => episode.episode),
      <int>[0, 1, 2],
    );
  });

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

  // 刮削按 AniDB 作品把同一文件名系列拆成多个播放列表（Shoko 多 series）后，
  // 重扫不得按 overlap 把它们并回去；已在别的播放列表里的文件不再重新归组。
  test('已归属别的播放列表的文件重扫时不被并回同名系列合集', () async {
    final int sourceId = await addSource('/library');
    for (final ({String uid, String path}) item in <({
      String uid,
      String path,
    })>[
      (uid: 'show-01', path: '/library/Show S01E01.mkv'),
      (uid: 'show-02', path: '/library/Show S01E02.mkv'),
      (uid: 'show-14', path: '/library/Show S01E14.mkv'),
    ]) {
      await addVideo(uid: item.uid, path: item.path, sourceId: sourceId);
    }
    // 模拟拆分结果：两个按 AniDB 作品命名的播放列表，原「Show」合集已删。
    final int first =
        await db.createMediaCollection('Show Part 1', collectionType: 'playlist');
    await db.addToCollection(first, MediaKind.video, 'show-01');
    await db.addToCollection(first, MediaKind.video, 'show-02');
    final int second =
        await db.createMediaCollection('Show Part 2', collectionType: 'playlist');
    await db.addToCollection(second, MediaKind.video, 'show-14');

    final VideoFolderGroupSummary rescan = await coordinator.groupPaths(
      videoPaths: <String>[
        '/library/Show S01E01.mkv',
        '/library/Show S01E02.mkv',
        '/library/Show S01E14.mkv',
      ],
      sourceId: sourceId,
    );
    expect(rescan.createdCollectionIds, isEmpty, reason: '不重建「Show」');
    expect(rescan.updatedCollectionIds, isEmpty, reason: '不把 E14 并进 Part 1');
    expect(
        (await db.getCollectionItems(first))
            .map((MediaCollectionItemRow i) => i.entryKey),
        <String>['show-01', 'show-02']);
    expect(
        (await db.getCollectionItems(second))
            .map((MediaCollectionItemRow i) => i.entryKey),
        <String>['show-14']);
    expect(await db.getAllMediaCollections(), hasLength(2));
  });

  // BUG-2835：VCB BD 包的 `CDs/` 里十几张专辑、一百多首 flac。按系列名归组时
  // 曲目名（`24. 悲愴.flac`）没有系列名 → 一首一个散片，全部平铺进「全部视频」。
  group('BUG-2835 纯音频按专辑目录成辑', () {
    const String root = '/anime/Mushoku Tensei S2';
    const String albumA =
        '$root/CDs/[230927] TVアニメ「無職転生Ⅱ」オリジナル・サウンドトラック [24bit_48kHz] (flac)';
    const String albumB = '$root/CDs/[230712] 聖域 (flac+webp)';
    final List<String> tracks = <String>[
      '$albumA/01. 異世界の朝.flac',
      '$albumA/24. 悲愴.flac',
      '$albumB/01. 聖域.flac',
      '$albumB/02. 聖域 (Instrumental).flac',
    ];
    final List<String> episodes = <String>[
      '$root/[VCB-Studio] Mushoku Tensei S2 [01][Ma10p_1080p][x265_flac].mkv',
      '$root/[VCB-Studio] Mushoku Tensei S2 [02][Ma10p_1080p][x265_flac].mkv',
    ];

    Future<int> seed() async {
      final int sourceId = await addSource(root);
      int i = 0;
      for (final String path in <String>[...tracks, ...episodes]) {
        await addVideo(uid: 'v${i++}', path: path, sourceId: sourceId);
      }
      return sourceId;
    }

    Future<Map<String, List<String>>> membersByName() async {
      return <String, List<String>>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          c.name: <String>[
            for (final MediaCollectionItemRow item
                in await db.getCollectionItems(c.id))
              item.entryKey,
          ],
      };
    }

    test('作品模式：一张专辑一个目录合集，正片照旧按系列归组', () async {
      final int sourceId = await seed();
      final VideoFolderGroupSummary first = await coordinator.groupPaths(
        videoPaths: <String>[...tracks, ...episodes],
        sourceId: sourceId,
      );
      expect(first.createdCollectionIds, hasLength(3));
      final Map<String, List<String>> byName = await membersByName();
      expect(
        byName['TVアニメ「無職転生Ⅱ」オリジナル・サウンドトラック'],
        <String>['v0', 'v1'],
        reason: '剥掉发售日前缀与结尾规格标签；同专辑曲目进同一个合集',
      );
      expect(byName['聖域'], <String>['v2', 'v3']);
      expect(
        byName.values.where(
          (List<String> m) => m.contains('v4') && m.contains('v5'),
        ),
        hasLength(1),
        reason: '正片仍走系列归组，且不与任何专辑混在一起',
      );
      for (final MediaCollectionRow c in await db.getAllMediaCollections()) {
        if (c.name == '聖域') {
          expect(c.collectionType, 'collection');
          expect(c.sourceFolderPath, albumB);
        }
      }
      final VideoFolderGroupSummary rescan = await coordinator.groupPaths(
        videoPaths: <String>[...episodes, ...tracks].reversed.toList(),
        sourceId: sourceId,
      );
      expect(rescan.createdCollectionIds, isEmpty, reason: '重扫幂等');
      expect(rescan.updatedCollectionIds, isEmpty);
      expect(
        applyVideoFolderCollectionPolicy(
          primary: await db.getPrimaryCollectionIdByEntry(),
          collections: await db.getAllMediaCollections(),
          items: await db.getAllCollectionItems(),
          books: await db.allVideoBooks(),
          sources: await db.getMediaSourcesByKind('video'),
        ).keys,
        containsAll(<String>['video|v0', 'video|v1', 'video|v2', 'video|v3']),
        reason: '作品模式下专辑合集也必须是曲目的主归属，否则系列墙上仍是散片',
      );
    });

    test('目录模式：专辑不被并进 CDs 这一级目录合集', () async {
      final int sourceId = await seed();
      await coordinator.groupPaths(
        videoPaths: <String>[...tracks, ...episodes],
        sourceId: sourceId,
        groupingMode: 'folder',
        sourceRoot: root,
      );
      final Map<String, List<String>> byName = await membersByName();
      expect(byName['聖域'], <String>['v2', 'v3']);
      expect(byName.containsKey('CDs'), isFalse,
          reason: '一级目录口径会把所有专辑糊成一个「CDs」合集');
      expect(byName.values.expand((List<String> m) => m),
          containsAll(<String>['v4', 'v5']),
          reason: '正片照旧进根目录合集');
    });

    test('专辑名清洗：只剥首尾修饰，剥空退回原名', () {
      expect(audioAlbumDisplayName('[230712] 聖域 (flac+webp)'), '聖域');
      expect(
        audioAlbumDisplayName('(20231025) Album [24bit_96kHz] [FLAC]'),
        'Album',
      );
      expect(audioAlbumDisplayName('Disc (Bonus) Mix'), 'Disc (Bonus) Mix',
          reason: '中间的括号是名字的一部分');
      expect(audioAlbumDisplayName('[FLAC]'), '[FLAC]');
      expect(
        videoAudioAlbumFolderPath(r'D:\Anime\CDs\Album\01.flac'),
        'd:/anime/cds/album',
      );
    });
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
