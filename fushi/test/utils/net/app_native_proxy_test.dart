import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi/src/utils/net/app_proxy.dart';

void main() {
  late AppNativeProxy relay;
  late String Function() oldMode;
  late String Function() oldProxy;
  late String Function() oldUsername;
  late String Function() oldPassword;

  setUp(() async {
    oldMode = appUserProxyModeReader;
    oldProxy = appUserProxyReader;
    oldUsername = appUserProxyUsernameReader;
    oldPassword = appUserProxyPasswordReader;
    appUserProxyModeReader = () => kProxyModeDirect;
    appUserProxyUsernameReader = () => '';
    appUserProxyPasswordReader = () => '';
    relay = await AppNativeProxy.start();
  });
  tearDown(() async {
    await relay.close();
    appUserProxyModeReader = oldMode;
    appUserProxyReader = oldProxy;
    appUserProxyUsernameReader = oldUsername;
    appUserProxyPasswordReader = oldPassword;
  });

  String auth() =>
      'Basic ${base64.encode(utf8.encode(relay.endpoint.userInfo))}';

  Future<String> raw(String headers) async {
    final Socket socket = await Socket.connect(
      relay.endpoint.host,
      relay.endpoint.port,
    );
    try {
      socket.write('$headers\r\nConnection: close\r\n\r\n');
      return await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 5));
    } finally {
      socket.destroy();
    }
  }

  test(
    'duplicate local authorization is rejected without an uncaught error',
    () async {
      final String response = await raw(
        'GET http://origin.invalid/ HTTP/1.1\r\nHost: origin.invalid\r\nProxy-Authorization: ${auth()}\r\nProxy-Authorization: ${auth()}',
      );
      expect(response, startsWith('HTTP/1.1 407'));
    },
  );

  test('CONNECT cannot smuggle query or fragment into authority', () async {
    for (final String suffix in <String>['?other=443', '#other']) {
      final String response = await raw(
        'CONNECT origin.invalid:443$suffix HTTP/1.1\r\nHost: origin.invalid\r\nProxy-Authorization: ${auth()}',
      );
      expect(response, startsWith('HTTP/1.1 502'));
    }
  });

  for (final String challenge in <String>['Digest', 'oversized']) {
    test(
      'CONNECT rejects $challenge without sending upstream credentials',
      () async {
        final ServerSocket upstream = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(upstream.close);
        int attempts = 0;
        upstream.listen((Socket socket) {
          attempts++;
          addTearDown(socket.destroy);
          socket.listen((List<int> data) {
            expect(
              latin1.decode(data),
              isNot(contains('Proxy-Authorization:')),
            );
            socket.write(
              challenge == 'Digest'
                  ? 'HTTP/1.1 407 Authentication required\r\nProxy-Authenticate: Digest realm="upstream"\r\nContent-Length: 0\r\n\r\n'
                  : 'HTTP/1.1 200 OK\r\nX-Padding: ${'x' * 65536}\r\n\r\n',
            );
          });
        });
        appUserProxyModeReader = () => kProxyModeManual;
        appUserProxyReader = () => '127.0.0.1:${upstream.port}';
        appUserProxyUsernameReader = () => 'upstream-user';
        appUserProxyPasswordReader = () => 'upstream-password';
        final String response = await raw(
          'CONNECT origin.invalid:443 HTTP/1.1\r\nHost: origin.invalid\r\nProxy-Authorization: ${auth()}',
        );
        expect(response, startsWith('HTTP/1.1 502'));
        expect(attempts, 1);
      },
    );
  }

  test(
    'local token and authorization are redacted from native diagnostics',
    () {
      final String diagnostic = '${relay.endpoint} ${auth()}';
      final String sanitized = redactAppNativeProxySecrets(diagnostic);
      expect(
        sanitized,
        isNot(contains(relay.endpoint.userInfo.split(':').last)),
      );
      expect(sanitized, isNot(contains(auth())));
    },
  );

  Future<({int status, String body})> get(
    Uri target, {
    bool authenticate = true,
  }) async {
    final HttpClient client = HttpClient()
      ..findProxy = (Uri _) =>
          'PROXY ${relay.endpoint.host}:${relay.endpoint.port}';
    try {
      final HttpClientRequest request = await client.getUrl(target);
      if (authenticate) {
        request.headers.set(HttpHeaders.proxyAuthorizationHeader, auth());
      }
      final HttpClientResponse response = await request.close();
      return (
        status: response.statusCode,
        body: await utf8.decoder.bind(response).join(),
      );
    } finally {
      client.close(force: true);
    }
  }

  test(
    'requires local authorization before making any outbound connection',
    () async {
      final result = await get(
        Uri.parse('http://not-resolved.invalid/'),
        authenticate: false,
      );
      expect(result.status, HttpStatus.proxyAuthenticationRequired);
      expect(result.body, isEmpty);
    },
  );

  test(
    'local HTTP bypass works in manual mode and never forwards relay credentials',
    () async {
      final HttpServer origin = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => origin.close(force: true));
      origin.listen((HttpRequest request) async {
        expect(
          request.headers.value(HttpHeaders.proxyAuthorizationHeader),
          isNull,
        );
        request.response.headers.set('content-type', 'text/plain');
        request.response.write('local response');
        await request.response.close();
      });
      appUserProxyModeReader = () => kProxyModeManual;
      appUserProxyReader = () => '127.0.0.1:1';
      final result = await get(
        Uri.parse('http://127.0.0.1:${origin.port}/cover'),
      );
      expect(result.status, 200);
      expect(result.body, 'local response');
    },
  );

  test(
    'same endpoint resolves updated settings on every HTTP request',
    () async {
      Future<HttpServer> upstream(String name) async {
        final HttpServer server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => server.close(force: true));
        server.listen((HttpRequest request) async {
          expect(request.requestedUri.host, 'origin.invalid');
          request.response.write(name);
          await request.response.close();
        });
        return server;
      }

      final HttpServer first = await upstream('first');
      final HttpServer second = await upstream('second');
      appUserProxyModeReader = () => kProxyModeManual;
      appUserProxyReader = () => '127.0.0.1:${first.port}';
      expect((await get(Uri.parse('http://origin.invalid/a'))).body, 'first');
      appUserProxyReader = () => '127.0.0.1:${second.port}';
      expect((await get(Uri.parse('http://origin.invalid/b'))).body, 'second');
    },
  );

  test(
    'CONNECT tunnels bytes through authenticated upstream without leaking local token',
    () async {
      final ServerSocket upstream = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => upstream.close());
      final Completer<String> receivedHeader = Completer<String>();
      upstream.listen((Socket socket) {
        addTearDown(socket.destroy);
        bool connected = false;
        String header = '';
        socket.listen((List<int> data) {
          if (!connected) {
            header += latin1.decode(data);
            if (!header.contains('\r\n\r\n')) {
              return;
            }
            if (!header.contains('Proxy-Authorization:')) {
              socket.write(
                'HTTP/1.1 407 Proxy authentication required\r\nProxy-Authenticate: Basic realm="upstream"\r\nContent-Length: 0\r\n\r\n',
              );
              unawaited(socket.flush().then((_) => socket.close()));
              return;
            }
            receivedHeader.complete(header);
            connected = true;
            socket.write('HTTP/1.1 200 Connection established\r\n\r\n');
          } else {
            socket.add(data);
          }
        });
      });
      appUserProxyModeReader = () => kProxyModeManual;
      appUserProxyReader = () => '127.0.0.1:${upstream.port}';
      appUserProxyUsernameReader = () => 'upstream-user';
      appUserProxyPasswordReader = () => 'upstream-password';
      final Socket socket = await Socket.connect(
        relay.endpoint.host,
        relay.endpoint.port,
      );
      addTearDown(socket.destroy);
      final StreamIterator<List<int>> reader = StreamIterator<List<int>>(
        socket,
      );
      addTearDown(reader.cancel);
      socket.write(
        'CONNECT origin.invalid:443 HTTP/1.1\r\nHost: origin.invalid:443\r\nProxy-Authorization: ${auth()}\r\n\r\n',
      );
      String response = '';
      while (!response.contains('\r\n\r\n') && await reader.moveNext()) {
        response += latin1.decode(reader.current);
      }
      expect(response, startsWith('HTTP/1.1 200'));
      final String header = await receivedHeader.future;
      expect(header, contains('CONNECT origin.invalid:443 HTTP/1.1'));
      expect(
        header,
        contains(base64.encode(utf8.encode('upstream-user:upstream-password'))),
      );
      expect(header, isNot(contains(auth())));
      socket.write('tunnel payload');
      expect(await reader.moveNext(), isTrue);
      expect(utf8.decode(reader.current), 'tunnel payload');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'native child proxy environment overrides inherited bypass variables',
    () {
      final Map<String, String> environment = appNativeProxyEnvironment(
        relay.endpoint,
      );
      expect(environment['HTTPS_PROXY'], relay.endpoint.toString());
      expect(environment['http_proxy'], relay.endpoint.toString());
      expect(environment['NO_PROXY'], '');
      expect(environment['no_proxy'], '');
    },
  );
}
