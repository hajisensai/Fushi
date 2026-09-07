import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';

const VideoMetadataLookup lookup = VideoMetadataLookup(
    provider: VideoMetadataProviderKind.mal,
    externalId: '1',
    mediaKind: VideoMetadataMediaKind.tv);

http.Response response(Object payload) =>
    http.Response(jsonEncode(payload), 200, headers: <String, String>{
      'content-type': 'application/json; charset=utf-8'
    });

void main() {
  test(
      'MAL details preserve identity, native aliases, score and Japanese credits',
      () async {
    final List<String> paths = <String>[];
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
        requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
        client: MockClient((http.Request request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/full')) {
            return response(<String, Object?>{
              'data': <String, Object?>{
                'mal_id': 1,
                'title': 'Cowboy Bebop',
                'title_japanese': 'カウボーイビバップ',
                'title_english': 'Cowboy Bebop',
                'type': 'TV',
                'episodes': 26,
                'aired': <String, Object?>{'from': '1998-04-03T00:00:00+09:00'},
                'score': 8.75,
                'scored_by': 123,
                'duration': '24 min per ep',
                'images': <String, Object?>{
                  'jpg': <String, Object?>{
                    'large_image_url': 'https://example.org/cover.jpg'
                  }
                },
              }
            });
          }
          if (request.url.path.endsWith('/characters')) {
            return response(<String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'character': <String, Object?>{'mal_id': 7, 'name': 'Spike'},
                  'voice_actors': <Object?>[
                    <String, Object?>{
                      'language': 'Japanese',
                      'person': <String, Object?>{'mal_id': 8, 'name': 'Koichi'}
                    },
                    <String, Object?>{
                      'language': 'English',
                      'person': <String, Object?>{'mal_id': 9, 'name': 'Steve'}
                    },
                  ]
                },
              ]
            });
          }
          return response(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'person': <String, Object?>{'mal_id': 10, 'name': 'Director'},
                'positions': <String>['Director']
              },
            ]
          });
        }));
    final VideoMetadataWork work = (await provider.fetchWork(lookup))!;
    expect(work.provider, VideoMetadataProviderKind.mal);
    expect(work.ids.single.value, '1');
    expect(work.title, 'カウボーイビバップ');
    expect(work.aliases, contains('Cowboy Bebop'));
    expect(work.year, 1998);
    expect(work.rating, 8.75);
    expect(work.ratingVotes, 123);
    expect(work.runtimeMinutes, 24);
    expect(work.images.single.provider, VideoMetadataProviderKind.mal);
    expect(work.credits.length, 2);
    expect(work.credits.first.person.name, 'Koichi');
    expect(work.credits.last.kind, VideoMetadataCreditKind.director);
    await provider.fetchWork(lookup);
    expect(paths.length, 3);
    provider.close();
  });

  test(
      'episode pagination uses real records, skips untitled and maps only source season one',
      () async {
    final List<String?> pages = <String?>[];
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
        requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
        client: MockClient((http.Request request) async {
          final String? page = request.url.queryParameters['page'];
          pages.add(page);
          return response(<String, Object?>{
            'pagination': <String, Object?>{'has_next_page': page == '1'},
            'data': page == '1'
                ? <Object?>[
                    <String, Object?>{
                      'mal_id': 1,
                      'title': 'First',
                      'score': 4.5
                    },
                    <String, Object?>{'mal_id': 2, 'title': null},
                  ]
                : <Object?>[
                    <String, Object?>{'mal_id': 3, 'title_japanese': '三話'}
                  ],
          });
        }));
    final List<VideoMetadataEpisode> episodes =
        await provider.fetchEpisodes(lookup, seasonNumber: 1);
    expect(episodes.map((VideoMetadataEpisode item) => item.episodeNumber),
        <int>[1, 3]);
    expect(episodes.first.rating, 9);
    expect(episodes.first.ids.single.value, '1/1');
    expect(pages, <String>['1', '2']);
    expect(await provider.fetchEpisodes(lookup, seasonNumber: 2), isEmpty);
    expect(pages.length, 2);
    provider.close();
  });

  test('MAL search does not filter out OVA and special TV works at the API',
      () async {
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
        requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
        client: MockClient((http.Request request) async {
          expect(request.url.queryParameters['type'], isNull);
          expect(request.url.queryParameters['limit'], '25');
          return response(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{'mal_id': 1, 'title': 'OVA', 'type': 'OVA'},
              <String, Object?>{'mal_id': 2, 'title': 'Film', 'type': 'Movie'},
            ]
          });
        }));
    final List<VideoMetadataWork> works = await provider.search(
        const VideoMetadataSearchRequest(
            title: 'name', mediaKind: VideoMetadataMediaKind.tv, limit: 50));
    expect(works.single.title, 'OVA');
    provider.close();
  });

  test(
      'shared gate coalesces reads, isolates cached JSON and limits every provider',
      () async {
    DateTime now = DateTime.utc(2026);
    final List<DateTime> starts = <DateTime>[];
    final MalVideoMetadataRequestGate gate = MalVideoMetadataRequestGate(
        now: () => now,
        sleep: (Duration duration) async {
          now = now.add(duration);
        });
    Future<VideoMetadataHttpResponse> load() async {
      starts.add(now);
      return const VideoMetadataHttpResponse(
          statusCode: 200, body: '{"data":[]}', headers: <String, String>{});
    }

    final List<Map<String, Object?>> values =
        await Future.wait(<Future<Map<String, Object?>>>[
      gate.get('a', load),
      gate.get('a', load),
      gate.get('b', load),
    ]);
    expect(starts.length, 2);
    expect(starts[1].difference(starts[0]), const Duration(seconds: 1));
    values.first['data'] = 'mutated';
    expect((await gate.get('a', load))['data'], isEmpty);
  });

  test('429 propagates without retry and applies global Retry-After cooldown',
      () async {
    DateTime now = DateTime.utc(2026);
    final DateTime start = now;
    final MalVideoMetadataRequestGate gate = MalVideoMetadataRequestGate(
        now: () => now,
        sleep: (Duration duration) async {
          now = now.add(duration);
        });
    int calls = 0;
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
        requestGate: gate,
        client: MockClient((http.Request request) async {
          calls++;
          if (calls == 1) {
            return http.Response('limited', 429,
                headers: <String, String>{'retry-after': '12'});
          }
          return response(<String, Object?>{'data': <Object?>[]});
        }));
    const VideoMetadataSearchRequest request = VideoMetadataSearchRequest(
        title: 'name', mediaKind: VideoMetadataMediaKind.tv);
    await expectLater(provider.search(request),
        throwsA(isA<VideoMetadataNetworkException>()));
    expect(calls, 1);
    expect(await provider.search(request), isEmpty);
    expect(now.difference(start), const Duration(seconds: 12));
    provider.close();
  });

  test('optional credit failure retains MAL work and successful staff',
      () async {
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
      requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
      client: MockClient((http.Request request) async {
        if (request.url.path.endsWith('/full')) {
          return response(<String, Object?>{
            'data': <String, Object?>{
              'mal_id': 1,
              'title': 'Authoritative MAL title',
              'type': 'TV',
            },
          });
        }
        if (request.url.path.endsWith('/characters')) {
          return http.Response('Unavailable', 503);
        }
        return response(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'person': <String, Object?>{'mal_id': 10, 'name': 'Director'},
              'positions': <String>['Director'],
            },
          ],
        });
      }),
    );
    final VideoMetadataWork work = (await provider.fetchWork(lookup))!;
    expect(work.provider, VideoMetadataProviderKind.mal);
    expect(work.title, 'Authoritative MAL title');
    expect(work.credits.single.person.name, 'Director');
    expect(work.rawPayload?[malIncompleteCreditEndpointsKey],
        <String>['characters']);
    provider.close();
  });

  test('missing MAL full work returns null without fetching optional credits',
      () async {
    int calls = 0;
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
      requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
      client: MockClient((http.Request request) async {
        calls++;
        expect(request.url.path, '/v4/anime/1/full');
        return http.Response('Not Found', 404);
      }),
    );
    expect(await provider.fetchWork(lookup), isNull);
    expect(calls, 1);
    provider.close();
  });
}
