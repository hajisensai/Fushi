import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 哆啦A梦剧场版搜不到 / 自动补不上字幕（2026-10-23 用真 key 实测复现）：
///
/// - Jimaku 配额每 key 25 次请求一个窗口；回退词「Doraemon」一次搜出 62 个条目，
///   provider 逐条列文件（每条 1~2 次）→ 第一个 429 让整次搜索作废（面板「HTTP 429」）；
/// - TMDB 日文标题带「映画」前缀，Jimaku 模糊搜索带前缀零命中，去掉才命中；
/// - 只刮了 TMDB 的动画电影被判成真人（movie 分类），只搜 `anime=false` 永远搜不到。
///
/// 这里用与实测同形的假 Jimaku 钉住三条修复，并数请求数。

/// 62 个「Doraemon」条目，正确的那一条（3592）排在中间，与实测顺序同形。
String _doraemonEntries() {
  final List<Map<String, Object?>> entries = <Map<String, Object?>>[
    for (int i = 0; i < 62; i++)
      <String, Object?>{
        'id': 9000 + i,
        'name': 'Doraemon: Nobita no Other Movie $i',
        'japanese_name': 'ドラえもん のび太の別の映画$i',
        'flags': <String, Object?>{'anime': true, 'movie': true},
      },
  ];
  entries[21] = <String, Object?>{
    'id': 3592,
    'name': 'Doraemon: Nobita no Wan Nyan Jikuuden',
    'english_name': "Doraemon: Nobita's Wannyan Space-Time Legend",
    'japanese_name': 'ドラえもん のび太のワンニャン時空伝',
    'anilist_id': 2656,
    'flags': <String, Object?>{'anime': true, 'movie': true},
  };
  return jsonEncode(entries);
}

const String _wanNyanJa = 'ドラえもん のび太のワンニャン時空伝';

String _wanNyanEntry() => jsonEncode(<Map<String, Object?>>[
  <String, Object?>{
    'id': 3592,
    'name': 'Doraemon: Nobita no Wan Nyan Jikuuden',
    'japanese_name': _wanNyanJa,
    'flags': <String, Object?>{'anime': true, 'movie': true},
  },
]);

const String _wanNyanFiles =
    '[{"name":"[Conan06] Eiga Doraemon - 25 Nobita no '
    'Wan-Nyan Jikuuden (2004).jpn.ass","url":"http://x/1"},'
    '{"name":"映画ドラえもん.のび太のワンニャン時空伝.WEBRip.Netflix.ja[cc].srt",'
    '"url":"http://x/2"}]';

VideoMediaReference _movie({
  required VideoDiscoveryCategory category,
  String title = '映画ドラえもん のび太のワンニャン時空伝',
}) => VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '192904',
  mediaKind: VideoMetadataMediaKind.movie,
  discoveryCategory: category,
  title: title,
  tmdbId: 192904,
  episode: 25,
);

void main() {
  group('jimakuQueryVariants', () {
    test('剧场版前缀生成去前缀变体，紧跟原词', () {
      expect(
        jimakuQueryVariants(<String>[
          '映画ドラえもん のび太のワンニャン時空伝',
          'Doraemon',
          '劇場版 名探偵コナン',
        ]),
        <String>[
          '映画ドラえもん のび太のワンニャン時空伝',
          _wanNyanJa,
          'Doraemon',
          '劇場版 名探偵コナン',
          '名探偵コナン',
        ],
      );
    });

    test('空词丢弃、重复去重；不带前缀原样', () {
      expect(
        jimakuQueryVariants(<String>[' ', 'K-ON!', 'K-ON!', '映画']),
        <String>['K-ON!', '映画'],
      );
    });
  });

  group('JimakuVideoSubtitleProvider 不打穿配额', () {
    test('泛化回退词搜出 62 个条目：只列最像的几个，且选中正确条目', () async {
      final List<String> calls = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        final String path = req.url.path;
        if (path.endsWith('/files')) {
          calls.add('files:$path:${req.url.query}');
          if (path.contains('/3592/')) {
            return http.Response.bytes(utf8.encode(_wanNyanFiles), 200);
          }
          return http.Response('[]', 200);
        }
        final String query = req.url.queryParameters['query'] ?? '';
        calls.add('search:$query:${req.url.queryParameters['anime']}');
        if (query == 'Doraemon') {
          return http.Response.bytes(utf8.encode(_doraemonEntries()), 200);
        }
        return http.Response('[]', 200);
      });
      final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
        client: JimakuClient(apiKey: 'k', client: client),
      );

      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(
            VideoSubtitleSearchRequest(
              media: _movie(category: VideoDiscoveryCategory.anime),
              alternateTitles: const <String>['Doraemon'],
              episode: 25,
            ),
          );

      expect(result.failures, isEmpty);
      expect(
        result.items.map((VideoSubtitleCandidate c) => c.collectionId).toSet(),
        <String>{'3592'},
      );
      final int fileCalls = calls
          .where((String c) => c.startsWith('files:'))
          .length;
      expect(
        fileCalls,
        lessThanOrEqualTo(kJimakuMaxEntriesPerSearch),
        reason: '62 个条目逐条列文件会把 25 次/窗口的配额当场打穿：$calls',
      );
      // 电影条目不带集号：「Movie 25」不是第 25 集，也不再补列整季包。
      expect(
        calls.where(
          (String c) => c.startsWith('files:') && c.contains('episode'),
        ),
        isEmpty,
      );
    });

    test('「映画」前缀零命中时用去前缀变体命中，总请求数是个位数', () async {
      final List<String> calls = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        if (req.url.path.endsWith('/files')) {
          calls.add('files');
          return http.Response.bytes(utf8.encode(_wanNyanFiles), 200);
        }
        final Map<String, String> p = req.url.queryParameters;
        final String query = p['query'] ?? '';
        calls.add(
          p.containsKey('tmdb_id')
              ? 'tmdb:${p['tmdb_id']}:${p['anime']}'
              : 'search:$query:${p['anime']}',
        );
        if (query == _wanNyanJa) {
          return http.Response.bytes(utf8.encode(_wanNyanEntry()), 200);
        }
        return http.Response('[]', 200);
      });
      final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
        client: JimakuClient(apiKey: 'k', client: client),
      );

      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(
            VideoSubtitleSearchRequest(
              media: _movie(category: VideoDiscoveryCategory.anime),
              alternateTitles: const <String>['Doraemon'],
            ),
          );

      expect(result.items, hasLength(2));
      // 「Doraemon」那一档根本走不到：变体紧跟原词，先命中就停。
      expect(calls, <String>[
        'tmdb:movie:192904:true',
        'search:映画ドラえもん のび太のワンニャン時空伝:true',
        'search:$_wanNyanJa:true',
        'files',
      ]);
    });

    test('只刮了 TMDB 的动画电影（movie 分类）：真人档空了再搜动画档', () async {
      final List<String> calls = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        if (req.url.path.endsWith('/files')) {
          return http.Response.bytes(utf8.encode(_wanNyanFiles), 200);
        }
        final Map<String, String> p = req.url.queryParameters;
        final String key = p.containsKey('tmdb_id')
            ? 'tmdb:${p['tmdb_id']}'
            : 'query:${p['query']}';
        calls.add('$key:${p['anime']}');
        if (p['query'] == _wanNyanJa && p['anime'] == 'true') {
          return http.Response.bytes(utf8.encode(_wanNyanEntry()), 200);
        }
        return http.Response('[]', 200);
      });
      final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
        client: JimakuClient(apiKey: 'k', client: client),
      );

      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(
            VideoSubtitleSearchRequest(
              media: _movie(category: VideoDiscoveryCategory.movie),
            ),
          );

      expect(result.items, isNotEmpty);
      expect(calls, <String>[
        'tmdb:movie:192904:false',
        'tmdb:movie:192904:true',
        'query:映画ドラえもん のび太のワンニャン時空伝:false',
        'query:映画ドラえもん のび太のワンニャン時空伝:true',
        'query:$_wanNyanJa:false',
        'query:$_wanNyanJa:true',
      ]);
    });

    test('后面的条目被限流：保留已拿到的候选并如实报部分失败', () async {
      final List<Map<String, Object?>> entries = <Map<String, Object?>>[
        for (int i = 1; i <= 3; i++)
          <String, Object?>{'id': i, 'name': 'Show $i'},
      ];
      final MockClient client = MockClient((http.Request req) async {
        if (req.url.path.endsWith('/files')) {
          if (req.url.path.contains('/entries/1/')) {
            return http.Response(
              '[{"name":"Show 01.ja.srt","url":"http://x/1"}]',
              200,
            );
          }
          return http.Response('{"error":"rate limited"}', 429);
        }
        return http.Response(jsonEncode(entries), 200);
      });
      final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
        client: JimakuClient(apiKey: 'k', client: client),
      );

      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(VideoSubtitleSearchRequest(query: 'Show', anime: true));

      expect(result.items.single.fileName, 'Show 01.ja.srt');
      expect(result.isPartial, isTrue);
      expect(
        result.failures.single.kind,
        ExternalProviderFailureKind.rateLimited,
      );
    });

    test('首个条目就被限流：整次搜索失败（不是「没有字幕」）', () async {
      final MockClient client = MockClient((http.Request req) async {
        if (req.url.path.endsWith('/files')) {
          return http.Response('{"error":"rate limited"}', 429);
        }
        return http.Response('[{"id":1,"name":"Show"}]', 200);
      });
      final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
        client: JimakuClient(apiKey: 'k', client: client),
      );

      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(VideoSubtitleSearchRequest(query: 'Show', anime: true));

      expect(result.isTotalFailure, isTrue);
      expect(result.failures.single.statusCode, 429);
    });
  });
}
