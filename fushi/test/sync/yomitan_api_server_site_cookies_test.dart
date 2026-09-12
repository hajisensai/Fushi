// BUG-2480：漫画源登录「从浏览器导入」——扩展经 /api/extension/status 看到登记，
// 经 /api/extension/site-cookies 回传站点 cookie。真实 HTTP 层验证：
// - 没登记时 status 回包不带 cookieImport；登记后带 {host, nonce}；
// - 回传 nonce 对 → 登记者收到、只留同站点条目；nonce 错 / 无登记 → 409；
// - 登记结束后旧 nonce 不再被接受。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/sync/yomitan_api_server.dart';

class _FakeLookup implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => null;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

List<String> _noopTokenize(String text) => <String>[text];
String _noopReading(String word) => '';

Future<HttpClientResponse> _post(int port, String path, Object body) async {
  final HttpClient c = HttpClient();
  final HttpClientRequest req = await c.postUrl(
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode(body));
  return req.close();
}

Future<Map<String, dynamic>> _json(HttpClientResponse resp) async {
  final String s = await resp.transform(utf8.decoder).join();
  return jsonDecode(s) as Map<String, dynamic>;
}

Map<String, Object?> _cookie(
  String name,
  String domain, {
  bool hostOnly = false,
}) => <String, Object?>{
  'name': name,
  'value': 'v-$name',
  'domain': domain,
  'path': '/',
  'secure': true,
  'httpOnly': true,
  'hostOnly': hostOnly,
  'expirationDate': 1800000000,
};

void main() {
  late YomitanApiServer server;

  setUp(() async {
    BrowserCookieImportGate.resetForTesting();
    server = YomitanApiServer(
      port: 0,
      lookupService: _FakeLookup(),
      tokenizer: _noopTokenize,
      readingResolver: _noopReading,
    );
    await server.start();
  });

  tearDown(() async {
    BrowserCookieImportGate.resetForTesting();
    await server.stop();
  });

  test('status 回包：没登记不带 cookieImport；登记后带 host（去 www.）+ nonce', () async {
    final Map<String, dynamic> before = await _json(
      await _post(server.port, '/api/extension/status', {}),
    );
    expect(before.containsKey('cookieImport'), isFalse);

    final BrowserCookieImportRequestHandle handle =
        BrowserCookieImportGate.begin('www.BookWalker.jp');
    addTearDown(handle.end);
    final Map<String, dynamic> after = await _json(
      await _post(server.port, '/api/extension/status', {}),
    );
    expect(after['cookieImport'], <String, Object?>{
      'host': 'bookwalker.jp',
      'nonce': handle.request.nonce,
    });
  });

  test('回传 nonce 对 → 登记者收到整批；同站点过滤在 app 侧', () async {
    final BrowserCookieImportRequestHandle handle =
        BrowserCookieImportGate.begin('bookwalker.jp');
    addTearDown(handle.end);
    final Future<BrowserCookieDelivery> delivered = handle.deliveries.first;

    final HttpClientResponse resp = await _post(
      server.port,
      '/api/extension/site-cookies',
      {
        'nonce': handle.request.nonce,
        'host': 'bookwalker.jp',
        'cookies': <Object?>[
          _cookie('session', '.bookwalker.jp'),
          _cookie('member', 'member.bookwalker.jp', hostOnly: true),
          _cookie('_ga', '.google-analytics.com'),
          <String, Object?>{'value': 'no-name'},
        ],
      },
    );
    expect(resp.statusCode, 200);
    expect((await _json(resp))['count'], 3);

    final BrowserCookieDelivery delivery = await delivered.timeout(
      const Duration(seconds: 5),
    );
    expect(delivery.cookies.map((BrowserSiteCookie c) => c.name), <String>[
      'session',
      'member',
      '_ga',
    ]);
    // Chromium 的域 cookie 带前导点；去掉后 hostOnly=false。
    final BrowserSiteCookie session = delivery.cookies[0];
    expect(session.domain, 'bookwalker.jp');
    expect(session.hostOnly, isFalse);
    expect(session.expiresAt, 1800000000 * 1000);
    expect(delivery.cookies[1].hostOnly, isTrue);

    // 进 jar 的只有同站点两条，第三方域被挡在外面。
    final List<MangaCookie> forJar = browserCookiesForSite(
      delivery.cookies,
      'bookwalker.jp',
    );
    expect(forJar.map((MangaCookie c) => c.name).toSet(), <String>{
      'session',
      'member',
    });
  });

  test('nonce 错 / 没登记 / 登记已结束 → 409，什么都不写', () async {
    final HttpClientResponse none = await _post(
      server.port,
      '/api/extension/site-cookies',
      {'nonce': 'whatever', 'host': 'bookwalker.jp', 'cookies': <Object?>[]},
    );
    expect(none.statusCode, 409);

    final BrowserCookieImportRequestHandle handle =
        BrowserCookieImportGate.begin('bookwalker.jp');
    final HttpClientResponse wrong =
        await _post(server.port, '/api/extension/site-cookies', {
          'nonce': 'not-${handle.request.nonce}',
          'host': 'bookwalker.jp',
          'cookies': <Object?>[],
        });
    expect(wrong.statusCode, 409);

    handle.end();
    expect(BrowserCookieImportGate.pending, isNull);
    final HttpClientResponse ended = await _post(
      server.port,
      '/api/extension/site-cookies',
      {
        'nonce': handle.request.nonce,
        'host': 'bookwalker.jp',
        'cookies': <Object?>[],
      },
    );
    expect(ended.statusCode, 409);
  });

  test('缺字段 → 400', () async {
    final HttpClientResponse resp = await _post(
      server.port,
      '/api/extension/site-cookies',
      {'host': 'x.jp'},
    );
    expect(resp.statusCode, 400);
  });
}
