import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/ai/web_search.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('WebSearchConfig', () {
    test('tryParse 好 JSON', () {
      final WebSearchConfig? c = WebSearchConfig.tryParse(
        '{"kind":"searxng","endpoint":" https://s.example.org ","apiKey":""}',
      );
      expect(c, isNotNull);
      expect(c!.kind, WebSearchKind.searxng);
      expect(c.endpoint, 'https://s.example.org');
      expect(c.apiKey, isNull);
      expect(c.isUsable, isTrue);
    });

    test('tryParse 坏输入 -> null', () {
      expect(WebSearchConfig.tryParse(null), isNull);
      expect(WebSearchConfig.tryParse(''), isNull);
      expect(WebSearchConfig.tryParse('not json'), isNull);
      expect(WebSearchConfig.tryParse('[1]'), isNull);
      expect(WebSearchConfig.tryParse('{"kind":"google"}'), isNull);
    });

    test('isUsable', () {
      expect(
        const WebSearchConfig(kind: WebSearchKind.searxng).isUsable,
        false,
      );
      expect(
        const WebSearchConfig(
          kind: WebSearchKind.searxng,
          endpoint: 'ftp://x.org',
        ).isUsable,
        false,
      );
      expect(
        const WebSearchConfig(
          kind: WebSearchKind.searxng,
          endpoint: 'not a url',
        ).isUsable,
        false,
      );
      expect(const WebSearchConfig(kind: WebSearchKind.brave).isUsable, false);
      expect(
        const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'k').isUsable,
        true,
      );
    });

    test('encode 往返', () {
      const WebSearchConfig c = WebSearchConfig(
        kind: WebSearchKind.brave,
        apiKey: 'secret',
      );
      expect(WebSearchConfig.tryParse(c.encode()), c);
      const WebSearchConfig s = WebSearchConfig(
        kind: WebSearchKind.searxng,
        endpoint: 'https://s.example.org',
      );
      expect(WebSearchConfig.tryParse(s.encode()), s);
    });
  });

  group('结果解析', () {
    test('parseSearxngResults 丢弃非 http 链接', () {
      final List<WebSearchHit> hits = parseSearxngResults(
        jsonEncode(<String, Object?>{
          'results': <Object?>[
            <String, Object?>{
              'title': 'A <b>b</b>',
              'url': 'https://a.example/x',
              'content': 'snip &amp; more',
            },
            <String, Object?>{'title': 'js', 'url': 'javascript:alert(1)'},
            <String, Object?>{'title': 'file', 'url': 'file:///etc/passwd'},
            <String, Object?>{'title': 'no url'},
            'junk',
          ],
        }),
      );
      expect(hits, hasLength(1));
      expect(hits.single.url, Uri.parse('https://a.example/x'));
      expect(hits.single.title, contains('A'));
      expect(hits.single.snippet, contains('snip'));
    });

    test('parseSearxngResults 形状不对 -> 空；坏 JSON 抛', () {
      expect(parseSearxngResults('{"results":"x"}'), isEmpty);
      expect(parseSearxngResults('[]'), isEmpty);
      expect(() => parseSearxngResults('<html>'), throwsFormatException);
    });

    test('parseBraveResults', () {
      final List<WebSearchHit> hits = parseBraveResults(
        jsonEncode(<String, Object?>{
          'web': <String, Object?>{
            'results': <Object?>[
              <String, Object?>{
                'title': 'T',
                'url': 'http://b.example/p',
                'description': 'D',
              },
              <String, Object?>{'title': 'bad', 'url': 'ftp://b.example'},
            ],
          },
        }),
      );
      expect(hits, hasLength(1));
      expect(hits.single.snippet, 'D');
      expect(parseBraveResults('{}'), isEmpty);
    });
  });

  group('isFetchableWebSearchUrl', () {
    test('公网 http(s) 可抓', () {
      expect(isFetchableWebSearchUrl(Uri.parse('https://example.com/a')), true);
      expect(isFetchableWebSearchUrl(Uri.parse('http://example.com')), true);
      expect(isFetchableWebSearchUrl(Uri.parse('https://8.8.8.8/')), true);
    });

    test('本机 / 内网 / 非 http 一律拒', () {
      for (final String u in <String>[
        'http://localhost/',
        'http://127.0.0.1/',
        'http://10.1.2.3/',
        'http://192.168.1.1/',
        'http://172.16.0.1/',
        'http://172.31.255.1/',
        'http://[::1]/',
        'http://[fc00::1]/',
        // IPv4-mapped / 未指定 / 链路本地 / 云元数据 / 组播。
        'http://[::ffff:127.0.0.1]/',
        'http://[::ffff:10.0.0.1]/',
        'http://[::ffff:192.168.0.1]/',
        'http://[::]/',
        'http://0.0.0.0/',
        'http://169.254.169.254/',
        'http://[fe80::1]/',
        'http://224.0.0.1/',
        'http://[ff02::1]/',
        'file:///etc/passwd',
        'ftp://example.com/',
      ]) {
        expect(isFetchableWebSearchUrl(Uri.parse(u)), false, reason: u);
      }
    });

    test('IPv4-mapped 的公网地址照常可抓', () {
      expect(
        isFetchableWebSearchUrl(Uri.parse('http://[::ffff:8.8.8.8]/')),
        true,
      );
      expect(
        isPublicWebSearchAddress(InternetAddress('2606:4700::1111')),
        true,
      );
    });
  });

  group('WebSearchClient.fetchPage', () {
    Future<List<InternetAddress>> resolveTo(String ip) async =>
        <InternetAddress>[InternetAddress(ip)];

    WebSearchClient fetcher(
      List<Uri> seen,
      http.Response Function(Uri url) respond, {
      WebSearchHostResolver? resolveHost,
    }) => WebSearchClient(
      config: const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'k'),
      client: MockClient((http.Request r) async {
        expect(r.followRedirects, isFalse);
        seen.add(r.url);
        return respond(r.url);
      }),
      resolveHost: resolveHost ?? (String _) => resolveTo('93.184.216.34'),
    );

    test('302 跳到 127.0.0.1：拒绝，不请求跳转目标', () async {
      final List<Uri> seen = <Uri>[];
      final WebSearchClient c = fetcher(
        seen,
        (Uri u) => http.Response(
          '',
          302,
          headers: <String, String>{'location': 'http://127.0.0.1:8080/admin'},
        ),
      );
      expect(await c.fetchPage(Uri.parse('https://lyrics.example/a')), isNull);
      expect(seen, <Uri>[Uri.parse('https://lyrics.example/a')]);
    });

    test('302 跳到 ::ffff:127.0.0.1 / 解析到内网的域名：都拒', () async {
      final List<Uri> seen = <Uri>[];
      final WebSearchClient c = fetcher(
        seen,
        (Uri u) => http.Response(
          '',
          301,
          headers: <String, String>{
            'location': u.host == 'lyrics.example'
                ? 'http://[::ffff:127.0.0.1]/'
                : '/x',
          },
        ),
      );
      expect(await c.fetchPage(Uri.parse('https://lyrics.example/a')), isNull);
      expect(seen, hasLength(1));

      final List<Uri> seen2 = <Uri>[];
      final WebSearchClient rebind = fetcher(
        seen2,
        (Uri u) => http.Response('<p>secret</p>', 200),
        resolveHost: (String host) => host == 'intranet.example'
            ? resolveTo('10.0.0.5')
            : resolveTo('93.184.216.34'),
      );
      expect(
        await rebind.fetchPage(Uri.parse('https://intranet.example/')),
        isNull,
      );
      expect(seen2, isEmpty);
    });

    test('跳到公网地址照常跟（相对 Location 按当前页解析），跳数有上限', () async {
      final List<Uri> seen = <Uri>[];
      final WebSearchClient c = fetcher(
        seen,
        (Uri u) => u.path == '/final'
            ? http.Response.bytes(utf8.encode('<p>君の声が聞こえる</p>'), 200)
            : http.Response(
                '',
                307,
                headers: <String, String>{'location': '/final'},
              ),
      );
      final WebSearchPage? page = await c.fetchPage(
        Uri.parse('https://lyrics.example/start'),
      );
      expect(page, isNotNull);
      expect(page!.text, contains('君の声が聞こえる'));
      expect(seen.map((Uri u) => u.toString()), <String>[
        'https://lyrics.example/start',
        'https://lyrics.example/final',
      ]);

      final List<Uri> loop = <Uri>[];
      final WebSearchClient looping = fetcher(
        loop,
        (Uri u) => http.Response(
          '',
          302,
          headers: <String, String>{'location': '${u.path}x'},
        ),
      );
      expect(
        await looping.fetchPage(Uri.parse('https://lyrics.example/a')),
        isNull,
      );
      expect(loop, hasLength(kWebSearchMaxRedirects + 1));
    });

    test('建连函数：解析出非公网地址就不建连（DNS rebinding）', () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      int hits = 0;
      server.listen((HttpRequest r) {
        hits++;
        r.response
          ..write('secret')
          ..close();
      });
      addTearDown(() => server.close(force: true));
      int lookups = 0;
      // 第一次（抓页前校验）给公网地址，之后（建连时）换成回环。
      Future<List<InternetAddress>> rebinding(String host) async =>
          lookups++ == 0
          ? <InternetAddress>[InternetAddress('93.184.216.34')]
          : <InternetAddress>[InternetAddress.loopbackIPv4];

      await expectLater(
        webSearchPinnedConnectionFactory(
          (String _) async => <InternetAddress>[InternetAddress.loopbackIPv4],
        )(Uri.parse('http://rebind.example:${server.port}/'), null, null),
        throwsA(isA<SocketException>()),
      );

      final WebSearchClient c = WebSearchClient(
        config: const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'k'),
        resolveHost: rebinding,
      );
      addTearDown(c.close);
      expect(
        await c.fetchPage(Uri.parse('http://rebind.example:${server.port}/')),
        isNull,
      );
      expect(hits, 0);
    });
  });

  group('WebSearchClient.search', () {
    test('SearXNG 请求带 format=json 与 q', () async {
      late Uri seen;
      final WebSearchClient client = WebSearchClient(
        config: const WebSearchConfig(
          kind: WebSearchKind.searxng,
          endpoint: 'https://s.example.org',
        ),
        client: MockClient((http.Request r) async {
          seen = r.url;
          return http.Response(
            jsonEncode(<String, Object?>{
              'results': <Object?>[
                <String, Object?>{'title': 't', 'url': 'https://r.example/1'},
              ],
            }),
            200,
          );
        }),
      );
      final List<WebSearchHit> hits = await client.search('主題歌 op');
      expect(seen.path, '/search');
      expect(seen.queryParameters['format'], 'json');
      expect(seen.queryParameters['q'], '主題歌 op');
      expect(hits, hasLength(1));
    });

    test('Brave 带 X-Subscription-Token 头', () async {
      late http.Request seen;
      final WebSearchClient client = WebSearchClient(
        config: const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'tok'),
        client: MockClient((http.Request r) async {
          seen = r;
          return http.Response(
            jsonEncode(<String, Object?>{
              'web': <String, Object?>{
                'results': <Object?>[
                  <String, Object?>{'title': 't', 'url': 'https://r.example/1'},
                ],
              },
            }),
            200,
          );
        }),
      );
      final List<WebSearchHit> hits = await client.search('q');
      expect(seen.headers['X-Subscription-Token'], 'tok');
      expect(seen.url.host, 'api.search.brave.com');
      expect(seen.url.queryParameters['q'], 'q');
      expect(hits, hasLength(1));
    });

    test('未配全 / 空查询 / HTTP 失败 -> 空列表，不抛', () async {
      int calls = 0;
      final http.Client mock = MockClient((http.Request r) async {
        calls++;
        return http.Response('boom', 500);
      });
      final WebSearchClient unusable = WebSearchClient(
        config: const WebSearchConfig(kind: WebSearchKind.brave),
        client: mock,
      );
      expect(await unusable.search('q'), isEmpty);
      final WebSearchClient ok = WebSearchClient(
        config: const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'k'),
        client: mock,
      );
      expect(await ok.search('  '), isEmpty);
      expect(calls, 0);
      expect(await ok.search('q'), isEmpty);
      expect(calls, 1);
    });
  });
}
