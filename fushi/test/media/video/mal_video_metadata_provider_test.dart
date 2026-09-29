import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_airing_status.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';

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
        // 资料语言 ja：标题取 title_japanese。语言不再是隐含的，见下一条用例。
        language: 'ja',
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

  test('MAL 标题按资料语言选：en 取英文名，其它语言 MAL 无译名落原文，三种都在别名池',
      () async {
    Future<VideoMetadataWork> fetch(String language) async {
      final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
          language: language,
          requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
          client: MockClient((http.Request request) async {
            if (request.url.path.endsWith('/full')) {
              return response(<String, Object?>{
                'data': <String, Object?>{
                  'mal_id': 1,
                  'title': 'Sousou no Frieren',
                  'title_japanese': '葬送のフリーレン',
                  'title_english': "Frieren: Beyond Journey's End",
                  'type': 'TV',
                }
              });
            }
            return response(<String, Object?>{'data': <Object?>[]});
          }));
      addTearDown(provider.close);
      return (await provider.fetchWork(lookup))!;
    }

    final VideoMetadataWork english = await fetch('en-US');
    expect(english.title, "Frieren: Beyond Journey's End");
    expect(english.originalTitle, '葬送のフリーレン');
    expect(english.aliases,
        containsAll(<String>['葬送のフリーレン', 'Sousou no Frieren']));

    // zh-CN：MAL 没有中文名，落原文；译名由合并层的 TMDB 补充源换上。
    final VideoMetadataWork chinese = await fetch('zh-CN');
    expect(chinese.title, '葬送のフリーレン');
    expect(
        chinese.aliases,
        containsAll(
            <String>['Sousou no Frieren', "Frieren: Beyond Journey's End"]));
    expect(chinese.aliases, isNot(contains('葬送のフリーレン')),
        reason: '选中的标题不重复进别名');

    final VideoMetadataWork japanese = await fetch('ja');
    expect(japanese.title, '葬送のフリーレン');
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
    // Jikan 60 req/min：1 s 正好贴着上限，留 10% 余量（BUG-2595）。
    expect(starts[1].difference(starts[0]), const Duration(milliseconds: 1100));
    values.first['data'] = 'mutated';
    expect((await gate.get('a', load))['data'], isEmpty);
  });

  test(
      '429 waits out Retry-After, retries the same request in place and keeps '
      'the global cooldown (BUG-2595)', () async {
    DateTime now = DateTime.utc(2026);
    final DateTime start = now;
    final List<DateTime> starts = <DateTime>[];
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
          starts.add(now);
          if (calls == 1) {
            return http.Response('limited', 429,
                headers: <String, String>{'retry-after': '12'});
          }
          return response(<String, Object?>{'data': <Object?>[]});
        }));
    const VideoMetadataSearchRequest request = VideoMetadataSearchRequest(
        title: 'name', mediaKind: VideoMetadataMediaKind.tv);
    // 一次 429 不再让调用方失败：冷却 12 s 后原样重发即成功。
    expect(await provider.search(request), isEmpty);
    expect(calls, 2);
    expect(starts[1].difference(starts[0]), const Duration(seconds: 12));
    expect(now.difference(start), const Duration(seconds: 12));
    // 命中缓存，不再发请求。
    expect(await provider.search(request), isEmpty);
    expect(calls, 2);
    provider.close();
  });

  test('persistent 429 gives up after the retry budget', () async {
    DateTime now = DateTime.utc(2026);
    final MalVideoMetadataRequestGate gate = MalVideoMetadataRequestGate(
        now: () => now,
        sleep: (Duration duration) async {
          now = now.add(duration);
        },
        maxRateLimitRetries: 2);
    int calls = 0;
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
        requestGate: gate,
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response('limited', 429,
              headers: <String, String>{'retry-after': '1'});
        }));
    const VideoMetadataSearchRequest request = VideoMetadataSearchRequest(
        title: 'name', mediaKind: VideoMetadataMediaKind.tv);
    await expectLater(
        provider.search(request),
        throwsA(isA<VideoMetadataNetworkException>()
            .having((e) => e.statusCode, 'statusCode', 429)));
    expect(calls, 3, reason: '首发 + 2 次重试');
    provider.close();
  });

  test('optional credit failure retains MAL work and successful staff',
      () async {
    int characterCalls = 0;
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
      requestGate: MalVideoMetadataRequestGate(
          interval: Duration.zero, sleep: (Duration _) async {}),
      client: MockClient((http.Request request) async {
        if (request.url.path.endsWith('/characters')) characterCalls++;
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
    expect(hasIncompleteMalCredits(work), isTrue);
    expect(characterCalls, 3, reason: '5xx 首发 + 2 次有界重试后才放弃');
    provider.close();
  });

  test(
      'transient 5xx on a credits endpoint is retried in place and the voice '
      'cast survives (BUG-2612)', () async {
    DateTime now = DateTime.utc(2026);
    final List<Duration> sleeps = <Duration>[];
    final MalVideoMetadataRequestGate gate = MalVideoMetadataRequestGate(
        interval: Duration.zero,
        now: () => now,
        sleep: (Duration duration) async {
          sleeps.add(duration);
          now = now.add(duration);
        });
    int characterCalls = 0;
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
      requestGate: gate,
      client: MockClient((http.Request request) async {
        if (request.url.path.endsWith('/full')) {
          return response(<String, Object?>{
            'data': <String, Object?>{'mal_id': 1, 'title': 'T', 'type': 'TV'},
          });
        }
        if (request.url.path.endsWith('/characters')) {
          // Jikan 上游连不上时的真实形态：整批 504。
          if (++characterCalls == 1) {
            return http.Response(
                '{"status":504,"type":"BadResponseException"}', 504);
          }
          return response(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'character': <String, Object?>{'mal_id': 7, 'name': 'Spike'},
                'voice_actors': <Object?>[
                  <String, Object?>{
                    'language': 'Japanese',
                    'person': <String, Object?>{'mal_id': 8, 'name': 'Koichi'},
                  },
                ],
              },
            ],
          });
        }
        return response(<String, Object?>{'data': <Object?>[]});
      }),
    );
    final VideoMetadataWork work = (await provider.fetchWork(lookup))!;
    expect(characterCalls, 2);
    expect(sleeps, <Duration>[const Duration(seconds: 2)]);
    expect(work.credits.single.person.name, 'Koichi');
    expect(hasIncompleteMalCredits(work), isFalse);
    provider.close();
  });

  test('4xx on a credits endpoint is not retried', () async {
    int characterCalls = 0;
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
      requestGate: MalVideoMetadataRequestGate(
          interval: Duration.zero, sleep: (Duration _) async {}),
      client: MockClient((http.Request request) async {
        if (request.url.path.endsWith('/full')) {
          return response(<String, Object?>{
            'data': <String, Object?>{'mal_id': 1, 'title': 'T', 'type': 'TV'},
          });
        }
        if (request.url.path.endsWith('/characters')) {
          characterCalls++;
          return http.Response('Not Found', 404);
        }
        return response(<String, Object?>{'data': <Object?>[]});
      }),
    );
    final VideoMetadataWork work = (await provider.fetchWork(lookup))!;
    expect(characterCalls, 1);
    expect(hasIncompleteMalCredits(work), isTrue);
    provider.close();
  });

  test('MAL placeholder images are treated as no image (BUG-2612)', () async {
    final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
      requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
      client: MockClient((http.Request request) async {
        if (request.url.path.endsWith('/full')) {
          return response(<String, Object?>{
            'data': <String, Object?>{'mal_id': 1, 'title': 'T', 'type': 'TV'},
          });
        }
        if (request.url.path.endsWith('/characters')) {
          return response(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'character': <String, Object?>{
                  'mal_id': 7,
                  'name': 'Nameless',
                  'images': <String, Object?>{
                    'jpg': <String, Object?>{
                      'image_url':
                          'https://cdn.myanimelist.net/img/sp/icon/apple-touch-icon-256.png',
                    },
                  },
                },
                'voice_actors': <Object?>[
                  <String, Object?>{
                    'language': 'Japanese',
                    'person': <String, Object?>{
                      'mal_id': 8,
                      'name': 'Newcomer',
                      'images': <String, Object?>{
                        'jpg': <String, Object?>{
                          'image_url':
                              'https://cdn.myanimelist.net/images/questionmark_23.gif',
                        },
                      },
                    },
                  },
                  <String, Object?>{
                    'language': 'Japanese',
                    'person': <String, Object?>{
                      'mal_id': 9,
                      'name': 'Veteran',
                      'images': <String, Object?>{
                        'jpg': <String, Object?>{
                          'image_url':
                              'https://cdn.myanimelist.net/images/voiceactors/1/2.jpg',
                          'large_image_url':
                              'https://cdn.myanimelist.net/images/voiceactors/1/2l.jpg',
                        },
                      },
                    },
                  },
                ],
              },
            ],
          });
        }
        return response(<String, Object?>{'data': <Object?>[]});
      }),
    );
    final VideoMetadataWork work = (await provider.fetchWork(lookup))!;
    expect(work.credits, hasLength(2));
    expect(work.credits[0].person.profileUrl, isNull,
        reason: 'questionmark 占位不是照片，留空让合并层用别的源补');
    expect(work.credits[0].character?.imageUrl, isNull);
    expect(work.credits[1].person.profileUrl,
        'https://cdn.myanimelist.net/images/voiceactors/1/2l.jpg');
    expect(
        isMalPlaceholderImageUrl(
            'https://cdn.myanimelist.net/images/questionmark_50.gif'),
        isTrue);
    expect(
        isMalPlaceholderImageUrl(
            'https://cdn.myanimelist.net/images/characters/9/310307.jpg'),
        isFalse);
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

  group('MAL airing status and end date', () {
    Future<VideoMetadataWork> fetch(Map<String, Object?> extra) async {
      final MalVideoMetadataProvider provider = MalVideoMetadataProvider(
        requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
        client: MockClient((http.Request request) async {
          if (request.url.path.endsWith('/full')) {
            return response(<String, Object?>{
              'data': <String, Object?>{
                'mal_id': 1,
                'title': 'Sousou no Frieren',
                'type': 'TV',
                ...extra,
              }
            });
          }
          return response(<String, Object?>{'data': <Object?>[]});
        }),
      );
      addTearDown(provider.close);
      return (await provider.fetchWork(lookup))!;
    }

    test('status keeps the Jikan raw string; endDate comes from aired.to',
        () async {
      final VideoMetadataWork work = await fetch(<String, Object?>{
        'status': 'Currently Airing',
        'airing': true,
        'aired': <String, Object?>{
          'from': '2023-09-29T00:00:00+09:00',
          'to': '2024-03-22T00:00:00+09:00',
        },
      });
      expect(work.status, 'Currently Airing');
      expect(work.premiered, '2023-09-29');
      expect(work.endDate, '2024-03-22');
      expect(work.airingStatus, VideoAiringStatus.airing);
    });

    test('missing status falls back to airing: true', () async {
      final VideoMetadataWork work =
          await fetch(<String, Object?>{'airing': true});
      expect(work.status, 'Currently Airing');
      expect(work.airingStatus, VideoAiringStatus.airing);
      expect(work.endDate, isNull);
    });

    test('airing: false without status stays null instead of guessing',
        () async {
      final VideoMetadataWork work =
          await fetch(<String, Object?>{'airing': false});
      expect(work.status, isNull);
      expect(work.airingStatus, isNull);
    });

    test('finished status normalizes and originalLanguage is never filled',
        () async {
      final VideoMetadataWork work = await fetch(<String, Object?>{
        'status': 'Finished Airing',
        'airing': false,
        'aired': <String, Object?>{'to': null},
      });
      expect(work.status, 'Finished Airing');
      expect(work.airingStatus, VideoAiringStatus.finished);
      expect(work.endDate, isNull);
      expect(work.originalLanguage, isNull,
          reason: 'Jikan 无语言字段，MAL 收录中 / 韩动画，不能硬填 ja');
    });
  });
}
