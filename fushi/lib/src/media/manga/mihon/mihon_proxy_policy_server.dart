import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/utils/net/app_proxy.dart';

/// Authenticated loopback policy lookup for the JVM's per-URL ProxySelector.
/// Secrets stay in memory, never in process arguments, URLs, or logs.
class MihonProxyPolicyServer {
  MihonProxyPolicyServer._(this._server, this._token) {
    _server.listen((HttpRequest request) => unawaited(_serve(request)));
  }

  final HttpServer _server;
  final String _token;

  int get port => _server.port;

  static Future<MihonProxyPolicyServer> start(String token) async {
    await primeAppProxy();
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return MihonProxyPolicyServer._(server, token);
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $_token') {
        request.response.statusCode = HttpStatus.unauthorized;
        return;
      }
      final Uri? uri = Uri.tryParse(request.uri.queryParameters['url'] ?? '');
      if (request.method != 'GET' ||
          request.uri.path != '/proxy-policy' ||
          uri == null ||
          !const <String>['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        return;
      }
      final String directive = resolveAppProxyDirective(uri);
      final ({String username, String password})? credentials =
          resolveAppProxyCredentials(uri);
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.write(
        jsonEncode(<String, Object?>{
          'directive': directive,
          if (credentials != null) 'username': credentials.username,
          if (credentials != null) 'password': credentials.password,
        }),
      );
    } on Object {
      request.response.statusCode = HttpStatus.internalServerError;
    } finally {
      await request.response.close();
    }
  }

  Future<void> close() async => _server.close(force: true);
}
