// AniList 搜索关键词 macron 归一化（BUG：带官方 romaji 长音的番剧名搜不到）。
//
// 根因（curl 实证）：AniList search 索引用双元音拼法（Chuunibyou），对 macron
// 长音（Chūnibyō）不做归一化匹配 → 用户打/复制带 macron 的官方 romaji 得 0
// 结果。normalizeAniListSearch 把 macron 展开成双元音（Chūnibyō→Chuunibyou）让其命中。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show Response;
import 'package:http/testing.dart';
import 'package:fushi/src/media/video/anilist_client.dart';

void main() {
  group('normalizeAniListSearch', () {
    test('strips macron vowels to their base latin letters', () {
      // 用户复制的官方 romaji（带 macron）→ AniList 认得的拼法基础。
      expect(normalizeAniListSearch('Chūnibyō Demo Koi ga Shitai!'),
          'Chuunibyou Demo Koi ga Shitai!');
      expect(normalizeAniListSearch('Tōkyō Gūru'), 'Toukyou Guuru');
      expect(normalizeAniListSearch('Frieren'), 'Frieren'); // no-op
    });

    test('handles all five long vowels, both cases', () {
      expect(normalizeAniListSearch('ĀāĒēĪīŌōŪū'), 'AaaaEeeeIiiiOuouUuuu');
    });

    test('drops combining macron (NFD decomposed form, U+0304)', () {
      // 分解形式：字母 + U+0304（combining macron）→ 基础字母（丢弃 macron）。
      expect(normalizeAniListSearch('Chūnibyō'), 'Chuunibyoo');
    });

    test('empty / plain queries are unchanged', () {
      expect(normalizeAniListSearch(''), '');
      expect(normalizeAniListSearch('bocchi the rock'), 'bocchi the rock');
    });
  });

  group('AniList title fallbacks', () {
    test('keeps the full title then retries the leading comma segment', () {
      expect(
        aniListSearchQueries('Watashi o Tabetai, Hito de Nashi'),
        <String>[
          'Watashi o Tabetai, Hito de Nashi',
          'Watashi o Tabetai',
        ],
      );
    });

    test('retries a conservative fallback only after an empty response',
        () async {
      final List<String> requested = <String>[];
      final MockClient mock = MockClient((request) async {
        final Map<String, dynamic> payload =
            jsonDecode(request.body) as Map<String, dynamic>;
        final String query =
            (payload['variables'] as Map<String, dynamic>)['search'] as String;
        requested.add(query);
        if (query != 'Watashi o Tabetai') {
          return Response(
            jsonEncode(<String, dynamic>{
              'data': <String, dynamic>{
                'Page': <String, dynamic>{'media': <dynamic>[]},
              },
            }),
            200,
          );
        }
        return Response(
          jsonEncode(<String, dynamic>{
            'data': <String, dynamic>{
              'Page': <String, dynamic>{
                'media': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 183385,
                    'title': <String, dynamic>{
                      'romaji': 'Watashi wo Tabetai, Hitodenashi',
                    },
                  },
                ],
              },
            },
          }),
          200,
        );
      });
      final AniListClient client = AniListClient(client: mock);
      final AniListSearchOutcome outcome =
          await client.searchAnime('Watashi o Tabetai, Hito de Nashi');
      expect(outcome.media.single.id, 183385);
      expect(outcome.degraded, isFalse);
      expect(requested, <String>[
        'Watashi o Tabetai, Hito de Nashi',
        'Watashi o Tabetai',
      ]);
      client.close();
    });
  });

  // BUG-1782：「AniList 说没有这部番」与「这次根本没问上」此前共用同一个空列表，
  // 调用方只能一律当「没搜到」。下游 Jimaku 因此在限流时静默退化成纯文本搜索，把同
  // 系列所有季平铺给用户；AniList 恢复后又自己好了——用户报「更新之后筛选怎么坏了」
  // 「起了怪了，现在又行了，不知如何触发」。这一组锁住两者不再等价。
  group('AniListSearchOutcome 区分「查无此番」与「没问上」(BUG-1782)', () {
    Response ok(List<Map<String, dynamic>> media) => Response(
          jsonEncode(<String, dynamic>{
            'data': <String, dynamic>{
              'Page': <String, dynamic>{'media': media},
            },
          }),
          200,
        );

    test('200 空结果 = AniList 明确答了没有，不是降级', () async {
      final AniListClient client = AniListClient(
        client: MockClient((_) async => ok(<Map<String, dynamic>>[])),
      );
      final AniListSearchOutcome outcome = await client.searchAnime('Yuru Yuri');
      expect(outcome.media, isEmpty);
      expect(outcome.degraded, isFalse,
          reason: '真的没这部番时不该报降级，否则每次搜不到都在吓唬用户');
      client.close();
    });

    test('429 限流 = 降级，且带得出原因', () async {
      final AniListClient client = AniListClient(
        client: MockClient((_) async => Response('rate limited', 429)),
      );
      final AniListSearchOutcome outcome = await client.searchAnime('Yuru Yuri');
      expect(outcome.media, isEmpty);
      expect(outcome.degraded, isTrue,
          reason: '429 此前被吞成空列表，与「查无此番」无法区分——正是本 bug 的根因；'
              '放送日历页共用同一个 client 按 perPage:50 翻页，很容易把配额烧掉');
      expect(outcome.failure, contains('429'));
      client.close();
    });

    test('网络异常 = 降级', () async {
      final AniListClient client = AniListClient(
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      final AniListSearchOutcome outcome = await client.searchAnime('Yuru Yuri');
      expect(outcome.degraded, isTrue);
      client.close();
    });

    test('先失败后成功：只要有一次问上了就不报降级', () async {
      // 第一个查询词 500，回退查询词 200 且有结果 → 链路是通的，不该吓唬用户。
      int calls = 0;
      final AniListClient client = AniListClient(
        client: MockClient((_) async {
          calls++;
          if (calls == 1) return Response('boom', 500);
          return ok(<Map<String, dynamic>>[
            <String, dynamic>{
              'id': 10495,
              'title': <String, dynamic>{'romaji': 'Yuru Yuri'},
            },
          ]);
        }),
      );
      final AniListSearchOutcome outcome =
          await client.searchAnime('Yuru Yuri, Nachuyachumi');
      expect(outcome.media.single.id, 10495);
      expect(outcome.degraded, isFalse);
      client.close();
    });

    test('先成功答没有、后一个回退查询 429：仍不报降级', () async {
      // anySuccess 而不是 lastFailure 决定：AniList 已经明确答过一次「没有」，
      // 后续保守回退词的失败不该被翻译成「结果不可信」。
      int calls = 0;
      final AniListClient client = AniListClient(
        client: MockClient((_) async {
          calls++;
          if (calls == 1) return ok(<Map<String, dynamic>>[]);
          return Response('rate limited', 429);
        }),
      );
      final AniListSearchOutcome outcome =
          await client.searchAnime('Yuru Yuri, Nachuyachumi');
      expect(calls, greaterThan(1), reason: '这条用例要求真的走到第二个回退查询词');
      expect(outcome.media, isEmpty);
      expect(outcome.degraded, isFalse);
      client.close();
    });
  });
}
