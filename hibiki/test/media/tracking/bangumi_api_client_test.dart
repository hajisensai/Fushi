import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/bangumi_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('getCollection uses the authenticated username path and auth headers',
      () async {
    late http.Request captured;
    final BangumiApiClient client = BangumiApiClient(
      accessToken: 'secret-token',
      userAgent:
          'hajisensai/Fushi/1.2.0 (https://github.com/hajisensai/hibiki)',
      client: MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          '{"type":3,"ep_status":4,"vol_status":1}',
          200,
        );
      }),
    );
    addTearDown(client.close);

    final BangumiUserCollection? value =
        await client.getCollection('alice name', 123);

    expect(captured.url.path, '/v0/users/alice%20name/collections/123');
    expect(captured.headers['Authorization'], 'Bearer secret-token');
    expect(captured.headers['User-Agent'], contains('hajisensai/Fushi/1.2.0'));
    expect(value!.episodeProgress, 4);
  });

  test('search filters the official subject type and parses Chinese title',
      () async {
    late http.Request captured;
    final BangumiApiClient client = BangumiApiClient(
      accessToken: 'token',
      userAgent: 'test-agent',
      client: MockClient((http.Request request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'data': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 42,
                'type': 2,
                'name': 'Sousou no Frieren',
                'name_cn': '葬送的芙莉莲',
                'platform': 'TV',
                'eps': 28,
                'volumes': 0,
                'images': <String, String>{'medium': 'https://example/42.jpg'},
              },
            ],
          })),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );
    addTearDown(client.close);

    final List<BangumiSubject> results =
        await client.searchSubjects(keyword: '芙莉莲', subjectType: 2);

    expect(captured.method, 'POST');
    expect(
      (jsonDecode(captured.body) as Map<String, dynamic>)['filter'],
      <String, dynamic>{
        'type': <dynamic>[2],
      },
    );
    expect(results.single.displayName, '葬送的芙莉莲');
    expect(results.single.episodeCount, 28);
  });

  test('游戏条目(type 4)不被解析器丢弃，音乐(3)/三次元(6)仍然丢弃', () async {
    final BangumiApiClient client = BangumiApiClient(
      accessToken: 'token',
      userAgent: 'test-agent',
      client: MockClient((http.Request request) async {
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'data': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 13,
                'type': 4,
                'name': 'CLANNAD',
                'name_cn': '团子大家族',
                'platform': '游戏',
                'eps': 0,
                'volumes': 0,
              },
              <String, dynamic>{
                'id': 99,
                'type': 3,
                'name': 'Some album',
                'name_cn': '',
                'platform': '音乐',
                'eps': 0,
                'volumes': 0,
              },
              <String, dynamic>{
                'id': 98,
                'type': 6,
                'name': 'Some drama',
                'name_cn': '',
                'platform': '三次元',
                'eps': 0,
                'volumes': 0,
              },
            ],
          })),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );
    addTearDown(client.close);

    final List<BangumiSubject> results =
        await client.searchSubjects(keyword: 'CLANNAD', subjectType: 4);

    expect(results.map((BangumiSubject s) => s.id), <int>[13]);
    expect(results.single.displayName, '团子大家族');
    // 游戏条目没有话数/卷数，正是 status 模式存在的理由。
    expect(results.single.episodeCount, 0);
    expect(results.single.volumeCount, 0);
  });

  test('getSubject reads official chapter and volume totals', () async {
    late http.Request captured;
    final BangumiApiClient client = BangumiApiClient(
      accessToken: 'token',
      userAgent: 'test-agent',
      client: MockClient((http.Request request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'id': 7,
            'type': 1,
            'name': 'Novel',
            'name_cn': '小说',
            'platform': '书籍',
            'eps': 24,
            'volumes': 3,
          })),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final BangumiSubject subject = await client.getSubject(7);

    expect(captured.method, 'GET');
    expect(captured.url.path, '/v0/subjects/7');
    expect(subject.episodeCount, 24);
    expect(subject.volumeCount, 3);
  });

  test('watched anime list follows every official collection page', () async {
    final List<http.Request> captured = <http.Request>[];
    final BangumiApiClient client = BangumiApiClient(
      accessToken: 'token',
      userAgent: 'test-agent',
      client: MockClient((http.Request request) async {
        captured.add(request);
        final int offset =
            int.parse(request.url.queryParameters['offset'] ?? '0');
        final int id = offset == 0 ? 41 : 42;
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'total': 51,
            'limit': 50,
            'offset': offset,
            'data': <Map<String, dynamic>>[
              <String, dynamic>{
                'subject_id': id,
                'subject_type': 2,
                'type': 2,
                'ep_status': offset == 0 ? 12 : 24,
                'updated_at': '2026-07-29T12:00:00+08:00',
                'subject': <String, dynamic>{
                  'id': id,
                  'type': 2,
                  'name': 'Anime $id',
                  'name_cn': '番剧 $id',
                  'platform': 'TV',
                  'eps': offset == 0 ? 12 : 24,
                  'volumes': 0,
                  'images': <String, String>{
                    'medium': 'https://example/$id.jpg',
                  },
                },
              },
            ],
          })),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final List<BangumiWatchedItem> watched =
        await client.getWatchedAnime('alice name');

    expect(captured, hasLength(2));
    expect(captured.first.url.path, '/v0/users/alice%20name/collections');
    expect(
        captured.first.url.queryParameters, containsPair('subject_type', '2'));
    expect(captured.first.url.queryParameters, containsPair('type', '2'));
    expect(captured.last.url.queryParameters, containsPair('offset', '50'));
    expect(
      watched.map((BangumiWatchedItem item) => item.subject.id),
      <int>[41, 42],
    );
    expect(watched.last.episodeProgress, 24);
  });

  test('markEpisodesDone sends one idempotent batch patch', () async {
    late http.Request captured;
    final BangumiApiClient client = BangumiApiClient(
      accessToken: 'token',
      userAgent: 'test-agent',
      client: MockClient((http.Request request) async {
        captured = request;
        return http.Response('', 204);
      }),
    );
    addTearDown(client.close);

    await client.markEpisodesDone(7, <int>[11, 12]);

    expect(captured.method, 'PATCH');
    expect(captured.url.path, '/v0/users/-/collections/7/episodes');
    expect(
      jsonDecode(captured.body),
      <String, dynamic>{
        'episode_id': <dynamic>[11, 12],
        'type': 2,
      },
    );
  });
}
