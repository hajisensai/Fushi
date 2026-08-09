import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/anilist_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/authorized_douban_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/bangumi_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/fanart_video_image_provider.dart';
import 'package:fushi/src/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('TmdbVideoMetadataProvider contract', () {
    test('BUG-1466 resolves a season-like episode group for Re:Zero S03',
        () async {
      final MockClient client = MockClient((http.Request request) async {
        if (request.url.path.endsWith('/tv/65942/episode_groups')) {
          return _json(<String, Object?>{
            'results': <Object?>[
              <String, Object?>{
                'id': 'absolute',
                'type': 2,
                'name': 'Absolute',
              },
              <String, Object?>{
                'id': 'seasons',
                'type': 6,
                'name': 'Seasons',
              },
            ],
          });
        }
        if (request.url.path.endsWith('/tv/episode_group/seasons')) {
          return _json(<String, Object?>{
            'id': 'seasons',
            'groups': <Object?>[
              <String, Object?>{
                'id': 'season-3',
                'name': 'Season 3',
                'order': 3,
                'episodes': <Object?>[
                  for (int i = 0; i < 16; i++)
                    <String, Object?>{
                      'id': 5100 + i,
                      'order': i,
                      'season_number': 1,
                      'episode_number': 51 + i,
                      'name': 'Episode ${i + 1}',
                    },
                ],
              },
            ],
          });
        }
        return _json(<String, Object?>{'groups': <Object?>[]});
      });
      final TmdbVideoMetadataProvider provider =
          TmdbVideoMetadataProvider(apiKey: 'KEY', client: client);
      const VideoMetadataLookup lookup = VideoMetadataLookup(
        provider: VideoMetadataProviderKind.tmdb,
        externalId: '65942',
        mediaKind: VideoMetadataMediaKind.tv,
      );

      final VideoMetadataLookup grouped = (await provider.resolveEpisodeGroup(
        lookup,
        seasonNumber: 3,
        episodeCount: 16,
      ))!;
      expect(grouped.episodeGroupId, 'seasons');
      final List<VideoMetadataEpisode> episodes = await provider.fetchEpisodes(
        grouped,
        seasonNumber: 3,
      );
      expect(episodes, hasLength(16));
      expect(episodes.first.seasonNumber, 3);
      expect(episodes.first.episodeNumber, 1);
      expect(episodes.last.episodeNumber, 16);
    });

    test('maps details, external ids, credits, seasons, episodes and images',
        () async {
      final MockClient client = MockClient((http.Request request) async {
        if (request.url.path.endsWith('/tv/100/season/1/episode/1')) {
          return _json(<String, Object?>{
            'id': 501,
            'season_number': 1,
            'episode_number': 1,
            'name': 'Pilot detail',
            'external_ids': <String, Object?>{
              'imdb_id': 'tt-episode',
              'tvdb_id': 9001,
            },
            'crew': <Object?>[
              <String, Object?>{
                'id': 77,
                'name': 'Episode director',
                'job': 'Director',
              },
            ],
            'images': <String, Object?>{
              'stills': <Object?>[
                <String, Object?>{
                  'file_path': '/detail-still.jpg',
                  'vote_average': 9.5,
                },
              ],
            },
          });
        }
        if (request.url.path.endsWith('/tv/100/season/1')) {
          return _json(<String, Object?>{
            'id': 500,
            'season_number': 1,
            'name': 'Season 1',
            'air_date': '2024-01-01',
            'episodes': <Object?>[
              <String, Object?>{
                'id': 501,
                'season_number': 1,
                'episode_number': 1,
                'name': 'Pilot',
                'overview': 'Episode plot',
                'air_date': '2024-01-02',
                'runtime': 24,
                'still_path': '/still.jpg',
                'guest_stars': <Object?>[
                  <String, Object?>{
                    'id': 9,
                    'name': 'Guest',
                    'character': 'Hero',
                  },
                ],
              },
            ],
          });
        }
        if (request.url.path.endsWith('/tv/100')) {
          expect(request.url.queryParameters['language'], 'zh-CN');
          expect(request.url.queryParameters['api_key'], 'KEY');
          return _json(<String, Object?>{
            'id': 100,
            'name': '作品',
            'original_name': 'Work',
            'first_air_date': '2024-01-01',
            'overview': 'Plot',
            'vote_average': 8.2,
            'vote_count': 120,
            'number_of_seasons': 1,
            'number_of_episodes': 12,
            'episode_run_time': <Object?>[24],
            'poster_path': '/poster.jpg',
            'external_ids': <String, Object?>{
              'imdb_id': 'tt123',
              'tvdb_id': 456,
            },
            'genres': <Object?>[
              <String, Object?>{'name': 'Animation'},
            ],
            'credits': <String, Object?>{
              'crew': <Object?>[
                <String, Object?>{
                  'id': 7,
                  'name': 'Director',
                  'job': 'Director',
                },
              ],
              'cast': <Object?>[
                <String, Object?>{
                  'id': 8,
                  'name': 'Actor',
                  'character': 'Lead',
                  'order': 0,
                },
              ],
            },
            'images': <String, Object?>{
              'posters': <Object?>[
                <String, Object?>{
                  'file_path': '/low.jpg',
                  'vote_average': 5.0,
                  'vote_count': 100,
                },
                <String, Object?>{
                  'file_path': '/best.jpg',
                  'vote_average': 9.0,
                  'vote_count': 5,
                },
              ],
              'backdrops': <Object?>[],
              'logos': <Object?>[],
            },
            'seasons': <Object?>[
              <String, Object?>{
                'id': 500,
                'season_number': 1,
                'name': 'Season 1',
                'episode_count': 12,
              },
            ],
          });
        }
        return _json(<String, Object?>{'results': <Object?>[]});
      });
      final TmdbVideoMetadataProvider provider =
          TmdbVideoMetadataProvider(apiKey: 'KEY', client: client);
      const VideoMetadataLookup lookup = VideoMetadataLookup(
        provider: VideoMetadataProviderKind.tmdb,
        externalId: '100',
        mediaKind: VideoMetadataMediaKind.tv,
      );

      final VideoMetadataWork work = (await provider.fetchWork(lookup))!;
      expect(work.title, '作品');
      expect(
        work.ids.where((VideoMetadataId id) => id.isDefault).single.type,
        'imdb',
      );
      expect(work.ids.any((VideoMetadataId id) => id.type == 'tvdb'), isTrue);
      expect(
          work.credits.map((VideoMetadataCredit c) => c.kind),
          containsAll(<VideoMetadataCreditKind>[
            VideoMetadataCreditKind.director,
            VideoMetadataCreditKind.actor,
          ]));
      expect(
        work.images
            .where(
                (VideoMetadataImage image) => image.url.endsWith('/best.jpg'))
            .single
            .voteAverage,
        9,
      );

      final List<VideoMetadataEpisode> episodes =
          await provider.fetchEpisodes(lookup, seasonNumber: 1);
      expect(episodes.single.title, 'Pilot');
      expect(
          episodes.single.credits.single.kind, VideoMetadataCreditKind.guest);
      expect(episodes.single.images.single.url, endsWith('/still.jpg'));

      final VideoMetadataEpisode detailed = (await provider.fetchEpisode(
        lookup,
        seasonNumber: 1,
        episodeNumber: 1,
      ))!;
      expect(
        detailed.ids.map((VideoMetadataId id) => id.type),
        containsAll(<String>['tmdb', 'imdb', 'tvdb']),
      );
      expect(
        detailed.credits.single.kind,
        VideoMetadataCreditKind.director,
      );
      expect(detailed.images.single.url, endsWith('/detail-still.jpg'));
    });

    test('BUG-1461 localized search keeps the English title used to match',
        () async {
      final List<String> requestedLanguages = <String>[];
      final MockClient client = MockClient((http.Request request) async {
        final String language = request.url.queryParameters['language'] ?? '';
        requestedLanguages.add(language);
        if (request.url.path.endsWith('/search/multi')) {
          final String name = switch (language) {
            'en-US' => 'Himouto! Umaru-chan',
            'ja-JP' => '干物妹!うまるちゃん',
            _ => '干物妹！小埋',
          };
          return _json(<String, Object?>{
            'results': <Object?>[
              <String, Object?>{
                'id': 67126,
                'media_type': 'tv',
                'name': name,
                'original_name': '干物妹!うまるちゃん',
                'first_air_date': '2015-07-09',
              },
            ],
          });
        }
        if (request.url.path.endsWith('/tv/67126')) {
          return _json(<String, Object?>{
            'id': 67126,
            'name': '干物妹！小埋',
            'original_name': '干物妹!うまるちゃん',
            'first_air_date': '2015-07-09',
            'alternative_titles': <String, Object?>{
              'results': <Object?>[
                <String, Object?>{'title': 'Himouto Umaru Chan'},
              ],
            },
            'seasons': <Object?>[
              <String, Object?>{
                'id': 70001,
                'season_number': 1,
                'name': 'Season 1',
                'episode_count': 12,
              },
            ],
          });
        }
        return _json(<String, Object?>{});
      });
      final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
        apiKey: 'KEY',
        client: client,
        language: 'zh-CN',
      );

      final VideoMetadataResolution result = await VideoMetadataResolver(
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
          provider,
        ]),
      ).resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.tmdb,
        mediaKind: VideoMetadataMediaKind.tv,
        titleCandidates: <String>['Himouto! Umaru-chan'],
        year: 2015,
        seasonNumber: 1,
      ));

      expect(result.status, VideoMetadataResolutionStatus.matched);
      expect(result.lookup?.externalId, '67126');
      expect(requestedLanguages, containsAll(<String>['zh-CN', 'en-US']));
      final VideoMetadataWork details =
          (await provider.fetchWork(result.lookup!))!;
      expect(details.aliases, contains('Himouto Umaru Chan'));
    });
  });

  group('BangumiVideoMetadataProvider contract', () {
    test('uses official v0 endpoints and maps voice actor relationships',
        () async {
      final MockClient client = MockClient((http.Request request) async {
        if (request.url.path.endsWith('/subjects/253/characters')) {
          return _json(<Object?>[
            <String, Object?>{
              'id': 10,
              'name': '角色',
              'actors': <Object?>[
                <String, Object?>{'id': 20, 'name': '声优'},
              ],
            },
          ]);
        }
        if (request.url.path.endsWith('/subjects/253/persons')) {
          return _json(<Object?>[
            <String, Object?>{
              'relation': '导演',
              'person': <String, Object?>{'id': 30, 'name': '监督'},
            },
          ]);
        }
        if (request.url.path.endsWith('/subjects/253')) {
          return _json(<String, Object?>{
            'id': 253,
            'name': '原题',
            'name_cn': '中文题',
            'platform': 'TV',
            'date': '2020-01-01',
            'eps': 1,
            'summary': '简介',
            'images': <String, Object?>{'large': 'https://img/cover.jpg'},
          });
        }
        if (request.url.path.endsWith('/episodes')) {
          return _json(<String, Object?>{
            'total': 1,
            'data': <Object?>[
              <String, Object?>{
                'id': 40,
                'sort': 1,
                'name': '第一话',
                'airdate': '2020-01-02',
              },
            ],
          });
        }
        throw StateError('Unexpected ${request.url}');
      });
      final BangumiVideoMetadataProvider provider =
          BangumiVideoMetadataProvider(client: client);
      final VideoMetadataWork work = (await provider.fetchWork(
        const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.bangumi,
          externalId: '253',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
      ))!;

      expect(work.title, '中文题');
      expect(work.seasons.single.episodes.single.title, '第一话');
      expect(
        work.credits.map((VideoMetadataCredit value) => value.kind),
        containsAll(<VideoMetadataCreditKind>[
          VideoMetadataCreditKind.voiceActor,
          VideoMetadataCreditKind.director,
        ]),
      );
      final VideoMetadataCredit voice = work.credits.firstWhere(
        (VideoMetadataCredit value) =>
            value.kind == VideoMetadataCreditKind.voiceActor,
      );
      expect(voice.person.name, '声优');
      expect(voice.character?.name, '角色');
    });
  });

  group('AniListVideoMetadataProvider contract', () {
    test('maps official GraphQL work and Japanese voice actor', () async {
      final MockClient client = MockClient((http.Request request) async {
        final Map<String, Object?> body =
            (jsonDecode(request.body) as Map).cast<String, Object?>();
        expect(body['query'], contains('voiceActors'));
        return _json(<String, Object?>{
          'data': <String, Object?>{
            'Media': <String, Object?>{
              'id': 1,
              'format': 'TV',
              'title': <String, Object?>{
                'native': '作品',
                'romaji': 'Work',
              },
              'startDate': <String, Object?>{
                'year': 2022,
                'month': 4,
                'day': 1,
              },
              'episodes': 12,
              'averageScore': 85,
              'coverImage': <String, Object?>{'extraLarge': 'https://cover'},
              'characters': <String, Object?>{
                'edges': <Object?>[
                  <String, Object?>{
                    'node': <String, Object?>{
                      'id': 2,
                      'name': <String, Object?>{'native': '角色'},
                      'image': <String, Object?>{},
                    },
                    'voiceActors': <Object?>[
                      <String, Object?>{
                        'id': 3,
                        'name': <String, Object?>{'native': '声优'},
                        'image': <String, Object?>{},
                      },
                    ],
                  },
                ],
              },
              'staff': <String, Object?>{'edges': <Object?>[]},
            },
          },
        });
      });
      final AniListVideoMetadataProvider provider =
          AniListVideoMetadataProvider(client: client);
      final VideoMetadataWork work = (await provider.fetchWork(
        const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.anilist,
          externalId: '1',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
      ))!;

      expect(work.rating, 8.5);
      expect(work.credits.single.kind, VideoMetadataCreditKind.voiceActor);
      expect(work.credits.single.language, 'ja');
      expect(
        await provider.fetchEpisodes(
          const VideoMetadataLookup(
            provider: VideoMetadataProviderKind.anilist,
            externalId: '1',
            mediaKind: VideoMetadataMediaKind.tv,
          ),
          seasonNumber: 1,
        ),
        isEmpty,
        reason: 'AniList has no reliable episode-level metadata',
      );
    });
  });

  group('FanartVideoImageProvider contract', () {
    test('requires TVDB for TV and sorts zh, en, no-language then likes',
        () async {
      Uri? captured;
      final FanartVideoImageProvider provider = FanartVideoImageProvider(
        apiKey: 'KEY',
        client: MockClient((http.Request request) async {
          captured = request.url;
          return _json(<String, Object?>{
            'tvposter': <Object?>[
              <String, Object?>{
                'url': 'https://en',
                'lang': 'en',
                'likes': '99',
              },
              <String, Object?>{
                'url': 'https://zh-low',
                'lang': 'zh',
                'likes': '1',
              },
              <String, Object?>{
                'url': 'https://zh-high',
                'lang': 'zh',
                'likes': '5',
              },
            ],
          });
        }),
      );
      final List<VideoMetadataImage> images = await provider.fetchImages(
        VideoMetadataWork(
          provider: VideoMetadataProviderKind.tmdb,
          kind: VideoMetadataMediaKind.tv,
          title: 'Work',
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'tvdb', value: '123'),
          ],
        ),
      );

      expect(captured?.path, endsWith('/tv/123'));
      expect(captured?.queryParameters['api-key'], 'KEY');
      expect(images.map((VideoMetadataImage value) => value.url),
          <String>['https://zh-high', 'https://zh-low', 'https://en']);
    });
  });

  group('AuthorizedDoubanVideoMetadataProvider contract', () {
    test('unconfigured adapter is unavailable and sends no request', () async {
      int calls = 0;
      final AuthorizedDoubanVideoMetadataProvider provider =
          AuthorizedDoubanVideoMetadataProvider(
        endpoint: '',
        token: '',
        client: MockClient((http.Request request) async {
          calls++;
          return _json(<String, Object?>{});
        }),
      );

      expect(provider.isAvailable, isFalse);
      await expectLater(
        provider.search(const VideoMetadataSearchRequest(
          title: 'Movie',
          mediaKind: VideoMetadataMediaKind.movie,
        )),
        throwsA(isA<VideoMetadataProviderUnavailable>()),
      );
      expect(calls, 0);
    });

    test('configured adapter sends bearer token and maps neutral response',
        () async {
      String? authorization;
      final AuthorizedDoubanVideoMetadataProvider provider =
          AuthorizedDoubanVideoMetadataProvider(
        endpoint: 'https://licensed.example/v1/',
        token: 'TOKEN',
        client: MockClient((http.Request request) async {
          authorization = request.headers['authorization'];
          return _json(<String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'id': '1292052',
                'kind': 'movie',
                'title': '肖申克的救赎',
                'year': 1994,
                'rating': 9.7,
              },
            ],
          });
        }),
      );

      final List<VideoMetadataWork> works = await provider.search(
        const VideoMetadataSearchRequest(
          title: '肖申克的救赎',
          mediaKind: VideoMetadataMediaKind.movie,
        ),
      );
      expect(authorization, 'Bearer TOKEN');
      expect(works.single.ids.single.value, '1292052');
      expect(works.single.rating, 9.7);
    });

    test('never sends bearer token over non-loopback HTTP', () async {
      int calls = 0;
      final AuthorizedDoubanVideoMetadataProvider provider =
          AuthorizedDoubanVideoMetadataProvider(
        endpoint: 'http://licensed.example/v1',
        token: 'TOKEN',
        client: MockClient((http.Request request) async {
          calls++;
          return _json(<String, Object?>{});
        }),
      );

      expect(provider.isAvailable, isFalse);
      await expectLater(
        provider.search(const VideoMetadataSearchRequest(
          title: 'Movie',
          mediaKind: VideoMetadataMediaKind.movie,
        )),
        throwsA(isA<VideoMetadataProviderUnavailable>()),
      );
      expect(calls, 0);
    });

    test('allows HTTP only for an explicit loopback bridge', () async {
      Uri? captured;
      final AuthorizedDoubanVideoMetadataProvider provider =
          AuthorizedDoubanVideoMetadataProvider(
        endpoint: 'http://127.0.0.1:17321/v1',
        token: 'LOCAL_TOKEN',
        client: MockClient((http.Request request) async {
          captured = request.url;
          return _json(<String, Object?>{'items': <Object?>[]});
        }),
      );

      expect(provider.isAvailable, isTrue);
      await provider.search(const VideoMetadataSearchRequest(
        title: 'Movie',
        mediaKind: VideoMetadataMediaKind.movie,
      ));
      expect(captured?.host, '127.0.0.1');
      expect(captured?.port, 17321);
    });
  });
}

http.Response _json(Object? value, [int statusCode = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(value)),
      statusCode,
      headers: const <String, String>{'content-type': 'application/json'},
    );
