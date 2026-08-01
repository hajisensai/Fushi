// TODO-2487 放送日历：AniList airingSchedules 查询的解析纯函数 + 客户端契约。
// 关键契约：① mediaIds 为 null 时变量表**不含** ids 键（GraphQL 规范里缺省的
// 变量使实参视同未写；显式 null 会被当作「mediaId_in: null」过滤出 0 结果）；
// ② 非 200（含 429 rate limit）抛 AniListRequestException 如实上抛，不吞错。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hibiki/src/media/video/anilist_client.dart';

String _pageBody({
  List<Map<String, dynamic>> schedules = const <Map<String, dynamic>>[],
  bool hasNextPage = false,
}) =>
    jsonEncode(<String, dynamic>{
      'data': <String, dynamic>{
        'Page': <String, dynamic>{
          'pageInfo': <String, dynamic>{'hasNextPage': hasNextPage},
          'airingSchedules': schedules,
        },
      },
    });

void main() {
  group('parseAniListAiringResponse', () {
    test('parses schedules with media titles and hasNextPage', () {
      final AniListAiringPage page = parseAniListAiringResponse(_pageBody(
        hasNextPage: true,
        schedules: <Map<String, dynamic>>[
          <String, dynamic>{
            'mediaId': 42,
            'episode': 7,
            'airingAt': 1770000000,
            'media': <String, dynamic>{
              'title': <String, dynamic>{'romaji': 'Sousou no Frieren'},
              'coverImage': <String, dynamic>{'large': 'https://x/c.png'},
              'episodes': 28,
              'seasonYear': 2026,
            },
          },
        ],
      ));
      expect(page.hasNextPage, isTrue);
      final AniListAiringEpisode episode = page.episodes.single;
      expect(episode.mediaId, 42);
      expect(episode.episode, 7);
      expect(episode.airingAtSeconds, 1770000000);
      expect(episode.media.displayTitle, 'Sousou no Frieren');
      expect(episode.media.coverUrl, 'https://x/c.png');
    });

    test('returns empty page on malformed body', () {
      expect(parseAniListAiringResponse('not json').episodes, isEmpty);
      expect(parseAniListAiringResponse('{}').episodes, isEmpty);
      expect(parseAniListAiringResponse('{}').hasNextPage, isFalse);
    });

    test('skips entries missing required int fields', () {
      final AniListAiringPage page = parseAniListAiringResponse(_pageBody(
        schedules: <Map<String, dynamic>>[
          <String, dynamic>{'mediaId': 'bad', 'episode': 1, 'airingAt': 2},
          <String, dynamic>{'mediaId': 3, 'episode': 1, 'airingAt': 2},
        ],
      ));
      expect(page.episodes.single.mediaId, 3);
    });
  });

  group('AniListClient.fetchAiringSchedulePage', () {
    test('sends window variables and omits ids when mediaIds is null',
        () async {
      late Map<String, dynamic> captured;
      final AniListClient client = AniListClient(
        client: MockClient((http.Request request) async {
          captured = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(_pageBody(), 200);
        }),
      );
      await client.fetchAiringSchedulePage(
        airingAtGreater: 100,
        airingAtLesser: 200,
      );
      client.close();
      final Map<String, dynamic> variables =
          captured['variables'] as Map<String, dynamic>;
      expect(variables['from'], 100);
      expect(variables['to'], 200);
      expect(variables['page'], 1);
      expect(variables.containsKey('ids'), isFalse);
    });

    test('passes mediaIds and page when provided', () async {
      late Map<String, dynamic> captured;
      final AniListClient client = AniListClient(
        client: MockClient((http.Request request) async {
          captured = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(_pageBody(), 200);
        }),
      );
      await client.fetchAiringSchedulePage(
        airingAtGreater: 100,
        airingAtLesser: 200,
        mediaIds: <int>[9, 5],
        page: 3,
      );
      client.close();
      final Map<String, dynamic> variables =
          captured['variables'] as Map<String, dynamic>;
      expect(variables['ids'], <int>[9, 5]);
      expect(variables['page'], 3);
    });

    test('throws AniListRequestException with status on non-200', () async {
      final AniListClient client = AniListClient(
        client: MockClient(
          (http.Request request) async => http.Response('rate limited', 429),
        ),
      );
      await expectLater(
        client.fetchAiringSchedulePage(airingAtGreater: 0, airingAtLesser: 1),
        throwsA(
          isA<AniListRequestException>()
              .having((AniListRequestException e) => e.statusCode, 'statusCode',
                  429)
              .having(
                (AniListRequestException e) => e.message,
                'message',
                contains('rate limited'),
              ),
        ),
      );
      client.close();
    });

    test('parses a 200 response into episodes', () async {
      final AniListClient client = AniListClient(
        client: MockClient(
          (http.Request request) async => http.Response(
            _pageBody(
              schedules: <Map<String, dynamic>>[
                <String, dynamic>{'mediaId': 1, 'episode': 2, 'airingAt': 3},
              ],
            ),
            200,
          ),
        ),
      );
      final AniListAiringPage page = await client.fetchAiringSchedulePage(
        airingAtGreater: 0,
        airingAtLesser: 10,
      );
      client.close();
      expect(page.episodes.single.episode, 2);
      expect(page.hasNextPage, isFalse);
    });
  });
}
