import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_danmaku_source.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  // 让签名相关断言与本机是否已填内置密钥 (dandanplay_secret.dart) 无关：每个用例前
  // 清空内置凭据，用例内需要时再显式注入，用例后恢复。否则填了真值的开发机上「默认
  // 不签名」类断言会失败。
  late String savedEmbeddedId;
  late String savedEmbeddedSecret;
  setUp(() {
    savedEmbeddedId = DandanplayConfig.embeddedAppId;
    savedEmbeddedSecret = DandanplayConfig.embeddedAppSecret;
    DandanplayConfig.embeddedAppId = '';
    DandanplayConfig.embeddedAppSecret = '';
  });
  tearDown(() {
    DandanplayConfig.embeddedAppId = savedEmbeddedId;
    DandanplayConfig.embeddedAppSecret = savedEmbeddedSecret;
  });

  group('DandanplayClient', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_dandanplay_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('computes MD5 from the first 16MiB only', () async {
      final File file = File(p.join(tempDir.path, 'video.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);

      final String hash = await dandanplayFileHash(file);

      expect(hash, '08d6c05a21512a79a1dfeb9d2a8f262f');
    });

    test('exact match posts hash metadata then fetches related comments',
        () async {
      final File file = File(p.join(tempDir.path, 'Episode 01.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final List<http.Request> requests = <http.Request>[];
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((http.Request request) async {
          requests.add(request);
          if (request.url.path == '/api/v2/match') {
            final Map<String, dynamic> body =
                jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['fileName'], 'Episode 01');
            expect(body['fileHash'], '08d6c05a21512a79a1dfeb9d2a8f262f');
            expect(body['fileSize'], 4);
            return http.Response(
              jsonEncode(<String, dynamic>{
                'success': true,
                'isMatched': true,
                'matches': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'episodeId': 42,
                    'animeTitle': 'Demo',
                    'episodeTitle': '01',
                    'shift': 1.5,
                  },
                ],
              }),
              200,
            );
          }
          expect(request.url.path, '/api/v2/comment/42');
          expect(request.url.queryParameters['withRelated'], 'true');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'count': 1,
              'comments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'p': '2.00,1,16777215,100',
                  'm': 'online',
                },
              ],
            }),
            200,
          );
        }),
      );

      final DandanplayFetchResult result =
          await client.fetchBestDanmakuForFile(file);

      expect(result.status, DandanplayFetchStatus.hit);
      expect(result.match?.episodeId, 42);
      expect(result.items, hasLength(1));
      expect(result.items.single.text, 'online');
      expect(result.items.single.startMs, 3500,
          reason: 'match.shift delays fetched comments by seconds');
      expect(requests, hasLength(2));
    });

    test('multiple fuzzy matches degrade to needsSelection without fetching',
        () async {
      final File file = File(p.join(tempDir.path, 'Episode 02.mkv'));
      file.writeAsBytesSync(<int>[1]);
      int commentFetches = 0;
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((http.Request request) async {
          if (request.url.path.startsWith('/api/v2/comment')) {
            commentFetches++;
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'success': true,
              'isMatched': false,
              'matches': <Map<String, dynamic>>[
                <String, dynamic>{'episodeId': 1, 'animeTitle': 'A'},
                <String, dynamic>{'episodeId': 2, 'animeTitle': 'B'},
              ],
            }),
            200,
          );
        }),
      );

      final DandanplayFetchResult result =
          await client.fetchBestDanmakuForFile(file);

      expect(result.status, DandanplayFetchStatus.needsSelection);
      expect(result.matches, hasLength(2));
      expect(result.items, isEmpty);
      expect(commentFetches, 0);
    });

    test('no match and network failure degrade gracefully', () async {
      final File file = File(p.join(tempDir.path, 'Episode 03.mkv'));
      file.writeAsBytesSync(<int>[1]);
      final DandanplayClient noMatchClient = DandanplayClient(
        httpClient: MockClient((_) async => http.Response(
              jsonEncode(<String, dynamic>{
                'success': true,
                'isMatched': false,
                'matches': <Map<String, dynamic>>[],
              }),
              200,
            )),
      );
      final DandanplayFetchResult noMatch =
          await noMatchClient.fetchBestDanmakuForFile(file);
      expect(noMatch.status, DandanplayFetchStatus.noMatch);
      expect(noMatch.items, isEmpty);

      final DandanplayClient failureClient = DandanplayClient(
        httpClient: MockClient((_) async => throw const SocketException('x')),
      );
      final DandanplayFetchResult failure =
          await failureClient.fetchBestDanmakuForFile(file);
      expect(failure.status, DandanplayFetchStatus.networkError);
      expect(failure.items, isEmpty);
    });

    test('comment fetch timeout degrades gracefully', () async {
      final File file = File(p.join(tempDir.path, 'Episode 04.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final DandanplayClient client = DandanplayClient(
        commentTimeout: const Duration(milliseconds: 1),
        httpClient: MockClient((http.Request request) async {
          if (request.url.path == '/api/v2/match') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'success': true,
                'isMatched': true,
                'matches': <Map<String, dynamic>>[
                  <String, dynamic>{'episodeId': 42},
                ],
              }),
              200,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response(
            jsonEncode(<String, dynamic>{'comments': <dynamic>[]}),
            200,
          );
        }),
      );

      final DandanplayFetchResult result =
          await client.fetchBestDanmakuForFile(file);

      expect(result.status, DandanplayFetchStatus.networkError);
      expect(result.items, isEmpty);
    });

    // ---- BUG-1054 回归：拉弹幕的失败必须能被调用方区分，且不与轻量请求共用超时 ----

    test(
        'BUG-1054: comment fetch reports non-2xx as serverError instead of an '
        'empty comment list', () async {
      for (final int code in <int>[403, 404, 500]) {
        final DandanplayClient client = DandanplayClient(
          httpClient: MockClient(
              (http.Request request) async => http.Response('', code)),
        );

        final DandanplayFetchResult result = await client
            .fetchCommentsForMatch(const DandanplayMatch(episodeId: 42));

        expect(result.status, DandanplayFetchStatus.serverError,
            reason: 'HTTP $code 是失败，不是「这一集 0 条弹幕」——'
                '此前一律被压成 const []，手动绑定于是「成功」关面板、零提示');
        expect(result.error, code, reason: '状态码要留在结果里供日志/文案分级');
        expect(result.items, isEmpty);
      }
    });

    test('BUG-1054: comment fetch reports network failure as networkError',
        () async {
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((_) async => throw const SocketException('x')),
      );

      final DandanplayFetchResult result = await client
          .fetchCommentsForMatch(const DandanplayMatch(episodeId: 42));

      expect(result.status, DandanplayFetchStatus.networkError);
      expect(result.items, isEmpty);
    });

    test('BUG-1054: a valid episode with zero comments stays a hit', () async {
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((_) async => http.Response(
              jsonEncode(<String, dynamic>{'comments': <dynamic>[]}),
              200,
            )),
      );

      final DandanplayFetchResult result = await client
          .fetchCommentsForMatch(const DandanplayMatch(episodeId: 42));

      expect(result.status, DandanplayFetchStatus.hit,
          reason: '「该集有效但暂无弹幕」与「拉取失败」是两回事，必须能分开');
      expect(result.items, isEmpty);
    });

    test(
        'BUG-1054: comment fetch uses its own long timeout, not the light-request '
        'one', () async {
      // 直接触发点：搜索/匹配（几 KB）与拉弹幕（withRelated=true，服务端聚合第三方源、
      // 响应体可达数 MB）此前共用同一个 8s；http.get().timeout() 计的是整个响应体下载完
      // 的时间，正片弹幕于是稳定超时 → 用户只看到「弹幕加载失败，请稍后重试」。
      // 只把轻量超时压到 1ms，commentTimeout 用默认值：谁再让拉弹幕复用 _timeout，
      // 本用例立刻红。
      final DandanplayClient client = DandanplayClient(
        timeout: const Duration(milliseconds: 1),
        httpClient: MockClient((http.Request request) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return http.Response(
            jsonEncode(<String, dynamic>{
              'comments': <Map<String, dynamic>>[
                <String, dynamic>{'p': '2.00,1,16777215,100', 'm': 'slow'},
              ],
            }),
            200,
          );
        }),
      );

      final DandanplayFetchResult result = await client
          .fetchCommentsForMatch(const DandanplayMatch(episodeId: 42));

      expect(result.status, DandanplayFetchStatus.hit,
          reason: '拉弹幕比 1ms 的轻量超时慢得多也必须成功——它走默认的 commentTimeout');
      expect(result.items.single.text, 'slow');

      // 对照：同一个 client 下，轻量请求仍受 1ms 约束。
      final DandanplaySearchResult search = await client.searchEpisodes('demo');
      expect(search.status, DandanplayFetchStatus.networkError,
          reason: '搜索仍走 timeout，两档超时确实是分开的');
    });

    test(
        'BUG-1054: fetchBestDanmakuForFile propagates the comment failure '
        'instead of claiming a hit with zero comments', () async {
      final File file = File(p.join(tempDir.path, 'Episode 10.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((http.Request request) async {
          if (request.url.path == '/api/v2/match') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'success': true,
                'isMatched': true,
                'matches': <Map<String, dynamic>>[
                  <String, dynamic>{'episodeId': 42},
                ],
              }),
              200,
            );
          }
          return http.Response('', 403);
        }),
      );

      final DandanplayFetchResult result =
          await client.fetchBestDanmakuForFile(file);

      expect(result.status, DandanplayFetchStatus.serverError,
          reason: '匹配成功但拉弹幕被拒 → 整体是失败，不能报 hit');
      expect(result.match?.episodeId, 42, reason: '已匹配到的集仍要保留供 UI 展示');
      expect(result.items, isEmpty);
    });

    test('comment parser is real Dandanplay JSON parser, not a mocked core',
        () {
      final List<VideoDanmakuItem> items = dandanplayCommentsToDanmaku(
        <Map<String, dynamic>>[
          <String, dynamic>{'p': '1.00,5,255,100', 'm': 'top'},
        ],
        shiftMs: -500,
      );

      expect(items.single.startMs, 500);
      expect(items.single.mode, VideoDanmakuMode.top);
      expect(items.single.colorArgb, 0xFF0000FF);
    });

    test('config base URL routes requests to a self-hosted mirror', () async {
      final File file = File(p.join(tempDir.path, 'Episode 05.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final List<Uri> hits = <Uri>[];
      final DandanplayClient client = DandanplayClient(
        config: const DandanplayConfig(baseUrl: 'https://mirror.example.com'),
        httpClient: MockClient((http.Request request) async {
          hits.add(request.url);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'success': true,
              'isMatched': true,
              'matches': <Map<String, dynamic>>[
                <String, dynamic>{'episodeId': 7},
              ],
            }),
            200,
          );
        }),
      );

      await client.matchFile(file);

      expect(hits.single.host, 'mirror.example.com');
      expect(hits.single.scheme, 'https');
      expect(hits.single.path, '/api/v2/match');
    });

    test('signed config attaches X-AppId / X-Timestamp / X-Signature headers',
        () async {
      final File file = File(p.join(tempDir.path, 'Episode 06.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final List<http.Request> requests = <http.Request>[];
      final DandanplayClient client = DandanplayClient(
        config: const DandanplayConfig(
          appId: 'my-app',
          appSecret: 'my-secret',
        ),
        httpClient: MockClient((http.Request request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'success': true,
              'isMatched': true,
              'matches': <Map<String, dynamic>>[
                <String, dynamic>{'episodeId': 9},
              ],
            }),
            200,
          );
        }),
      );

      await client.matchFile(file);

      final http.Request signed = requests.single;
      expect(signed.headers['X-AppId'], 'my-app');
      final String? ts = signed.headers['X-Timestamp'];
      expect(ts, isNotNull);
      // Recompute the documented signature: Base64(SHA256(AppId+TS+Path+Secret)).
      final List<int> payload =
          utf8.encode('my-app$ts/api/v2/match' 'my-secret');
      final String expected = base64.encode(sha256.convert(payload).bytes);
      expect(signed.headers['X-Signature'], expected);
    });

    test('unsigned (default) config sends no signature headers', () async {
      final File file = File(p.join(tempDir.path, 'Episode 07.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final List<http.Request> requests = <http.Request>[];
      final DandanplayClient client = DandanplayClient(
        config: DandanplayConfig.defaults,
        httpClient: MockClient((http.Request request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'success': true,
              'isMatched': true,
              'matches': <Map<String, dynamic>>[
                <String, dynamic>{'episodeId': 11},
              ],
            }),
            200,
          );
        }),
      );

      await client.matchFile(file);

      final http.Request request = requests.single;
      expect(request.headers.containsKey('X-AppId'), isFalse);
      expect(request.headers.containsKey('X-Signature'), isFalse);
      expect(request.url.host, 'api.dandanplay.net');
    });

    test('embedded app credentials sign requests when user config is unsigned',
        () async {
      // 内置官方凭据（编译期从 dandanplay_secret.dart 注入）让默认配置也签名，
      // 用户无需手动输入 API —— 本 feature 的核心行为。
      DandanplayConfig.embeddedAppId = 'builtin-app';
      DandanplayConfig.embeddedAppSecret = 'builtin-secret';
      final File file = File(p.join(tempDir.path, 'Episode 08.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final List<http.Request> requests = <http.Request>[];
      final DandanplayClient client = DandanplayClient(
        config: DandanplayConfig.defaults,
        httpClient: MockClient((http.Request request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'success': true,
              'isMatched': true,
              'matches': <Map<String, dynamic>>[
                <String, dynamic>{'episodeId': 13},
              ],
            }),
            200,
          );
        }),
      );

      await client.matchFile(file);

      final http.Request request = requests.single;
      expect(request.headers['X-AppId'], 'builtin-app',
          reason: '内置凭据让默认（空）配置也签名，用户无需手动输入 API');
      final String? ts = request.headers['X-Timestamp'];
      expect(ts, isNotNull);
      final List<int> payload =
          utf8.encode('builtin-app$ts/api/v2/match' 'builtin-secret');
      expect(request.headers['X-Signature'],
          base64.encode(sha256.convert(payload).bytes));
    });

    test('user AppId/AppSecret override the embedded credentials', () async {
      DandanplayConfig.embeddedAppId = 'builtin-app';
      DandanplayConfig.embeddedAppSecret = 'builtin-secret';
      final File file = File(p.join(tempDir.path, 'Episode 09.mkv'));
      file.writeAsBytesSync(<int>[1, 2, 3, 4]);
      final List<http.Request> requests = <http.Request>[];
      final DandanplayClient client = DandanplayClient(
        config: const DandanplayConfig(appId: 'mine', appSecret: 'mysecret'),
        httpClient: MockClient((http.Request request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'success': true,
              'isMatched': true,
              'matches': <Map<String, dynamic>>[
                <String, dynamic>{'episodeId': 14},
              ],
            }),
            200,
          );
        }),
      );

      await client.matchFile(file);

      expect(requests.single.headers['X-AppId'], 'mine',
          reason: '用户显式配置的 AppId 优先于内置凭据');
    });
  });

  group('DandanplayConfig', () {
    test('round-trips through encode/decode', () {
      const DandanplayConfig config = DandanplayConfig(
        baseUrl: 'http://10.0.0.1:8080',
        appId: 'a',
        appSecret: 'b',
      );
      expect(DandanplayConfig.decode(DandanplayConfig.encode(config)), config);
      expect(DandanplayConfig.decode(''), DandanplayConfig.defaults);
      expect(DandanplayConfig.decode('not-json'), DandanplayConfig.defaults);
    });

    test('resolvedBaseUri falls back to official for empty / invalid URLs', () {
      expect(const DandanplayConfig().resolvedBaseUri,
          Uri.parse(DandanplayConfig.officialBaseUrl));
      expect(const DandanplayConfig(baseUrl: 'not a url').resolvedBaseUri,
          Uri.parse(DandanplayConfig.officialBaseUrl));
      expect(const DandanplayConfig(baseUrl: 'ftp://x').resolvedBaseUri,
          Uri.parse(DandanplayConfig.officialBaseUrl));
      final Uri custom =
          const DandanplayConfig(baseUrl: 'https://m.example.com/api/v2/x')
              .resolvedBaseUri;
      // Strips any user-supplied path; only scheme + host (+ port) survive.
      expect(custom.scheme, 'https');
      expect(custom.host, 'm.example.com');
      expect(custom.path, '');
    });

    test('isSigned only when both AppId and AppSecret are present', () {
      // 内置凭据在此组已被顶层 setUp 清空，故这里纯测用户配置自身语义。
      expect(const DandanplayConfig().isSigned, isFalse);
      expect(const DandanplayConfig(appId: 'a').isSigned, isFalse);
      expect(const DandanplayConfig(appSecret: 'b').isSigned, isFalse);
      expect(
          const DandanplayConfig(appId: 'a', appSecret: 'b').isSigned, isTrue);
    });

    test('effective credentials fall back to embedded, user config overrides',
        () {
      DandanplayConfig.embeddedAppId = 'e-app';
      DandanplayConfig.embeddedAppSecret = 'e-secret';
      const DandanplayConfig empty = DandanplayConfig();
      expect(empty.effectiveAppId, 'e-app');
      expect(empty.effectiveAppSecret, 'e-secret');
      expect(empty.isSigned, isTrue, reason: '内置凭据非空时，空用户配置也算已签名（开箱即用）');

      const DandanplayConfig user =
          DandanplayConfig(appId: 'u-app', appSecret: 'u-secret');
      expect(user.effectiveAppId, 'u-app');
      expect(user.effectiveAppSecret, 'u-secret');

      // 只填一半：用户 AppId + 内置 AppSecret 也能凑齐生效凭据。
      const DandanplayConfig halfUser = DandanplayConfig(appId: 'u-app');
      expect(halfUser.effectiveAppId, 'u-app');
      expect(halfUser.effectiveAppSecret, 'e-secret');
      expect(halfUser.isSigned, isTrue);
    });

    test('signatureHeaders match the documented SHA256 scheme', () {
      const DandanplayConfig config =
          DandanplayConfig(appId: 'app', appSecret: 'sec');
      final DateTime now = DateTime.utc(2026, 1, 1, 0, 0, 0);
      final Map<String, String> headers =
          config.signatureHeaders('/api/v2/comment/42', now: now);
      final int ts = now.millisecondsSinceEpoch ~/ 1000;
      expect(headers['X-AppId'], 'app');
      expect(headers['X-Timestamp'], '$ts');
      final List<int> payload = utf8.encode('app$ts/api/v2/comment/42' 'sec');
      expect(
          headers['X-Signature'], base64.encode(sha256.convert(payload).bytes));
      // Unsigned config yields no headers at all.
      expect(const DandanplayConfig().signatureHeaders('/x'), isEmpty);
    });
  });

  group('DandanplayClient.searchEpisodes', () {
    test('parses animes and their episodes on a successful search', () async {
      final List<http.Request> requests = <http.Request>[];
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((http.Request request) async {
          requests.add(request);
          expect(request.url.path, '/api/v2/search/episodes');
          expect(request.url.queryParameters['anime'], 'demo');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'success': true,
              'animes': <Map<String, dynamic>>[
                <String, dynamic>{
                  'animeId': 7,
                  'animeTitle': 'Demo Show',
                  'typeDescription': 'TV',
                  'episodes': <Map<String, dynamic>>[
                    <String, dynamic>{'episodeId': 71, 'episodeTitle': '01'},
                    <String, dynamic>{'episodeId': 72, 'episodeTitle': '02'},
                  ],
                },
              ],
            }),
            200,
          );
        }),
      );

      final DandanplaySearchResult result = await client.searchEpisodes('demo');

      expect(result.status, DandanplayFetchStatus.hit);
      expect(result.animes, hasLength(1));
      expect(result.animes.single.animeId, 7);
      expect(result.animes.single.animeTitle, 'Demo Show');
      expect(result.animes.single.episodes, hasLength(2));
      expect(result.animes.single.episodes.first.episodeId, 71);
      expect(result.animes.single.episodes.last.episodeTitle, '02');
      expect(requests, hasLength(1));
    });

    test('empty keyword short-circuits with noMatch and no request', () async {
      int calls = 0;
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((http.Request request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      final DandanplaySearchResult result = await client.searchEpisodes('   ');
      expect(result.status, DandanplayFetchStatus.noMatch);
      expect(calls, 0);
    });

    test('empty animes list degrades to noMatch', () async {
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((http.Request request) async {
          return http.Response(
            jsonEncode(
                <String, dynamic>{'success': true, 'animes': <dynamic>[]}),
            200,
          );
        }),
      );
      final DandanplaySearchResult result =
          await client.searchEpisodes('nothing');
      expect(result.status, DandanplayFetchStatus.noMatch);
      expect(result.animes, isEmpty);
    });

    test('network failure surfaces as networkError', () async {
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((http.Request request) async {
          throw const SocketException('offline');
        }),
      );
      final DandanplaySearchResult result = await client.searchEpisodes('demo');
      expect(result.status, DandanplayFetchStatus.networkError);
    });
  });
}
