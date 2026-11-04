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

    test('key 存成 base64 apiKeyB64（与 ai_providers 同口径），不落明文', () {
      const WebSearchConfig c = WebSearchConfig(
        kind: WebSearchKind.brave,
        apiKey: 'tok-秘密',
      );
      final Map<String, Object?> json = c.toJson();
      expect(json.containsKey('apiKey'), isFalse);
      expect(json['apiKeyB64'], base64Encode(utf8.encode('tok-秘密')));
      expect(c.encode(), isNot(contains('tok-')));
      expect(WebSearchConfig.needsStorageMigration(c.encode()), isFalse);
    });

    test('旧版明文 apiKey 照读，并标成待迁移；坏 base64 当没填', () {
      const String legacy = '{"kind":"brave","apiKey":" old "}';
      expect(WebSearchConfig.tryParse(legacy)!.apiKey, 'old');
      expect(WebSearchConfig.needsStorageMigration(legacy), isTrue);
      final String migrated = WebSearchConfig.tryParse(legacy)!.encode();
      expect(WebSearchConfig.needsStorageMigration(migrated), isFalse);
      expect(WebSearchConfig.tryParse(migrated)!.apiKey, 'old');
      expect(
        WebSearchConfig.tryParse(
          '{"kind":"brave","apiKeyB64":"!!!not-base64"}',
        )!.apiKey,
        isNull,
      );
    });

    test('fromFields：去空白、空串当没填、未知后端 -> null', () {
      final WebSearchConfig? c = WebSearchConfig.fromFields(
        kind: 'brave',
        endpoint: ' ',
        apiKey: ' tok ',
      );
      expect(
        c,
        const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'tok'),
      );
      expect(WebSearchConfig.fromFields(kind: 'google'), isNull);
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

  group('抓页走代理：按已校验的 IP 建隧道（DNS rebinding）', () {
    /// 假代理：读 CONNECT 请求头并记下，回 [status]；2xx 后把隧道接到 [upstreamPort]
    /// （本机 HttpServer，不管 CONNECT 要的是哪个 IP），并记下隧道里客户端发的头几个字节。
    Future<_FakeProxy> startProxy({
      int? upstreamPort,
      String status = '200 Connection established',
    }) async {
      final _FakeProxy proxy = _FakeProxy(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      );
      proxy.server.listen((Socket client) {
        proxy.connections++;
        final List<int> buffered = <int>[];
        Socket? upstream;
        bool tunnelled = false;
        client.listen(
          (List<int> chunk) async {
            if (tunnelled) {
              proxy.tunnelBytes.addAll(chunk);
              upstream?.add(chunk);
              return;
            }
            buffered.addAll(chunk);
            final String text = latin1.decode(buffered);
            final int end = text.indexOf('\r\n\r\n');
            if (end < 0) return;
            proxy.requests.add(text.substring(0, end));
            tunnelled = true;
            if (!status.startsWith('2') || upstreamPort == null) {
              client.add(latin1.encode('HTTP/1.1 $status\r\n\r\n'));
              if (!status.startsWith('2')) await client.close();
              return;
            }
            upstream = await Socket.connect(
              InternetAddress.loopbackIPv4,
              upstreamPort,
            );
            upstream!.listen(
              client.add,
              onDone: () => client.close(),
              onError: (Object _) => client.destroy(),
            );
            client.add(latin1.encode('HTTP/1.1 $status\r\n\r\n'));
          },
          onDone: () => upstream?.close(),
          onError: (Object _) => upstream?.destroy(),
        );
      });
      addTearDown(proxy.server.close);
      return proxy;
    }

    test('http：CONNECT 的是校验过的 IP，不是主机名；页面经隧道取回，凭据不进源站', () async {
      final HttpServer origin = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final List<HttpRequest> seen = <HttpRequest>[];
      origin.listen((HttpRequest r) {
        seen.add(r);
        r.response
          ..headers.contentType = ContentType.html
          ..write('<html><body><p>歌詞 ほんもの</p></body></html>')
          ..close();
      });
      addTearDown(() => origin.close(force: true));
      final _FakeProxy proxy = await startProxy(upstreamPort: origin.port);

      final WebSearchClient c = WebSearchClient(
        config: const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'k'),
        resolveHost: (String _) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
        proxyDirective: (Uri _) => 'PROXY u:p@127.0.0.1:${proxy.server.port}',
      );
      addTearDown(c.close);
      final WebSearchPage? page = await c.fetchPage(
        Uri.parse('http://lyrics.example:${origin.port}/song?id=1'),
      );
      expect(page, isNotNull);
      expect(page!.text, contains('歌詞 ほんもの'));

      expect(proxy.requests, hasLength(1));
      final List<String> lines = proxy.requests.single.split('\r\n');
      expect(lines.first, 'CONNECT 93.184.216.34:${origin.port} HTTP/1.1');
      expect(
        lines,
        contains(
          'Proxy-Authorization: Basic ${base64Encode(utf8.encode('u:p'))}',
        ),
      );
      expect(proxy.requests.single, isNot(contains('lyrics.example')));
      // 源站看到的是 origin-form 请求 + 原主机名，代理凭据不外泄。
      expect(seen.single.uri.path, '/song');
      expect(seen.single.headers.host, 'lyrics.example');
      expect(seen.single.headers.value('proxy-authorization'), isNull);
    });

    test('https：CONNECT 的是 IP:443 形式，隧道里按原主机名发 TLS（SNI）', () async {
      final _FakeProxy proxy = await startProxy();
      final WebSearchClient c = WebSearchClient(
        config: const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'k'),
        resolveHost: (String _) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
        proxyDirective: (Uri _) => 'PROXY 127.0.0.1:${proxy.server.port}',
        requestTimeout: const Duration(seconds: 3),
      );
      addTearDown(c.close);
      // 假代理不接上游：TLS 握手不会完成，抓页失败返回 null；要看的是隧道里发了什么。
      expect(await c.fetchPage(Uri.parse('https://lyrics.example/a')), isNull);
      expect(
        proxy.requests.single.split('\r\n').first,
        'CONNECT 93.184.216.34:443 HTTP/1.1',
      );
      expect(proxy.tunnelBytes, isNotEmpty);
      expect(proxy.tunnelBytes.first, 0x16, reason: 'TLS handshake record');
      expect(latin1.decode(proxy.tunnelBytes), contains('lyrics.example'));
    });

    test('建连时被换成回环地址：连代理都不连', () async {
      final _FakeProxy proxy = await startProxy();
      int lookups = 0;
      final WebSearchClient c = WebSearchClient(
        config: const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'k'),
        resolveHost: (String _) async => lookups++ == 0
            ? <InternetAddress>[InternetAddress('93.184.216.34')]
            : <InternetAddress>[InternetAddress.loopbackIPv4],
        proxyDirective: (Uri _) => 'PROXY 127.0.0.1:${proxy.server.port}',
      );
      addTearDown(c.close);
      expect(await c.fetchPage(Uri.parse('http://rebind.example/')), isNull);
      expect(lookups, greaterThanOrEqualTo(2));
      expect(proxy.connections, 0);
    });

    test('代理拒绝隧道（407）/ 认不出的指令：抓页失败，不改走直连', () async {
      final _FakeProxy proxy = await startProxy(
        status: '407 Proxy Authentication Required',
      );
      final WebSearchClient refused = WebSearchClient(
        config: const WebSearchConfig(kind: WebSearchKind.brave, apiKey: 'k'),
        resolveHost: (String _) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
        proxyDirective: (Uri _) => 'PROXY 127.0.0.1:${proxy.server.port}',
      );
      addTearDown(refused.close);
      expect(await refused.fetchPage(Uri.parse('http://a.example/')), isNull);
      expect(proxy.requests, hasLength(1));

      await expectLater(
        webSearchPinnedConnectionFactory(
          (String _) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
          proxyDirective: (Uri _) => 'SOCKS 127.0.0.1:1080',
        )(Uri.parse('http://a.example/'), null, null),
        throwsA(isA<SocketException>()),
      );
    });

    test('装在会自己选代理的客户端上（proxyHost 非 null）：拒绝', () async {
      await expectLater(
        webSearchPinnedConnectionFactory(
          (String _) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
          proxyDirective: (Uri _) => 'DIRECT',
        )(Uri.parse('http://a.example/'), '127.0.0.1', 8080),
        throwsA(isA<StateError>()),
      );
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

/// 测试用假代理的记录。
class _FakeProxy {
  _FakeProxy(this.server);

  final ServerSocket server;

  /// 每条连接的 CONNECT 请求头（到空行为止）。
  final List<String> requests = <String>[];

  /// 隧道建成后客户端发来的字节。
  final List<int> tunnelBytes = <int>[];
  int connections = 0;
}
