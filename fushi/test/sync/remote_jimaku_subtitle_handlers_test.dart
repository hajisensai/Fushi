import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/sync/remote_jimaku_subtitle_handlers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 「Jimaku 查字幕」扩展桥（/api/subtitle/jimaku/search + /fetch 的共享 handler）契约：
/// - Jimaku 的 `anime` 是硬相等过滤且服务端默认 true：anime 缺省时空结果必须显式
///   `anime=false` 补搜（否则 U-Next 主力的真人剧/日剧永远 0 结果）；
/// - 无 API key 回 no-api-key（扩展提示去 app 设置里填），不是含糊的空结果；
/// - fetch 响应与 /api/subtitle/parse 同形（format+cues），扩展 InstallTrack 零改动。
void main() {
  const String srt = '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n';

  MockClient jimakuMock({
    required Map<String, List<Map<String, dynamic>>> entriesByAnimeParam,
    List<Map<String, dynamic>> files = const <Map<String, dynamic>>[],
    List<Uri>? seenUris,
  }) {
    return MockClient((http.Request request) async {
      seenUris?.add(request.url);
      final String path = request.url.path;
      if (path.endsWith('/entries/search')) {
        final String animeParam = request.url.queryParameters['anime'] ?? '';
        return http.Response(
          jsonEncode(entriesByAnimeParam[animeParam] ?? <Object>[]),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      if (path.contains('/entries/') && path.endsWith('/files')) {
        return http.Response(
          jsonEncode(files),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      if (path.endsWith('/download.srt')) {
        return http.Response.bytes(utf8.encode(srt), 200);
      }
      return http.Response('not found', 404);
    });
  }

  group('JimakuClient.buildEntrySearchParams', () {
    test('anime 缺省不带参数；true/false 显式透传', () {
      expect(
        JimakuClient.buildEntrySearchParams(<String, String>{'query': 'x'}),
        <String, String>{'query': 'x'},
      );
      expect(
        JimakuClient.buildEntrySearchParams(
          <String, String>{'query': 'x'},
          anime: false,
        ),
        <String, String>{'query': 'x', 'anime': 'false'},
      );
      expect(
        JimakuClient.buildEntrySearchParams(
          <String, String>{'anilist_id': '1'},
          anime: true,
        ),
        <String, String>{'anilist_id': '1', 'anime': 'true'},
      );
    });
  });

  group('buildJimakuSearchResponse', () {
    test('无 API key → no-api-key', () async {
      final Map<String, dynamic> res = await buildJimakuSearchResponse(
        <String, dynamic>{'query': 'ドラマ'},
        clientProvider: () => null,
        rememberCandidate: (_, __) => fail('不应记录候选'),
      );
      expect(res['ok'], isFalse);
      expect(res['error'], 'no-api-key');
    });

    test('query 与 anilistId 都缺 → missing-query', () async {
      final Map<String, dynamic> res = await buildJimakuSearchResponse(
        <String, dynamic>{},
        clientProvider: () => JimakuClient(
            apiKey: 'k', client: jimakuMock(entriesByAnimeParam: {})),
        rememberCandidate: (_, __) {},
      );
      expect(res['error'], 'missing-query');
    });

    test('anime 缺省时默认搜为空 → 显式 anime=false 补搜命中真人剧', () async {
      final List<Uri> seen = <Uri>[];
      final JimakuClient client = JimakuClient(
        apiKey: 'k',
        client: jimakuMock(
          entriesByAnimeParam: <String, List<Map<String, dynamic>>>{
            // 默认（不带 anime 参数）：空；显式 anime=false：命中日剧条目。
            '': <Map<String, dynamic>>[],
            'false': <Map<String, dynamic>>[
              <String, dynamic>{'id': 7, 'name': '日剧タイトル'},
            ],
          },
          files: <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'ep01.ja.srt',
              'url': 'https://jimaku.cc/dl/download.srt',
              'size': 100,
            },
          ],
          seenUris: seen,
        ),
      );
      final Map<String, RemoteJimakuCandidate> remembered =
          <String, RemoteJimakuCandidate>{};
      final Map<String, dynamic> res = await buildJimakuSearchResponse(
        <String, dynamic>{'query': '日剧タイトル'},
        clientProvider: () => client,
        rememberCandidate: (String handle, RemoteJimakuCandidate c) =>
            remembered[handle] = c,
      );
      expect(res['ok'], isTrue);
      final List<dynamic> candidates = res['candidates'] as List<dynamic>;
      expect(candidates, hasLength(1));
      final Map<String, dynamic> first =
          candidates.first as Map<String, dynamic>;
      expect(first['handle'], 'jimaku:7:ep01.ja.srt');
      expect(first['entryName'], '日剧タイトル');
      expect(remembered, contains('jimaku:7:ep01.ja.srt'));
      // 真的发过一次 anime=false 的补搜。
      expect(
        seen.any((Uri u) => u.queryParameters['anime'] == 'false'),
        isTrue,
        reason: '缺省空结果必须显式 anime=false 补搜，否则真人剧永远 0 结果',
      );
    });

    test('显式 anime=false 直达，不做二次补搜', () async {
      final List<Uri> seen = <Uri>[];
      final JimakuClient client = JimakuClient(
        apiKey: 'k',
        client: jimakuMock(
          entriesByAnimeParam: <String, List<Map<String, dynamic>>>{
            'false': <Map<String, dynamic>>[],
          },
          seenUris: seen,
        ),
      );
      final Map<String, dynamic> res = await buildJimakuSearchResponse(
        <String, dynamic>{'query': 'x', 'anime': false},
        clientProvider: () => client,
        rememberCandidate: (_, __) {},
      );
      expect(res['ok'], isTrue);
      expect(res['candidates'], isEmpty);
      expect(
        seen.where((Uri u) => u.path.endsWith('/entries/search')).length,
        1,
        reason: '调用方已显式指定 anime，空结果不再补搜',
      );
    });

    test('401 → unauthorized', () async {
      final JimakuClient client = JimakuClient(
        apiKey: 'bad',
        client: MockClient((_) async => http.Response('denied', 401)),
      );
      final Map<String, dynamic> res = await buildJimakuSearchResponse(
        <String, dynamic>{'query': 'x'},
        clientProvider: () => client,
        rememberCandidate: (_, __) {},
      );
      expect(res['ok'], isFalse);
      expect(res['error'], 'unauthorized');
    });
  });

  group('buildJimakuFetchResponse', () {
    RemoteJimakuCandidate candidate() => RemoteJimakuCandidate(
          entryId: 7,
          entryName: '日剧タイトル',
          fileName: 'ep01.ja.srt',
          fileUrl: 'https://jimaku.cc/dl/download.srt',
          language: 'ja',
        );

    test('未知 handle → unknown-handle（缓存过期/app 重启后扩展重搜即可恢复）', () async {
      final Map<String, dynamic> res = await buildJimakuFetchResponse(
        <String, dynamic>{'handle': 'jimaku:1:gone.srt'},
        clientProvider: () => JimakuClient(
            apiKey: 'k', client: jimakuMock(entriesByAnimeParam: {})),
        resolveCandidate: (_) => null,
      );
      expect(res['ok'], isFalse);
      expect(res['error'], 'unknown-handle');
    });

    test('下载 + 解析：响应与 /api/subtitle/parse 同形（format+cues）', () async {
      final Map<String, dynamic> res = await buildJimakuFetchResponse(
        <String, dynamic>{'handle': 'jimaku:7:ep01.ja.srt'},
        clientProvider: () => JimakuClient(
            apiKey: 'k', client: jimakuMock(entriesByAnimeParam: {})),
        resolveCandidate: (_) => candidate(),
      );
      expect(res['ok'], isTrue);
      expect(res['filename'], 'ep01.ja.srt');
      expect(res['language'], 'ja');
      expect(res['format'], 'srt');
      final List<dynamic> cues = res['cues'] as List<dynamic>;
      expect(cues, hasLength(1));
      final Map<String, dynamic> cue = cues.first as Map<String, dynamic>;
      expect(cue['text'], 'こんにちは');
      expect(cue['startMs'], 1000);
      expect(cue['endMs'], 2000);
    });
  });
}
