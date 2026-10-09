import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'ctl_endpoint.dart';
import 'ctl_protocol.dart';
import 'ctl_routes.dart';

/// app 侧实现的动作面。服务端只做鉴权、解析与状态码，不懂任何 app 语义。
abstract interface class CtlDesktopHandler {
  CtlAppStatus status();

  /// 打开一个「候选 argv」：视频路径或 `fushi://` 深链 / 卡片来源 URL。
  Future<CtlOpenResult> open(String target);

  Future<void> lookup(String word);

  /// 走与关窗口同一条落库再退出的路径。服务端先回 202 再调用它。
  Future<void> quit();

  /// 按域注册的其余路由（书库、词典、设置……），见 [CtlRoute]。
  List<CtlRoute> get routes;
}

/// 本机控制通道：只绑 127.0.0.1，随机端口，每次启动新 token。
///
/// 浏览器即便猜到端口也拿不到 token；另外带 `Origin` 头的请求一律 403——CLI 不发
/// 这个头，只有网页里的 fetch 会带，直接拒掉省得依赖 token 之外的任何假设。
class CtlServer {
  CtlServer({
    required this.handler,
    required this.stateDir,
    String? token,
    this.appVersion,
    int? processId,
  }) : token = token ?? generateCtlToken(),
       pid = processId ?? currentProcessId();

  final CtlDesktopHandler handler;
  final String stateDir;
  final String token;
  final String? appVersion;
  final int pid;

  HttpServer? _server;
  CtlEndpoint? _endpoint;

  CtlEndpoint? get endpoint => _endpoint;

  /// 绑定端口并写发现文件。重复调用无效。
  Future<CtlEndpoint> start() async {
    final CtlEndpoint? running = _endpoint;
    if (running != null) return running;
    final HttpServer server = await shelf_io.serve(
      _handle,
      InternetAddress.loopbackIPv4,
      0,
    );
    _server = server;
    final CtlEndpoint endpoint = CtlEndpoint(
      port: server.port,
      token: token,
      pid: pid,
      startedAt: DateTime.now().millisecondsSinceEpoch,
      appVersion: appVersion,
    );
    try {
      await writeCtlEndpoint(stateDir, endpoint);
    } catch (_) {
      await server.close(force: true);
      _server = null;
      rethrow;
    }
    _endpoint = endpoint;
    return endpoint;
  }

  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    final CtlEndpoint? endpoint = _endpoint;
    _endpoint = null;
    if (endpoint != null)
      await deleteCtlEndpointIfOwned(stateDir, endpoint.pid);
    await server?.close(force: true);
  }

  Future<shelf.Response> _handle(shelf.Request request) async {
    if (request.headers.containsKey('origin')) {
      return _error(403, 'forbidden');
    }
    if (!_authorized(request.headers['authorization'])) {
      return _error(401, kCtlErrorUnauthorized);
    }
    final String path = '/${request.url.path}';
    final String method = request.method.toUpperCase();
    try {
      if (path == kCtlStatusPath && method == 'GET') {
        return _json(200, handler.status().toJson());
      }
      if (method == 'POST') {
        switch (path) {
          case kCtlOpenPath:
            return _open(request);
          case kCtlLookupPath:
            return _lookup(request);
          case kCtlQuitPath:
            // 先把 202 送出去再退出：quit 会 exit(0)，晚了 CLI 只能看到连接断开。
            Timer.run(() => unawaited(handler.quit()));
            return _json(202, const <String, Object?>{'ok': true});
        }
      }
      return await _dispatchRoute(request, method, path);
    } on CtlFailure catch (failure) {
      return _error(failure.status, failure.code, message: failure.message);
    } on Object catch (error) {
      return _error(500, 'internal', message: '$error');
    }
  }

  Future<shelf.Response> _dispatchRoute(
    shelf.Request request,
    String method,
    String path,
  ) async {
    bool pathKnown = false;
    for (final CtlRoute route in handler.routes) {
      final Map<String, String>? params = route.match(path);
      if (params == null) continue;
      pathKnown = true;
      if (route.method != method) continue;
      if (route.requiresReady && !handler.status().initialised) {
        return _error(409, kCtlErrorNotReady);
      }
      final Map<String, Object?> body = await _jsonBody(request);
      final Object? result = await route.handler(
        CtlCall(
          method: method,
          path: path,
          params: params,
          query: request.url.queryParameters,
          body: body,
        ),
      );
      return _jsonAny(200, result ?? const <String, Object?>{'ok': true});
    }
    return pathKnown
        ? _error(405, 'method_not_allowed')
        : _error(404, 'not_found');
  }

  static Future<Map<String, Object?>> _jsonBody(shelf.Request request) async {
    final String text = await request.readAsString();
    if (text.trim().isEmpty) return const <String, Object?>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const CtlFailure.badRequest('body 不是合法 JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const CtlFailure.badRequest('body 必须是 JSON 对象');
    }
    return decoded;
  }

  Future<shelf.Response> _open(shelf.Request request) async {
    final String? target = await _stringField(request, 'target');
    if (target == null)
      return _error(400, kCtlErrorBadRequest, message: 'target 缺失');
    if (!handler.status().initialised) return _error(409, kCtlErrorNotReady);
    final CtlOpenResult result = await handler.open(target);
    final CtlOpenKind? kind = result.kind;
    if (kind == null) {
      return _error(422, kCtlErrorRejected, message: result.reason);
    }
    return _json(200, <String, Object?>{'ok': true, 'kind': kind.wireName});
  }

  Future<shelf.Response> _lookup(shelf.Request request) async {
    final String? word = await _stringField(request, 'word');
    if (word == null)
      return _error(400, kCtlErrorBadRequest, message: 'word 缺失');
    if (!handler.status().initialised) return _error(409, kCtlErrorNotReady);
    await handler.lookup(word);
    return _json(200, const <String, Object?>{'ok': true});
  }

  bool _authorized(String? header) {
    if (header == null) return false;
    const String prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return false;
    return _constantTimeEquals(header.substring(prefix.length).trim(), token);
  }

  static bool _constantTimeEquals(String a, String b) {
    final List<int> x = utf8.encode(a);
    final List<int> y = utf8.encode(b);
    int diff = x.length ^ y.length;
    for (int i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  static Future<String?> _stringField(
    shelf.Request request,
    String name,
  ) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final Object? value = decoded[name];
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }

  static shelf.Response _json(int status, Map<String, Object?> body) =>
      _jsonAny(status, body);

  static shelf.Response _jsonAny(int status, Object? body) => shelf.Response(
    status,
    body: jsonEncode(body),
    headers: const <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  );

  static shelf.Response _error(int status, String code, {String? message}) =>
      _json(status, <String, Object?>{
        'error': code,
        if (message != null) 'message': message,
      });
}
