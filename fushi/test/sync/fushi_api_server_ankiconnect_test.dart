import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_api_server.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_endpoint.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import '../srs/srs_test_support.dart' show openSrsTestStorage;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

class _NoLookup implements FushiRemoteLookupService {
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

Future<(int, String, Map<String, String>)> _send(
  int port,
  String method,
  String? body, {
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.open(
      method,
      '127.0.0.1',
      port,
      '/',
    );
    headers.forEach(req.headers.set);
    if (body != null) {
      req.headers.contentType = ContentType('text', 'plain');
      req.write(body);
    }
    final HttpClientResponse res = await req.close();
    final Map<String, String> h = <String, String>{};
    res.headers.forEach((String k, List<String> v) => h[k] = v.join(','));
    return (res.statusCode, await res.transform(utf8.decoder).join(), h);
  } finally {
    client.close(force: true);
  }
}

/// AnkiConnect 兼容端点挂在 Fushi API 根路径：注入才暴露、自带鉴权、OPTIONS 在 405 门之前。
void main() {
  late FushiApiServer server;
  late SrsAnkiConnectEndpoint endpoint;
  late FushiDatabase db;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final SrsStorage srs = await openSrsTestStorage();
    final SrsDbStore store = await SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: '01928c3e-0000-7000-8000-0000000000ff',
      deviceId: 'dev',
    );
    endpoint = SrsAnkiConnectEndpoint(
      handler: SrsAnkiConnectHandler(
        store: () async => store,
        instanceId: 'inst',
        apiKey: () => null,
      ),
    );
  });

  tearDown(() async {
    await server.stop();
    await db.close();
  });

  FushiApiServer make({SrsAnkiConnectEndpoint? ac, String? apiKey}) =>
      server = FushiApiServer(
        port: 0,
        lookupService: _NoLookup(),
        tokenizer: (List<String> ts) async => <List<TokenizedSegment>>[
          for (final String t in ts) <TokenizedSegment>[(text: t, reading: '')],
        ],
        apiKey: apiKey,
        ankiConnectEndpoint: ac,
      );

  test('未注入：根路径 404，不暴露', () async {
    await make().start();
    final (int code, _, _) = await _send(
      server.port,
      'POST',
      '{"action":"version","version":6}',
    );
    expect(code, 404);
  });

  test('注入后：text/plain POST 走兼容端点；运行中卸下立即 404', () async {
    await make(ac: endpoint).start();
    final (int code, String body, _) = await _send(
      server.port,
      'POST',
      '{"action":"version","version":6}',
    );
    expect(code, 200);
    expect(jsonDecode(body), <String, Object?>{'result': 6, 'error': null});
    server.ankiConnectEndpoint = null;
    final (int after, _, _) = await _send(
      server.port,
      'POST',
      '{"action":"version","version":6}',
    );
    expect(after, 404);
  });

  test('设了 Fushi API key：根路径不被 401 中间件挡（预检能过），由端点按 key 判', () async {
    await make(ac: endpoint, apiKey: 'k').start();
    final (int pre, _, Map<String, String> h) = await _send(
      server.port,
      'OPTIONS',
      null,
      headers: <String, String>{
        'origin': 'chrome-extension://abc',
        'access-control-request-method': 'POST',
      },
    );
    expect(pre, 200);
    expect(h['access-control-allow-origin'], 'chrome-extension://abc');
    final (int code, String body, _) = await _send(
      server.port,
      'POST',
      '{"action":"deckNames","version":6}',
    );
    expect(code, 200);
    // 端点的 apiKey 供给器与 server 分开注入（app 侧接同一个偏好）；这里端点没设 key。
    expect((jsonDecode(body) as Map)['result'], <String>['Default']);
  });

  test('网页 Origin 经浏览器打根路径 → 403', () async {
    await make(ac: endpoint).start();
    final (int code, _, Map<String, String> h) = await _send(
      server.port,
      'POST',
      '{"action":"addNote","version":6,"params":{}}',
      headers: <String, String>{'origin': 'https://evil.example'},
    );
    expect(code, 403);
    expect(h['access-control-allow-origin'], isNull);
  });
}
