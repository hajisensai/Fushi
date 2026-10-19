/// BUG-3520 / BUG-3521：封面请求带私有目录凭据头（OPDS 的 `X-API-Key`、Basic）
/// 时，重定向的凭据边界。
///
/// 走真实 loopback `HttpServer`（两个端口 = 两个 origin）：`dart:io` 自动跟随
/// 只剥 SDK 清单里的 `Authorization` / `Cookie`，`X-API-Key` 会被原样转发——
/// 这条不变式只在真实 HTTP 栈上成立或失败，mock 客户端测不出来。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';

void main() {
  final HttpOverrides? originalOverrides = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = originalOverrides);

  Future<HttpServer> serve(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    unawaited(() async {
      await for (final HttpRequest request in server) {
        await handler(request);
      }
    }());
    return server;
  }

  Future<void> drain(FileServiceResponse response) async {
    await response.content.drain<void>();
  }

  test('跨 origin 重定向：X-API-Key / Authorization 都不带到 CDN', () async {
    final Map<String, String?> atCdn = <String, String?>{};
    final HttpServer cdn = await serve((HttpRequest request) async {
      atCdn['x-api-key'] = request.headers.value('x-api-key');
      atCdn['authorization'] = request.headers.value('authorization');
      atCdn['user-agent'] = request.headers.value('x-fushi-ua');
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('image', 'png')
        ..add(<int>[1, 2, 3]);
      await request.response.close();
    });
    final HttpServer origin = await serve((HttpRequest request) async {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${cdn.port}/thumb.png',
        );
      await request.response.close();
    });

    final FileServiceResponse response = await AppImageFileService().get(
      'http://127.0.0.1:${origin.port}/opds/v2/books/1/thumbnail',
      headers: <String, String>{
        'X-API-Key': 'komga-key',
        'Authorization': 'Basic c2VjcmV0',
        'X-Fushi-UA': 'kept',
      },
    );
    await drain(response);
    expect(response.statusCode, 200);
    expect(atCdn['x-api-key'], isNull, reason: 'API key 绝不能送给第三方 origin');
    expect(atCdn['authorization'], isNull);
    expect(atCdn['user-agent'], 'kept', reason: '非凭据头照常转发');
  });

  test('同 origin 重定向：凭据头保留（否则私有目录封面仍是 401）', () async {
    String? apiKeyAtFinal;
    final HttpServer server = await serve((HttpRequest request) async {
      if (request.uri.path == '/thumbnail') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/thumbnail/real');
        await request.response.close();
        return;
      }
      apiKeyAtFinal = request.headers.value('x-api-key');
      request.response
        ..statusCode = apiKeyAtFinal == null ? 401 : 200
        ..add(<int>[1]);
      await request.response.close();
    });

    final FileServiceResponse response = await AppImageFileService().get(
      'http://127.0.0.1:${server.port}/thumbnail',
      headers: <String, String>{'X-API-Key': 'komga-key'},
    );
    await drain(response);
    expect(response.statusCode, 200);
    expect(apiKeyAtFinal, 'komga-key');
  });
}
