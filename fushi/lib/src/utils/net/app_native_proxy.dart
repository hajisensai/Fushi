import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

Future<AppNativeProxy>? _sharedProxy;
Future<AppNativeProxy>? _challengeProxy;
final Set<String> _nativeProxySecrets = <String>{};

/// Scrub native diagnostics before forwarding them to application logs/UI.
String redactAppNativeProxySecrets(String value) {
  for (final String secret in _nativeProxySecrets) {
    value = value.replaceAll(secret, '[native-proxy]');
  }
  return value;
}

/// 中继失败原因的落点。默认 [debugPrint]（被 `DebugLogService` 钩住，进得了
/// 「调试日志」页和上传的报错日志）；测试可替换。
///
/// 为什么必须有这个出口：中继对上只能回一个裸 502——native 客户端读不到响应体，
/// reqwest/hyper 把任何非 200 的 CONNECT 结果一律收敛成一个词 `unsuccessful`。
/// 于是「域名解析不了 / TCP 被拒 / 上游代理拒绝 CONNECT / 20 秒连接超时」四种
/// 完全不同的故障，在 Rust 侧长得一模一样。中继这边是唯一知道真实原因的地方，
/// 以前 `_serve` 的 catch-all 把它连同异常一起丢掉，两层各抹一半，最终用户只
/// 看到 `error sending request`（BUG-2381）。
void Function(String message) appNativeProxyLogSink = debugPrint;

/// Native HTTP engines cannot call Dart's per-URL proxy resolver. A loopback
/// forward proxy keeps redirects, HLS segments and later requests on that same
/// policy. The random local credential is unrelated to upstream credentials.
/// Keep this endpoint private: it authorizes access to the local relay.
Future<AppNativeProxy> ensureAppNativeProxy() =>
    _liveProxy(_sharedProxy, (Future<AppNativeProxy> started) {
      _sharedProxy = started;
    }, publicTargetsOnly: false);

Future<Uri> ensureAppNativeProxyEndpoint() async =>
    (await ensureAppNativeProxy()).endpoint;

/// Challenge JavaScript must not reach local origin servers, including through
/// service workers or WebSockets that skip WebView navigation callbacks.
Future<AppNativeProxy> ensureAppChallengeProxy() =>
    _liveProxy(_challengeProxy, (Future<AppNativeProxy> started) {
      _challengeProxy = started;
    }, publicTargetsOnly: true);

Future<Uri> ensureAppChallengeProxyEndpoint() async =>
    (await ensureAppChallengeProxy()).endpoint;

/// 缓存的中继**必须先验活再交出去**。
///
/// 这两个入口以前是 `??=`：一旦 Future 落定就是终身答案。两种情况因此变成
/// 「一次坏、永久坏，只能重启 app」——① 监听 socket 被系统回收（iOS 把 app
/// 挂起后就可能收走监听 socket，恢复后端口还在缓存里，native 客户端每次都撞
/// connection refused）；② 首次 `bind` 失败，那个**已失败**的 Future 被永久
/// 缓存，后面每次调用都重抛同一个旧异常，连重试的机会都没有（BUG-2381）。
///
/// 新 Future 在 await 之前就写回缓存，并发调用因此仍然只启一个中继。
Future<AppNativeProxy> _liveProxy(
  Future<AppNativeProxy>? cached,
  void Function(Future<AppNativeProxy> started) store, {
  required bool publicTargetsOnly,
}) async {
  if (cached != null) {
    try {
      final AppNativeProxy proxy = await cached;
      if (proxy.isRunning) return proxy;
    } on Object catch (error) {
      appNativeProxyLogSink(
        redactAppNativeProxySecrets('native proxy: restarting after $error'),
      );
    }
  }
  final Future<AppNativeProxy> started = AppNativeProxy.start(
    publicTargetsOnly: publicTargetsOnly,
  );
  store(started);
  return started;
}

/// Proxy environment for a native child. Clear inherited bypass rules because
/// the relay applies the application's rules separately to every destination.
Map<String, String> appNativeProxyEnvironment(Uri endpoint) => <String, String>{
  for (final String key in <String>[
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'ALL_PROXY',
    'http_proxy',
    'https_proxy',
    'all_proxy',
  ])
    key: endpoint.toString(),
  'NO_PROXY': '',
  'no_proxy': '',
};

class AppNativeProxy {
  AppNativeProxy._(this._server, this._secret, this._publicTargetsOnly);

  final HttpServer _server;
  final String _secret;
  final bool _publicTargetsOnly;
  final Set<Socket> _sockets = <Socket>{};
  final Set<HttpClient> _clients = <HttpClient>{};
  bool _closed = false;

  /// 监听 socket 还活着。为 false 时 [ensureAppNativeProxy] 会另起一个。
  bool get isRunning => !_closed;

  Uri get endpoint => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    userInfo: 'fushi:$_secret',
  );

  static Future<AppNativeProxy> start({bool publicTargetsOnly = false}) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Random random = Random.secure();
    final String secret = base64Url.encode(
      List<int>.generate(32, (int _) => random.nextInt(256)),
    );
    final AppNativeProxy proxy = AppNativeProxy._(
      server,
      secret,
      publicTargetsOnly,
    );
    _nativeProxySecrets.addAll(<String>{
      secret,
      base64.encode(utf8.encode('fushi:$secret')),
    });
    server.listen(
      (HttpRequest request) => unawaited(proxy._serve(request)),
      onDone: () => proxy._closed = true,
      onError: (Object error) {
        proxy._closed = true;
        appNativeProxyLogSink(
          redactAppNativeProxySecrets('native proxy: listener failed: $error'),
        );
      },
    );
    return proxy;
  }

  Future<void> close() async {
    _closed = true;
    for (final Socket socket in _sockets.toList()) {
      socket.destroy();
    }
    for (final HttpClient client in _clients.toList()) {
      client.close(force: true);
    }
    await _server.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    final String authorization =
        'Basic ${base64.encode(utf8.encode('fushi:$_secret'))}';
    final List<String>? supplied =
        request.headers[HttpHeaders.proxyAuthorizationHeader];
    if (supplied == null ||
        supplied.length != 1 ||
        supplied.single != authorization) {
      request.response.statusCode = HttpStatus.proxyAuthenticationRequired;
      request.response.headers.set(
        HttpHeaders.proxyAuthenticateHeader,
        'Basic realm="Fushi native"',
      );
      await request.response.close();
      return;
    }
    try {
      if (request.method == 'CONNECT') {
        await _connect(request);
      } else {
        await _forward(request);
      }
    } on Object catch (error) {
      // 原因只走应用日志，绝不进响应：响应体会被 native 客户端当成上游内容，
      // 而中继凭据必须先脱敏。
      _report(request, error);
      // Never return proxy URLs, authentication or native request bodies in an
      // error. The caller receives an actionable transport status.
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } on Object {
        /* A detached/closed tunnel has no HTTP response left. */
      }
    }
  }

  /// 一行「方法 + 去掉 query 的目标 + 真实异常」，凭据脱敏后交给日志出口。
  static void _report(HttpRequest request, Object error) {
    final String target = request.method == 'CONNECT'
        ? request.uri.toString()
        : request.requestedUri.replace(query: '', fragment: '').toString();
    appNativeProxyLogSink(
      redactAppNativeProxySecrets(
        'native proxy: ${request.method} $target -> $error',
      ),
    );
  }

  Future<void> _forward(HttpRequest request) async {
    final Uri uri = request.requestedUri;
    if (!uri.isScheme('http') || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    if (await _rejectPrivateTarget(request, uri)) return;
    final HttpClient client = createAppHttpClient()..autoUncompress = false;
    _clients.add(client);
    try {
      final HttpClientRequest outbound = await client.openUrl(
        request.method,
        uri,
      );
      outbound.followRedirects = false;
      _copyHeaders(request.headers, outbound.headers);
      await outbound.addStream(request);
      final HttpClientResponse response = await outbound.close();
      request.response.statusCode = response.statusCode;
      _copyHeaders(response.headers, request.response.headers);
      await request.response.addStream(response);
      await request.response.close();
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<void> _connect(HttpRequest request) async {
    final Uri target = Uri.parse('https://${request.uri}');
    if (target.host.isEmpty ||
        target.userInfo.isNotEmpty ||
        target.port < 1 ||
        target.port > 65535 ||
        target.hasQuery ||
        target.hasFragment ||
        (target.path.isNotEmpty && target.path != '/')) {
      throw const FormatException('Invalid CONNECT target');
    }
    if (await _rejectPrivateTarget(request, target)) return;
    final tunnel = await _openTunnel(target);
    final Socket upstream = tunnel.socket;
    final StreamIterator<List<int>> reader = tunnel.reader;
    Socket? downstream;
    try {
      request.response.statusCode = HttpStatus.ok;
      downstream = await request.response.detachSocket();
      _sockets.add(downstream);
      final Socket client = downstream;
      await Future.wait(<Future<void>>[
        upstream.addStream(client).then((_) async {
          await upstream.close();
        }),
        client.addStream(_remaining(reader, tunnel.remaining)).then((_) async {
          await client.close();
        }),
      ], eagerError: true);
    } finally {
      await reader.cancel();
      upstream.destroy();
      downstream?.destroy();
      _sockets.remove(upstream);
      _sockets.remove(downstream);
    }
  }

  Future<bool> _rejectPrivateTarget(HttpRequest request, Uri target) async {
    if (!_publicTargetsOnly || !isDirectProxyTarget(target.host)) return false;
    request.response.statusCode = HttpStatus.forbidden;
    await request.response.close();
    return true;
  }

  Future<
    ({Socket socket, StreamIterator<List<int>> reader, List<int> remaining})
  >
  _openTunnel(Uri target) async {
    final String directive = resolveAppProxyDirective(target);
    final String? proxy = proxyHostPortFromDirective(directive);
    final Uri peer = proxy == null ? target : Uri.parse('http://$proxy');
    final ({String username, String password})? credentials =
        resolveAppProxyCredentials(target);
    for (int attempt = 0; attempt < 2; attempt++) {
      // A settings change while waiting for a challenge must never send old
      // credentials to a newly selected proxy, or vice versa.
      if (attempt > 0 &&
          (resolveAppProxyDirective(target) != directive ||
              resolveAppProxyCredentials(target) != credentials)) {
        throw const HttpException('Proxy settings changed');
      }
      final Socket socket = await Socket.connect(
        peer.host,
        peer.port,
        timeout: kAppHttpConnectionTimeout,
      );
      _sockets.add(socket);
      final StreamIterator<List<int>> reader = StreamIterator<List<int>>(
        socket,
      );
      bool keep = false;
      try {
        if (proxy == null) {
          keep = true;
          return (socket: socket, reader: reader, remaining: const <int>[]);
        }
        final String auth = attempt == 0 || credentials == null
            ? ''
            : 'Proxy-Authorization: Basic ${base64.encode(utf8.encode('${credentials.username}:${credentials.password}'))}\r\n';
        final String host = target.host.contains(':')
            ? '[${target.host}]'
            : target.host;
        final String authority = '$host:${target.port}';
        socket.write(
          'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n$auth\r\n',
        );
        await socket.flush();
        final response = await _readConnectResponse(
          reader,
        ).timeout(kAppHttpConnectionTimeout);
        if (response.status == 200) {
          keep = true;
          return (
            socket: socket,
            reader: reader,
            remaining: response.remaining,
          );
        }
        if (attempt != 0 ||
            response.status != 407 ||
            !response.basic ||
            credentials == null) {
          throw const HttpException('Upstream proxy refused CONNECT');
        }
      } finally {
        if (!keep) {
          socket.destroy();
          await reader.cancel();
          _sockets.remove(socket);
        }
      }
    }
    throw const HttpException('Upstream proxy refused CONNECT');
  }

  static Future<({int status, bool basic, List<int> remaining})>
  _readConnectResponse(StreamIterator<List<int>> reader) async {
    final List<int> bytes = <int>[];
    while (await reader.moveNext()) {
      bytes.addAll(reader.current);
      for (int i = 3; i < bytes.length && i < 65536; i++) {
        if (bytes[i - 3] == 13 &&
            bytes[i - 2] == 10 &&
            bytes[i - 1] == 13 &&
            bytes[i] == 10) {
          final String headers = latin1.decode(bytes.sublist(0, i + 1));
          final RegExpMatch? match = RegExp(
            r'^HTTP/1\.[01] (\d{3})(?: |\r)',
          ).firstMatch(headers);
          if (match == null) {
            throw const HttpException('Invalid proxy response');
          }
          return (
            status: int.parse(match.group(1)!),
            basic: RegExp(
              r'^proxy-authenticate:\s*basic(?:\s|$)',
              multiLine: true,
              caseSensitive: false,
            ).hasMatch(headers),
            remaining: bytes.sublist(i + 1),
          );
        }
      }
      if (bytes.length >= 65536) {
        throw const HttpException('Proxy header too large');
      }
    }
    throw const HttpException('Upstream proxy closed CONNECT');
  }

  static Stream<List<int>> _remaining(
    StreamIterator<List<int>> reader,
    List<int> initial,
  ) async* {
    if (initial.isNotEmpty) {
      yield initial;
    }
    while (await reader.moveNext()) {
      yield reader.current;
    }
  }

  static void _copyHeaders(HttpHeaders source, HttpHeaders destination) {
    final Set<String> excluded = <String>{
      'connection',
      'proxy-connection',
      'proxy-authorization',
      'proxy-authenticate',
      'keep-alive',
      'transfer-encoding',
      'te',
      'trailer',
      'upgrade',
      ...?source
          .value('connection')
          ?.split(',')
          .map((String value) => value.trim().toLowerCase()),
    };
    source.forEach((String name, List<String> values) {
      if (!excluded.contains(name.toLowerCase())) {
        destination.set(name, values);
      }
    });
  }
}
