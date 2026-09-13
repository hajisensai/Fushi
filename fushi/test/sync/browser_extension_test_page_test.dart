// 新手引导「试一试」页：装完扩展后用户需要一张**真能被内容脚本注入的 http 页**来确认
// 插件活着（Chrome 默认不给扩展 file:// 权限，本地 HTML 证明不了任何事）。这里钉两件事：
// ① 生成的 HTML 自带「内容脚本注入」自检判据与转义；② server 上它是免鉴权的裸 GET。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/browser_extension_test_page.dart';
import 'package:fushi/src/sync/yomitan_api_server.dart';

class _FakeLookup implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async =>
      null;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async =>
      null;
}

const BrowserExtensionTestPageStrings _strings =
    BrowserExtensionTestPageStrings(
  title: '试一试浏览器扩展',
  intro: 'intro',
  probeChecking: 'checking',
  probeOk: 'injected',
  probeMissing: 'missing',
  stepPopupTitle: 'popup',
  stepPopupBody: 'click the icon',
  stepLookupTitle: 'shift',
  stepLookupBody: 'hold shift',
  sampleLabel: 'sample',
);

String _page({String sentence = '今日はいい天気ですね。', String lang = 'ja'}) =>
    buildBrowserExtensionTestPage(
      sentence: sentence,
      languageTag: lang,
      strings: _strings,
    );

Future<HttpClientResponse> _request(
  int port,
  String method,
  String path, {
  String? apiKey,
}) async {
  final HttpClient client = HttpClient();
  final HttpClientRequest req =
      await client.open(method, '127.0.0.1', port, path);
  if (apiKey != null) req.headers.set('X-API-Key', apiKey);
  return req.close();
}

void main() {
  group('试用页 HTML', () {
    test('自检判据是内容脚本写在根节点上的标记属性，不靠肉眼判断', () {
      final String html = _page();
      // 标记名必须与 tools/browser-extension/content.js 第一行写的属性一致。
      expect(kBrowserExtensionContentScriptMarker, 'data-fushi-cs');
      expect(html, contains('data-marker="data-fushi-cs"'));
      expect(html, contains('hasAttribute(box.dataset.marker)'));
      // 三态文案走 data-* 属性，脚本里不嵌动态字符串。
      expect(html, contains('data-ok="injected"'));
      expect(html, contains('data-missing="missing"'));
      expect(html, contains('checking'));
    });

    test('例句与语言标签落进页面，语言标签同时给 html 和例句块', () {
      final String html = _page(sentence: 'Hola mundo', lang: 'es');
      expect(html, contains('<html lang="es">'));
      expect(html, contains('<div class="sample" lang="es">Hola mundo</div>'));
    });

    test('例句与文案一律 HTML 转义（例句来自词典语言表，但不许有注入面）', () {
      final String html = _page(sentence: '<script>alert(1)</script>');
      expect(html, isNot(contains('<script>alert(1)</script>')));
      expect(html, contains('&lt;script&gt;'));
      // 页面只有自检那一个脚本块。
      expect('<script'.allMatches(html).length, 1);
    });
  });

  group('server 路由', () {
    late YomitanApiServer server;
    tearDown(() async => server.stop());

    Future<void> start({
      String? apiKey,
      String Function()? provider,
    }) async {
      server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        tokenizer: (String t) => <String>[t],
        readingResolver: (String w) => '',
        extensionTestPageProvider: provider,
        apiKey: apiKey,
      );
      await server.start();
    }

    test('裸 GET 免鉴权拿到 HTML（浏览器地址栏没有 Authorization 可带）', () async {
      await start(apiKey: 'k123', provider: _page);
      final HttpClientResponse resp =
          await _request(server.port, 'GET', kBrowserExtensionTestPagePath);
      expect(resp.statusCode, 200);
      expect(resp.headers.contentType?.mimeType, 'text/html');
      final String body = await resp.transform(utf8.decoder).join();
      expect(body, contains('data-marker="data-fushi-cs"'));
    });

    test('POST 到该路径是 405，不落进 POST-only 的 API 分发', () async {
      await start(provider: _page);
      final HttpClientResponse resp =
          await _request(server.port, 'POST', kBrowserExtensionTestPagePath);
      expect(resp.statusCode, 405);
    });

    test('未注入 provider（旧装配 / 配对 host）时 404，不崩', () async {
      await start();
      final HttpClientResponse resp =
          await _request(server.port, 'GET', kBrowserExtensionTestPagePath);
      expect(resp.statusCode, 404);
    });

    test('免鉴权只对这一条路径开口，其它端点仍要 key', () async {
      await start(apiKey: 'k123', provider: _page);
      final HttpClientResponse resp =
          await _request(server.port, 'POST', '/termEntries');
      expect(resp.statusCode, 401);
    });
  });
}
