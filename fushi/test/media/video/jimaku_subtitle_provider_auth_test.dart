import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-3000：Jimaku 请求本身的契约——按 https://jimaku.cc/api/docs 的真实响应形状
/// 伪造 HTTP，钉住鉴权头、选中番剧（AniList id）后的检索参数、集数参数，以及
/// 401 不会被吞成「找不到字幕」。
///
/// 401 的 body 形状取自 2026-10-05 对 `GET /api/entries/search` 的匿名实测：
/// `{"error":"unauthorized","code":7}`。
void main() {
  const String apiKey = 'jimaku-test-key';
  // Mirai Nikki（未来日记）的 AniList id。
  const int miraiNikkiAnilistId = 10620;

  VideoSubtitleSearchRequest request({int? episode}) =>
      VideoSubtitleSearchRequest(
        media: VideoMediaReference(
          providerId: 'anilist',
          mediaId: '10620',
          mediaKind: VideoMetadataMediaKind.tv,
          discoveryCategory: VideoDiscoveryCategory.anime,
          title: 'Mirai Nikki',
          anilistId: miraiNikkiAnilistId,
        ),
        episode: episode,
      );

  test('每个请求都带原样的 Authorization 头；按 AniList id 找条目、按集数列文件', () async {
    final List<http.Request> requests = <http.Request>[];
    final MockClient client = MockClient((http.Request req) async {
      requests.add(req);
      if (req.url.path == '/api/entries/search') {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Object?>[
              <String, Object?>{
                'id': 1234,
                'name': 'Mirai Nikki',
                'english_name': 'The Future Diary',
                'japanese_name': '未来日記',
                'anilist_id': miraiNikkiAnilistId,
                'flags': <String, Object?>{
                  'anime': true,
                  'movie': false,
                  'adult': false,
                  'unverified': false,
                  'external': false,
                },
                'last_modified': '2024-01-02T03:04:05.000Z',
              },
            ]),
          ),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      if (req.url.path == '/api/entries/1234/files') {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<Object?>[
              <String, Object?>{
                'url':
                    'https://jimaku.cc/entry/1234/download/'
                    '[Group] Mirai Nikki - 07.ja.srt',
                'name': '[Group] Mirai Nikki - 07.ja.srt',
                'size': 40211,
                'last_modified': '2024-01-02T03:04:05.000Z',
              },
            ]),
          ),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });
    final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
      client: JimakuClient(apiKey: apiKey, client: client),
    );

    final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
        .search(request(episode: 7));

    expect(result.failures, isEmpty);
    expect(result.items.map((VideoSubtitleCandidate c) => c.fileName), <String>[
      '[Group] Mirai Nikki - 07.ja.srt',
    ]);
    // 条目搜索 + 带集号的文件列表 + 不带集号的全表（只为补回整季压缩包）。
    expect(requests, hasLength(3));
    for (final http.Request req in requests) {
      expect(
        req.headers['Authorization'],
        apiKey,
        reason: 'Jimaku 要求 Authorization 直接放 key，不加 Bearer 前缀',
      );
    }
    final Uri search = requests.first.url;
    expect(search.queryParameters['anilist_id'], '$miraiNikkiAnilistId');
    expect(search.queryParameters['anime'], 'true');
    expect(requests[1].url.queryParameters['episode'], '7');
    expect(requests[2].url.queryParameters, isEmpty);
  });

  test('401（key 无效）是带状态码的 unauthorized 失败，不是空结果', () async {
    final MockClient client = MockClient(
      (http.Request req) async => http.Response(
        '{"error":"unauthorized","code":7}',
        401,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    );
    final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
      client: JimakuClient(apiKey: 'wrong-key', client: client),
    );

    final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
        .search(request());

    expect(result.items, isEmpty);
    expect(result.failures, hasLength(1));
    expect(
      result.failures.single.kind,
      ExternalProviderFailureKind.unauthorized,
    );
    expect(result.failures.single.statusCode, 401);
  });
}
