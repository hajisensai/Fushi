import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/tracking/bangumi_api_client.dart';
import 'package:hibiki/src/media/tracking/media_tracking_repository.dart';
import 'package:hibiki/src/media/tracking/media_tracking_service.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

class _FakeBangumiApi implements BangumiTrackingApi {
  BangumiUserCollection? collection;
  List<BangumiEpisode> episodes = const <BangumiEpisode>[];
  BangumiSubject subject = const BangumiSubject(
    id: 88,
    type: 1,
    name: 'Remote book',
    nameCn: '',
    platform: '书籍',
    episodeCount: 0,
    volumeCount: 0,
  );
  Exception? error;
  final List<Map<String, dynamic>> creates = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> patches = <Map<String, dynamic>>[];
  final List<List<int>> episodePatches = <List<int>>[];
  List<BangumiSubject> searchResults = const <BangumiSubject>[];
  final List<({String keyword, int subjectType})> searches =
      <({String keyword, int subjectType})>[];

  void _throwIfNeeded() {
    final Exception? value = error;
    if (value != null) throw value;
  }

  @override
  Future<BangumiUser> getMe() async {
    _throwIfNeeded();
    return const BangumiUser(username: 'alice', nickname: 'Alice');
  }

  @override
  Future<List<BangumiSubject>> searchSubjects({
    required String keyword,
    required int subjectType,
  }) async {
    searches.add((keyword: keyword, subjectType: subjectType));
    _throwIfNeeded();
    return searchResults;
  }

  @override
  Future<BangumiSubject> getSubject(int subjectId) async {
    _throwIfNeeded();
    return subject;
  }

  @override
  Future<BangumiUserCollection?> getCollection(
    String username,
    int subjectId,
  ) async {
    _throwIfNeeded();
    expect(username, 'alice');
    return collection;
  }

  @override
  Future<void> createCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  }) async {
    _throwIfNeeded();
    creates.add(payload);
  }

  @override
  Future<void> patchCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  }) async {
    _throwIfNeeded();
    patches.add(payload);
  }

  @override
  Future<List<BangumiEpisode>> getMainEpisodes(int subjectId) async {
    _throwIfNeeded();
    return episodes;
  }

  @override
  Future<void> markEpisodesDone(
    int subjectId,
    List<int> episodeIds,
  ) async {
    _throwIfNeeded();
    episodePatches.add(episodeIds);
  }

  @override
  void close() {}
}

void main() {
  late HibikiDatabase db;
  late PreferencesRepository preferences;
  late MediaTrackingRepository repository;
  late _FakeBangumiApi api;
  late MediaTrackingService service;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    preferences = PreferencesRepository(db);
    await preferences.loadFromDb();
    await preferences.setPref(kBangumiAccessTokenPref, 'token');
    repository = MediaTrackingRepository(db);
    api = _FakeBangumiApi();
    service = MediaTrackingService(
      repository: repository,
      preferences: preferences,
      userAgent: 'test-agent',
      apiFactory: (_) => api,
    );
  });

  tearDown(() async {
    preferences.dispose();
    await db.close();
  });

  test('anime sync creates doing collection and marks all episodes to progress',
      () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '8',
      mediaTitle: 'Anime',
      kind: TrackingKind.anime,
      subjectId: 88,
      subjectName: 'Remote anime',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '8',
      localProgress: 1,
      completed: false,
    );
    api.episodes = const <BangumiEpisode>[
      BangumiEpisode(id: 11, type: 0, sort: 1),
      BangumiEpisode(id: 12, type: 0, sort: 2),
      BangumiEpisode(id: 13, type: 0, sort: 3),
    ];

    final MediaTrackingSyncResult result = await service.syncNow();

    expect(result.succeeded, 1);
    expect(api.creates.single, <String, dynamic>{'type': 3});
    expect(api.episodePatches.single, <int>[11, 12]);
    expect(await repository.pendingCount(), 0);
  });

  test('finishing a partial local playlist does not mark a longer subject done',
      () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '8',
      mediaTitle: 'Partial anime',
      kind: TrackingKind.anime,
      subjectId: 88,
      subjectName: 'Long remote anime',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '8',
      localProgress: 1,
      completed: true,
    );
    api.collection = const BangumiUserCollection(
      type: 3,
      episodeProgress: 0,
      volumeProgress: 0,
    );
    api.episodes = const <BangumiEpisode>[
      BangumiEpisode(id: 11, type: 0, sort: 1),
      BangumiEpisode(id: 12, type: 0, sort: 2),
      BangumiEpisode(id: 13, type: 0, sort: 3),
    ];

    await service.syncNow();

    expect(api.episodePatches.single, <int>[11, 12]);
    expect(api.patches, isEmpty);
  });

  test('watching a partial subject promotes wish to doing', () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: 'episode-2',
      mediaTitle: 'Anime episode 2',
      kind: TrackingKind.anime,
      subjectId: 88,
      subjectName: 'Remote anime',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 2,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.video,
      mediaKey: 'episode-2',
      localProgress: 0,
      completed: false,
    );
    api.collection = const BangumiUserCollection(
      type: 1,
      episodeProgress: 0,
      volumeProgress: 0,
    );
    api.episodes = const <BangumiEpisode>[
      BangumiEpisode(id: 11, type: 0, sort: 1),
      BangumiEpisode(id: 12, type: 0, sort: 2),
      BangumiEpisode(id: 13, type: 0, sort: 3),
    ];

    await service.syncNow();

    expect(api.episodePatches.single, <int>[11, 12]);
    expect(api.patches.single, <String, dynamic>{'type': 3});
  });

  test('reaching the last subject episode promotes doing to watched', () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: 'last-episode',
      mediaTitle: 'Anime last episode',
      kind: TrackingKind.anime,
      subjectId: 88,
      subjectName: 'Remote anime',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 3,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.video,
      mediaKey: 'last-episode',
      localProgress: 0,
      completed: false,
    );
    api.collection = const BangumiUserCollection(
      type: 3,
      episodeProgress: 2,
      volumeProgress: 0,
    );
    api.episodes = const <BangumiEpisode>[
      BangumiEpisode(id: 11, type: 0, sort: 1),
      BangumiEpisode(id: 12, type: 0, sort: 2),
      BangumiEpisode(id: 13, type: 0, sort: 3),
    ];

    await service.syncNow();

    expect(api.episodePatches.single, <int>[11, 12, 13]);
    expect(api.patches.single, <String, dynamic>{'type': 2});
  });

  test('rewatching an earlier episode never downgrades watched to doing',
      () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: 'episode-2',
      mediaTitle: 'Anime episode 2',
      kind: TrackingKind.anime,
      subjectId: 88,
      subjectName: 'Remote anime',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 2,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.video,
      mediaKey: 'episode-2',
      localProgress: 0,
      completed: false,
    );
    api.collection = const BangumiUserCollection(
      type: 2,
      episodeProgress: 3,
      volumeProgress: 0,
    );
    api.episodes = const <BangumiEpisode>[
      BangumiEpisode(id: 11, type: 0, sort: 1),
      BangumiEpisode(id: 12, type: 0, sort: 2),
      BangumiEpisode(id: 13, type: 0, sort: 3),
    ];

    await service.syncNow();

    expect(api.episodePatches.single, <int>[11, 12]);
    expect(api.patches, isEmpty);
  });

  test('sync repairs a completed legacy video whose outbox was already empty',
      () async {
    final DateTime completedAt = DateTime.fromMillisecondsSinceEpoch(2000);
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'legacy-episode-2',
        title: 'Legacy anime 02',
        videoPath: r'C:\Anime\Legacy\02.mkv',
        completedAt: Value<DateTime?>(completedAt),
      ),
    );
    await repository.saveMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: 'legacy-episode-2',
      mediaTitle: 'Legacy anime 02',
      kind: TrackingKind.anime,
      subjectId: 88,
      subjectName: 'Remote anime',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 2,
    );
    expect(await repository.pendingCount(), 0);
    api.collection = const BangumiUserCollection(
      type: 1,
      episodeProgress: 0,
      volumeProgress: 0,
    );
    api.episodes = const <BangumiEpisode>[
      BangumiEpisode(id: 11, type: 0, sort: 1),
      BangumiEpisode(id: 12, type: 0, sort: 2),
      BangumiEpisode(id: 13, type: 0, sort: 3),
    ];

    final MediaTrackingSyncResult result = await service.syncNow();

    expect(result.succeeded, 1);
    expect(api.episodePatches.single, <int>[11, 12]);
    expect(api.patches.single, <String, dynamic>{'type': 3});
    expect(await repository.pendingCount(), 0);
    expect(
      preferences.getPref(
        kVideoTrackingReconcileWatermarkPref,
        defaultValue: 0,
      ),
      isNonZero,
    );
  });

  test('completed collection reconciliation uses its highest completed member',
      () async {
    final int collectionId = await db.createMediaCollection('Legacy playlist');
    for (int index = 0; index < 3; index++) {
      final String uid = 'legacy-collection-$index';
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: 'Episode ${index + 1}',
          videoPath: 'C:/Anime/Legacy/${index + 1}.mkv',
          completedAt: index < 2
              ? Value<DateTime?>(
                  DateTime.fromMillisecondsSinceEpoch(3000 + index),
                )
              : const Value<DateTime?>.absent(),
        ),
      );
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
    await repository.saveMapping(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '$collectionId',
      mediaTitle: 'Legacy playlist',
      kind: TrackingKind.anime,
      subjectId: 88,
      subjectName: 'Remote anime',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
    );
    api.collection = const BangumiUserCollection(
      type: 1,
      episodeProgress: 0,
      volumeProgress: 0,
    );
    api.episodes = const <BangumiEpisode>[
      BangumiEpisode(id: 11, type: 0, sort: 1),
      BangumiEpisode(id: 12, type: 0, sort: 2),
      BangumiEpisode(id: 13, type: 0, sort: 3),
    ];

    await service.syncNow();

    expect(api.episodePatches.single, <int>[11, 12]);
    expect(api.patches.single, <String, dynamic>{'type': 3});
  });

  test(
      'episode progress uses subject-local order when Bangumi sort starts later',
      () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: 'episode-2',
      mediaTitle: 'Split cour episode 2',
      kind: TrackingKind.anime,
      subjectId: 88,
      subjectName: 'Split cour',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 2,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.video,
      mediaKey: 'episode-2',
      localProgress: 0,
      completed: false,
    );
    api.episodes = const <BangumiEpisode>[
      BangumiEpisode(id: 51, type: 0, sort: 51),
      BangumiEpisode(id: 52, type: 0, sort: 52),
      BangumiEpisode(id: 53, type: 0, sort: 53),
    ];

    final MediaTrackingSyncResult result = await service.syncNow();

    expect(result.succeeded, 1);
    expect(api.episodePatches.single, <int>[51, 52]);
    expect(await repository.pendingCount(), 0);
  });

  test('book sync never regresses remote progress and can mark done', () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book',
      mediaTitle: 'Book',
      kind: TrackingKind.novel,
      subjectId: 7,
      subjectName: 'Remote book',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book',
      localProgress: 5,
      completed: true,
    );
    api.collection = const BangumiUserCollection(
      type: 3,
      episodeProgress: 7,
      volumeProgress: 0,
    );

    await service.syncNow();

    expect(api.patches.single, <String, dynamic>{'type': 2});
    expect(api.patches.single, isNot(contains('ep_status')));
  });

  test('starting a novel promotes wish to reading before chapter one ends',
      () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'novel',
      mediaTitle: 'Novel',
      kind: TrackingKind.novel,
      subjectId: 88,
      subjectName: 'Remote novel',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'novel',
      localProgress: 0,
      completed: false,
    );
    api.collection = const BangumiUserCollection(
      type: 1,
      episodeProgress: 0,
      volumeProgress: 0,
    );

    await service.syncNow();

    expect(api.patches.single, <String, dynamic>{'type': 3});
  });

  test('partial novel progress never downgrades an already read collection',
      () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'read-novel',
      mediaTitle: 'Read novel',
      kind: TrackingKind.novel,
      subjectId: 88,
      subjectName: 'Remote novel',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'read-novel',
      localProgress: 2,
      completed: false,
    );
    api.collection = const BangumiUserCollection(
      type: 2,
      episodeProgress: 0,
      volumeProgress: 0,
    );

    await service.syncNow();

    expect(api.patches.single, <String, dynamic>{'ep_status': 2});
    expect(api.patches.single, isNot(contains('type')));
  });

  test('finishing one volume keeps a longer book subject in reading', () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'volume-2',
      mediaTitle: 'Novel volume 2',
      kind: TrackingKind.novel,
      subjectId: 88,
      subjectName: 'Remote novel series',
      progressMode: TrackingProgressMode.volume,
      progressOffset: 2,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'volume-2',
      localProgress: 0,
      completed: true,
    );
    api.subject = const BangumiSubject(
      id: 88,
      type: 1,
      name: 'Remote novel series',
      nameCn: '',
      platform: '书籍',
      episodeCount: 0,
      volumeCount: 3,
    );
    api.collection = const BangumiUserCollection(
      type: 1,
      episodeProgress: 0,
      volumeProgress: 0,
    );

    await service.syncNow();

    expect(
      api.patches.single,
      <String, dynamic>{'vol_status': 2, 'type': 3},
    );
  });

  test('finishing the last remote volume promotes reading to read', () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'volume-3',
      mediaTitle: 'Novel volume 3',
      kind: TrackingKind.novel,
      subjectId: 88,
      subjectName: 'Remote novel series',
      progressMode: TrackingProgressMode.volume,
      progressOffset: 3,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'volume-3',
      localProgress: 0,
      completed: true,
    );
    api.subject = const BangumiSubject(
      id: 88,
      type: 1,
      name: 'Remote novel series',
      nameCn: '',
      platform: '书籍',
      episodeCount: 0,
      volumeCount: 3,
    );
    api.collection = const BangumiUserCollection(
      type: 3,
      episodeProgress: 0,
      volumeProgress: 2,
    );

    await service.syncNow();

    expect(
      api.patches.single,
      <String, dynamic>{'vol_status': 3, 'type': 2},
    );
  });

  test('sync restores a legacy novel reading position after outbox was cleared',
      () async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'legacy-novel',
        title: 'Legacy novel',
        epubPath: '/tmp/legacy.epub',
        extractDir: '/tmp/legacy',
        chapterCount: 8,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookKey: 'legacy-novel',
        sectionIndex: 2,
        normCharOffset: 5000,
        updatedAt: 4000,
      ),
    );
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'legacy-novel',
      mediaTitle: 'Legacy novel',
      kind: TrackingKind.novel,
      subjectId: 88,
      subjectName: 'Remote novel',
      progressMode: TrackingProgressMode.chapter,
      progressOffset: 0,
    );
    api.collection = const BangumiUserCollection(
      type: 1,
      episodeProgress: 0,
      volumeProgress: 0,
    );
    expect(await repository.pendingCount(), 0);

    await service.syncNow();

    expect(
      api.patches.single,
      <String, dynamic>{'ep_status': 2, 'type': 3},
    );
    expect(await repository.pendingCount(), 0);
    expect(
      preferences.getPref(
        kBookTrackingReconcileWatermarkPref,
        defaultValue: 0,
      ),
      isNonZero,
    );
  });

  test('network failure keeps the update in the durable queue', () async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book',
      mediaTitle: 'Book',
      kind: TrackingKind.manga,
      subjectId: 7,
      subjectName: 'Remote book',
      progressMode: TrackingProgressMode.volume,
      progressOffset: 2,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.book,
      mediaKey: 'book',
      localProgress: 0,
      completed: true,
    );
    api.error = const BangumiApiException(
      statusCode: 503,
      message: 'temporarily unavailable',
    );

    final MediaTrackingSyncResult result = await service.syncNow();

    expect(result.failed, 1);
    expect(await repository.pendingCount(), 1);
  });

  test('video completion reuses scraped Bangumi subject and creates mapping',
      () async {
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video-1',
        title: '葬送的芙莉莲 01',
        videoPath: r'C:\Anime\Frieren\01.mkv',
      ),
    );
    await db.upsertVideoScrapeMeta(
      VideoScrapeMetaCompanion.insert(
        bookUid: 'video-1',
        source: 'bangumi',
        subjectId: '400602',
        title: '葬送的芙莉莲',
        scrapedAt: DateTime.now(),
      ),
    );

    await service.recordVideoCompleted(
      bookUid: 'video-1',
      episodeIndex: 0,
    );
    await service.syncNow();

    final MediaTrackingMappingRow? mapping = await repository.findMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: 'video-1',
    );
    expect(mapping, isNotNull);
    expect(mapping!.subjectId, 400602);
    expect(mapping.subjectName, '葬送的芙莉莲');
    expect(mapping.progressMode, TrackingProgressMode.episode.value);
    expect(api.searches, isEmpty, reason: '已刮出的 Bangumi id 不应重复搜索');
  });

  test('novel progress creates a unique exact-title chapter mapping', () async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'novel-key',
        title: '药屋少女的呢喃',
        epubPath: '/tmp/novel.epub',
        extractDir: '/tmp/novel',
        chapterCount: 12,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    api.searchResults = const <BangumiSubject>[
      BangumiSubject(
        id: 225878,
        type: 1,
        name: '薬屋のひとりごと',
        nameCn: '药屋少女的呢喃',
        platform: '书籍',
        episodeCount: 12,
        volumeCount: 1,
      ),
    ];

    await service.recordBookProgress(
      bookKey: 'novel-key',
      completedChapterCount: 3,
      completed: false,
    );
    await service.syncNow();

    final MediaTrackingMappingRow? mapping = await repository.findMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'novel-key',
    );
    expect(mapping, isNotNull);
    expect(mapping!.kind, TrackingKind.novel.value);
    expect(mapping.progressMode, TrackingProgressMode.chapter.value);
    expect(mapping.progressOffset, 0);
    expect(api.searches.single, (keyword: '药屋少女的呢喃', subjectType: 1));
  });

  test('novel series selects novel over same-title manga and syncs chapter',
      () async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'series-volume-1',
        title: '同名系列 01 (MFブックス)',
        epubPath: '/tmp/series-1.epub',
        extractDir: '/tmp/series-1',
        chapterCount: 4,
        chaptersJson: '''
[
  {"href":"text/nav.xhtml"},
  {"href":"text/chapter-1.xhtml"},
  {"href":"text/illustration.xhtml"},
  {"href":"text/chapter-2.xhtml"}
]
''',
        tocJson: const Value<String>('''
[
  {"title":"目次","href":"text/nav.xhtml"},
  {"title":"第一話","href":"text/chapter-1.xhtml"},
  {"title":"第二話","href":"text/chapter-2.xhtml"}
]
'''),
        importedAt: 1,
      ),
    );
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookKey: 'series-volume-1',
        sectionIndex: 2,
        normCharOffset: 0,
        updatedAt: 2,
      ),
    );
    api.searchResults = const <BangumiSubject>[
      BangumiSubject(
        id: 10,
        type: 1,
        name: '同名系列',
        nameCn: '',
        platform: '漫画',
        episodeCount: 120,
        volumeCount: 12,
      ),
      BangumiSubject(
        id: 20,
        type: 1,
        name: '同名系列',
        nameCn: '',
        platform: '小说',
        episodeCount: 262,
        volumeCount: 26,
      ),
    ];
    api.subject = const BangumiSubject(
      id: 20,
      type: 1,
      name: '同名系列',
      nameCn: '',
      platform: '小说',
      episodeCount: 262,
      volumeCount: 26,
    );
    api.collection = const BangumiUserCollection(
      type: 1,
      episodeProgress: 0,
      volumeProgress: 0,
    );

    await service.recordBookProgress(
      bookKey: 'series-volume-1',
      completedChapterCount: 17,
      completed: false,
    );
    await service.syncNow();
    while (await repository.pendingCount() > 0) {
      await service.syncNow();
    }

    final MediaTrackingMappingRow? volumeMapping = await repository.findMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'series-volume-1',
    );
    final MediaTrackingMappingRow? chapterMapping =
        await repository.findMapping(
      mediaType: TrackingMediaType.bookChapter,
      mediaKey: 'series-volume-1',
    );
    expect(volumeMapping, isNotNull);
    expect(volumeMapping!.subjectId, 20);
    expect(volumeMapping.progressMode, TrackingProgressMode.volume.value);
    expect(volumeMapping.progressOffset, 1);
    expect(chapterMapping, isNotNull);
    expect(chapterMapping!.subjectId, 20);
    expect(chapterMapping.progressOffset, 0);
    expect(api.searches.single, (keyword: '同名系列', subjectType: 1));
    expect(
      api.patches,
      anyElement(equals(<String, dynamic>{'ep_status': 1})),
      reason: '章节进度必须按 TOC 逻辑章节上报，不能使用 17 个 spine 文件',
    );
    expect(
      api.patches,
      anyElement(equals(<String, dynamic>{'type': 3})),
    );

    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookKey: 'series-volume-1',
        sectionIndex: 3,
        normCharOffset: 10000,
        updatedAt: 3,
      ),
    );
    await db.markEpubBookCompletedIfUnset(
      'series-volume-1',
      DateTime.fromMillisecondsSinceEpoch(3),
    );
    await service.recordBookProgress(
      bookKey: 'series-volume-1',
      completedChapterCount: 99,
      completed: true,
    );
    await service.syncNow();
    while (await repository.pendingCount() > 0) {
      await service.syncNow();
    }

    expect(
      api.patches,
      anyElement(equals(<String, dynamic>{'vol_status': 1, 'type': 3})),
      reason: '读完第 1/26 卷只增加卷数，收藏仍须保持在读',
    );
    expect(
      api.patches,
      anyElement(equals(<String, dynamic>{'ep_status': 2})),
    );
  });

  test('manga volume suffix reports previous volumes while current is reading',
      () async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'manga-key',
        title: '迷宫饭 第3卷',
        epubPath: '/tmp/manga/manga.json',
        extractDir: '/tmp/manga',
        chapterCount: 200,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
      ),
    );
    api.searchResults = const <BangumiSubject>[
      BangumiSubject(
        id: 110993,
        type: 1,
        name: 'ダンジョン飯',
        nameCn: '迷宫饭',
        platform: '漫画',
        episodeCount: 0,
        volumeCount: 14,
      ),
    ];

    await service.recordBookProgress(
      bookKey: 'manga-key',
      completedChapterCount: 80,
      completed: false,
    );

    final MediaTrackingMappingRow? mapping = await repository.findMapping(
      mediaType: TrackingMediaType.book,
      mediaKey: 'manga-key',
    );
    expect(mapping, isNotNull);
    expect(mapping!.kind, TrackingKind.manga.value);
    expect(mapping.progressMode, TrackingProgressMode.volume.value);
    expect(mapping.progressOffset, 3);
    expect(await repository.pendingCount(), 1);
    await service.syncNow();
    expect(await repository.pendingCount(), 0,
        reason: '漫画页码不能误写成 Bangumi 章节进度');
    expect(
      api.creates.single,
      <String, dynamic>{'vol_status': 2, 'type': 3},
      reason: '开始第 3 卷只代表前 2 卷已读，当前收藏应为在读',
    );

    api.error = const BangumiApiException(
      statusCode: 503,
      message: 'keep queued',
    );
    await service.recordBookProgress(
      bookKey: 'manga-key',
      completedChapterCount: 200,
      completed: true,
    );
    await service.syncNow();
    expect(await repository.pendingCount(), 1);
  });

  test('ambiguous exact-title book results are not auto-mapped', () async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'ambiguous-key',
        title: '同名作品',
        epubPath: '/tmp/ambiguous.epub',
        extractDir: '/tmp/ambiguous',
        chapterCount: 2,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    api.searchResults = const <BangumiSubject>[
      BangumiSubject(
        id: 1,
        type: 1,
        name: '同名作品',
        nameCn: '',
        platform: '书籍',
        episodeCount: 0,
        volumeCount: 0,
      ),
      BangumiSubject(
        id: 2,
        type: 1,
        name: '同名作品',
        nameCn: '',
        platform: '书籍',
        episodeCount: 0,
        volumeCount: 0,
      ),
    ];

    await service.recordBookProgress(
      bookKey: 'ambiguous-key',
      completedChapterCount: 1,
      completed: false,
    );

    expect(
      await repository.findMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: 'ambiguous-key',
      ),
      isNull,
    );
  });

  group('游戏收藏状态同步', () {
    Future<void> insertGame(
      String id, {
      required String name,
      int playStatus = 0,
    }) =>
        db.upsertGalgame(
          GalgamesCompanion.insert(
            id: id,
            name: name,
            exePath: 'C:\\games\\$id.exe',
            workdir: 'C:\\games',
            addedAt: 1000,
            playStatus: Value<int>(playStatus),
          ),
        );

    Future<void> scrapeBangumi(String gameId, String subjectId) =>
        db.upsertGalgameSource(
          GalgameSourcesCompanion.insert(
            gameId: gameId,
            source: 'bgm',
            externalId: Value<String?>(subjectId),
            dataJson: '{}',
            fetchedAt: 1000,
          ),
        );

    test('已刮削的游戏用 Bangumi 条目建映射并创建收藏', () async {
      await insertGame('g1', name: 'Sakura no Uta');
      await scrapeBangumi('g1', '4242');

      await service.recordGameStatus(gameId: 'g1', status: 3);
      // recordGameStatus 内部是 unawaited(syncNow())；syncNow 会返回同一个
      // in-flight future，await 它即可等到后台同步真正跑完。
      await service.syncNow();

      final MediaTrackingMappingRow? mapping = await repository.findMapping(
        mediaType: TrackingMediaType.game,
        mediaKey: 'g1',
      );
      expect(mapping, isNotNull);
      expect(mapping!.subjectId, 4242);
      expect(mapping.kind, TrackingKind.game.value);
      expect(mapping.progressMode, TrackingProgressMode.status.value);
      // offset 必须是 0，否则收藏 type 会被算成另一个状态。
      expect(mapping.progressOffset, 0);
      expect(api.creates, <Map<String, dynamic>>[
        <String, dynamic>{'type': 3},
      ]);
      // 游戏条目没有话数，绝不能去动 ep_status。
      expect(api.episodePatches, isEmpty);
    });

    test('状态回退如实同步：玩过 → 在玩', () async {
      await insertGame('g1', name: 'Sakura no Uta');
      await scrapeBangumi('g1', '4242');
      api.collection = const BangumiUserCollection(
        type: 2,
        episodeProgress: 0,
        volumeProgress: 0,
      );

      await service.recordGameStatus(gameId: 'g1', status: 3);
      await service.syncNow();

      expect(api.patches, <Map<String, dynamic>>[
        <String, dynamic>{'type': 3},
      ]);
    });

    test('远端状态已经一致时不发多余请求', () async {
      await insertGame('g1', name: 'Sakura no Uta');
      await scrapeBangumi('g1', '4242');
      api.collection = const BangumiUserCollection(
        type: 3,
        episodeProgress: 0,
        volumeProgress: 0,
      );

      await service.recordGameStatus(gameId: 'g1', status: 3);
      await service.syncNow();

      expect(api.patches, isEmpty);
      expect(api.creates, isEmpty);
    });

    test('未设置状态(0)不上报', () async {
      await insertGame('g1', name: 'Sakura no Uta', playStatus: 0);
      await scrapeBangumi('g1', '4242');

      await service.recordGameStatus(gameId: 'g1', status: 0);

      expect(
        await repository.findMapping(
          mediaType: TrackingMediaType.game,
          mediaKey: 'g1',
        ),
        isNull,
      );
      expect(api.creates, isEmpty);
      expect(api.patches, isEmpty);
    });

    test('未刮削时按名字搜游戏条目(type 4)，匹配不唯一就不建映射', () async {
      await insertGame('g1', name: 'Generic Title');
      api.searchResults = const <BangumiSubject>[
        BangumiSubject(
          id: 11,
          type: 4,
          name: 'Generic Title',
          nameCn: '',
          platform: '游戏',
          episodeCount: 0,
          volumeCount: 0,
        ),
        BangumiSubject(
          id: 12,
          type: 4,
          name: 'Generic Title',
          nameCn: '',
          platform: '游戏',
          episodeCount: 0,
          volumeCount: 0,
        ),
      ];

      await service.recordGameStatus(gameId: 'g1', status: 3);

      expect(api.searches.single.subjectType, 4);
      expect(
        await repository.findMapping(
          mediaType: TrackingMediaType.game,
          mediaKey: 'g1',
        ),
        isNull,
      );
      expect(api.creates, isEmpty);
    });

    test('连上账号后对账补发此前已设置的状态', () async {
      await insertGame('g1', name: 'Sakura no Uta', playStatus: 4);
      await scrapeBangumi('g1', '4242');

      // 换账号会把水位归零，强制从本地事实重建一次。
      await service.setAccessToken('token');
      await service.syncNow(force: true);

      expect(api.creates, <Map<String, dynamic>>[
        <String, dynamic>{'type': 4},
      ]);
    });
  });

  test('Bangumi 条目类型按 kind 映射', () {
    expect(bangumiSubjectTypeOf(TrackingKind.anime), 2);
    expect(bangumiSubjectTypeOf(TrackingKind.game), 4);
    expect(bangumiSubjectTypeOf(TrackingKind.novel), 1);
    expect(bangumiSubjectTypeOf(TrackingKind.manga), 1);
  });

  // BUG-1220：整条追踪链路原本零可观测——成功即删 outbox 行、失败只进错误日志并
  // 退避最长 6 小时、没建映射就静默返回。用户「看完了没反应」时无从判断断在哪一段。
  group('可见状态快照（BUG-1220）', () {
    Future<void> saveAnimeMapping() => repository.saveMapping(
          mediaType: TrackingMediaType.videoCollection,
          mediaKey: '8',
          mediaTitle: 'Anime',
          kind: TrackingKind.anime,
          subjectId: 88,
          subjectName: 'Remote anime',
          progressMode: TrackingProgressMode.episode,
          progressOffset: 1,
        );

    test('从未同步过与同步过零待办可区分', () async {
      final MediaTrackingStatus before = await service.loadStatus();
      expect(before.hasNeverSynced, isTrue);
      expect(before.configured, isTrue);

      // 队列本来就空：这一轮什么都没发出去，但确实跑过一次同步。成功即删行的
      // 设计下，若不落「上次同步」，这个状态与「从没跑过」在 UI 上完全同形。
      await service.syncNow(force: true);

      final MediaTrackingStatus after = await service.loadStatus();
      expect(after.hasNeverSynced, isFalse);
      expect(after.lastSyncAt, greaterThan(0));
      expect(after.pending, 0);
    });

    test('未配置令牌时同步不谎报「已同步过」', () async {
      await preferences.setPref(kBangumiAccessTokenPref, '');

      await service.syncNow(force: true);

      final MediaTrackingStatus status = await service.loadStatus();
      expect(status.configured, isFalse);
      expect(status.hasNeverSynced, isTrue, reason: '没有令牌那一轮一条都发不出去，不能记成同步过');
    });

    test('失败待办在退避窗口内仍带原因外显', () async {
      await saveAnimeMapping();
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.videoCollection,
        mediaKey: '8',
        localProgress: 1,
        completed: false,
      );
      api.error = const BangumiApiException(statusCode: 500, message: 'boom');

      final MediaTrackingSyncResult result = await service.syncNow(force: true);
      expect(result.failed, 1);

      // markFailed 把 nextAttemptAt 推到 30 秒后：发送侧（dueUpdates）此刻应看不到
      // 这一行，展示侧（loadStatus）必须照样能说出失败原因，否则退避窗口就是一个
      // 「零待办、零错误」的假象。
      expect(await repository.dueUpdates(), isEmpty);
      final MediaTrackingStatus status = await service.loadStatus();
      expect(status.pending, 1);
      expect(status.failures, hasLength(1));
      expect(status.failures.single.mediaTitle, 'Anime');
      expect(status.failures.single.error, contains('500'));
      expect(status.hasProblem, isTrue);
    });

    test('令牌被拒记成 unauthorized 状态', () async {
      await saveAnimeMapping();
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.videoCollection,
        mediaKey: '8',
        localProgress: 1,
        completed: false,
      );
      api.error = const BangumiApiException(statusCode: 401, message: 'nope');

      await service.syncNow(force: true);

      final MediaTrackingStatus status = await service.loadStatus();
      expect(status.unauthorized, isTrue);
      expect(status.hasProblem, isTrue);
    });

    test('connect 记住账号名，换令牌清掉旧账号', () async {
      final BangumiUser user = await service.connect('fresh-token');

      expect(user.nickname, 'Alice');
      expect(service.accountName, 'Alice');
      expect(service.accessToken, 'fresh-token');
      expect((await service.loadStatus()).accountName, 'Alice');

      await service.setAccessToken('another-token');
      expect(service.accountName, isEmpty,
          reason: '账号名属于旧令牌，换令牌后必须失效，不能挂着上一个账号');
    });

    test('待发送计数走 COUNT(*)，不被展示上限截断', () async {
      // allPending 带展示上限（默认 50 行），计数若跟着它走，待办多于上限时就会
      // 把「待发送 N 项」少报成上限值。
      for (int i = 0; i < 55; i++) {
        await repository.saveMapping(
          mediaType: TrackingMediaType.video,
          mediaKey: 'v$i',
          mediaTitle: 'Video $i',
          kind: TrackingKind.anime,
          subjectId: 1000 + i,
          subjectName: 'Remote $i',
          progressMode: TrackingProgressMode.episode,
          progressOffset: 1,
        );
        await repository.enqueueProgress(
          mediaType: TrackingMediaType.video,
          mediaKey: 'v$i',
          localProgress: 1,
          completed: false,
        );
      }

      final MediaTrackingStatus status = await service.loadStatus();

      expect(status.pending, 55);
    });

    test('伴随的 bookChapter 映射不作为独立条目外显', () async {
      await repository.saveMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: 'book-1',
        mediaTitle: 'Novel',
        kind: TrackingKind.novel,
        subjectId: 77,
        subjectName: 'Remote novel',
        progressMode: TrackingProgressMode.volume,
        progressOffset: 2,
      );
      await repository.saveMapping(
        mediaType: TrackingMediaType.bookChapter,
        mediaKey: 'book-1',
        mediaTitle: 'Novel',
        kind: TrackingKind.novel,
        subjectId: 77,
        subjectName: 'Remote novel',
        progressMode: TrackingProgressMode.chapter,
        progressOffset: 12,
      );

      final MediaTrackingStatus status = await service.loadStatus();

      expect(status.mappings, hasLength(1));
      expect(status.mappings.single.mediaType, TrackingMediaType.book.value);
    });

    test('同步结束自增 statusRevision 供 UI 刷新', () async {
      final int before = service.statusRevision.value;

      await service.syncNow(force: true);

      expect(service.statusRevision.value, greaterThan(before));
    });

    test('自动匹配重试绕过十分钟 miss 退避并立即重新关联', () async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'retry-book',
          title: 'Retry Book',
          epubPath: '/tmp/retry.epub',
          extractDir: '/tmp/retry',
          chapterCount: 4,
          chaptersJson: '[]',
          importedAt: 1,
        ),
      );
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookKey: 'retry-book',
          sectionIndex: 2,
          normCharOffset: 0,
          updatedAt: 2,
        ),
      );

      await service.recordBookProgress(
        bookKey: 'retry-book',
        completedChapterCount: 2,
        completed: false,
      );
      expect(api.searches, hasLength(1));
      expect((await service.loadStatus()).automaticMappingMissCount, 1);

      // 普通事件仍被十分钟退避挡住；显式重试必须绕过它。
      await service.recordBookProgress(
        bookKey: 'retry-book',
        completedChapterCount: 2,
        completed: false,
      );
      expect(api.searches, hasLength(1));

      api.searchResults = const <BangumiSubject>[
        BangumiSubject(
          id: 99,
          type: 1,
          name: 'Retry Book',
          nameCn: '',
          platform: '小说',
          episodeCount: 4,
          volumeCount: 1,
        ),
      ];
      final MediaTrackingMappingRetryResult result =
          await service.retryAutomaticMappings();

      expect(result.attempted, 1);
      expect(result.matched, 1);
      expect(api.searches, hasLength(2), reason: '重试必须真的再次请求匹配');
      expect((await service.loadStatus()).automaticMappingMissCount, 0);
      expect(
        await repository.findMapping(
          mediaType: TrackingMediaType.book,
          mediaKey: 'retry-book',
        ),
        isNotNull,
      );
      expect(api.creates, <Map<String, dynamic>>[
        <String, dynamic>{'ep_status': 2, 'type': 3},
      ]);
    });

    test('手动关联后当前权威进度补发一次且后续同步幂等', () async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'manual-book',
          title: 'Manual Book',
          epubPath: '/tmp/manual.epub',
          extractDir: '/tmp/manual',
          chapterCount: 4,
          chaptersJson: '[]',
          importedAt: 1,
        ),
      );
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookKey: 'manual-book',
          sectionIndex: 2,
          normCharOffset: 0,
          updatedAt: 2,
        ),
      );

      final MediaTrackingSyncResult result =
          await service.saveManualMappingAndSync(
        mediaType: TrackingMediaType.book,
        mediaKey: 'manual-book',
        mediaTitle: 'Manual Book',
        kind: TrackingKind.novel,
        subjectId: 77,
        subjectName: 'Remote manual book',
        progressMode: TrackingProgressMode.chapter,
        progressOffset: 0,
      );

      expect(result.succeeded, 1);
      expect(api.creates, <Map<String, dynamic>>[
        <String, dynamic>{'ep_status': 2, 'type': 3},
      ]);
      expect(await repository.pendingCount(), 0);

      await service.syncNow(force: true);
      expect(api.creates, hasLength(1),
          reason: '同一 mapping 水位后的重复同步不得再次补发当前进度');
    });

    test('自动匹配网络失败保留可诊断 miss 状态', () async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'offline-book',
          title: 'Offline Book',
          epubPath: '/tmp/offline.epub',
          extractDir: '/tmp/offline',
          chapterCount: 2,
          chaptersJson: '[]',
          importedAt: 1,
        ),
      );
      api.error = const BangumiApiException(
        statusCode: 503,
        message: 'offline',
      );

      await service.recordBookProgress(
        bookKey: 'offline-book',
        completedChapterCount: 1,
        completed: false,
      );

      final MediaTrackingStatus status = await service.loadStatus();
      expect(status.automaticMappingMissCount, 1);
      expect(status.automaticMappingErrors, hasLength(1));
      expect(status.automaticMappingErrors.single, contains('503'));
      expect(status.hasProblem, isTrue);
    });
  });
}
