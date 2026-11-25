import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';

/// T2 G2 (a hand link sends nothing during its Undo window), G7 / G6 (a
/// link removed by hand stays removed and says so) and G13 (the same link
/// again sends nothing new), at the service layer with a fake site.

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// Anime site that links media server episodes by its own id.
final class _Site implements TrackingProvider, TrackingAnimeLinker {
  final Map<int, TrackingLinkedSubject> byId = <int, TrackingLinkedSubject>{};
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
  Future<TrackingLinkedSubject?> animeById(int subjectId) async {
    lookups.add('id:$subjectId');
    return byId[subjectId];
  }

  @override
  Future<TrackingLinkedSubject?> animeForMalId(int malAnimeId) async => null;
}

RemoteAnimeEpisode _episode(int number, {int? site}) => RemoteAnimeEpisode(
  mediaKey: 'jellyfin|srv|u|item$number',
  title: 'Show S1E$number',
  episodeNumber: number,
  seasonNumber: 1,
  isMovie: false,
  seasonIds: site == null
      ? const <String, String>{}
      : <String, String>{'anilist': '$site'},
  seriesIds: const <String, String>{},
  seasonEpisodeCount: 12,
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

  /// Episode [number] watched with no id the site knows (remembered,
  /// unlinked), then linked by hand to entry 50 the way the dialog does.
  Future<TrackingLinkUndo> handLink(int number) async {
    await service.recordRemoteVideoCompleted(_episode(number));
    final RemoteAnimeEpisode episode = _episode(number);
    return (await service.linkItemToSubjectUndoable(
      mediaType: TrackingMediaType.remoteVideo,
      mediaKey: episode.mediaKey,
      mediaTitle: episode.title,
      kind: TrackingKind.anime,
      providerId: site.id,
      hit: const TrackingSearchHit(
        subjectId: 50,
        name: 'Entry 50',
        kind: TrackingKind.anime,
      ),
      progressMode: TrackingProgressMode.episode,
      progressOffset: number,
    )).undo;
  }

  group('G2: a hand link waits for its Undo window', () {
    test('nothing is sent, not even by "Sync now"; Undo leaves no trace and '
        'says nothing was sent', () async {
      final TrackingLinkUndo undo = await handLink(3);
      await service.syncNow(force: true);
      expect(site.pushed, isEmpty);
      expect(await repository.pendingCount(provider: site.id), 1);

      expect(await service.undoLink(undo), isFalse);
      expect(await repository.listMappings(provider: site.id), isEmpty);
      expect(await repository.allPending(provider: site.id), isEmpty);
      await service.syncNow(force: true);
      expect(site.pushed, isEmpty);
    });

    test('a new event for the link keeps it waiting', () async {
      await handLink(3);
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: _episode(3).mediaKey,
        localProgress: 1,
        completed: false,
        provider: site.id,
      );
      expect(await repository.dueUpdates(provider: site.id), isEmpty);
    });

    test('the Undo bar closing sends it; an Undo after that says it was '
        'already sent', () async {
      final TrackingLinkUndo undo = await handLink(3);
      await service.releaseLinkHold(undo);
      expect(site.pushed.single.outbox.progress, 3);
      expect(await service.undoLink(undo), isTrue);
    });

    test('leaving the page sends every waiting hand link', () async {
      await handLink(3);
      await handLink(4);
      await service.releaseAllLinkHolds();
      expect(site.pushed, hasLength(2));
    });

    test('the wait is stored with the update: it ends by itself (after a '
        'restart too), nothing is lost', () async {
      await handLink(3);
      final int later = DateTime.now()
          .add(kTrackingLinkUndoHold)
          .add(const Duration(seconds: 1))
          .millisecondsSinceEpoch;
      expect(await repository.dueUpdates(provider: site.id), isEmpty);
      expect(
        await repository.dueUpdates(provider: site.id, nowMs: later),
        hasLength(1),
      );
      expect(kTrackingLinkUndoHold, greaterThan(kTrackingLinkUndoVisible));
    });
  });

  group('G7 / G6: a link removed by hand stays removed', () {
    test('the next watch does not link it again from the server ids; it is '
        'listed as removed by the user', () async {
      site.byId[11] = TrackingLinkedSubject(
        subjectId: 11,
        name: 'Show 11',
        episodeCount: 12,
      );
      final RemoteAnimeEpisode episode = _episode(3, site: 11);
      await service.recordRemoteVideoCompleted(episode);
      await service.syncNow();
      final MediaTrackingMappingRow linked = (await repository.findMapping(
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: episode.mediaKey,
        provider: site.id,
      ))!;
      expect(site.lookups, <String>['id:11']);

      await service.removeLink(linked);
      await service.recordRemoteVideoCompleted(episode);
      expect(
        await repository.findMapping(
          mediaType: TrackingMediaType.remoteVideo,
          mediaKey: episode.mediaKey,
          provider: site.id,
        ),
        isNull,
      );
      expect(site.lookups, <String>['id:11'], reason: 'not looked up again');

      final MediaTrackingUnlinkedItem item =
          (await repository.listUnlinkedHistory()).single;
      expect(item.removedByUser, isTrue);
    });

    test('a hand link still works after a removal', () async {
      site.byId[11] = TrackingLinkedSubject(
        subjectId: 11,
        name: 'Show 11',
        episodeCount: 12,
      );
      final RemoteAnimeEpisode episode = _episode(3, site: 11);
      await service.recordRemoteVideoCompleted(episode);
      await service.removeLink(
        (await repository.listMappings(provider: site.id)).single,
      );
      await service.saveManualMappingAndSync(
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: episode.mediaKey,
        mediaTitle: episode.title,
        kind: TrackingKind.anime,
        subjectId: 11,
        subjectName: 'Show 11',
        progressMode: TrackingProgressMode.episode,
        progressOffset: 3,
        provider: site.id,
      );
      expect(await repository.listMappings(provider: site.id), hasLength(1));
    });

    test('a new hand link clears "removed by you"; removing again writes '
        'it back and automatic linking stays blocked (T3 H2)', () async {
      site.byId[11] = TrackingLinkedSubject(
        subjectId: 11,
        name: 'Show 11',
        episodeCount: 12,
      );
      final RemoteAnimeEpisode episode = _episode(3, site: 11);
      Future<bool> removed() => repository.isLinkRemovedByUser(
        provider: site.id,
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: episode.mediaKey,
      );
      Future<void> handLink11() => service.saveManualMappingAndSync(
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: episode.mediaKey,
        mediaTitle: episode.title,
        kind: TrackingKind.anime,
        subjectId: 11,
        subjectName: 'Show 11',
        progressMode: TrackingProgressMode.episode,
        progressOffset: 3,
        provider: site.id,
      );
      await service.recordRemoteVideoCompleted(episode);
      await service.removeLink(
        (await repository.listMappings(provider: site.id)).single,
      );
      expect(await removed(), isTrue);

      await handLink11();
      expect(await removed(), isFalse);

      await service.removeLink(
        (await repository.listMappings(provider: site.id)).single,
      );
      expect(await removed(), isTrue);
      await service.recordRemoteVideoCompleted(episode);
      expect(await repository.listMappings(provider: site.id), isEmpty);
    });

    test('linkItemToSubjectUndoable reports held only when it queued an '
        'update (T3 H1)', () async {
      await service.recordRemoteVideoCompleted(_episode(3));
      final RemoteAnimeEpisode episode = _episode(3);
      Future<bool> link() async => (await service.linkItemToSubjectUndoable(
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: episode.mediaKey,
        mediaTitle: episode.title,
        kind: TrackingKind.anime,
        providerId: site.id,
        hit: const TrackingSearchHit(
          subjectId: 50,
          name: 'Entry 50',
          kind: TrackingKind.anime,
        ),
        progressMode: TrackingProgressMode.episode,
        progressOffset: 3,
      )).held;
      expect(await link(), isTrue);
      // Sent (the hold let go): the same entry and number again queues
      // nothing, so nothing waits for the message to close.
      await service.releaseAllLinkHolds();
      expect(site.pushed, isNotEmpty);
      expect(await link(), isFalse);
    });

    test('a season with a linked episode lists the unlinked one as itself, '
        'not as the season', () async {
      site.byId[11] = TrackingLinkedSubject(
        subjectId: 11,
        name: 'Show 11',
        episodeCount: 12,
      );
      await service.recordRemoteVideoCompleted(_episode(1, site: 11));
      await service.recordRemoteVideoCompleted(_episode(2, site: 11));
      await service.syncNow();
      final MediaTrackingMappingRow first = (await repository.findMapping(
        mediaType: TrackingMediaType.remoteVideo,
        mediaKey: _episode(1).mediaKey,
        provider: site.id,
      ))!;
      await service.removeLink(first);

      final MediaTrackingUnlinkedItem item =
          (await repository.listUnlinkedHistory()).single;
      expect(item.mediaType, TrackingMediaType.remoteVideo);
      expect(item.mediaKey, _episode(1).mediaKey);
      expect(item.episodeNumber, 1);
      expect(item.removedByUser, isTrue);
    });
  });

  test('G13: linking again to the same entry and number sends nothing '
      'new', () async {
    final TrackingLinkUndo undo = await handLink(3);
    await service.releaseLinkHold(undo);
    expect(site.pushed, hasLength(1));
    final List<MediaTrackingActivityRow> activity = await service
        .loadActivity();

    final TrackingLinkUndo again = await handLink(3);
    await service.releaseLinkHold(again);
    expect(site.pushed, hasLength(1));
    expect(await service.loadActivity(), hasLength(activity.length));
  });
}
