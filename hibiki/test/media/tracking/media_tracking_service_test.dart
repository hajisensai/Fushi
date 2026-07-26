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
  }) async =>
      const <BangumiSubject>[];

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
}
