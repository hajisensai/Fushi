import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_endpoint.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/fushi_api_server_manager.dart';

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

void main() {
  test('start then stop toggles isRunning and frees port', () async {
    final FushiApiServerManager mgr = FushiApiServerManager(
      lookupService: _FakeLookup(),
      tokenizer: (String t) => <String>[t],
      readingResolver: (String w) => '',
    );

    // Bind to an ephemeral port (0) so concurrent CI test isolates never
    // contend on a fixed port (TODO-1014); read the real port back from the
    // manager after start().
    await mgr.start(port: 0, apiKey: '');
    expect(mgr.isRunning, true);
    final int boundPort = mgr.port!;

    final HttpClient client = HttpClient();
    final HttpClientRequest req = await client.post(
      '127.0.0.1',
      boundPort,
      '/serverVersion',
    );
    final HttpClientResponse resp = await req.close();
    expect(resp.statusCode, 200);
    final dynamic body = jsonDecode(await resp.transform(utf8.decoder).join());
    expect(body['version'], 1);
    client.close(force: true);

    await mgr.stop();
    expect(mgr.isRunning, false);
  });

  FushiApiServerManager makeManager() => FushiApiServerManager(
    lookupService: _FakeLookup(),
    tokenizer: (String t) => <String>[t],
    readingResolver: (String w) => '',
  );

  SrsAnkiConnectEndpoint makeEndpoint() => SrsAnkiConnectEndpoint(
    handler: SrsAnkiConnectHandler(
      store: () async => throw StateError('version needs no store'),
      instanceId: 'inst',
      apiKey: () => null,
    ),
  );

  Future<int> postVersion(int port) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req = await client.post('127.0.0.1', port, '/');
      req.headers.contentType = ContentType('text', 'plain');
      req.write('{"action":"version","version":6}');
      final HttpClientResponse res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  // 冷启动的真实时序：initialise 不 await 地起 API server，绑端口（I/O）期间 SRS
  // runtime 同步注入 AnkiConnect 端点。注入必须落到这台 server 上，否则根路径恒 404。
  test('绑端口期间注入的 AnkiConnect 端点在 server 上生效', () async {
    final FushiApiServerManager mgr = makeManager();
    final Future<void> starting = mgr.start(port: 0, apiKey: 'k');
    mgr.ankiConnectEndpoint = makeEndpoint();
    await starting;
    expect(await postVersion(mgr.port!), 200);
    await mgr.stop();
  });

  test('绑端口期间注入后又卸下：根路径不再由兼容端点受理', () async {
    final FushiApiServerManager mgr = makeManager();
    final Future<void> starting = mgr.start(port: 0, apiKey: 'k');
    mgr.ankiConnectEndpoint = makeEndpoint();
    mgr.ankiConnectEndpoint = null;
    await starting;
    // 没有端点时根路径照常走 Fushi API 鉴权：这里设了 key、请求没带 → 401。
    expect(await postVersion(mgr.port!), 401);
    await mgr.stop();
  });

  test('绑端口期间被 stop：起好的 server 随即关闭，不留孤儿', () async {
    final FushiApiServerManager mgr = makeManager();
    final Future<void> starting = mgr.start(port: 0, apiKey: '');
    final Future<void> stopping = mgr.stop();
    await starting;
    await stopping;
    expect(mgr.isRunning, isFalse);
  });
}
