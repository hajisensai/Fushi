import 'dart:convert';

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
        'file:///etc/passwd',
        'ftp://example.com/',
      ]) {
        expect(isFetchableWebSearchUrl(Uri.parse(u)), false, reason: u);
      }
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
