import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart';

/// 宿主桥是插件全部网络的唯一出口：这里用本机真实 HTTP 服务器验证它把插件的
/// 头 / 体原样送出、会话 cookie 回带、重定向逐跳过拦截。
void main() {
  late HttpServer server;
  late String base;
  final List<HttpHeaders> seenHeaders = <HttpHeaders>[];
  final List<String> seenBodies = <String>[];

  setUp(() async {
    seenHeaders.clear();
    seenBodies.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((HttpRequest request) async {
      seenHeaders.add(request.headers);
      seenBodies.add(await utf8.decoder.bind(request).join());
      final HttpResponse response = request.response;
      switch (request.uri.path) {
        case '/login':
          response.cookies.add(Cookie('session', 'abc'));
          response.write('ok');
        case '/redirect-local':
          response.statusCode = HttpStatus.found;
          response.headers.set(
            HttpHeaders.locationHeader,
            'http://localhost:${server.port}/secret',
          );
        case '/redirect-ok':
          response.statusCode = HttpStatus.seeOther;
          response.headers.set(HttpHeaders.locationHeader, '/final');
        case '/final':
          response.write('landed ${request.method}');
        case '/gbk':
          // 「日本」的 GBK 字节：桥只搬字节，解码归插件（fetchText 的 encoding）。
          response.headers.contentType = ContentType('text', 'html');
          response.add(<int>[0xC8, 0xD5, 0xB1, 0xBE]);
        default:
          response.write('echo ${request.method}');
      }
      await response.close();
    });
  });

  tearDown(() => server.close(force: true));

  LnReaderFetchBridge bridge() => LnReaderFetchBridge(
    clientFactory: HttpClient.new,
    // 测试服务器本身在回环上：放行 127.0.0.1，只拦 localhost（模拟「打到本机」）。
    isBlockedHost: (String host) => host == 'localhost',
  );

  test('插件的请求头与请求体原样送出，缺省补 UA', () async {
    final Map<String, Object?> result = await bridge().perform(
      <String, Object?>{
        'url': '$base/echo',
        'method': 'POST',
        'headers': <String, Object?>{
          'Referer': 'https://example.com/',
          'content-type': 'application/x-www-form-urlencoded',
        },
        'body': base64Encode(utf8.encode('a=1&b=2')),
      },
    );
    expect(result['status'], 200);
    expect(utf8.decode(base64Decode(result['body']! as String)), 'echo POST');
    expect(seenHeaders.single.value('referer'), 'https://example.com/');
    expect(seenHeaders.single.value('user-agent'), contains('Chrome'));
    expect(seenBodies.single, 'a=1&b=2');
  });

  test('响应体按字节原样回传（非 UTF-8 站点靠插件自己解码）', () async {
    final Map<String, Object?> result = await bridge().perform(
      <String, Object?>{'url': '$base/gbk', 'method': 'GET'},
    );
    expect(base64Decode(result['body']! as String), <int>[
      0xC8,
      0xD5,
      0xB1,
      0xBE,
    ]);
  });

  test('会话 cookie 在同一桥内回带', () async {
    final LnReaderFetchBridge b = bridge();
    await b.perform(<String, Object?>{'url': '$base/login'});
    await b.perform(<String, Object?>{'url': '$base/next'});
    expect(seenHeaders.last.value('cookie'), 'session=abc');
    b.close();
  });

  test('303 重定向转 GET 并跟到底，回报最终地址', () async {
    final Map<String, Object?> result = await bridge()
        .perform(<String, Object?>{
          'url': '$base/redirect-ok',
          'method': 'POST',
          'body': base64Encode(utf8.encode('x')),
        });
    expect(result['url'], '$base/final');
    expect(utf8.decode(base64Decode(result['body']! as String)), 'landed GET');
  });

  test('重定向到被拦主机时不跟随', () async {
    final Map<String, Object?> result = await bridge().perform(
      <String, Object?>{'url': '$base/redirect-local'},
    );
    expect(result['error'], startsWith('blocked redirect'));
    expect(seenHeaders.length, 1, reason: '拦截必须发生在请求发出之前，被拦主机一次都不能被打到。');
  });

  test('非 http(s) 与被拦主机直接拒绝', () async {
    expect(
      (await bridge().perform(<String, Object?>{
        'url': 'file:///etc/passwd',
      }))['error'],
      startsWith('unsupported url'),
    );
    expect(
      (await bridge().perform(<String, Object?>{
        'url': 'http://localhost:${server.port}/',
      }))['error'],
      startsWith('blocked host'),
    );
    expect(seenHeaders, isEmpty);
  });

  test('生产拦截判据：回环 / localhost / 链路本地被拦，公网放行', () {
    expect(isLnReaderBlockedHost('localhost'), isTrue);
    expect(isLnReaderBlockedHost('api.localhost'), isTrue);
    expect(isLnReaderBlockedHost('127.0.0.1'), isTrue);
    expect(isLnReaderBlockedHost('127.8.9.1'), isTrue);
    expect(isLnReaderBlockedHost('[::1]'), isTrue);
    expect(isLnReaderBlockedHost('169.254.169.254'), isTrue);
    expect(isLnReaderBlockedHost('ncode.syosetu.com'), isFalse);
    expect(isLnReaderBlockedHost('93.184.216.34'), isFalse);
  });
}
