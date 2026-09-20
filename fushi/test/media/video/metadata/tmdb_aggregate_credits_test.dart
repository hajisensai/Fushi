/// BUG-2612：TMDB 剧集人物表要用跨季汇总的 `aggregate_credits`（`credits` 只有
/// 常驻主演），配音角色「X (voice)」归为 voiceActor 并剥后缀。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object payload) =>
    http.Response(jsonEncode(payload), 200, headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    });

Map<String, Object?> _person(int id, String name, {String? profile}) =>
    <String, Object?>{
      'id': id,
      'name': name,
      'original_name': name,
      'gender': 1,
      'profile_path': profile,
    };

void main() {
  const VideoMetadataLookup tv = VideoMetadataLookup(
    provider: VideoMetadataProviderKind.tmdb,
    externalId: '100',
    mediaKind: VideoMetadataMediaKind.tv,
  );
  const VideoMetadataLookup movie = VideoMetadataLookup(
    provider: VideoMetadataProviderKind.tmdb,
    externalId: '200',
    mediaKind: VideoMetadataMediaKind.movie,
  );

  test('TV works request aggregate_credits and flatten roles / jobs', () async {
    final List<Uri> requests = <Uri>[];
    final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
      apiKey: 'KEY',
      client: MockClient((http.Request request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/tv/100')) {
          return _json(<String, Object?>{
            'id': 100,
            'name': 'Frieren',
            'first_air_date': '2023-09-29',
            'credits': <String, Object?>{
              'cast': <Object?>[
                <String, Object?>{
                  ..._person(1, 'Atsumi Tanezaki', profile: '/atsumi.jpg'),
                  'character': 'Frieren (voice)',
                  'credit_id': 'c-main',
                  'order': 0,
                },
              ],
              'crew': <Object?>[],
            },
            'aggregate_credits': <String, Object?>{
              'cast': <Object?>[
                <String, Object?>{
                  ..._person(1, 'Atsumi Tanezaki', profile: '/atsumi.jpg'),
                  'roles': <Object?>[
                    <String, Object?>{
                      'credit_id': 'c-main',
                      'character': 'Frieren (voice)',
                      'episode_count': 28,
                    },
                  ],
                  'order': 0,
                },
                <String, Object?>{
                  ..._person(2, 'Kana Ichinose'),
                  'roles': <Object?>[
                    <String, Object?>{
                      'credit_id': 'c-ubel',
                      'character': 'Ubel (voice)',
                      'episode_count': 6,
                    },
                    <String, Object?>{
                      'credit_id': 'c-ubel-young',
                      'character': 'Young Ubel (voice)',
                      'episode_count': 1,
                    },
                  ],
                  'order': 12,
                },
                <String, Object?>{
                  ..._person(3, 'Live Actor'),
                  'roles': <Object?>[
                    <String, Object?>{
                      'credit_id': 'c-live',
                      'character': 'Host',
                      'episode_count': 1,
                    },
                  ],
                  'order': 30,
                },
              ],
              'crew': <Object?>[
                <String, Object?>{
                  ..._person(9, 'Keiichiro Saito'),
                  'department': 'Directing',
                  'jobs': <Object?>[
                    <String, Object?>{
                      'credit_id': 'c-dir',
                      'job': 'Series Director',
                      'episode_count': 28,
                    },
                  ],
                },
              ],
            },
          });
        }
        return http.Response('Not Found', 404);
      }),
    );
    final VideoMetadataWork work = (await provider.fetchWork(tv))!;
    expect(
      requests.single.queryParameters['append_to_response'],
      contains('aggregate_credits'),
    );
    final Iterable<VideoMetadataCredit> voice = work.credits.where(
        (VideoMetadataCredit c) =>
            c.kind == VideoMetadataCreditKind.voiceActor);
    expect(
      voice.map((VideoMetadataCredit c) => c.roleName),
      <String>['Frieren', 'Ubel', 'Young Ubel'],
      reason: '一人多角色展开成多条，(voice) 后缀剥掉',
    );
    expect(voice.first.character?.name, 'Frieren');
    expect(voice.first.person.profileUrl,
        'https://image.tmdb.org/t/p/original/atsumi.jpg');
    expect(voice.first.providerCreditId, 'c-main');
    final VideoMetadataCredit live = work.credits.singleWhere(
        (VideoMetadataCredit c) => c.kind == VideoMetadataCreditKind.actor);
    expect(live.roleName, 'Host', reason: '没有 (voice) 的仍是 actor');
    final VideoMetadataCredit director = work.credits.singleWhere(
        (VideoMetadataCredit c) => c.kind == VideoMetadataCreditKind.director);
    expect(director.job, 'Series Director');
    expect(director.providerCreditId, 'c-dir');
    // `credits` 里的常驻主演与汇总表重叠时不重复。
    expect(
      work.credits
          .where((VideoMetadataCredit c) => c.person.name == 'Atsumi Tanezaki'),
      hasLength(1),
    );
    provider.close();
  });

  test('movies keep plain credits and do not request aggregate_credits',
      () async {
    final List<Uri> requests = <Uri>[];
    final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
      apiKey: 'KEY',
      client: MockClient((http.Request request) async {
        requests.add(request.url);
        return _json(<String, Object?>{
          'id': 200,
          'title': 'Movie',
          'credits': <String, Object?>{
            'cast': <Object?>[
              <String, Object?>{
                ..._person(5, 'Someone'),
                'character': 'Lead',
                'credit_id': 'm-1',
                'order': 0,
              },
            ],
            'crew': <Object?>[],
          },
        });
      }),
    );
    final VideoMetadataWork work = (await provider.fetchWork(movie))!;
    expect(
      requests.single.queryParameters['append_to_response'],
      isNot(contains('aggregate_credits')),
    );
    expect(work.credits.single.kind, VideoMetadataCreditKind.actor);
    expect(work.credits.single.roleName, 'Lead');
    provider.close();
  });
}
