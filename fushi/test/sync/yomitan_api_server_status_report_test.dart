// BUG-1079：/api/extension/status 请求体解析——扩展自报「浏览器中实际加载的 build」。
// 此前扩展写死 '{}'、server 完全不读 body → app 对浏览器里实际跑的版本零感知，自更新
// 静默失败无从发现。本测在真实 HTTP 层验证：
// - 新扩展带 {build, version} → onExtensionReport 收到；
// - 旧扩展 '{}' / 空 body / 非法 JSON / build 类型错 → 容错不回调、响应与现状一致。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
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

List<String> _noopTokenize(String text) => <String>[text];
String _noopReading(String word) => '';

Future<HttpClientResponse> _postRaw(
  int port,
  String path,
  String rawBody, {
  String? auth,
}) async {
  // 不在这里 close client（响应尚未被调用方读取）；测试进程退出即回收。
  final HttpClient c = HttpClient();
  final HttpClientRequest req =
      await c.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
  req.headers.contentType = ContentType.json;
  if (auth != null) req.headers.set('authorization', auth);
  req.write(rawBody);
  return req.close();
}

Future<Map<String, dynamic>> _json(HttpClientResponse resp) async {
  final String s = await resp.transform(utf8.decoder).join();
  return jsonDecode(s) as Map<String, dynamic>;
}

void main() {
  group('BUG-1079 /api/extension/status body report', () {
    late YomitanApiServer server;
    late List<(String, String?)> reports;
    late int seenCount;

    Future<void> startServer() async {
      reports = <(String, String?)>[];
      seenCount = 0;
      server = YomitanApiServer(
        port: 0, // ephemeral
        lookupService: _FakeLookup(),
        tokenizer: _noopTokenize,
        readingResolver: _noopReading,
        extensionBuildProvider: () => 'ffff0000ffff0000',
        onExtensionSeen: () => seenCount++,
        onExtensionReport: (String build, String? version) =>
            reports.add((build, version)),
      );
      await server.start();
    }

    setUp(() async => startServer());
    tearDown(() async => server.stop());

    test('扩展自报 build+version → onExtensionReport 收到', () async {
      final HttpClientResponse resp = await _postRaw(
        server.port,
        '/api/extension/status',
        jsonEncode(
            <String, dynamic>{'build': 'abcd1234abcd1234', 'version': '0.3.0'}),
      );
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      // 响应契约不变：仍回带内置指纹 + ready。
      expect(j['app'], 'fushi');
      expect(j['ready'], true);
      expect(j['extensionBuild'], 'ffff0000ffff0000');
      expect(reports, <(String, String?)>[('abcd1234abcd1234', '0.3.0')]);
      expect(seenCount, 1, reason: 'last-seen 探活回调不受影响');
    });

    test('只报 build 不报 version → version 为 null', () async {
      await _postRaw(server.port, '/api/extension/status',
          jsonEncode(<String, dynamic>{'build': 'abcd1234abcd1234'}));
      expect(reports, <(String, String?)>[('abcd1234abcd1234', null)]);
    });

    test('旧扩展 \'{}\' body → 不回调、响应与现状一致（向后兼容）', () async {
      final HttpClientResponse resp =
          await _postRaw(server.port, '/api/extension/status', '{}');
      expect(resp.statusCode, 200);
      final Map<String, dynamic> j = await _json(resp);
      expect(j['app'], 'fushi');
      expect(j['extensionBuild'], 'ffff0000ffff0000');
      expect(reports, isEmpty);
      expect(seenCount, 1, reason: '旧扩展仍刷新 last-seen');
    });

    test('空 body / 非法 JSON / build 类型错 → 容错不回调不报错', () async {
      expect(
          (await _postRaw(server.port, '/api/extension/status', '')).statusCode,
          200);
      expect(
          (await _postRaw(server.port, '/api/extension/status', 'not json'))
              .statusCode,
          200);
      expect(
          (await _postRaw(server.port, '/api/extension/status',
                  jsonEncode(<String, dynamic>{'build': 42})))
              .statusCode,
          200);
      expect(
          (await _postRaw(server.port, '/api/extension/status',
                  jsonEncode(<String, dynamic>{'build': ''})))
              .statusCode,
          200);
      expect(reports, isEmpty);
    });

    test('未注入 onExtensionReport（旧 app 装配）→ 带 build 也不炸', () async {
      await server.stop();
      server = YomitanApiServer(
        port: 0,
        lookupService: _FakeLookup(),
        tokenizer: _noopTokenize,
        readingResolver: _noopReading,
      );
      await server.start();
      final HttpClientResponse resp = await _postRaw(
          server.port,
          '/api/extension/status',
          jsonEncode(<String, dynamic>{'build': 'abcd1234abcd1234'}));
      expect(resp.statusCode, 200);
      expect((await _json(resp))['app'], 'fushi');
    });
  });
}
