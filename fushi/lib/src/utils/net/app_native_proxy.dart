import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fushi/src/utils/net/app_http.dart';
import 'package:fushi/src/utils/net/app_proxy.dart';

Future<AppNativeProxy>? _sharedProxy;
final Set<String> _nativeProxySecrets = <String>{};

/// Scrub native diagnostics before forwarding them to application logs/UI.
String redactAppNativeProxySecrets(String value) {
  for (final String secret in _nativeProxySecrets) {
    value = value.replaceAll(secret, '[native-proxy]');
  }
  return value;
}

/// Native HTTP engines cannot call Dart's per-URL proxy resolver. A loopback
/// forward proxy keeps redirects, HLS segments and later requests on that same
/// policy. The random local credential is unrelated to upstream credentials.
/// Keep this endpoint private: it authorizes access to the local relay.
Future<Uri> ensureAppNativeProxyEndpoint() async =>
    (await (_sharedProxy ??= AppNativeProxy.start())).endpoint;

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
  AppNativeProxy._(this._server, this._secret);

  final HttpServer _server;
  final String _secret;
  final Set<Socket> _sockets = <Socket>{};
  final Set<HttpClient> _clients = <HttpClient>{};

  Uri get endpoint => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    userInfo: 'fushi:$_secret',
  );

  static Future<AppNativeProxy> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Random random = Random.secure();
    final String secret = base64Url.encode(
      List<int>.generate(32, (int _) => random.nextInt(256)),
    );
    final AppNativeProxy proxy = AppNativeProxy._(server, secret);
    _nativeProxySecrets.addAll(<String>{
      secret,
      base64.encode(utf8.encode('fushi:$secret')),
    });
    server.listen((HttpRequest request) => unawaited(proxy._serve(request)));
    return proxy;
  }

  Future<void> close() async {
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
    } on Object {
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

  Future<void> _forward(HttpRequest request) async {
    final Uri uri = request.requestedUri;
    if (!uri.isScheme('http') || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
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
