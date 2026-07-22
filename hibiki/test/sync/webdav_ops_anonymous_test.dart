// BUG-1016 匿名 / 无鉴权 WebDAV：用户名和密码都留空时，请求必须【不带】
// Authorization 头（而不是发 `Basic base64(':')`，那样匿名服务器多半仍回 401）。
// 有任一凭据时行为不变，照发 Basic 头。
//
// 用进程内 HttpServer 冒充 WebDAV 端点，对 PROPFIND 回 207，记录每个请求收到的
// Authorization 头，端到端断言 WebDavOps.buildRequest 的真实行为。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';

class _FakeDav {
  _FakeDav(this.server, this.origin);
  final HttpServer server;
  final String origin;
  final List<String?> authHeaders = <String?>[];

  static Future<_FakeDav> start() async {
    final HttpServer srv =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _FakeDav fake = _FakeDav(srv, 'http://127.0.0.1:${srv.port}');
    srv.listen((HttpRequest req) async {
      fake.authHeaders.add(req.headers.value(HttpHeaders.authorizationHeader));
      await req.drain<Object?>();
      // Minimal 207 multistatus so testConnection treats it as success.
      req.response.statusCode = 207;
      req.response.headers
          .set(HttpHeaders.contentTypeHeader, 'application/xml; charset=utf-8');
      req.response.write(
          '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>');
      await req.response.close();
    });
    return fake;
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  late _FakeDav dav;

  setUp(() async {
    dav = await _FakeDav.start();
  });
  tearDown(() async {
    await dav.stop();
  });

  test('空用户名+空密码 → 不带 Authorization 头，且连接成功（匿名 WebDAV）', () async {
    final WebDavOps ops =
        WebDavOps(baseUrl: '${dav.origin}/dav', username: '', password: '');
    await ops.testConnection();
    ops.close();
    expect(dav.authHeaders, isNotEmpty);
    expect(dav.authHeaders.every((String? h) => h == null), isTrue,
        reason: '匿名 WebDAV 请求不应带 Authorization 头');
  });

  test('有用户名密码 → 照发 Basic 头（行为不变）', () async {
    final WebDavOps ops = WebDavOps(
        baseUrl: '${dav.origin}/dav', username: 'reader', password: 'pw');
    await ops.testConnection();
    ops.close();
    expect(dav.authHeaders, isNotEmpty);
    expect(dav.authHeaders.first, startsWith('Basic '));
  });

  test('只有密码（用户名空）→ 仍发 Basic 头（非匿名）', () async {
    final WebDavOps ops = WebDavOps(
        baseUrl: '${dav.origin}/dav', username: '', password: 'token');
    await ops.testConnection();
    ops.close();
    expect(dav.authHeaders.first, startsWith('Basic '));
  });
}
