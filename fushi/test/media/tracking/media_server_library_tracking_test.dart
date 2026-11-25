import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_tracking_panel.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart'
    show FushiContinueMark;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';

/// T1 F3: a library row added from a media server (`media-server://`) has
/// one tracking identity, its server's (episode / season), whatever the
/// order of playing, adding to the library and marking watched.
final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in anime site that knows AniList id 186497 (12 episodes).
final class _Site implements TrackingProvider, TrackingAnimeLinker {
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  String get id => RemoteAnimeIdType.anilist;

  @override
  String get displayName => 'AniList';

  @override
  String get siteHost => '';

  @override
  TrackingProviderCapabilities get capabilities =>
      const TrackingProviderCapabilities(
        kinds: <TrackingKind>{TrackingKind.anime},
        progressModes: <TrackingProgressMode>{TrackingProgressMode.episode},
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
  Future<TrackingLinkedSubject?> animeById(int subjectId) async =>
      subjectId == 186497
      ? const TrackingLinkedSubject(
          subjectId: 186497,
          name: 'Koori no Jouheki',
          episodeCount: 12,
        )
      : null;

  @override
  Future<TrackingLinkedSubject?> animeForMalId(int malAnimeId) async => null;
}

RemoteAnimeEpisode _episode(int number, {bool withIds = true}) =>
    RemoteAnimeEpisode(
      mediaKey: 'jellyfin|srv|u|item$number',
      title: 'The Ramparts of Ice S1E$number',
      episodeNumber: number,
      seasonNumber: 1,
      seasonIds: withIds
          ? const <String, String>{'anilist': '186497'}
          : const <String, String>{},
      seasonEpisodeCount: 12,
      seriesId: 'show1',
      seriesTitle: 'The Ramparts of Ice',
      serverName: 'Home server',
    );

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

  /// Episodes 1 and 2 added to the library from the server, in their show's
  /// playlist; episode 1 marked watched.
  Future<int> addToLibrary() async {
    for (final int number in <int>[1, 2]) {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'item$number',
          title: 'The Ramparts of Ice - S01E0$number',
          videoPath:
              'media-server://item$number/The Ramparts of Ice - S01E0'
              '$number',
          completedAt: Value<DateTime?>(
            number == 1 ? DateTime(2026, 11, 11) : null,
          ),
        ),
      );
    }
    final int id = await db.createMediaCollection(
      'The Ramparts of Ice',
      collectionType: 'playlist',
    );
    await db.addToCollection(id, MediaKind.video, 'item1');
    await db.addToCollection(id, MediaKind.video, 'item2');
    return id;
  }

  Future<List<MediaTrackingUnlinkedItem>> unlinked() async =>
      (await service.loadHomeSnapshot()).unlinked;

  Future<FushiContinueMark?> markOf(String uid, int collectionId) async =>
      homeTrackingMark(
        snapshot: await service.loadHomeSnapshot(),
        keys: <HomeTrackingKey>[
          (type: TrackingMediaType.video, key: uid),
          (type: TrackingMediaType.videoCollection, key: '$collectionId'),
        ],
      );

  test(
    'played first, then added: the library rows are covered by the '
    'server link, not listed, and the catch-up sends nothing again',
    () async {
      await service.recordRemoteVideoCompleted(_episode(1));
      await service.syncNow();
      expect(site.pushed.single.outbox.progress, 1);

      final int collection = await addToLibrary();
      expect(await unlinked(), isEmpty);
      expect((await markOf('item1', collection))?.problem, isFalse);
      expect(
        (await markOf('item2', collection))?.problem,
        isFalse,
        reason: 'an unwatched episode of the linked season',
      );

      await service.syncNow(force: true);
      expect(site.pushed, hasLength(1));

      // Playing episode 2 from the library reports the server identity once.
      await service.recordRemoteVideoCompleted(
        _episode(2),
        libraryBookUid: 'item2',
      );
      await service.syncNow(force: true);
      expect(
        site.pushed.map((PendingTrackingUpdate u) => u.outbox.progress),
        <int>[1, 2],
      );
    },
  );

  test('added first and marked by hand: nothing is listed for the library '
      'row; the server identity is, and a hand link made on the library '
      'collection links the season and sends once', () async {
    final int collection = await addToLibrary();
    expect(await unlinked(), isEmpty, reason: 'not a library video of its own');
    // The library path never sends for it either.
    await service.recordVideoCompleted(
      bookUid: 'item1',
      collectionId: collection,
      episodeIndex: 0,
    );
    expect(site.pushed, isEmpty);
    await expectLater(
      service.saveManualMappingAndSync(
        mediaType: TrackingMediaType.videoCollection,
        mediaKey: '$collection',
        mediaTitle: 'The Ramparts of Ice',
        kind: TrackingKind.anime,
        subjectId: 186497,
        subjectName: 'Koori no Jouheki',
        progressMode: TrackingProgressMode.episode,
        progressOffset: 1,
        provider: site.id,
      ),
      throwsA(isA<MediaServerLibraryLinkError>()),
      reason: 'its season is not known before an episode was reported',
    );

    // The hand mark reports the server identity (no ids on this server).
    await service.recordRemoteVideoCompleted(
      _episode(1, withIds: false),
      libraryBookUid: 'item1',
    );
    final MediaTrackingUnlinkedItem item = (await unlinked()).single;
    expect(item.mediaType, TrackingMediaType.remoteSeries);
    expect(
      (await markOf('item1', collection))?.problem,
      isTrue,
      reason: 'the Continue card says it needs a link',
    );

    await service.linkItemToSubject(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '$collection',
      mediaTitle: 'The Ramparts of Ice',
      kind: TrackingKind.anime,
      providerId: site.id,
      hit: const TrackingSearchHit(
        subjectId: 186497,
        name: 'Koori no Jouheki',
        kind: TrackingKind.anime,
      ),
      progressMode: TrackingProgressMode.episode,
      progressOffset: 7,
    );
    final MediaTrackingMappingRow link =
        (await repository.listMappings()).single;
    expect(link.mediaType, TrackingMediaType.remoteSeries.value);
    expect(link.mediaKey, item.mediaKey);
    expect(link.progressOffset, 1, reason: 'episodes count as themselves');
    expect(site.pushed.single.outbox.progress, 1);
    expect(await unlinked(), isEmpty);
    expect((await markOf('item2', collection))?.problem, isFalse);

    await service.syncNow(force: true);
    expect(site.pushed, hasLength(1), reason: 'no second send');

    await service.recordRemoteVideoCompleted(
      _episode(2, withIds: false),
      libraryBookUid: 'item2',
    );
    await service.syncNow(force: true);
    expect(
      site.pushed.map((PendingTrackingUpdate u) => u.outbox.progress),
      <int>[1, 2],
    );
  });

  test('a library link made before the rule is inert: shown for removal, '
      'never sent', () async {
    final int collection = await addToLibrary();
    await repository.saveMapping(
      mediaType: TrackingMediaType.videoCollection,
      mediaKey: '$collection',
      mediaTitle: 'The Ramparts of Ice',
      kind: TrackingKind.anime,
      subjectId: 186497,
      subjectName: 'Koori no Jouheki',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
      provider: site.id,
    );
    final int id = (await repository.listMappings()).single.id;
    final MediaTrackingHomeSnapshot snapshot = await service.loadHomeSnapshot();
    expect(snapshot.inertMappingIds, contains(id));
    expect(snapshot.mediaServerInertMappingIds, <int>{id});
    await service.syncNow(force: true);
    expect(site.pushed, isEmpty);
  });
}
