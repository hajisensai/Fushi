import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart'
    show discOrdinalEpisodeOverrides;
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
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
      db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(uid),
          videoPath: Value<String>(path),
          sourceId: Value<int?>(sourceId),
        ),
      );

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
    final List<VideoSourceScrapeWork> work = await VideoSourceWorkPlanner(
      db,
    ).plan(source);

    expect(work, hasLength(2));
    final VideoSourceScrapeWork show = work.singleWhere(
      (VideoSourceScrapeWork item) => item.isEpisodic,
    );
    expect(show.collection!.id, collectionId);
    expect(show.members.map((VideoBookRow row) => row.bookUid), <String>[
      'a-01',
      'a-02',
    ]);
    expect(
      show.members.every((VideoBookRow row) => row.sourceId == sourceA),
      isTrue,
    );

    final VideoSourceScrapeWork movie = work.singleWhere(
      (VideoSourceScrapeWork item) => !item.isEpisodic,
    );
    expect(movie.members.single.bookUid, 'movie-a');
  });

  test('纯集号标签标题判为不可自动识别（BUG-2001）', () async {
    final int sourceId = await addSource('D:/A');
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    VideoSourceScrapeWork work(String title) => VideoSourceScrapeWork(
      source: source,
      title: title,
      members: const <VideoBookRow>[],
    );
    expect(work('特典 S00E01').hasIdentifiableTitle, isFalse);
    expect(work('S00E01').hasIdentifiableTitle, isFalse);
    expect(work('SP S01E02').hasIdentifiableTitle, isFalse);
    expect(work('sp-S00E03').hasIdentifiableTitle, isFalse);
    expect(work('哆啦A梦：大雄的秘密道具博物馆').hasIdentifiableTitle, isTrue);
    expect(work('Show S01E01 The Pilot').hasIdentifiableTitle, isTrue);
    expect(work('Steins;Gate').hasIdentifiableTitle, isTrue);
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
    final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
      db,
    ).plan(source);

    expect(works, hasLength(2));
    expect(
      works.every((VideoSourceScrapeWork work) => !work.isEpisodic),
      isTrue,
    );
  });

  test('成员分属不同作品的清单合集按文件各自识别（BUG-4696）', () async {
    // 用户库实测：「哆啦A梦剧场版合集 播放列表」装着两部被旧整理器命名成
    // `<片名> - S00E01.mkv` 的剧场版，整个合集当一部作品去认只能待确认。
    final int sourceId = await addSource('D:/video');
    await addVideo(
      'sky',
      'D:/video/哆啦A梦：大雄与天空的理想乡/Season 00/哆啦A梦：大雄与天空的理想乡 - S00E01.mkv',
      sourceId,
    );
    await addVideo(
      'earth',
      'D:/video/哆啦A梦：大雄的地球交响乐/Season 00/哆啦A梦：大雄的地球交响乐 - S00E01.mkv',
      sourceId,
    );
    final int mixed = await db.createMediaCollection(
      '哆啦A梦剧场版合集 播放列表',
      collectionType: 'playlist',
    );
    await db.addToCollection(mixed, MediaKind.video, 'sky');
    await db.addToCollection(mixed, MediaKind.video, 'earth');
    // 对照：同一部作品的两集仍是一个剧集单元。
    await addVideo('s-01', 'D:/video/Show/Show - S01E01.mkv', sourceId);
    await addVideo('s-02', 'D:/video/Show/Show - S01E02.mkv', sourceId);
    final int show = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await db.addToCollection(show, MediaKind.video, 's-01');
    await db.addToCollection(show, MediaKind.video, 's-02');

    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
      db,
    ).plan(source);

    expect(
      works.map((VideoSourceScrapeWork work) => work.stableKey).toSet(),
      <String>{'book:sky', 'book:earth', 'collection:$show'},
    );
  });

  group('作品名只在目录上的剧集合集仍是一个剧集单元（不按集拆）', () {
    // 回归守卫：曾拿「文件名解出的作品名两两不同」判混装清单，`01.mkv` 解出
    // 「01」、`第01話 旅立ち` 解出「旅立ち」，整部剧被拆成逐集的单文件作品。
    Future<void> expectSingleCollection(List<String> paths) async {
      final int sourceId = await addSource('D:/video');
      final int collectionId = await db.createMediaCollection(
        'Show',
        collectionType: 'playlist',
      );
      for (int i = 0; i < paths.length; i++) {
        await addVideo('ep-$i', paths[i], sourceId);
        await db.addToCollection(collectionId, MediaKind.video, 'ep-$i');
      }
      final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
      final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
        db,
      ).plan(source);
      expect(
        works.map((VideoSourceScrapeWork work) => work.stableKey).toList(),
        <String>['collection:$collectionId'],
      );
      expect(works.single.members, hasLength(paths.length));
    }

    test('自动分组的 Show/01.mkv、02.mkv', () async {
      await expectSingleCollection(<String>[
        'D:/video/Show/01.mkv',
        'D:/video/Show/02.mkv',
        'D:/video/Show/03.mkv',
      ]);
    });

    test('第01集.mp4', () async {
      await expectSingleCollection(<String>[
        'D:/video/Show/第01集.mp4',
        'D:/video/Show/第02集.mp4',
      ]);
    });

    test('Show/S01E01.mkv', () async {
      await expectSingleCollection(<String>[
        'D:/video/Show/S01E01.mkv',
        'D:/video/Show/S01E02.mkv',
      ]);
    });

    test('Show/Season 01/S01E01 - Pilot.mkv', () async {
      await expectSingleCollection(<String>[
        'D:/video/Show/Season 01/S01E01 - Pilot.mkv',
        'D:/video/Show/Season 01/S01E02 - Second.mkv',
      ]);
    });

    test('手建清单装「第01話 旅立ち」「第02話 帰還」', () async {
      await expectSingleCollection(<String>[
        'D:/video/Show/第01話 旅立ち.mkv',
        'D:/video/Show/第02話 帰還.mkv',
      ]);
    });

    test('分季目录 Season 01/01.mkv 与 Season 02/01.mkv 不算集位冲突', () async {
      await expectSingleCollection(<String>[
        'D:/video/Show/Season 01/01.mkv',
        'D:/video/Show/Season 02/01.mkv',
      ]);
    });
  });

  test('混装清单合集上已记着作品身份时按合集认，不拆开绕过身份', () async {
    final int sourceId = await addSource('D:/video');
    await addVideo('sky', 'D:/video/A/Season 00/A - S00E01.mkv', sourceId);
    await addVideo('earth', 'D:/video/B/Season 00/B - S00E01.mkv', sourceId);
    final int mixed = await db.createMediaCollection(
      '剧场版合集',
      collectionType: 'playlist',
    );
    await db.addToCollection(mixed, MediaKind.video, 'sky');
    await db.addToCollection(mixed, MediaKind.video, 'earth');
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        mediaType: 'tv',
        title: '用户确认的作品',
        collectionId: Value<int?>(mixed),
        updatedAt: 0,
      ),
    );
    await db.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:tmdb',
          provider: 'tmdb',
          externalId: '1234',
          isPrimary: const Value<bool>(true),
          updatedAt: 0,
        ),
      ],
    );

    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
      db,
    ).plan(source);

    expect(
      works.map((VideoSourceScrapeWork work) => work.stableKey).toList(),
      <String>['collection:$mixed'],
    );
  });

  test('re0 方括号 PV、菜单与迷你动画不产生独立刮削作品', () async {
    final int sourceId = await addSource('D:/smb/re0');
    const String root =
        'D:/smb/re0/[DBD-Raws][Re：从零开始的异世界生活 第三季]'
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
    final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
      db,
    ).plan(source);

    expect(works, hasLength(1));
    expect(works.single.collection?.id, collectionId);
    expect(
      works.single.members.map((VideoBookRow row) => row.bookUid),
      <String>['main-01', 'main-02'],
    );
  });

  test('yt-dlp 默认命名的 YouTube 视频不进刮削计划，同来源番剧照常', () async {
    final int sourceId = await addSource('D:/影视');
    await addVideo(
      'yt-01',
      'D:/影视/vlog/【韓国ソウル旅行①】女子2人で食べて買って [dQw4w9WgXcQ].mp4',
      sourceId,
    );
    await addVideo(
      'yt-02',
      'D:/影视/vlog/北京ユニバに初めて行ったら [jNQXAC9IVRw].f137.mp4',
      sourceId,
    );
    await addVideo(
      'anime-01',
      'D:/影视/[SubsPlease] Sousou no Frieren - 01 (1080p) [F02B9CEE].mkv',
      sourceId,
    );

    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
      db,
    ).plan(source);

    expect(
      works.map((VideoSourceScrapeWork work) => work.members.single.bookUid),
      <String>['anime-01'],
    );
  });

  test('按集展开、跨两张盘的原盘合集是一部剧集作品，集号按合集顺序连续', () async {
    // 只有「全部播放」的剧集盘入库后：同一发布的两张盘并在一个合集里，成员是虚拟的
    // 分集路径，按盘序 × 盘内集序排（docs/specs/2026-11-15-bluray-playitem-episodes.md）。
    final int sourceId = await addSource('D:/bd');
    final int collectionId = await db.createMediaCollection(
      '魔女の旅々',
      collectionType: 'playlist',
    );
    final List<String> paths = <String>[
      for (final String disc in <String>['Disc 1', 'Disc 2'])
        for (int item = 1; item <= 6; item++)
          'D:/bd/Majo [BDMV]/$disc/BDMV/PLAYLIST/00001.p0$item.mpls',
    ];
    // 入库顺序故意与路径字典序、uid 字典序都不同：集号只认合集内顺序。
    for (final (int index, String path) in paths.indexed) {
      final String uid =
          'ep-${(97 + (index * 7) % 12).toRadixString(36)}$index';
      await addVideo(uid, path, sourceId);
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }

    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final VideoSourceScrapeWork work = (await VideoSourceWorkPlanner(
      db,
    ).plan(source)).single;
    expect(work.isEpisodic, isTrue);
    expect(work.title, '魔女の旅々');
    expect(work.members.map((VideoBookRow row) => row.videoPath), paths);
    final Map<String, (int, int)> overrides = discOrdinalEpisodeOverrides(work);
    expect(
      <(int, int)>[
        for (final VideoBookRow member in work.members)
          overrides[member.bookUid]!,
      ],
      <(int, int)>[for (int i = 1; i <= 12; i++) (1, i)],
    );
  });

  test('单张逐集播放列表的盘不套顺序集号（维持按文件名的旧行为）', () async {
    final int sourceId = await addSource('D:/bd');
    final int collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    for (final String id in <String>['00003', '00004']) {
      await addVideo(id, 'D:/bd/Show/BDMV/PLAYLIST/$id.mpls', sourceId);
      await db.addToCollection(collectionId, MediaKind.video, id);
    }
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final VideoSourceScrapeWork work = (await VideoSourceWorkPlanner(
      db,
    ).plan(source)).single;
    expect(work.isEpisodic, isTrue);
    expect(discOrdinalEpisodeOverrides(work), isEmpty);
  });
}
