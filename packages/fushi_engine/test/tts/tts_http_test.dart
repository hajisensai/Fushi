import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/providers/tts_http.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:test/test.dart';

/// 本机回环上的假端点：每个请求都回 [body]（JSON 文本）。
Future<HttpServer> _serve(String body) async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  server.listen((HttpRequest request) async {
    try {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.add(utf8.encode(body));
      await request.response.close();
    } catch (_) {
      // 客户端读到上限就断开：服务端写剩下的数据会失败，与被测行为无关。
    }
  });
  return server;
}

Matcher _tooLarge() => throwsA(
  isA<TtsFailure>()
      .having((TtsFailure f) => f.code, 'code', TtsFailureCode.badResponse)
      .having((TtsFailure f) => f.detail, 'detail', 'too large'),
);

void main() {
  late HttpClient client;
  final List<HttpServer> servers = <HttpServer>[];

  setUp(() => client = HttpClient());

  tearDown(() async {
    client.close(force: true);
    for (final HttpServer s in servers) {
      await s.close(force: true);
    }
    servers.clear();
  });

  Future<Uri> endpoint(String body) async {
    final HttpServer server = await _serve(body);
    servers.add(server);
    return Uri.parse('http://127.0.0.1:${server.port}/voices');
  }

  // 一个远超上限的合法 JSON 数组（约 8 KB）。
  final String big = jsonEncode(<String>[
    for (int i = 0; i < 400; i++) 'voice-$i-padding-padding',
  ]);

  test('ttsGetJson 解析上限内的声音列表', () async {
    final Uri uri = await endpoint('[{"name":"a"},{"name":"b"}]');
    final Object? json = await ttsGetJson(client: client, uri: uri);
    expect(json, isA<List<Object?>>());
    expect((json! as List<Object?>).length, 2);
  });

  test('ttsGetJson 响应体超过上限即失败，不整块读进内存', () async {
    final Uri uri = await endpoint(big);
    expect(utf8.encode(big).length, greaterThan(4096));
    await expectLater(
      ttsGetJson(client: client, uri: uri, maxResponseBytes: 1024),
      _tooLarge(),
    );
  });

  test('ttsGetJson 默认上限与合成同一道 kTtsMaxResponseBytes', () async {
    final Uri uri = await endpoint(big);
    // 远小于默认上限的正文照常解析（默认参数确实接上了常量而不是 0 / 无限）。
    final Object? json = await ttsGetJson(client: client, uri: uri);
    expect((json! as List<Object?>).length, 400);
    expect(kTtsMaxResponseBytes, 64 * 1024 * 1024);
  });

  test('ttsPostJson 按原始字节计上限（多字节字符不按字符数漏算）', () async {
    // 1000 个「声」= 3000 字节 UTF-8，但只有 1000 个字符。
    final String body = jsonEncode(<String>['声' * 1000]);
    final Uri uri = await endpoint(body);
    await expectLater(
      ttsPostJson(
        client: client,
        uri: uri,
        body: const <String, Object?>{},
        cancel: TtsCancelToken(),
        maxResponseBytes: 2048,
      ),
      _tooLarge(),
    );
  });
}
