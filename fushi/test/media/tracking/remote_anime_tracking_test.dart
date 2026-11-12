import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';

final class _FakeSession implements TrackingProviderSession {
  @override
  void close() {}
}

/// In-memory anime site: subjects by its own id and by MAL id.
final class _FakeAnimeSite implements TrackingProvider, TrackingAnimeLinker {
  final Map<int, TrackingLinkedSubject> byId = <int, TrackingLinkedSubject>{};
  final Map<int, TrackingLinkedSubject> byMal = <int, TrackingLinkedSubject>{};
  final List<String> lookups = <String>[];
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];
  Exception? lookupError;

  // Must equal the id type the candidates carry, so `animeById` is used.
  @override
  String get id => RemoteAnimeIdType.anilist;

  @override
  String get displayName => 'Fake site';

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
  Future<TrackingProviderSession> openSession() async => _FakeSession();

  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) async {
    pushed.add(update);
  }

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;

  @override
  Future<TrackingLinkedSubject?> animeById(int subjectId) async {
    lookups.add('id:$subjectId');
    final Exception? error = lookupError;
    if (error != null) throw error;
    return byId[subjectId];
  }

  @override
  Future<TrackingLinkedSubject?> animeForMalId(int malAnimeId) async {
    lookups.add('mal:$malAnimeId');
    final Exception? error = lookupError;
    if (error != null) throw error;
    return byMal[malAnimeId];
  }
}

TrackingLinkedSubject _subject(int id, {int? episodes = 12}) =>
    TrackingLinkedSubject(
      subjectId: id,
      name: 'Show $id',
      episodeCount: episodes,
    );

AnimeIdentityEntry _entry({
  required int anidb,
  int? anilist,
  Set<int> mal = const <int>{},
  int? tmdb,
  int? tmdbSeason,
  int? tmdbOffset,
  int? tvdb,
  int? tvdbSeason,
  int? tvdbOffset,
  bool tmdbMovie = false,
}) => AnimeIdentityEntry(
  anidbId: anidb,
  malIds: mal,
  anilistId: anilist,
  tmdbId: tmdb,
  tmdbSeason: tmdbSeason,
  tmdbEpisodeOffset: tmdbOffset,
  tvdbId: tvdb,
  tvdbSeason: tvdbSeason,
  tvdbEpisodeOffset: tvdbOffset,
  tmdbIsMovieNamespace: tmdbMovie,
);

AnimeCrossIds _crossIds({
  Map<int, AnimeIdentityEntry> anidb = const <int, AnimeIdentityEntry>{},
  Map<int, List<AnimeIdentityEntry>> tmdb =
      const <int, List<AnimeIdentityEntry>>{},
  Map<int, List<AnimeIdentityEntry>> tvdb =
      const <int, List<AnimeIdentityEntry>>{},
  Map<int, List<AnimeIdentityEntry>> tmdbMovie =
      const <int, List<AnimeIdentityEntry>>{},
  bool fail = false,
}) => AnimeCrossIds(
  entryForAnidb: (int id) async {
    if (fail) throw Exception('offline');
    return anidb[id];
  },
  entriesForTmdbTv: (int id) async {
    if (fail) throw Exception('offline');
    return tmdb[id] ?? const <AnimeIdentityEntry>[];
  },
  entriesForTvdb: (int id) async {
    if (fail) throw Exception('offline');
    return tvdb[id] ?? const <AnimeIdentityEntry>[];
  },
  entriesForTmdbMovie: (int id) async {
    if (fail) throw Exception('offline');
    return tmdbMovie[id] ?? const <AnimeIdentityEntry>[];
  },
);

RemoteAnimeEpisode _episode({
  int episode = 3,
  int? season = 1,
  bool movie = false,
  Map<String, String> seasonIds = const <String, String>{},
  Map<String, String> seriesIds = const <String, String>{},
  int? seasonCount,
}) => RemoteAnimeEpisode(
  mediaKey: 'jellyfin|srv|u|item$episode',
  title: 'Show S${season}E$episode',
  episodeNumber: episode,
  seasonNumber: season,
  isMovie: movie,
  seasonIds: seasonIds,
  seriesIds: seriesIds,
  seasonEpisodeCount: seasonCount,
);

void main() {
  group('remoteAnimeCandidates', () {
    test('season ids first, then series ids for season 1', () async {
      final List<RemoteAnimeCandidate> out = await remoteAnimeCandidates(
        _episode(
          seasonIds: const <String, String>{'anilist': '11'},
          seriesIds: const <String, String>{'anilist': '22', 'mal': '33'},
        ),
      );
      expect(out, <RemoteAnimeCandidate>[
        (idType: 'anilist', id: 11, episode: 3, sameSeason: true),
        (idType: 'anilist', id: 22, episode: 3, sameSeason: true),
        (idType: 'mal', id: 33, episode: 3, sameSeason: true),
      ]);
    });

    test('a series id never names a later season', () async {
      final List<RemoteAnimeCandidate> out = await remoteAnimeCandidates(
        _episode(
          season: 2,
          seriesIds: const <String, String>{'anilist': '22', 'mal': '33'},
        ),
      );
      expect(out, isEmpty);
    });

    test('specials and unnumbered episodes give nothing', () async {
      expect(
        await remoteAnimeCandidates(
          _episode(
            season: 0,
            seasonIds: const <String, String>{'anilist': '11'},
          ),
        ),
        isEmpty,
      );
      expect(
        await remoteAnimeCandidates(
          _episode(
            episode: 0,
            seasonIds: const <String, String>{'anilist': '11'},
          ),
        ),
        isEmpty,
      );
    });

    test('AniDB goes through the offline list', () async {
      final AnimeCrossIds ids = _crossIds(
        anidb: <int, AnimeIdentityEntry>{
          5: _entry(anidb: 5, anilist: 50),
          6: _entry(anidb: 6, mal: <int>{60}),
          7: _entry(anidb: 7, mal: <int>{70, 71}),
        },
      );
      Future<List<RemoteAnimeCandidate>> forAnidb(String id) =>
          remoteAnimeCandidates(
            _episode(seasonIds: <String, String>{'anidb': id}),
            crossIds: ids,
          );
      expect(await forAnidb('5'), <RemoteAnimeCandidate>[
        (idType: 'anilist', id: 50, episode: 3, sameSeason: true),
      ]);
      expect(await forAnidb('6'), <RemoteAnimeCandidate>[
        (idType: 'mal', id: 60, episode: 3, sameSeason: true),
      ]);
      expect(await forAnidb('7'), isEmpty, reason: 'two MAL ids: no answer');
    });

    test('TMDB season + episode uses the offline season offsets', () async {
      final AnimeCrossIds ids = _crossIds(
        tmdb: <int, List<AnimeIdentityEntry>>{
          900: <AnimeIdentityEntry>[
            _entry(anidb: 1, anilist: 101, tmdbSeason: 1, tmdbOffset: 0),
            _entry(anidb: 2, anilist: 102, tmdbSeason: 1, tmdbOffset: 12),
            _entry(anidb: 3, anilist: 103, tmdbSeason: 2, tmdbOffset: 0),
          ],
        },
      );
      Future<List<RemoteAnimeCandidate>> at(int season, int episode) =>
          remoteAnimeCandidates(
            _episode(
              season: season,
              episode: episode,
              seriesIds: const <String, String>{'tmdb': '900'},
            ),
            crossIds: ids,
          );
      expect(await at(1, 5), <RemoteAnimeCandidate>[
        (idType: 'anilist', id: 101, episode: 5, sameSeason: false),
      ]);
      expect(await at(1, 15), <RemoteAnimeCandidate>[
        (idType: 'anilist', id: 102, episode: 3, sameSeason: false),
      ]);
      expect(await at(2, 4), <RemoteAnimeCandidate>[
        (idType: 'anilist', id: 103, episode: 4, sameSeason: false),
      ]);
      expect(await at(3, 1), isEmpty);
    });

    test(
      'TVDB works the same; two entries at one offset is ambiguous',
      () async {
        final AnimeCrossIds ids = _crossIds(
          tvdb: <int, List<AnimeIdentityEntry>>{
            400: <AnimeIdentityEntry>[
              _entry(anidb: 1, anilist: 201, tvdbSeason: 1, tvdbOffset: 0),
            ],
            401: <AnimeIdentityEntry>[
              _entry(anidb: 2, anilist: 202, tvdbSeason: 1, tvdbOffset: 0),
              _entry(anidb: 3, anilist: 203, tvdbSeason: 1, tvdbOffset: 0),
            ],
          },
        );
        expect(
          await remoteAnimeCandidates(
            _episode(seriesIds: const <String, String>{'tvdb': '400'}),
            crossIds: ids,
          ),
          <RemoteAnimeCandidate>[
            (idType: 'anilist', id: 201, episode: 3, sameSeason: false),
          ],
        );
        expect(
          await remoteAnimeCandidates(
            _episode(seriesIds: const <String, String>{'tvdb': '401'}),
            crossIds: ids,
          ),
          isEmpty,
        );
      },
    );

    test('an offline list failure keeps the server ids', () async {
      final List<RemoteAnimeCandidate> out = await remoteAnimeCandidates(
        _episode(
          seasonIds: const <String, String>{'anilist': '11', 'anidb': '5'},
          seriesIds: const <String, String>{'tmdb': '900'},
        ),
        crossIds: _crossIds(fail: true),
      );
      expect(out, <RemoteAnimeCandidate>[
        (idType: 'anilist', id: 11, episode: 3, sameSeason: true),
      ]);
    });

    test('a movie is episode 1 of its own ids', () async {
      final List<RemoteAnimeCandidate> out = await remoteAnimeCandidates(
        _episode(
          movie: true,
          season: null,
          episode: 0,
          seriesIds: const <String, String>{'anilist': '30'},
        ),
      );
      expect(out, <RemoteAnimeCandidate>[
        (idType: 'anilist', id: 30, episode: 1, sameSeason: true),
      ]);
    });

    test('a movie with only a TMDB id uses the offline movie entry', () async {
      final AnimeCrossIds ids = _crossIds(
        tmdbMovie: <int, List<AnimeIdentityEntry>>{
          916224: <AnimeIdentityEntry>[
            _entry(anidb: 9, anilist: 142770, tmdb: 916224, tmdbMovie: true),
          ],
          5: <AnimeIdentityEntry>[
            _entry(anidb: 10, anilist: 1, tmdb: 5, tmdbMovie: true),
            _entry(anidb: 11, anilist: 2, tmdb: 5, tmdbMovie: true),
          ],
        },
      );
      Future<List<RemoteAnimeCandidate>> forTmdb(String id) =>
          remoteAnimeCandidates(
            _episode(
              movie: true,
              season: null,
              seriesIds: <String, String>{'tmdb': id},
            ),
            crossIds: ids,
          );
      expect(await forTmdb('916224'), <RemoteAnimeCandidate>[
        (idType: 'anilist', id: 142770, episode: 1, sameSeason: true),
      ]);
      expect(await forTmdb('5'), isEmpty, reason: 'two entries: no answer');
    });
  });

  group('Plex ids', () {
    test('Guid list and legacy agent guids', () {
      expect(
        PlexApi.parseProviderIds(<String, Object?>{
          'guid': 'plex://show/5d9c08',
          'Guid': <Object?>[
            <String, Object?>{'id': 'imdb://tt123'},
            <String, Object?>{'id': 'tmdb://209867'},
            <String, Object?>{'id': 'tvdb://424536'},
          ],
        }),
        <String, String>{'imdb': 'tt123', 'tmdb': '209867', 'tvdb': '424536'},
      );
      expect(
        PlexApi.parseProviderIds(<String, Object?>{
          'guid': 'com.plexapp.agents.hama://anidb-17617/1/3?lang=en',
        }),
        <String, String>{'anidb': '17617'},
      );
      expect(
        PlexApi.parseProviderIds(<String, Object?>{
          'guid': 'com.plexapp.agents.hama://tvdb3-424536?lang=en',
        }),
        isEmpty,
        reason: 'remapped HAMA numbering is not a plain TVDB id',
      );
      expect(
        PlexApi.parseProviderIds(<String, Object?>{
          'guid': 'com.plexapp.agents.thetvdb://424536/1/3?lang=en',
        }),
        <String, String>{'tvdb': '424536'},
      );
    });

    test('episode numbering, season count and ids', () {
      final RemoteAnimeEpisode? out = PlexVideoClient.trackingEpisodeOf(
        const PlexMetadata(
          ratingKey: '3',
          type: 'episode',
          title: 'Ep',
          grandparentTitle: 'Frieren',
          parentIndex: 1,
          index: 3,
        ),
        season: const PlexMetadata(
          ratingKey: '2',
          type: 'season',
          title: 'Season 1',
          leafCount: 28,
        ),
        show: const PlexMetadata(
          ratingKey: '1',
          type: 'show',
          title: 'Frieren',
          providerIds: <String, String>{'tmdb': '209867'},
        ),
        mediaKey: 'k',
      );
      expect(out!.title, 'Frieren S1E3');
      expect(out.episodeNumber, 3);
      expect(out.seasonNumber, 1);
      expect(out.seasonEpisodeCount, 28);
      expect(out.seriesIds, <String, String>{'tmdb': '209867'});
      expect(
        PlexVideoClient.trackingEpisodeOf(
          const PlexMetadata(ratingKey: '1', type: 'show', title: 'S'),
          mediaKey: 'k',
        ),
        isNull,
      );
    });
  });

  group('JellyfinVideoClient.trackingEpisodeOf', () {
    test('episode: numbering, season and series ids, season count', () {
      final RemoteAnimeEpisode? out = JellyfinVideoClient.trackingEpisodeOf(
        const JellyfinItem(
          id: 'e1',
          name: 'Ep name',
          type: 'Episode',
          seriesName: 'Frieren',
          seasonNumber: 1,
          episodeNumber: 3,
          providerIds: <String, String>{'tvdb': '999'},
        ),
        season: const JellyfinItem(
          id: 's1',
          name: 'Season 1',
          type: 'Season',
          childCount: 28,
          providerIds: <String, String>{'anilist': '154587'},
        ),
        series: const JellyfinItem(
          id: 'x',
          name: 'Frieren',
          type: 'Series',
          providerIds: <String, String>{'tmdb': '209867'},
        ),
        mediaKey: 'k',
      );
      expect(out, isNotNull);
      expect(out!.mediaKey, 'k');
      expect(out.title, 'Frieren S1E3');
      expect(out.episodeNumber, 3);
      expect(out.seasonNumber, 1);
      expect(out.seasonIds, <String, String>{'anilist': '154587'});
      expect(out.seriesIds, <String, String>{'tmdb': '209867'});
      expect(out.seasonEpisodeCount, 28);
      expect(out.isMovie, isFalse);
    });

    test(
      'movie uses its own ids; folders and unnumbered episodes give null',
      () {
        final RemoteAnimeEpisode? movie = JellyfinVideoClient.trackingEpisodeOf(
          const JellyfinItem(
            id: 'm',
            name: 'Suzume',
            type: 'Movie',
            providerIds: <String, String>{'anilist': '142770'},
          ),
          mediaKey: 'k',
        );
        expect(movie!.isMovie, isTrue);
        expect(movie.seriesIds, <String, String>{'anilist': '142770'});
        expect(
          JellyfinVideoClient.trackingEpisodeOf(
            const JellyfinItem(id: 's', name: 'S', type: 'Series'),
            mediaKey: 'k',
          ),
          isNull,
        );
        expect(
          JellyfinVideoClient.trackingEpisodeOf(
            const JellyfinItem(id: 'e', name: 'E', type: 'Episode'),
            mediaKey: 'k',
          ),
          isNull,
        );
      },
    );
  });

  group('service: media server episodes (fake site)', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;
    late MediaTrackingRepository repository;
    late _FakeAnimeSite site;
    late MediaTrackingService service;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      repository = MediaTrackingRepository(db);
      site = _FakeAnimeSite();
      service = MediaTrackingService(
        repository: repository,
        preferences: prefs,
        userAgent: 'test',
        extraProviders: <TrackingProvider>[site],
        animeCrossIds: _crossIds(
          tmdb: <int, List<AnimeIdentityEntry>>{
            900: <AnimeIdentityEntry>[
              _entry(anidb: 1, anilist: 101, tmdbSeason: 1, tmdbOffset: 0),
              _entry(anidb: 2, anilist: 102, tmdbSeason: 1, tmdbOffset: 12),
            ],
          },
          anidb: <int, AnimeIdentityEntry>{
            6: _entry(anidb: 6, mal: <int>{60}),
          },
        ),
      );
    });

    tearDown(() async {
      service.dispose();
      prefs.dispose();
      await db.close();
    });

    Future<MediaTrackingMappingRow?> link(RemoteAnimeEpisode episode) =>
        repository.findMapping(
          mediaType: TrackingMediaType.remoteVideo,
          mediaKey: episode.mediaKey,
          provider: site.id,
        );

    Future<void> finish(RemoteAnimeEpisode episode) async {
      await service.recordRemoteVideoCompleted(episode);
      await service.syncNow();
    }

    test('links from the site id and sends the episode', () async {
      site.byId[11] = _subject(11);
      final RemoteAnimeEpisode episode = _episode(
        seasonIds: const <String, String>{'anilist': '11'},
        seasonCount: 12,
      );

      await finish(episode);

      final MediaTrackingMappingRow mapping = (await link(episode))!;
      expect(mapping.subjectId, 11);
      expect(mapping.subjectName, 'Show 11');
      expect(mapping.progressOffset, 3);
      expect(mapping.mediaTitle, 'Show S1E3');
      expect(mapping.kind, TrackingKind.anime.value);
      expect(mapping.progressMode, TrackingProgressMode.episode.value);
      expect(mapping.linkSource, TrackingLinkSource.id);
      expect(site.lookups, <String>['id:11']);
      final PendingTrackingUpdate pushed = site.pushed.single;
      expect(pushed.mapping.subjectId, 11);
      expect(pushed.outbox.progress, 3);
      expect(pushed.outbox.completed, isFalse);
      expect(
        await repository.findMapping(
          mediaType: TrackingMediaType.remoteVideo,
          mediaKey: episode.mediaKey,
        ),
        isNull,
        reason: 'Bangumi does not track media server playback',
      );
    });

    test('links from a MAL id through animeForMalId', () async {
      site.byMal[33] = _subject(77);
      final RemoteAnimeEpisode episode = _episode(
        seriesIds: const <String, String>{'mal': '33'},
      );

      await finish(episode);

      final MediaTrackingMappingRow mapping = (await link(episode))!;
      expect(mapping.subjectId, 77);
      expect(mapping.progressOffset, 3);
      expect(mapping.linkSource, TrackingLinkSource.id);
      expect(site.lookups, <String>['mal:33']);
      expect(site.pushed.single.outbox.progress, 3);
    });

    test('an AniDB id reaches the site through the offline MAL id', () async {
      site.byMal[60] = _subject(66);
      final RemoteAnimeEpisode episode = _episode(
        seasonIds: const <String, String>{'anidb': '6'},
      );

      await finish(episode);

      expect((await link(episode))!.subjectId, 66);
      expect(site.lookups, <String>['mal:60']);
      expect(site.pushed.single.outbox.progress, 3);
    });

    test(
      'an id whose episode count disagrees is skipped for the next one',
      () async {
        // Server season 1 has 24 episodes; id 22 is the first cour only.
        site.byId[22] = _subject(22, episodes: 12);
        site.byId[102] = _subject(102, episodes: 12);
        final RemoteAnimeEpisode episode = _episode(
          episode: 15,
          seasonIds: const <String, String>{'anilist': '22'},
          seriesIds: const <String, String>{'tmdb': '900'},
          seasonCount: 24,
        );

        await finish(episode);

        final MediaTrackingMappingRow mapping = (await link(episode))!;
        expect(mapping.subjectId, 102, reason: 'second cour via TMDB offset');
        expect(mapping.progressOffset, 3);
        expect(site.lookups, <String>['id:22', 'id:102']);
        expect(site.pushed.single.outbox.progress, 3);
      },
    );

    test('a season of another length on a season id is not linked', () async {
      site.byId[11] = _subject(11, episodes: 12);
      final RemoteAnimeEpisode episode = _episode(
        seasonIds: const <String, String>{'anilist': '11'},
        seasonCount: 13,
      );

      await finish(episode);

      expect(await link(episode), isNull);
      expect(site.lookups, <String>['id:11']);
      expect(site.pushed, isEmpty);
    });

    test('an episode past the site episode count is not linked', () async {
      site.byId[11] = _subject(11, episodes: 12);
      final RemoteAnimeEpisode episode = _episode(
        episode: 13,
        seasonIds: const <String, String>{'anilist': '11'},
      );

      await finish(episode);

      expect(await link(episode), isNull);
      expect(site.pushed, isEmpty);
    });

    test('an unknown site episode count still links', () async {
      site.byId[11] = _subject(11, episodes: null);
      final RemoteAnimeEpisode episode = _episode(
        episode: 40,
        seasonIds: const <String, String>{'anilist': '11'},
        seasonCount: 50,
      );

      await finish(episode);

      expect((await link(episode))!.progressOffset, 40);
      expect(site.pushed.single.outbox.progress, 40);
    });

    test('a movie ignores the season count check', () async {
      site.byId[30] = _subject(30, episodes: 1);
      final RemoteAnimeEpisode episode = _episode(
        movie: true,
        season: null,
        episode: 0,
        seriesIds: const <String, String>{'anilist': '30'},
        seasonCount: 5,
      );

      await finish(episode);

      expect((await link(episode))!.progressOffset, 1);
      expect(site.pushed.single.outbox.progress, 1);
    });

    // T1 F3 item 1e: the site gets the movie's one episode (it completes a
    // one-episode entry itself) once; watching it again, a forced sync or a
    // restarted service sends nothing more. (No ids: listed under "Needs
    // attention", see remote_episode_unlinked_test.dart.)
    test('a movie linked from server ids is sent once, not again on '
        'replay', () async {
      site.byId[30] = _subject(30, episodes: 1);
      final RemoteAnimeEpisode movie = _episode(
        movie: true,
        season: null,
        episode: 0,
        seriesIds: const <String, String>{'anilist': '30'},
      );

      await finish(movie);
      final PendingTrackingUpdate sent = site.pushed.single;
      expect(sent.mapping.subjectId, 30);
      expect(sent.outbox.progress, 1, reason: 'episode 1 of 1: completed');

      await finish(movie);
      await service.syncNow(force: true);
      expect(site.pushed, hasLength(1), reason: 'watched again');

      service.dispose();
      service = MediaTrackingService(
        repository: repository,
        preferences: prefs,
        userAgent: 'test',
        extraProviders: <TrackingProvider>[site],
      );
      await finish(movie);
      expect(site.pushed, hasLength(1), reason: 'after a restart');
      expect(site.lookups, <String>['id:30'], reason: 'the link is reused');
      expect(await repository.allPending(provider: site.id), isEmpty);
    });

    test('specials (season 0) are not looked up', () async {
      site.byId[11] = _subject(11);
      final RemoteAnimeEpisode episode = _episode(
        season: 0,
        seasonIds: const <String, String>{'anilist': '11'},
      );

      await finish(episode);

      expect(await link(episode), isNull);
      expect(site.lookups, isEmpty);
      expect(site.pushed, isEmpty);
    });

    test('no id the site knows = no link, nothing sent', () async {
      final RemoteAnimeEpisode episode = _episode(
        seasonIds: const <String, String>{'anilist': '404'},
      );
      await finish(episode);
      expect(await link(episode), isNull);
      expect(site.lookups, <String>['id:404']);
      expect(site.pushed, isEmpty);
    });

    test('a lookup failure links nothing and retries next time', () async {
      site.byId[11] = _subject(11);
      site.byId[22] = _subject(22);
      site.lookupError = Exception('offline');
      final RemoteAnimeEpisode episode = _episode(
        seasonIds: const <String, String>{'anilist': '11'},
        seriesIds: const <String, String>{'anilist': '22'},
      );

      await finish(episode);

      expect(await link(episode), isNull);
      expect(site.lookups, <String>['id:11'], reason: 'stops at the failure');
      expect(site.pushed, isEmpty);

      site.lookupError = null;
      await finish(episode);

      expect((await link(episode))!.subjectId, 11);
      expect(site.pushed.single.outbox.progress, 3);
    });

    test('an existing link is reused without new lookups', () async {
      site.byId[11] = _subject(11);
      final RemoteAnimeEpisode episode = _episode(
        seasonIds: const <String, String>{'anilist': '11'},
      );
      await finish(episode);
      expect(site.lookups, <String>['id:11']);

      await finish(episode);

      expect(site.lookups, <String>['id:11']);
      expect((await link(episode))!.subjectId, 11);
    });

    test('a private library entry sends nothing', () async {
      site.byId[11] = _subject(11);
      await db.setMediaPrivate(TagHostKind.video, 'item3', true);
      final RemoteAnimeEpisode episode = _episode(
        seasonIds: const <String, String>{'anilist': '11'},
      );
      await service.recordRemoteVideoCompleted(
        episode,
        libraryBookUid: 'item3',
      );
      await service.syncNow();
      expect(await link(episode), isNull);
      expect(site.lookups, isEmpty);
      expect(site.pushed, isEmpty);
    });

    test('nothing happens while the site is off', () async {
      site.byId[11] = _subject(11);
      await service.setProviderEnabled(site.id, false);
      final RemoteAnimeEpisode episode = _episode(
        seasonIds: const <String, String>{'anilist': '11'},
      );
      await finish(episode);
      expect(await link(episode), isNull);
      expect(site.lookups, isEmpty);
      expect(site.pushed, isEmpty);
    });

    test('nothing happens while anime is off for the site', () async {
      site.byId[11] = _subject(11);
      await service.setKindEnabled(site.id, TrackingKind.anime, false);
      final RemoteAnimeEpisode episode = _episode(
        seasonIds: const <String, String>{'anilist': '11'},
      );
      await finish(episode);
      expect(await link(episode), isNull);
      expect(site.lookups, isEmpty);
      expect(site.pushed, isEmpty);
    });
  });
}
