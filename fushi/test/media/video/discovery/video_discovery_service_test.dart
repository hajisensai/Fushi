import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_adapters.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_service.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('TMDB discovery adapter', () {
    test('uses discover filters and maps a real movie response', () async {
      late Uri requested;
      final TmdbVideoDiscoveryProvider provider = TmdbVideoDiscoveryProvider(
        apiKey: 'secret-key',
        client: MockClient((http.Request request) async {
          requested = request.url;
          return http.Response(
            jsonEncode(<String, Object?>{
              'page': 1,
              'total_pages': 2,
              'results': <Object?>[
                <String, Object?>{
                  'id': 42,
                  'title': 'Test Movie',
                  'original_title': 'Original Movie',
                  'release_date': '2024-03-02',
                  'overview': 'Overview',
                  'vote_average': 8.4,
                  'vote_count': 100,
                  'genre_ids': <int>[16],
                  'poster_path': '/cover.jpg',
                  'backdrop_path': '/backdrop.jpg',
                },
              ],
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
      addTearDown(provider.close);

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await provider.discover(
        const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.movie,
          year: 2024,
          genre: 'Animation',
          region: 'JP',
          sort: VideoDiscoverySort.rating,
        ),
      );

      expect(requested.path, '/3/discover/movie');
      expect(requested.queryParameters['api_key'], 'secret-key');
      expect(requested.queryParameters['primary_release_year'], '2024');
      expect(requested.queryParameters['with_genres'], '16');
      expect(requested.queryParameters['region'], 'JP');
      expect(requested.queryParameters['sort_by'], 'vote_average.desc');
      expect(result.successfulProviderCount, 1);
      expect(result.failures, isEmpty);
      expect(result.items.single.hasMore, isTrue);
      final VideoDiscoveryItem item = result.items.single.items.single;
      expect(item.reference.tmdbId, 42);
      expect(item.reference.mediaKind, VideoMetadataMediaKind.movie);
      expect(item.reference.discoveryCategory, VideoDiscoveryCategory.movie);
      expect(item.posterUrl, endsWith('/cover.jpg'));
      expect(item.genres, contains('Animation'));
    });

    test('interleaves movies and series in the all category', () async {
      final TmdbVideoDiscoveryProvider provider = TmdbVideoDiscoveryProvider(
        apiKey: 'secret-key',
        client: MockClient((http.Request request) async {
          final bool movie = request.url.path.endsWith('/movie/popular');
          return http.Response(
            jsonEncode(<String, Object?>{
              'total_pages': 1,
              'results': <Object?>[
                <String, Object?>{
                  'id': movie ? 1 : 2,
                  if (movie) 'title': 'Movie' else 'name': 'Series',
                  if (movie)
                    'release_date': '2025-01-01'
                  else
                    'first_air_date': '2025-01-01',
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(provider.close);

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await provider.discover(const VideoDiscoveryRequest());

      expect(
        result.items.single.items.map(
          (VideoDiscoveryItem item) => item.reference.mediaKind,
        ),
        <VideoMetadataMediaKind>[
          VideoMetadataMediaKind.movie,
          VideoMetadataMediaKind.tv,
        ],
      );
    });

    test('classifies HTTP 429 without exposing the request URL', () async {
      final VideoMetadataHttpClient transport = VideoMetadataHttpClient(
        client: MockClient((http.Request request) async {
          return http.Response('rate limited', 429);
        }),
        maxAttempts: 1,
      );
      final TmdbVideoDiscoveryProvider provider = TmdbVideoDiscoveryProvider(
        apiKey: 'super-secret',
        transport: transport,
      );
      addTearDown(transport.close);

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await provider.discover(
        const VideoDiscoveryRequest(category: VideoDiscoveryCategory.movie),
      );

      expect(result.isTotalFailure, isTrue);
      expect(
        result.failures.single.kind,
        ExternalProviderFailureKind.rateLimited,
      );
      expect(
          result.failures.single.toString(), isNot(contains('super-secret')));
      expect(result.failures.single.toString(), isNot(contains('api_key')));
    });

    test('search applies genre region year and requested sort locally',
        () async {
      final List<int> requestedPages = <int>[];
      final TmdbVideoDiscoveryProvider provider = TmdbVideoDiscoveryProvider(
        apiKey: 'secret-key',
        client: MockClient((http.Request request) async {
          final int page = int.parse(request.url.queryParameters['page']!);
          requestedPages.add(page);
          expect(request.url.path, '/3/search/movie');
          expect(request.url.queryParameters['query'], 'Test');
          expect(request.url.queryParameters['primary_release_year'], '2024');
          expect(request.url.queryParameters['with_genres'], isNull);
          expect(request.url.queryParameters['region'], isNull);
          expect(request.url.queryParameters['sort_by'], isNull);
          return http.Response(
            jsonEncode(<String, Object?>{
              'total_pages': 2,
              'results': page == 1
                  ? <Object?>[
                      _tmdbMovie(
                        id: 1,
                        title: 'Wrong country',
                        score: 9.9,
                        genres: const <int>[16],
                        countries: const <String>['US'],
                      ),
                      _tmdbMovie(
                        id: 2,
                        title: 'Lower rated match',
                        score: 7.0,
                        genres: const <int>[16],
                        countries: const <String>['JP'],
                      ),
                    ]
                  : <Object?>[
                      _tmdbMovie(
                        id: 3,
                        title: 'Higher rated match',
                        score: 8.5,
                        genres: const <int>[16],
                        countries: const <String>['JP'],
                      ),
                      _tmdbMovie(
                        id: 4,
                        title: 'Wrong genre',
                        score: 9.8,
                        genres: const <int>[28],
                        countries: const <String>['JP'],
                      ),
                    ],
            }),
            200,
          );
        }),
      );
      addTearDown(provider.close);

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await provider.search(
        const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.movie,
          query: 'Test',
          pageSize: 2,
          year: 2024,
          genre: 'Animation',
          region: 'JP',
          sort: VideoDiscoverySort.rating,
        ),
      );

      expect(requestedPages, <int>[1, 2]);
      expect(
        result.items.single.items
            .map((VideoDiscoveryItem item) => item.reference.tmdbId),
        <int?>[3, 2],
      );
      expect(result.items.single.hasMore, isFalse);
    });

    test('rejects an unrecognized search genre instead of ignoring it',
        () async {
      final TmdbVideoDiscoveryProvider provider = TmdbVideoDiscoveryProvider(
        apiKey: 'secret-key',
        client: MockClient((http.Request request) async {
          fail('unsupported filters must fail before network access');
        }),
      );
      addTearDown(provider.close);

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await provider.search(
        const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.movie,
          query: 'Test',
          genre: 'Not a TMDB genre',
        ),
      );

      expect(result.isTotalFailure, isTrue);
      expect(
        result.failures.single.kind,
        ExternalProviderFailureKind.unsupported,
      );
    });

    test('search stops pagination when the local filter scan cap is reached',
        () async {
      int calls = 0;
      final TmdbVideoDiscoveryProvider provider = TmdbVideoDiscoveryProvider(
        apiKey: 'secret-key',
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'total_pages': 500,
              'results': <Object?>[
                _tmdbMovie(
                  id: calls,
                  title: 'Non-matching $calls',
                  score: 8,
                  genres: const <int>[16],
                  countries: const <String>['US'],
                ),
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(provider.close);

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await provider.search(
        const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.movie,
          query: 'Test',
          genre: 'Animation',
          region: 'JP',
        ),
      );

      expect(calls, 20);
      expect(result.items.single.items, isEmpty);
      expect(result.items.single.hasMore, isFalse);
    });

    test('accepts the provider-neutral Sci-Fi genre alias', () async {
      final TmdbVideoDiscoveryProvider provider = TmdbVideoDiscoveryProvider(
        apiKey: 'secret-key',
        client: MockClient((http.Request request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'total_pages': 1,
              'results': <Object?>[
                _tmdbMovie(
                  id: 878,
                  title: 'Science fiction match',
                  score: 8,
                  genres: const <int>[878],
                  countries: const <String>['JP'],
                ),
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(provider.close);

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await provider.search(
        const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.movie,
          query: 'Test',
          genre: 'Sci-Fi',
        ),
      );

      expect(result.failures, isEmpty);
      expect(
          result.items.single.items.single.genres, contains('Science Fiction'));
    });
  });

  group('AniList discovery adapter', () {
    test('loads the current seasonal feed through GraphQL', () async {
      late Map<String, Object?> variables;
      final AniListVideoDiscoveryProvider provider =
          AniListVideoDiscoveryProvider(
        now: () => DateTime(2026, 8, 9),
        client: MockClient((http.Request request) async {
          final Map<String, Object?> body =
              jsonDecode(request.body) as Map<String, Object?>;
          variables = body['variables']! as Map<String, Object?>;
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <String, Object?>{
                'Page': <String, Object?>{
                  'pageInfo': <String, Object?>{'hasNextPage': false},
                  'media': <Object?>[
                    <String, Object?>{
                      'id': 7,
                      'idMal': 70,
                      'format': 'MOVIE',
                      'title': <String, Object?>{
                        'native': '劇場版テスト',
                        'romaji': 'Gekijouban Test',
                        'english': 'Test Movie',
                      },
                      'startDate': <String, Object?>{
                        'year': 2026,
                        'month': 7,
                        'day': 1,
                      },
                      'averageScore': 80,
                      'popularity': 1000,
                      'genres': <String>['Action'],
                      'coverImage': <String, Object?>{
                        'large': 'https://img.test/cover.jpg',
                      },
                    },
                  ],
                },
              },
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
      addTearDown(provider.close);

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await provider.discover(
        const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.anime,
          feed: VideoDiscoveryFeed.airing,
        ),
      );

      expect(variables['season'], 'SUMMER');
      expect(variables['seasonYear'], 2026);
      expect(variables['status'], 'RELEASING');
      expect(result.failures, isEmpty, reason: '${result.failures}');
      expect(result.items, isNotEmpty);
      final VideoDiscoveryItem item = result.items.single.items.single;
      expect(item.reference.anilistId, 7);
      expect(item.reference.mediaKind, VideoMetadataMediaKind.movie);
      expect(item.reference.discoveryCategory, VideoDiscoveryCategory.anime);
      expect(item.score, 8.0);
    });

    test('maps the provider-neutral Science Fiction genre to Sci-Fi', () async {
      late Map<String, Object?> variables;
      final AniListVideoDiscoveryProvider provider =
          AniListVideoDiscoveryProvider(
        client: MockClient((http.Request request) async {
          final Map<String, Object?> body =
              jsonDecode(request.body) as Map<String, Object?>;
          variables = body['variables']! as Map<String, Object?>;
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': <String, Object?>{
                'Page': <String, Object?>{
                  'pageInfo': <String, Object?>{'hasNextPage': false},
                  'media': <Object?>[],
                },
              },
            }),
            200,
          );
        }),
      );
      addTearDown(provider.close);

      await provider.search(
        const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.anime,
          query: 'Test',
          genre: 'Science Fiction',
        ),
      );

      expect(variables['genre'], 'Sci-Fi');
    });

    test('rejects a TMDB-only composite genre instead of ignoring it',
        () async {
      final AniListVideoDiscoveryProvider provider =
          AniListVideoDiscoveryProvider(
        client: MockClient((http.Request request) async {
          fail('unsupported genre must fail before network access');
        }),
      );
      addTearDown(provider.close);

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await provider.search(
        const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.anime,
          query: 'Test',
          genre: 'Sci-Fi & Fantasy',
        ),
      );

      expect(result.isTotalFailure, isTrue);
      expect(
        result.failures.single.kind,
        ExternalProviderFailureKind.unsupported,
      );
    });
  });

  group('VideoDiscoveryService', () {
    test('preserves successful items when another provider fails', () async {
      final _FakeProvider success = _FakeProvider(
        id: 'success',
        priority: 1,
        response: ProviderBatchResult<VideoDiscoveryPage>.success(
          <VideoDiscoveryPage>[
            VideoDiscoveryPage(
              items: <VideoDiscoveryItem>[
                _item(
                  provider: 'tmdb',
                  id: '1',
                  title: 'Movie',
                  year: 2025,
                ),
              ],
              page: 1,
              hasMore: false,
            ),
          ],
        ),
      );
      final _FakeProvider failure = _FakeProvider(
        id: 'failure',
        priority: 2,
        response: ProviderBatchResult<VideoDiscoveryPage>.failure(
          const ExternalProviderFailure(
            providerId: 'failure',
            operation: 'discover',
            kind: ExternalProviderFailureKind.rateLimited,
            message: 'provider rate limited',
          ),
        ),
      );
      final VideoDiscoveryService service = VideoDiscoveryService(
        providers: <VideoDiscoveryProvider>[success, failure],
      );

      final ProviderBatchResult<VideoDiscoveryPage> result =
          await service.load(const VideoDiscoveryRequest());

      expect(result.isPartial, isTrue);
      expect(result.items.single.items.single.reference.title, 'Movie');
      expect(result.failures.single.providerId, 'failure');
    });

    test('reuses page one from a non-paging supplement in later windows',
        () async {
      final _FakeProvider paged = _FakeProvider(
        id: 'paged',
        priority: 1,
        supportsPaging: true,
        response: ProviderBatchResult<VideoDiscoveryPage>.success(
          <VideoDiscoveryPage>[
            VideoDiscoveryPage(
                items: const <VideoDiscoveryItem>[], page: 2, hasMore: false),
          ],
        ),
      );
      final _FakeProvider supplement = _FakeProvider(
        id: 'supplement',
        priority: 2,
        supportsPaging: false,
        response: ProviderBatchResult<VideoDiscoveryPage>.success(
          <VideoDiscoveryPage>[
            VideoDiscoveryPage(
                items: const <VideoDiscoveryItem>[], page: 1, hasMore: false),
          ],
        ),
      );
      final VideoDiscoveryService service = VideoDiscoveryService(
        providers: <VideoDiscoveryProvider>[paged, supplement],
      );

      await service.load(
        const VideoDiscoveryRequest(query: 'test', page: 2),
      );

      expect(paged.searchCalls, 1);
      expect(supplement.searchCalls, 1);
    });

    test('global page two consumes provider page-one tails before page two',
        () async {
      final _PagedFakeProvider first = _PagedFakeProvider(
        id: 'first',
        priority: 1,
        pages: <int, List<VideoDiscoveryItem>>{
          1: <VideoDiscoveryItem>[
            _item(provider: 'tmdb', id: '1', title: 'A1', year: 2025),
            _item(provider: 'tmdb', id: '2', title: 'A2', year: 2025),
          ],
          2: <VideoDiscoveryItem>[
            _item(provider: 'tmdb', id: '3', title: 'A3', year: 2025),
          ],
        },
      );
      final _PagedFakeProvider second = _PagedFakeProvider(
        id: 'second',
        priority: 2,
        pages: <int, List<VideoDiscoveryItem>>{
          1: <VideoDiscoveryItem>[
            _item(provider: 'bangumi', id: '11', title: 'B1', year: 2025),
            _item(provider: 'bangumi', id: '12', title: 'B2', year: 2025),
          ],
          2: <VideoDiscoveryItem>[
            _item(provider: 'bangumi', id: '13', title: 'B3', year: 2025),
          ],
        },
      );
      final VideoDiscoveryService service = VideoDiscoveryService(
        providers: <VideoDiscoveryProvider>[first, second],
      );

      final ProviderBatchResult<VideoDiscoveryPage> pageOne =
          await service.load(
        const VideoDiscoveryRequest(pageSize: 2),
      );
      final ProviderBatchResult<VideoDiscoveryPage> pageTwo =
          await service.load(
        const VideoDiscoveryRequest(page: 2, pageSize: 2),
      );

      expect(
        pageOne.items.single.items
            .map((VideoDiscoveryItem item) => item.reference.title),
        <String>['A1', 'B1'],
      );
      expect(
        pageTwo.items.single.items
            .map((VideoDiscoveryItem item) => item.reference.title),
        <String>['A2', 'B2'],
      );
      expect(first.requestedPages, <int>[1, 1, 2]);
      expect(second.requestedPages, <int>[1, 1, 2]);
    });

    test('post-filters and sorts Bangumi metadata search summaries', () async {
      VideoDiscoveryItem bangumiItem({
        required String id,
        required String title,
        required List<String> genres,
        required List<String> countries,
        required int votes,
      }) =>
          VideoDiscoveryItem.fromMetadataWork(
            work: VideoMetadataWork(
              provider: VideoMetadataProviderKind.bangumi,
              kind: VideoMetadataMediaKind.tv,
              title: title,
              year: 2025,
              rating: 8,
              ratingVotes: votes,
              genres: genres,
              countries: countries,
              ids: <VideoMetadataId>[
                VideoMetadataId(
                  type: 'bangumi',
                  value: id,
                  isDefault: true,
                ),
              ],
            ),
            discoveryCategory: VideoDiscoveryCategory.anime,
          );

      final _FakeProvider bangumi = _FakeProvider(
        id: 'bangumi',
        priority: 1,
        supportsPaging: false,
        response: ProviderBatchResult<VideoDiscoveryPage>.success(
          <VideoDiscoveryPage>[
            VideoDiscoveryPage(
              items: <VideoDiscoveryItem>[
                bangumiItem(
                  id: '1',
                  title: 'Low popularity',
                  genres: const <String>['Sci-Fi'],
                  countries: const <String>['Japan'],
                  votes: 10,
                ),
                bangumiItem(
                  id: '2',
                  title: 'Wrong genre',
                  genres: const <String>['Comedy'],
                  countries: const <String>['JP'],
                  votes: 1000,
                ),
                bangumiItem(
                  id: '3',
                  title: 'High popularity',
                  genres: const <String>['Science Fiction'],
                  countries: const <String>['JP'],
                  votes: 100,
                ),
              ],
              page: 1,
              hasMore: false,
            ),
          ],
        ),
      );
      final VideoDiscoveryService service = VideoDiscoveryService(
        providers: <VideoDiscoveryProvider>[bangumi],
      );

      final ProviderBatchResult<VideoDiscoveryPage> result = await service.load(
        const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.anime,
          query: 'Test',
          year: 2025,
          genre: 'Sci-Fi',
          region: 'JP',
          sort: VideoDiscoverySort.popularity,
        ),
      );

      expect(
        result.items.single.items
            .map((VideoDiscoveryItem item) => item.reference.title),
        <String>['High popularity', 'Low popularity'],
      );
    });

    test('hydrates AniList details and supplements them from Bangumi',
        () async {
      final VideoMetadataWork anilistWork = VideoMetadataWork(
        provider: VideoMetadataProviderKind.anilist,
        kind: VideoMetadataMediaKind.tv,
        title: 'Primary Anime',
        year: 2026,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'anilist', value: '1', isDefault: true),
        ],
      );
      final VideoMetadataWork bangumiWork = VideoMetadataWork(
        provider: VideoMetadataProviderKind.bangumi,
        kind: VideoMetadataMediaKind.tv,
        title: '中文标题',
        plot: 'Bangumi summary',
        aliases: const <String>['Bangumi Alias'],
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'bangumi', value: '2', isDefault: true),
        ],
        credits: <VideoMetadataCredit>[
          VideoMetadataCredit(
            kind: VideoMetadataCreditKind.voiceActor,
            person: VideoMetadataPerson(name: 'Voice Actor'),
          ),
        ],
      );
      final VideoDiscoveryService service = VideoDiscoveryService(
        providers: const <VideoDiscoveryProvider>[],
        metadataProviders: <VideoMetadataProvider>[
          _FakeMetadataProvider(
            kind: VideoMetadataProviderKind.anilist,
            work: anilistWork,
          ),
          _FakeMetadataProvider(
            kind: VideoMetadataProviderKind.bangumi,
            work: bangumiWork,
          ),
        ],
      );
      final VideoDiscoveryItem item = VideoDiscoveryItem(
        reference: VideoMediaReference(
          providerId: 'anilist',
          mediaId: '1',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.anime,
          title: 'Primary Anime',
          year: 2026,
          anilistId: 1,
          bangumiId: 2,
        ),
        confirmedLookup: const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.anilist,
          externalId: '1',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
      );

      final VideoMetadataWork? result = await service.loadDetails(item);

      expect(result?.provider, VideoMetadataProviderKind.anilist);
      expect(result?.plot, 'Bangumi summary');
      expect(result?.aliases, containsAll(<String>['中文标题', 'Bangumi Alias']));
      expect(result?.credits.single.person.name, 'Voice Actor');
      expect(
        result?.ids.map((VideoMetadataId id) => id.type),
        containsAll(<String>['anilist', 'bangumi']),
      );
    });
  });

  group('identity merge', () {
    test('weakly merges anime aliases and prefers AniList identity', () {
      final VideoDiscoveryItem bangumi = _item(
        provider: 'bangumi',
        id: '22',
        title: 'Test Anime',
        year: 2026,
        category: VideoDiscoveryCategory.anime,
      );
      final VideoDiscoveryItem anilist = _item(
        provider: 'anilist',
        id: '11',
        title: 'Test Anime!',
        year: 2026,
        category: VideoDiscoveryCategory.anime,
      );

      final List<VideoDiscoveryItem> result = mergeVideoDiscoveryItems(
        <VideoDiscoveryItem>[bangumi, anilist],
        request: const VideoDiscoveryRequest(
          category: VideoDiscoveryCategory.anime,
        ),
      );

      expect(result, hasLength(1));
      expect(result.single.reference.providerId, 'anilist');
      expect(result.single.reference.anilistId, 11);
      expect(result.single.reference.bangumiId, 22);
    });

    test('does not merge conflicting ids from the same namespace', () {
      final List<VideoDiscoveryItem> result = mergeVideoDiscoveryItems(
        <VideoDiscoveryItem>[
          _item(
            provider: 'tmdb',
            id: '1',
            title: 'Same',
            year: 2025,
          ),
          _item(
            provider: 'tmdb',
            id: '2',
            title: 'Same',
            year: 2025,
          ),
        ],
        request: const VideoDiscoveryRequest(),
      );

      expect(result, hasLength(2));
    });

    test('does not weakly merge when the year is absent', () {
      final List<VideoDiscoveryItem> result = mergeVideoDiscoveryItems(
        <VideoDiscoveryItem>[
          _item(provider: 'anilist', id: '1', title: 'Same'),
          _item(provider: 'bangumi', id: '2', title: 'Same'),
        ],
        request: const VideoDiscoveryRequest(),
      );

      expect(result, hasLength(2));
    });

    test('merges a single-episode anime TV summary with the matching movie',
        () {
      final VideoMetadataWork bangumiWork = VideoMetadataWork(
        provider: VideoMetadataProviderKind.bangumi,
        kind: VideoMetadataMediaKind.tv,
        title: '超时空辉夜姬！',
        year: 2026,
        episodeCount: 1,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'bangumi', value: '604826', isDefault: true),
        ],
      );
      final VideoDiscoveryItem bangumi = VideoDiscoveryItem.fromMetadataWork(
        work: bangumiWork,
        discoveryCategory: VideoDiscoveryCategory.anime,
      );
      final VideoDiscoveryItem tmdb = _item(
        provider: 'tmdb',
        id: '1234',
        title: '超时空辉夜姬!',
        year: 2026,
      );

      final List<VideoDiscoveryItem> result = mergeVideoDiscoveryItems(
        <VideoDiscoveryItem>[bangumi, tmdb],
        request: const VideoDiscoveryRequest(query: '辉夜姬'),
      );

      expect(result, hasLength(1));
      expect(result.single.reference.mediaKind, VideoMetadataMediaKind.movie);
      expect(result.single.reference.providerId, 'tmdb');
      expect(result.single.reference.tmdbId, 1234);
      expect(result.single.reference.bangumiId, 604826);
    });

    test('does not merge a multi-episode anime series into a movie', () {
      final VideoMetadataWork anilistWork = VideoMetadataWork(
        provider: VideoMetadataProviderKind.anilist,
        kind: VideoMetadataMediaKind.tv,
        title: 'Same title',
        year: 2026,
        runtimeMinutes: 24,
        episodeCount: 12,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'anilist', value: '99', isDefault: true),
        ],
      );
      final VideoDiscoveryItem anilist = VideoDiscoveryItem.fromMetadataWork(
        work: anilistWork,
        discoveryCategory: VideoDiscoveryCategory.anime,
      );

      final List<VideoDiscoveryItem> result = mergeVideoDiscoveryItems(
        <VideoDiscoveryItem>[
          anilist,
          _item(
            provider: 'tmdb',
            id: '100',
            title: 'Same title',
            year: 2026,
          ),
        ],
        request: const VideoDiscoveryRequest(query: 'Same title'),
      );

      expect(result, hasLength(2));
    });

    test('a transitive match cannot bypass another namespace conflict', () {
      final VideoDiscoveryItem tmdb = VideoDiscoveryItem(
        reference: VideoMediaReference(
          providerId: 'tmdb',
          mediaId: '1',
          mediaKind: VideoMetadataMediaKind.movie,
          discoveryCategory: VideoDiscoveryCategory.movie,
          title: 'One',
          year: 2025,
          tmdbId: 1,
          imdbId: 'tt100',
        ),
      );
      final VideoDiscoveryItem anilist = VideoDiscoveryItem(
        reference: VideoMediaReference(
          providerId: 'anilist',
          mediaId: '10',
          mediaKind: VideoMetadataMediaKind.movie,
          discoveryCategory: VideoDiscoveryCategory.anime,
          title: 'Two',
          year: 2025,
          anilistId: 10,
          imdbId: 'tt100',
        ),
      );
      final VideoDiscoveryItem bangumi = VideoDiscoveryItem(
        reference: VideoMediaReference(
          providerId: 'bangumi',
          mediaId: '20',
          mediaKind: VideoMetadataMediaKind.movie,
          discoveryCategory: VideoDiscoveryCategory.anime,
          title: 'Three',
          year: 2025,
          bangumiId: 20,
          externalIds: const <String, String>{
            'anilist': '10',
            'tmdb': '2',
          },
        ),
      );

      final List<VideoDiscoveryItem> result = mergeVideoDiscoveryItems(
        <VideoDiscoveryItem>[tmdb, anilist, bangumi],
        request: const VideoDiscoveryRequest(),
      );

      expect(result, hasLength(2));
    });
  });
}

VideoDiscoveryItem _item({
  required String provider,
  required String id,
  required String title,
  int? year,
  VideoDiscoveryCategory category = VideoDiscoveryCategory.movie,
}) {
  final VideoMetadataProviderKind providerKind = switch (provider) {
    'anilist' => VideoMetadataProviderKind.anilist,
    'bangumi' => VideoMetadataProviderKind.bangumi,
    _ => VideoMetadataProviderKind.tmdb,
  };
  final VideoMetadataMediaKind kind = category == VideoDiscoveryCategory.movie
      ? VideoMetadataMediaKind.movie
      : VideoMetadataMediaKind.tv;
  final VideoMetadataWork work = VideoMetadataWork(
    provider: providerKind,
    kind: kind,
    title: title,
    year: year,
    ids: <VideoMetadataId>[
      VideoMetadataId(type: provider, value: id, isDefault: true),
    ],
  );
  return VideoDiscoveryItem.fromMetadataWork(
    work: work,
    discoveryCategory: category,
    externalId: id,
  );
}

class _FakeProvider implements VideoDiscoveryProvider {
  _FakeProvider({
    required this.id,
    required this.priority,
    required this.response,
    this.supportsPaging = true,
  });

  @override
  final String id;

  @override
  final int priority;

  final ProviderBatchResult<VideoDiscoveryPage> response;
  final bool supportsPaging;
  int searchCalls = 0;

  @override
  VideoDiscoveryCapabilities get capabilities => VideoDiscoveryCapabilities(
        supportsPaging: supportsPaging,
        feeds: VideoDiscoveryFeed.values,
      );

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> discover(
    VideoDiscoveryRequest request,
  ) async =>
      response;

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> search(
    VideoDiscoveryRequest request,
  ) async {
    searchCalls++;
    return response;
  }

  @override
  void close() {}
}

class _PagedFakeProvider implements VideoDiscoveryProvider {
  _PagedFakeProvider({
    required this.id,
    required this.priority,
    required this.pages,
  });

  @override
  final String id;

  @override
  final int priority;

  final Map<int, List<VideoDiscoveryItem>> pages;
  final List<int> requestedPages = <int>[];

  @override
  VideoDiscoveryCapabilities get capabilities => VideoDiscoveryCapabilities(
        feeds: VideoDiscoveryFeed.values,
      );

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> discover(
    VideoDiscoveryRequest request,
  ) async {
    requestedPages.add(request.page);
    return ProviderBatchResult<VideoDiscoveryPage>.success(
      <VideoDiscoveryPage>[
        VideoDiscoveryPage(
          items: pages[request.page] ?? const <VideoDiscoveryItem>[],
          page: request.page,
          hasMore: pages.containsKey(request.page + 1),
        ),
      ],
    );
  }

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> search(
    VideoDiscoveryRequest request,
  ) =>
      discover(request);

  @override
  void close() {}
}

Map<String, Object?> _tmdbMovie({
  required int id,
  required String title,
  required double score,
  required List<int> genres,
  required List<String> countries,
}) =>
    <String, Object?>{
      'id': id,
      'title': title,
      'release_date': '2024-01-01',
      'vote_average': score,
      'vote_count': 100,
      'popularity': score * 10,
      'genre_ids': genres,
      'origin_country': countries,
    };

class _FakeMetadataProvider implements VideoMetadataProvider {
  const _FakeMetadataProvider({required this.kind, required this.work});

  final VideoMetadataProviderKind kind;
  final VideoMetadataWork work;

  @override
  VideoMetadataProviderKind get providerKind => kind;

  @override
  bool get isAvailable => true;

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      work;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      const <VideoMetadataEpisode>[];

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async =>
      <VideoMetadataWork>[work];

  @override
  void close() {}
}
