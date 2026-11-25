import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in anime + manga site that links media server items by its own
/// id and records lookups and sends.
final class _Site implements TrackingProvider, TrackingAnimeLinker {
  final List<String> lookups = <String>[];
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  String get id => RemoteAnimeIdType.anilist;

  @override
  String get displayName => 'Site';

  @override
  String get siteHost => '';

  @override
  TrackingProviderCapabilities get capabilities =>
      const TrackingProviderCapabilities(
        kinds: <TrackingKind>{TrackingKind.anime, TrackingKind.manga},
        progressModes: <TrackingProgressMode>{
          TrackingProgressMode.episode,
          TrackingProgressMode.volume,
        },
      );

  @override
  bool get isConfigured => true;

  @override
  Future<TrackingProviderSession> openSession() async => _Session();

  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) async => pushed.add(update);

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;

  @override
  Future<TrackingLinkedSubject?> animeById(int subjectId) async {
    lookups.add('id:$subjectId');
    return TrackingLinkedSubject(
      subjectId: subjectId,
      name: 'Show $subjectId',
      episodeCount: 1,
    );
  }

  @override
  Future<TrackingLinkedSubject?> animeForMalId(int malAnimeId) async {
    lookups.add('mal:$malAnimeId');
    return null;
  }
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late MediaTrackingRepository repository;
  late _Site site;
  late MediaTrackingService service;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    repository = MediaTrackingRepository(db);
    site = _Site();
    service = MediaTrackingService(
      repository: repository,
      preferences: prefs,
      userAgent: 'test',
      extraProviders: <TrackingProvider>[site],
    );
  });

  tearDown(() async {
    service.dispose();
    prefs.dispose();
    await db.close();
  });

  Future<void> seedVideo(String uid, String title, {bool watched = true}) =>
      db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: title,
          videoPath: '/anime/$uid.mkv',
          completedAt: Value<DateTime?>(
            watched ? DateTime.fromMillisecondsSinceEpoch(2000) : null,
          ),
        ),
      );

  Future<void> linkVideo(String uid, {int offset = 1}) =>
      repository.saveMapping(
        mediaType: TrackingMediaType.video,
        mediaKey: uid,
        mediaTitle: uid,
        kind: TrackingKind.anime,
        subjectId: 7,
        subjectName: 'Remote',
        progressMode: TrackingProgressMode.episode,
        progressOffset: offset,
        provider: site.id,
      );

  Future<void> linkBook(String key) => repository.saveMapping(
    mediaType: TrackingMediaType.book,
    mediaKey: key,
    mediaTitle: key,
    kind: TrackingKind.manga,
    subjectId: 9,
    subjectName: 'Remote book',
    progressMode: TrackingProgressMode.volume,
    progressOffset: 1,
    provider: site.id,
  );

  Future<bool> unlisted(String type, String key) async =>
      !(await repository.listUnlinkedHistory()).any(
        (MediaTrackingUnlinkedItem item) =>
            item.mediaType.value == type && item.mediaKey == key,
      );

  test('an ignored video is not queued or sent; its link stays', () async {
    await seedVideo('v1', 'Frieren 01');
    await linkVideo('v1');
    await service.ignoreItem(
      mediaType: TrackingMediaType.video,
      mediaKey: 'v1',
      mediaTitle: 'Frieren 01',
      kind: TrackingKind.anime,
    );

    await service.recordVideoCompleted(bookUid: 'v1', episodeIndex: 0);
    expect(
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.video,
        mediaKey: 'v1',
        localProgress: 0,
        completed: false,
        provider: site.id,
      ),
      isFalse,
      reason: 'the queue refuses an ignored item',
    );
    await service.syncNow(force: true);

    expect(site.pushed, isEmpty);
    expect(await repository.pendingCount(), 0);
    expect(
      await repository.findMapping(
        mediaType: TrackingMediaType.video,
        mediaKey: 'v1',
        provider: site.id,
      ),
      isNotNull,
    );
  });

  test('a row queued before ignoring waits (paused) and is sent after '
      '"Track again"', () async {
    await seedVideo('v1', 'Frieren 01');
    await seedVideo('v2', 'Dungeon Meshi 01');
    await linkVideo('v1');
    await linkVideo('v2');
    for (final String uid in <String>['v1', 'v2']) {
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.video,
        mediaKey: uid,
        localProgress: 0,
        completed: false,
        provider: site.id,
      );
    }
    await service.ignoreItem(
      mediaType: TrackingMediaType.video,
      mediaKey: 'v1',
      mediaTitle: 'Frieren 01',
    );

    await service.syncNow(force: true);
    expect(
      site.pushed.map((PendingTrackingUpdate u) => u.mapping.mediaKey),
      <String>['v2'],
    );
    expect(await repository.pendingCount(), 1, reason: 'v1 still waits');

    await service.trackAgain(
      mediaType: TrackingMediaType.video.value,
      mediaKey: 'v1',
    );
    await service.syncNow(force: true);
    expect(
      site.pushed.map((PendingTrackingUpdate u) => u.mapping.mediaKey),
      <String>['v2', 'v1'],
    );
    expect(await repository.pendingCount(), 0);
  });

  test('progress made while ignored is sent by the catch-up after '
      '"Track again"', () async {
    await seedVideo('v1', 'Frieren 03', watched: false);
    await linkVideo('v1', offset: 3);
    await service.ignoreItem(
      mediaType: TrackingMediaType.video,
      mediaKey: 'v1',
      mediaTitle: 'Frieren 03',
    );
    // Watched to the end while ignored: nothing goes out, the watermark
    // passes it.
    await seedVideo('v1', 'Frieren 03');
    await service.recordVideoCompleted(bookUid: 'v1', episodeIndex: 0);
    await service.syncNow(force: true);
    expect(site.pushed, isEmpty);

    await service.trackAgain(
      mediaType: TrackingMediaType.video.value,
      mediaKey: 'v1',
    );
    await service.syncNow(force: true);
    expect(site.pushed, hasLength(1));
    expect(site.pushed.single.outbox.progress, 3);
  });

  test('an ignored item never needs a link (list, Home snapshot)', () async {
    await seedVideo('v1', 'Frieren 01');
    expect(await unlisted('video', 'v1'), isFalse);
    expect((await service.loadHomeSnapshot()).unlinked, hasLength(1));

    await service.ignoreItem(
      mediaType: TrackingMediaType.video,
      mediaKey: 'v1',
      mediaTitle: 'Frieren 01',
    );
    expect(await unlisted('video', 'v1'), isTrue);
    expect((await service.loadHomeSnapshot()).unlinked, isEmpty);
    expect((await service.listIgnored()).single.mediaTitle, 'Frieren 01');

    await service.trackAgain(
      mediaType: TrackingMediaType.video.value,
      mediaKey: 'v1',
    );
    expect(await unlisted('video', 'v1'), isFalse);
    expect(await service.listIgnored(), isEmpty);
  });

  test('an ignored media server item is never linked automatically', () async {
    const RemoteAnimeEpisode movie = RemoteAnimeEpisode(
      mediaKey: 'jellyfin|srv|u|movie1',
      title: 'Some movie',
      episodeNumber: 1,
      isMovie: true,
      seriesIds: <String, String>{'anilist': '11'},
    );
    await service.ignoreItem(
      mediaType: TrackingMediaType.remoteVideo,
      mediaKey: movie.mediaKey,
      mediaTitle: movie.title,
      kind: TrackingKind.anime,
    );
    await service.recordRemoteVideoCompleted(movie);
    await service.syncNow(force: true);
    expect(site.lookups, isEmpty);
    expect(site.pushed, isEmpty);
    expect(
      await repository.findMapping(
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: movie.mediaKey,
        provider: site.id,
      ),
      isNull,
    );

    await service.trackAgain(
      mediaType: TrackingMediaType.remoteVideo.value,
      mediaKey: movie.mediaKey,
    );
    await service.recordRemoteVideoCompleted(movie);
    await service.syncNow();
    expect(site.lookups, <String>['id:11'], reason: 'links once tracked');
  });

  test('a video collection on the list covers a member added later', () async {
    final int collection = await db.createMediaCollection(
      'Frieren',
      collectionType: 'playlist',
    );
    await seedVideo('v1', 'Frieren 01');
    await db.addToCollection(collection, MediaKind.video, 'v1');
    await service.ignoreItem(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '$collection',
      mediaTitle: 'Frieren',
    );
    expect(await unlisted('video_collection', '$collection'), isTrue);
    expect(await unlisted('video', 'v1'), isTrue);

    // A new episode joins the ignored collection.
    await seedVideo('v2', 'Frieren 02');
    await db.addToCollection(collection, MediaKind.video, 'v2');
    await linkVideo('v2');
    expect(await unlisted('video', 'v2'), isTrue);
    await service.recordVideoCompleted(
      bookUid: 'v2',
      collectionId: collection,
      episodeIndex: 1,
    );
    await service.syncNow(force: true);
    expect(site.pushed, isEmpty);
    expect(await repository.pendingCount(), 0);
  });

  test('a book series on the list covers a volume imported later', () async {
    final int series = await db.createMediaCollection('Ajin');
    await db.addToCollection(series, MediaKind.epub, 'Ajin 01');
    await service.ignoreItem(
      mediaType: TrackingMediaType.bookCollection,
      mediaKey: '$series',
      mediaTitle: 'Ajin',
      kind: TrackingKind.manga,
    );

    // Volume 2 is imported and grouped into the series afterwards.
    await db.addToCollection(series, MediaKind.epub, 'Ajin 02');
    await linkBook('Ajin 02');
    final TrackingIgnoreIndex index = await repository.loadIgnoreIndex();
    expect(index.covers(TrackingMediaType.book.value, 'Ajin 02'), isTrue);
    expect(
      index.covers(TrackingMediaType.bookChapter.value, 'Ajin 02'),
      isTrue,
      reason: 'the chapter companion follows its book',
    );
    expect(index.covers(TrackingMediaType.book.value, 'Other'), isFalse);
    expect(
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.book,
        mediaKey: 'Ajin 02',
        localProgress: 0,
        completed: true,
        provider: site.id,
      ),
      isFalse,
    );
    expect(
      (await repository.bookSeriesCollections('Ajin 02')).single.name,
      'Ajin',
    );
  });
}
