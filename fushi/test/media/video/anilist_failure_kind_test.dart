// AniList 失败**分类**：把「连不上」与「AniList 官方自己把 API 关了」分开。
//
// 现场实证（2026-09-07，curl 直连与经代理各打一次，结果一致）：
//   POST https://graphql.anilist.co  →  HTTP 403, server: cloudflare
//   {"errors":[{"message":"The AniList API has been temporarily disabled
//               due to severe stability issues.","status":403}]}
// 同一时刻 https://anilist.co/ 返回 200——网站活着，是**公开 API 被官方停用**。
//
// 这类失败此前和「网络不通」共用一句「加载失败」+ 一段英文异常串，并且 UI 一律
// 附送「站点无法直连时，可在下载设置中配置网络代理」。用户于是去折腾代理，而请求
// 其实早已打到 AniList 并被它当面拒绝——配到天亮也好不了。本文件钉死这条判据。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException, Response;
import 'package:http/testing.dart';
import 'package:fushi/src/media/video/anilist_client.dart';

/// AniList 停服时的真实响应体（照抄 2026-09-07 实测原文）。
const String kDisabledBody =
    '{"errors":[{"message":"The AniList API has been temporarily disabled '
    'due to severe stability issues.","status":403,'
    '"locations":[{"line":1,"column":1}]}],"data":null}';

void main() {
  group('classifyAniListHttpFailure', () {
    test('403 + 官方停服文案 = apiDisabled（不是连不上）', () {
      expect(
        classifyAniListHttpFailure(403, kDisabledBody),
        AniListFailureKind.apiDisabled,
      );
    });

    test('403 但正文不是停服文案 = other，不冒认官方停服', () {
      // 真被 WAF / 反爬拦下来也是 403。把它说成「官方停用了 API」同样是误导，
      // 只不过方向相反——所以判据必须是「状态码 + 正文」两者，不能只看 403。
      expect(
        classifyAniListHttpFailure(403, '<html>Attention Required! Cloudflare'),
        AniListFailureKind.other,
      );
    });

    test('429 = rateLimited', () {
      expect(
        classifyAniListHttpFailure(429, 'Too Many Requests'),
        AniListFailureKind.rateLimited,
      );
    });

    test('5xx = other', () {
      expect(
        classifyAniListHttpFailure(502, 'bad gateway'),
        AniListFailureKind.other,
      );
    });
  });

  group('classifyAniListError', () {
    test('传输层异常 = unreachable（这才是该提代理的场合）', () {
      for (final Object error in <Object>[
        const SocketException('offline'),
        TimeoutException('timed out'),
        const HandshakeException('tls failed'),
        ClientException('connection closed'),
      ]) {
        expect(
          classifyAniListError(error),
          AniListFailureKind.unreachable,
          reason: '$error 应判为连不上',
        );
      }
    });

    test('AniListRequestException 按其状态码 + 正文归类', () {
      expect(
        classifyAniListError(const AniListRequestException(403, kDisabledBody)),
        AniListFailureKind.apiDisabled,
      );
      expect(
        classifyAniListError(const AniListRequestException(429, 'slow down')),
        AniListFailureKind.rateLimited,
      );
    });

    test('描述串路径同样认得出停服（searchAnime 折出来的就是串）', () {
      // searchAnime 不抛异常，把逐次失败折成人类可读串。若这条路径认不出停服，
      // 搜番对话框仍会退回「去配代理」的错误建议——分类必须两条路径都成立。
      expect(
        classifyAniListError('HTTP 403: $kDisabledBody'),
        AniListFailureKind.apiDisabled,
      );
    });
  });

  group('searchAnime 把停服如实带给 UI', () {
    test('403 停服 → degraded + kind=apiDisabled + 正文进 failure', () async {
      final AniListClient client = AniListClient(
        client: MockClient((_) async => Response(kDisabledBody, 403)),
      );
      final AniListSearchOutcome outcome = await client.searchAnime('Frieren');
      expect(outcome.degraded, isTrue);
      expect(outcome.kind, AniListFailureKind.apiDisabled);
      expect(
        outcome.failure,
        contains('temporarily disabled'),
        reason: '响应体一旦被折成裸 "HTTP 403"，下游就再也分不出停服与被拦',
      );
      client.close();
    });

    test('429 → kind=rateLimited', () async {
      final AniListClient client = AniListClient(
        client: MockClient((_) async => Response('rate limited', 429)),
      );
      final AniListSearchOutcome outcome = await client.searchAnime('Frieren');
      expect(outcome.kind, AniListFailureKind.rateLimited);
      client.close();
    });

    test('网络不通 → kind=unreachable', () async {
      final AniListClient client = AniListClient(
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      final AniListSearchOutcome outcome = await client.searchAnime('Frieren');
      expect(outcome.kind, AniListFailureKind.unreachable);
      client.close();
    });

    test('成功时 kind 为 null（没有失败就没有类别）', () async {
      final AniListClient client = AniListClient(
        client: MockClient(
          (_) async => Response(
            jsonEncode(<String, dynamic>{
              'data': <String, dynamic>{
                'Page': <String, dynamic>{
                  'media': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 1,
                      'title': <String, dynamic>{'romaji': 'Frieren'},
                    },
                  ],
                },
              },
            }),
            200,
          ),
        ),
      );
      final AniListSearchOutcome outcome = await client.searchAnime('Frieren');
      expect(outcome.degraded, isFalse);
      expect(outcome.kind, isNull);
      client.close();
    });
  });

  group('fetchAiringSchedulePage 抛出的异常自带类别', () {
    test('403 停服 → 异常的 kind 是 apiDisabled', () async {
      final AniListClient client = AniListClient(
        client: MockClient((_) async => Response(kDisabledBody, 403)),
      );
      await expectLater(
        client.fetchAiringSchedulePage(airingAtGreater: 0, airingAtLesser: 1),
        throwsA(
          isA<AniListRequestException>().having(
            (AniListRequestException e) => e.kind,
            'kind',
            AniListFailureKind.apiDisabled,
          ),
        ),
      );
      client.close();
    });
  });
}
