// AniList 搜索关键词 macron 归一化（BUG：带官方 romaji 长音的番剧名搜不到）。
//
// 根因（curl 实证）：AniList search 索引用双元音拼法（Chuunibyou），对 macron
// 长音（Chūnibyō）不做归一化匹配 → 用户打/复制带 macron 的官方 romaji 得 0
// 结果。normalizeAniListSearch 把 macron 展开成双元音（Chūnibyō→Chuunibyou）让其命中。

import 'dart:convert';

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
      final List<AniListMedia> matches =
          await client.searchAnime('Watashi o Tabetai, Hito de Nashi');
      expect(matches.single.id, 183385);
      expect(requested, <String>[
        'Watashi o Tabetai, Hito de Nashi',
        'Watashi o Tabetai',
      ]);
      client.close();
    });
  });
}
