/// WebUI / admin API 的 HTTP 服务：独立端口、admin token 鉴权、静态单页。
///
/// 鉴权两条路都认同一个 token：
/// - `Authorization: Bearer <admin_token>`（脚本 / curl）
/// - cookie `fushi_admin=<admin_token>`（浏览器；`POST /login` 用表单拿到）
///
/// 不做用户系统、不做 CSRF token：单管理员、局域网。跨站写请求靠 cookie
/// `SameSite=Strict` 挡住。TLS 与互联端口共用同一份自签证书（`tls: true` 时）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/web_ui.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

class AdminServer {
  AdminServer({
    required this.ctx,
    required this.token,
    this.securityContext,
  }) : _api = AdminApi(ctx);

  final AdminContext ctx;
  final String token;
  final SecurityContext? securityContext;
  final AdminApi _api;
  HttpServer? _server;

  int? get port => _server?.port;

  Future<void> start() async {
    final shelf.Handler handler = const shelf.Pipeline()
        .addMiddleware(_noCache)
        .addHandler(_dispatch);
    final Object address = ctx.config.adminBind == '0.0.0.0'
        ? InternetAddress.anyIPv4
        : ctx.config.adminBind;
    _server = await shelf_io.serve(
      handler,
      address,
      ctx.config.adminPort,
      securityContext: securityContext,
    );
    _server!.autoCompress = true;
  }

  Future<void> stop() async {
    final HttpServer? s = _server;
    _server = null;
    await s?.close(force: true);
  }

  static shelf.Handler _noCache(shelf.Handler inner) => (shelf.Request request) async {
        final shelf.Response response = await inner(request);
        return response.change(headers: <String, String>{
          'Cache-Control': 'no-store',
          'X-Content-Type-Options': 'nosniff',
          'X-Frame-Options': 'DENY',
        });
      };

  bool _authorized(shelf.Request request) => adminRequestAuthorized(
        authorization: request.headers['authorization'],
        cookie: request.headers['cookie'],
        token: token,
      );

  static bool _constantTimeEquals(String a, String b) =>
      adminConstantTimeEquals(a, b);

  Future<shelf.Response> _dispatch(shelf.Request request) async {
    final String path = '/${request.url.path}';
    final String method = request.method.toUpperCase();

    if (method == 'POST' && path == '/login') return _login(request);
    if (method == 'POST' && path == '/logout') {
      return shelf.Response.found('/', headers: <String, String>{
        'Set-Cookie': 'fushi_admin=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict',
      });
    }

    if (path.startsWith('/api/admin/')) {
      if (!_authorized(request)) {
        return shelf.Response(401,
            body: jsonEncode(const <String, Object?>{'error': 'unauthorized'}),
            headers: const <String, String>{'Content-Type': 'application/json; charset=utf-8'});
      }
      return _api.handle(request);
    }

    if (method == 'GET' && (path == '/' || path == '/index.html')) {
      return shelf.Response.ok(
        _authorized(request) ? adminWebUiHtml : adminLoginHtml,
        headers: const <String, String>{'Content-Type': 'text/html; charset=utf-8'},
      );
    }
    return shelf.Response.notFound('not found');
  }

  Future<shelf.Response> _login(shelf.Request request) async {
    final String body = await request.readAsString();
    final Map<String, String> form = Uri.splitQueryString(body);
    final String supplied = (form['token'] ?? '').trim();
    if (!_constantTimeEquals(supplied, token)) {
      // 失败故意慢一拍：单管理员 token 没有锁定策略，靠这一点抬高暴力成本。
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return shelf.Response.ok(
        adminLoginHtml.replaceFirst('<!--error-->', '<p class="err">Token 不正确</p>'),
        headers: const <String, String>{'Content-Type': 'text/html; charset=utf-8'},
      );
    }
    return shelf.Response.found('/', headers: <String, String>{
      // 与 adminRequestAuthorized 成对：写侧编码、读侧解码只有这一份真相。
      'Set-Cookie':
          adminSetCookieValue(token, secure: securityContext != null),
    });
  }
}

/// 管理端的凭据匹配（纯函数，可直接断言）。
///
/// 两条通道：`Authorization: Bearer <token>`（CLI / 脚本）与
/// `Cookie: fushi_admin=<token>`（浏览器，`POST /login` 发的）。
///
/// **cookie 值是编码过的**：token 是 `base64Url.encode(32 字节)`，32 % 3 == 2 ⇒
/// 必然以 `=` 结尾，而 `=` 在 cookie value 里按 RFC 6265 必须编码，所以写侧走
/// `Uri.encodeComponent`。读侧一度忘了解码，`%3D` 与 `=` 连长度都不等，
/// 常数时间比较首行就 false —— 浏览器于是「登录说成功、下一跳又被弹回登录」，
/// 而 Bearer 那条通道正常，所以 CLI 一切看着都好。
///
/// 解码失败（畸形的 % 序列）一律当作不匹配，**不回退去比原串**。
bool adminRequestAuthorized({
  required String? authorization,
  required String? cookie,
  required String token,
}) {
  if (authorization != null &&
      authorization.startsWith('Bearer ') &&
      adminConstantTimeEquals(authorization.substring(7).trim(), token)) {
    return true;
  }
  if (cookie == null) return false;
  for (final String part in cookie.split(';')) {
    final String kv = part.trim();
    if (!kv.startsWith('fushi_admin=')) continue;
    String value = kv.substring('fushi_admin='.length);
    try {
      value = Uri.decodeComponent(value);
    } on ArgumentError {
      continue;
    } on FormatException {
      continue;
    }
    if (adminConstantTimeEquals(value, token)) return true;
  }
  return false;
}

/// 常数时间字符串比较（长度不同直接 false —— 长度本就不是秘密）。
bool adminConstantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// 登录成功时下发的 Set-Cookie 值（纯函数：与 [adminRequestAuthorized] 成对，
/// 「写什么就必须读得回什么」由测试钉死）。
String adminSetCookieValue(String token, {required bool secure}) =>
    'fushi_admin=${Uri.encodeComponent(token)}; Path=/; HttpOnly; SameSite=Strict'
    '${secure ? '; Secure' : ''}; Max-Age=${30 * 24 * 3600}';
