import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in anime site that knows no media server ids.
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
    return null;
  }

  @override
  Future<TrackingLinkedSubject?> animeForMalId(int malAnimeId) async {
    lookups.add('mal:$malAnimeId');
    return null;
  }
}

RemoteAnimeEpisode _episode(
  int number, {
  String series = 's1',
  String seriesTitle = 'Frieren',
  int season = 1,
}) => RemoteAnimeEpisode(
  mediaKey: 'jellyfin|srv|u|$series-e$number',
  title: '$seriesTitle S${season}E$number',
  episodeNumber: number,
  seasonNumber: season,
  seriesId: series,
  seriesTitle: seriesTitle,
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

  Future<List<MediaTrackingUnlinkedItem>> remoteUnlinked() async =>
      <MediaTrackingUnlinkedItem>[
        for (final MediaTrackingUnlinkedItem item
            in (await service.loadHomeSnapshot()).unlinked)
          if (item.mediaType == TrackingMediaType.remoteSeries ||
              item.mediaType == TrackingMediaType.remoteVideo)
            item,
      ];

  test('group key: season of the series on this login; a movie alone', () {
    expect(
      remoteAnimeGroupKey(_episode(3)),
      'jellyfin|srv|u|series:s1|season:1',
    );
    expect(
      remoteAnimeGroupKey(
        const RemoteAnimeEpisode(
          mediaKey: 'plex|m|a|9',
          title: 'Show S2E1',
          episodeNumber: 1,
          seasonNumber: 2,
          seriesTitle: 'Show',
        ),
      ),
      'plex|m|a|title:show|season:2',
    );
    expect(
      remoteAnimeGroupKey(
        const RemoteAnimeEpisode(
          mediaKey: 'plex|m|a|10',
          title: 'Movie',
          episodeNumber: 1,
          isMovie: true,
        ),
      ),
      'plex|m|a|10',
    );
  });

  test('the Jellyfin client fills series id, title and server name', () {
    final RemoteAnimeEpisode? episode = JellyfinVideoClient.trackingEpisodeOf(
      const JellyfinItem(
        id: 'e3',
        name: 'Ep 3',
        type: 'Episode',
        seriesName: 'Frieren',
        seasonNumber: 1,
        episodeNumber: 3,
        seriesId: 'series9',
      ),
      mediaKey: 'jellyfin|srv|u|e3',
      serverName: 'Home server',
    );
    expect(episode!.seriesId, 'series9');
    expect(episode.seriesTitle, 'Frieren');
    expect(episode.serverName, 'Home server');
  });

  test('an unlinkable episode is remembered and listed once per season; a '
      'hand link sends the newest episode and later ones', () async {
    await service.recordRemoteVideoCompleted(_episode(3));
    await service.recordRemoteVideoCompleted(_episode(5));
    await service.recordRemoteVideoCompleted(_episode(5));

    final MediaTrackingUnlinkedItem item = (await remoteUnlinked()).single;
    expect(item.mediaType, TrackingMediaType.remoteSeries);
    expect(item.mediaKey, 'jellyfin|srv|u|series:s1|season:1');
    expect(item.mediaTitle, 'Frieren S1');
    expect(item.itemCount, 2);
    expect(item.source, 'Home server');
    expect(item.kind, TrackingKind.anime);
    expect(site.pushed, isEmpty);

    await service.linkItemToSubject(
      mediaType: item.mediaType,
      mediaKey: item.mediaKey,
      mediaTitle: item.mediaTitle,
      kind: TrackingKind.anime,
      providerId: site.id,
      hit: const TrackingSearchHit(
        subjectId: 101,
        name: 'Sousou no Frieren',
        kind: TrackingKind.anime,
      ),
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
    );
    expect(site.pushed.single.outbox.progress, 5);
    expect(site.pushed.single.mapping.subjectId, 101);
    expect(await remoteUnlinked(), isEmpty);
    expect(
      (await repository.listRemoteEpisodes()).length,
      2,
      reason: 'kept: the season link counts them',
    );

    // The next episode of that season goes through the season link.
    await service.recordRemoteVideoCompleted(_episode(6));
    await service.syncNow();
    expect(
      site.pushed.map((PendingTrackingUpdate u) => u.outbox.progress),
      <int>[5, 6],
    );
    expect(await remoteUnlinked(), isEmpty);
  });

  test(
    'a server address is neither stored nor shown as where it was played',
    () async {
      await service.recordRemoteVideoCompleted(
        RemoteAnimeEpisode(
          mediaKey: 'jellyfin|srv|u|m1',
          title: 'A Film',
          episodeNumber: 1,
          isMovie: true,
          seriesTitle: 'A Film',
          serverName: '192.0.2.10',
        ),
      );
      expect((await repository.listRemoteEpisodes()).single.serverName, '');
      expect((await remoteUnlinked()).single.source, '');

      // A row stored before with the host as its server name.
      await db
          .into(db.mediaTrackingRemoteEpisodes)
          .insert(
            MediaTrackingRemoteEpisodesCompanion.insert(
              mediaKey: 'jellyfin|srv|u|m2',
              groupKey: 'jellyfin|srv|u|m2',
              title: 'Another Film',
              episodeNumber: 1,
              isMovie: const Value<bool>(true),
              serverName: const Value<String>('media.example:8096'),
              watchedAt: 1,
            ),
          );
      expect(
        <String?>[
          for (final MediaTrackingUnlinkedItem item in await remoteUnlinked())
            item.source,
        ],
        <String>['', ''],
      );
    },
  );

  test('ignoring a season hides its episodes and covers later ones; "Track '
      'again" brings them back', () async {
    await service.recordRemoteVideoCompleted(_episode(1, series: 's2'));
    final MediaTrackingUnlinkedItem item = (await remoteUnlinked()).single;
    await service.ignoreItem(
      mediaType: item.mediaType,
      mediaKey: item.mediaKey,
      mediaTitle: item.mediaTitle,
      kind: item.kind,
    );
    expect(await repository.listRemoteEpisodes(), hasLength(1));
    expect(await remoteUnlinked(), isEmpty);

    site.lookups.clear();
    await service.recordRemoteVideoCompleted(_episode(2, series: 's2'));
    expect(await remoteUnlinked(), isEmpty);
    expect(site.lookups, isEmpty, reason: 'not even an id lookup');

    await service.trackAgain(
      mediaType: item.mediaType.value,
      mediaKey: item.mediaKey,
    );
    final MediaTrackingUnlinkedItem back = (await remoteUnlinked()).single;
    expect(back.mediaKey, item.mediaKey);
    expect(back.itemCount, 2, reason: 'also the one watched while ignored');
  });

  test('a movie with no ids is listed on its own', () async {
    const RemoteAnimeEpisode movie = RemoteAnimeEpisode(
      mediaKey: 'jellyfin|srv|u|m1',
      title: 'Some movie',
      episodeNumber: 1,
      isMovie: true,
      seriesTitle: 'Some movie',
      serverName: 'Home server',
    );
    await service.recordRemoteVideoCompleted(movie);
    final MediaTrackingUnlinkedItem item = (await remoteUnlinked()).single;
    expect(item.mediaType, TrackingMediaType.remoteVideo);
    expect(item.mediaKey, movie.mediaKey);
    expect(item.mediaTitle, 'Some movie');
    expect(item.episodeNumber, isNull, reason: 'a movie has no episode');
  });

  test('an episode with no series id or title is listed on its own with its '
      'episode number', () async {
    const RemoteAnimeEpisode episode = RemoteAnimeEpisode(
      mediaKey: 'jellyfin|srv|u|lone7',
      title: 'Episode 7',
      episodeNumber: 7,
      seasonNumber: 2,
      serverName: 'Home server',
    );
    await service.recordRemoteVideoCompleted(episode);
    final MediaTrackingUnlinkedItem item = (await remoteUnlinked()).single;
    expect(item.mediaType, TrackingMediaType.remoteVideo);
    expect(item.mediaKey, episode.mediaKey);
    expect(item.episodeNumber, 7);
  });
}
