// BUG-530：浏览器扩展（Netflix 等）查词/制卡端点必须在 YomitanApiServer 上可用——扩展被
// 安装助手自动配置指向该 server（port 19633 + yomitanApiKey），用 `Basic base64('hibiki:'+key)`
// 鉴权，POST `/api/lookup/dictionary` + `/api/mine`。历史 bug：这两个端点当时只在
// HibikiSyncServer 实现 → Netflix 查词/制卡全断。本测在真实 HTTP 层复现扩展请求验证修复。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/immersion_mine_payload.dart';
import 'package:hibiki/src/sync/yomitan_api_server.dart';
import 'package:hibiki/src/sync/yomitan_tokenize_adapter.dart';

class _FakeLookup implements HibikiRemoteLookupService {
  String? lastTerm;
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    lastTerm = term;
    final DictionarySearchResult r = DictionarySearchResult(searchTerm: term);
    r.popupJson = '{"html":"<b>$term</b>"}';
    return r;
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async =>
      null;
}

class _FakeMining implements HibikiRemoteMiningService {
  Map<String, String>? plainFields;
  ImmersionMinePayload? immersionPayload;
  @override
  Future<String> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async {
    plainFields = fields;
    return 'success';
  }

  @override
  Future<String> mineImmersion(ImmersionMinePayload payload) async {
    immersionPayload = payload;
    return 'success';
  }

  bool dupResult = false;
  String? lastDupExpression;
  String? lastDupReading;
  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async {
    lastDupExpression = expression;
    lastDupReading = reading;
    return dupResult;
  }
}

String _basic(String token) =>
    'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

Future<HttpClientResponse> _post(
  int port,
  String path,
  Map<String, dynamic> body, {
  String? auth,
}) async {
  // 不在这里 close client（响应尚未被调用方读取）；测试进程退出即回收。
  final HttpClient c = HttpClient();
  final HttpClientRequest req =
      await c.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
  req.headers.contentType = ContentType.json;
  if (auth != null) req.headers.set('authorization', auth);
  req.write(jsonEncode(body));
  return req.close();
}

Future<Map<String, dynamic>> _json(HttpClientResponse resp) async {
  final String s = await resp.transform(utf8.decoder).join();
  return jsonDecode(s) as Map<String, dynamic>;
}

void main() {
  const Tokenizer tok = _noopTokenize;
  const ReadingResolver rr = _noopReading;

  group('YomitanApiServer browser-extension endpoints (BUG-530)', () {
    late _FakeLookup lookup;
    late _FakeMining mining;
    late YomitanApiServer server;

    Future<void> startServer({
      String? apiKey,
      Map<String, String> Function()? themeColorsProvider,
    }) async {
      lookup = _FakeLookup();
      mining = _FakeMining();
      server = YomitanApiServer(
        port: 0, // ephemeral
        lookupService: lookup,
        miningService: mining,
        tokenizer: tok,
        readingResolver: rr,
        themeColorsProvider: themeColorsProvider,
        apiKey: apiKey,
      );
      await server.start();
    }

    tearDown(() async => server.stop());

    test('/api/lookup/dictionary works with Basic auth', () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '走る', 'record': false},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['type'], 'dictionaryResult');
      expect(lookup.lastTerm, '走る');
      expect((j['result'] as Map<String, dynamic>)['searchTerm'], '走る');
      expect(j['popupJson'], contains('走る'));
    });

    test(
        'lookup response carries popup size vars from themeColorsProvider '
        '(TODO-1185)', () async {
      // TODO-1185 follow-up：浏览器扩展弹窗尺寸跟随 app 内弹窗尺寸设置。app 注入的
      // browserExtensionThemeColors 把用户配置的 popupMaxWidth/Height 作为
      // --hibiki-popup-max-width / --hibiki-popup-max-height 放进查词响应 theme 字段，
      // content.js 逐项 setProperty 到 #entries-container，content.css 同名 var(...) 消费。
      Map<String, String> provider() => <String, String>{
            '--md-primary': 'rgb(1, 2, 3)',
            '--hibiki-popup-max-width': '520px',
            '--hibiki-popup-max-height': '640px',
          };
      await startServer(apiKey: 'k123', themeColorsProvider: provider);
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'record': false},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      final Map<String, dynamic> theme = j['theme'] as Map<String, dynamic>;
      expect(theme['--hibiki-popup-max-width'], '520px');
      expect(theme['--hibiki-popup-max-height'], '640px');
    });

    test('lookup response omits theme when provider absent (backward compat)',
        () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫', 'record': false},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      // 无 provider（旧 app / server 未注入）→ 不带 theme，扩展 CSS 回落默认 400x360。
      expect(j.containsKey('theme'), isFalse);
    });

    test('/api/mine with screenshot routes to mineImmersion', () async {
      await startServer(apiKey: 'k123');
      final String shot = base64Encode(Uint8List.fromList(<int>[1, 2, 3]));
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/mine',
        <String, dynamic>{
          'fields': <String, String>{'expression': '走る'},
          'sentence': '走り出した。',
          'timestampMs': 1234,
          'netflixVideoId': '81',
          'screenshotBase64': shot,
        },
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['result'], 'success');
      expect(mining.immersionPayload, isNotNull);
      expect(mining.immersionPayload!.screenshotBytes, <int>[1, 2, 3]);
      expect(mining.plainFields, isNull); // 未走纯文本回落
    });

    test('/api/mine plain text routes to mineEntry', () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/mine',
        <String, dynamic>{
          'fields': <String, String>{'expression': '本'},
          'sentence': '本を読む。',
        },
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp))['result'], 'success');
      expect(mining.plainFields, isNotNull);
      expect(mining.immersionPayload, isNull);
    });

    test('wrong token → 401', () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '走る'},
        auth: _basic('WRONG'),
      );
      expect(resp.statusCode, 401);
      await resp.drain<void>();
    });

    test('no api key configured → auth skipped (extension still works)',
        () async {
      await startServer(apiKey: null);
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/lookup/dictionary',
        <String, dynamic>{'term': '猫'},
        auth: _basic(''),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp))['type'], 'dictionaryResult');
    });

    test('mine without fields → 400', () async {
      await startServer(apiKey: null);
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/mine',
        <String, dynamic>{'sentence': 'no fields'},
      );
      expect(resp.statusCode, 400);
      await resp.drain<void>();
    });

    test('/api/duplicate returns real duplicate flag (TODO-1176)', () async {
      await startServer(apiKey: 'k123');
      mining.dupResult = true;
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/duplicate',
        <String, dynamic>{'expression': '走る', 'reading': 'はしる'},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp))['duplicate'], true);
      expect(mining.lastDupExpression, '走る');
      expect(mining.lastDupReading, 'はしる');
    });

    test('/api/duplicate empty expression → false without hitting backend',
        () async {
      await startServer(apiKey: 'k123');
      mining.dupResult = true;
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/duplicate',
        <String, dynamic>{'expression': ''},
        auth: _basic('k123'),
      );
      expect(resp.statusCode, 200);
      expect((await _json(resp))['duplicate'], false);
      expect(mining.lastDupExpression, isNull);
    });

    test('/api/duplicate wrong token → 401', () async {
      await startServer(apiKey: 'k123');
      final HttpClientResponse resp = await _post(
        server.port,
        '/api/duplicate',
        <String, dynamic>{'expression': '猫'},
        auth: _basic('WRONG'),
      );
      expect(resp.statusCode, 401);
      await resp.drain<void>();
    });
  });
}

List<String> _noopTokenize(String text) => <String>[text];
String _noopReading(String word) => '';
