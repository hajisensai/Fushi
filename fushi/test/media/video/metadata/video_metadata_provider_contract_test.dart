import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/anilist_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('TmdbVideoMetadataProvider contract', () {
    test(
      'BUG-1466 resolves a season-like episode group for Re:Zero S03',
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
        final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
          apiKey: 'KEY',
          client: client,
        );
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
        final List<VideoMetadataEpisode> episodes =
            await provider.fetchEpisodes(grouped, seasonNumber: 3);
        expect(episodes, hasLength(16));
        expect(episodes.first.seasonNumber, 3);
        expect(episodes.first.episodeNumber, 1);
        expect(episodes.last.episodeNumber, 16);
      },
    );

    // Shoko 图片语言序的 Main 槽：资料语言不含原语时按原语再拉一次 images 补进
    // 候选池（否则 zh 用户根本收不到日文海报）。
    test('fetchWork tops up original-language images when the metadata '
        'language leaves them out', () async {
      final List<String> imageLanguages = <String>[];
      final MockClient client = MockClient((http.Request request) async {
        if (request.url.path.endsWith('/tv/77/images')) {
          imageLanguages
              .add(request.url.queryParameters['include_image_language'] ?? '');
          return _json(<String, Object?>{
            'posters': <Object?>[
              <String, Object?>{
                'file_path': '/ja-poster.jpg',
                'iso_639_1': 'ja',
                'vote_average': 5.0,
              },
              // 与详情里已有的同一张：不重复进池。
              <String, Object?>{
                'file_path': '/zh-poster.jpg',
                'iso_639_1': 'zh',
                'vote_average': 9.0,
              },
            ],
          });
        }
        if (request.url.path.endsWith('/tv/77')) {
          return _json(<String, Object?>{
            'id': 77,
            'name': 'Show',
            'original_language': 'ja',
            'images': <String, Object?>{
              'posters': <Object?>[
                <String, Object?>{
                  'file_path': '/zh-poster.jpg',
                  'iso_639_1': 'zh',
                  'vote_average': 9.0,
                },
              ],
            },
          });
        }
        if (request.url.path.endsWith('/tv/78')) {
          return _json(<String, Object?>{
            'id': 78,
            'name': 'English show',
            'original_language': 'en',
          });
        }
        return _json(<String, Object?>{});
      });
      final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
        apiKey: 'KEY',
        client: client,
        language: 'zh-CN',
      );
      final VideoMetadataWork work = (await provider.fetchWork(
        const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: '77',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
      ))!;
      expect(imageLanguages, <String>['ja']);
      expect(
        work.images
            .where((VideoMetadataImage i) => i.kind == VideoMetadataImageKind.cover)
            .map((VideoMetadataImage i) => i.language)
            .toList(),
        <String?>['zh', 'ja'],
        reason: '原语海报补进来，重复 URL 只一张',
      );
      // 原语已在资料语言序里（en）→ 不多拉。
      await provider.fetchWork(const VideoMetadataLookup(
        provider: VideoMetadataProviderKind.tmdb,
        externalId: '78',
        mediaKind: VideoMetadataMediaKind.tv,
      ));
      expect(imageLanguages, <String>['ja']);
    });

    test(
      'listEpisodeGroups exposes every alternate ordering (Shoko '
      'TMDB_AlternateOrdering) and group-mode title aliases follow the group '
      'numbering',
      () async {
        final List<String> seasonRequests = <String>[];
        final MockClient client = MockClient((http.Request request) async {
          if (request.url.path.endsWith('/tv/65942/episode_groups')) {
            return _json(<String, Object?>{
              'results': <Object?>[
                <String, Object?>{
                  'id': 'absolute',
                  'type': 2,
                  'name': 'Absolute',
                  'group_count': 1,
                  'episode_count': 66,
                  'description': 'One long run',
                },
                <String, Object?>{
                  'id': 'seasons',
                  'type': 6,
                  'name': 'Seasons',
                  'group_count': 3,
                  'episode_count': 66,
                },
                <String, Object?>{'name': 'no id, dropped'},
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
                    for (int i = 0; i < 2; i++)
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
          if (request.url.path.endsWith('/tv/65942')) {
            return _json(<String, Object?>{
              'id': 65942,
              'name': 'Re:Zero',
              'original_language': 'ja',
            });
          }
          if (request.url.path.endsWith('/tv/65942/season/1')) {
            seasonRequests.add(request.url.queryParameters['language'] ?? '');
            return _json(<String, Object?>{
              'episodes': <Object?>[
                <String, Object?>{'episode_number': 51, 'name': 'Alias 51'},
                <String, Object?>{'episode_number': 52, 'name': 'Alias 52'},
                <String, Object?>{'episode_number': 53, 'name': 'Alias 53'},
              ],
            });
          }
          return _json(<String, Object?>{'groups': <Object?>[]});
        });
        final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
          apiKey: 'KEY',
          client: client,
          language: 'zh-CN',
        );
        const VideoMetadataLookup lookup = VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: '65942',
          mediaKind: VideoMetadataMediaKind.tv,
        );
        final List<VideoMetadataEpisodeGroupSummary> groups =
            await provider.listEpisodeGroups(lookup);
        expect(groups.map((g) => g.id), <String>['absolute', 'seasons'],
            reason: '不按类型过滤，没 id 的丢');
        expect(groups.first.type, 2);
        expect(groups.first.groupCount, 1);
        expect(groups.first.episodeCount, 66);
        expect(groups.first.description, 'One long run');
        expect(
          await provider.listEpisodeGroups(const VideoMetadataLookup(
            provider: VideoMetadataProviderKind.tmdb,
            externalId: '7',
            mediaKind: VideoMetadataMediaKind.movie,
          )),
          isEmpty,
        );

        // 分组模式下的集名别名：按默认季拉，再换回分组 (季, 集)。
        const VideoMetadataLookup grouped = VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: '65942',
          mediaKind: VideoMetadataMediaKind.tv,
          episodeGroupId: 'seasons',
        );
        final Map<int, List<String>> aliases =
            await provider.fetchEpisodeTitleAliases(grouped, seasonNumber: 3);
        expect(aliases, <int, List<String>>{
          1: <String>['Alias 51', 'Alias 51'],
          2: <String>['Alias 52', 'Alias 52'],
        });
        expect(seasonRequests, <String>['en-US', 'ja'],
            reason: '资料语言 zh 之外补 en-US 与原语 ja，只拉默认第 1 季');
      },
    );

    test(
      'maps details, external ids, credits, seasons, episodes and images',
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
            // 断言「配置的语言真的到了 wire 上」，而不是断言某个默认值——用一个
            // 既不是旧默认（zh-CN）也不是新兜底（en-US）的语言，才能证明这条链路
            // 是真的透传，不是恰好撞上了默认值。
            expect(request.url.queryParameters['language'], 'de-DE');
            // 图片语言与文字语言同源：de 派生出 de,en,null，不再写死 zh。
            expect(request.url.queryParameters['include_image_language'],
                'de,en,null');
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
        final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
          apiKey: 'KEY',
          client: client,
          language: 'de-DE',
        );
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
          ]),
        );
        expect(
          work.images
              .where(
                (VideoMetadataImage image) => image.url.endsWith('/best.jpg'),
              )
              .single
              .voteAverage,
          9,
        );

        final List<VideoMetadataEpisode> episodes =
            await provider.fetchEpisodes(lookup, seasonNumber: 1);
        expect(episodes.single.title, 'Pilot');
        expect(
          episodes.single.credits.single.kind,
          VideoMetadataCreditKind.guest,
        );
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
        expect(detailed.credits.single.kind, VideoMetadataCreditKind.director);
        expect(detailed.images.single.url, endsWith('/detail-still.jpg'));
      },
    );

    test(
      'changedTvShowIds pages /tv/changes and clamps to the 14-day window',
      () async {
        final List<Uri> calls = <Uri>[];
        final MockClient client = MockClient((http.Request request) async {
          calls.add(request.url);
          final int page = int.parse(request.url.queryParameters['page']!);
          return _json(<String, Object?>{
            'page': page,
            'total_pages': 2,
            'results': <Object?>[
              <String, Object?>{'id': 1000 + page, 'adult': false},
              <String, Object?>{'id': 30984, 'adult': false},
            ],
          });
        });
        final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
          apiKey: 'KEY',
          client: client,
          language: 'en-US',
        );
        final DateTime until = DateTime.utc(2026, 9, 20);
        final Set<int> ids = await provider.changedTvShowIds(
          since: DateTime.utc(2026, 9, 15),
          until: until,
        );
        expect(ids, <int>{1001, 1002, 30984});
        expect(calls, hasLength(2), reason: '两页，一个窗口');
        expect(calls.first.path, endsWith('/tv/changes'));
        expect(calls.first.queryParameters['start_date'], '2026-09-15');
        expect(calls.first.queryParameters['end_date'], '2026-09-20');
        expect(calls.last.queryParameters['page'], '2');

        // 40 天前：只能回看 14 天，切成两个 ≤13 天的窗口。
        calls.clear();
        await provider.changedTvShowIds(
          since: DateTime.utc(2026, 8, 10),
          until: until,
        );
        expect(calls.first.queryParameters['start_date'], '2026-09-06');
        expect(calls.first.queryParameters['end_date'], '2026-09-19');
        expect(calls.map((Uri u) => u.queryParameters['start_date']).toSet(),
            <String>{'2026-09-06', '2026-09-20'});
      },
    );

    test(
      'include_adult is sent only when the request asks for it (Shoko '
      'AutoSearchForShow includeRestricted)',
      () async {
        final List<Uri> searches = <Uri>[];
        final MockClient client = MockClient((http.Request request) async {
          if (request.url.path.endsWith('/search/multi')) {
            searches.add(request.url);
          }
          return _json(<String, Object?>{'results': <Object?>[]});
        });
        final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
          apiKey: 'KEY',
          client: client,
          language: 'en-US',
        );
        await provider.search(const VideoMetadataSearchRequest(
          title: 'Plain',
          mediaKind: VideoMetadataMediaKind.tv,
        ));
        expect(searches, isNotEmpty);
        expect(
          searches.every(
              (Uri uri) => !uri.queryParameters.containsKey('include_adult')),
          isTrue,
          reason: '默认维持 TMDB 的成人过滤',
        );
        searches.clear();
        await provider.search(const VideoMetadataSearchRequest(
          title: 'Restricted',
          mediaKind: VideoMetadataMediaKind.tv,
          includeAdult: true,
        ));
        expect(searches, isNotEmpty);
        expect(
          searches.every(
              (Uri uri) => uri.queryParameters['include_adult'] == 'true'),
          isTrue,
        );
      },
    );

    test(
      'BUG-1461 localized search keeps the English title used to match',
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
        ).resolve(
          VideoMetadataResolveRequest(
            selectedProvider: VideoMetadataProviderKind.tmdb,
            mediaKind: VideoMetadataMediaKind.tv,
            titleCandidates: <String>['Himouto! Umaru-chan'],
            year: 2015,
            seasonNumber: 1,
          ),
        );

        expect(result.status, VideoMetadataResolutionStatus.matched);
        expect(result.lookup?.externalId, '67126');
        expect(requestedLanguages, containsAll(<String>['zh-CN', 'en-US']));
        final VideoMetadataWork details = (await provider.fetchWork(
          result.lookup!,
        ))!;
        expect(details.aliases, contains('Himouto Umaru Chan'));
      },
    );
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
              'title': <String, Object?>{'native': '作品', 'romaji': 'Work'},
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
}

http.Response _json(Object? value, [int statusCode = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(value)),
      statusCode,
      headers: const <String, String>{'content-type': 'application/json'},
    );
