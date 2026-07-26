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
    return searchResults;
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

  test('manga volume suffix maps the volume and queues only on completion',
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
    expect(await repository.pendingCount(), 0,
        reason: '漫画页码不能误写成 Bangumi 章节进度');

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
}
