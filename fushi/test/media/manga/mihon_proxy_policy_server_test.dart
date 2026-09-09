import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_proxy_policy_server.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

void main() {
  test(
    'authenticated JVM policy follows live mode, credentials and local bypass',
    () async {
      final String Function() oldMode = appUserProxyModeReader;
      final String Function() oldProxy = appUserProxyReader;
      final String Function() oldUsername = appUserProxyUsernameReader;
      final String Function() oldPassword = appUserProxyPasswordReader;
      String mode = kProxyModeManual;
      appUserProxyModeReader = () => mode;
      appUserProxyReader = () => '127.0.0.1:7890';
      appUserProxyUsernameReader = () => 'alice';
      appUserProxyPasswordReader = () => 'secret';
      final MihonProxyPolicyServer server = await MihonProxyPolicyServer.start(
        'test-token',
      );
      final HttpClient client = HttpClient()..findProxy = (_) => 'DIRECT';
      Future<HttpClientResponse> request(
        String url, {
        String token = 'test-token',
      }) async {
        final HttpClientRequest req = await client.getUrl(
          Uri.http(
            '127.0.0.1:${server.port}',
            '/proxy-policy',
            <String, String>{'url': url},
          ),
        );
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        return req.close();
      }

      Future<Map<String, dynamic>> policy(String url) async {
        final HttpClientResponse response = await request(url);
        expect(response.statusCode, 200);
        return jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
      }

      try {
        final HttpClientResponse denied = await request(
          'https://example.com',
          token: 'wrong',
        );
        expect(denied.statusCode, 401);
        await denied.drain<void>();
        expect(await policy('https://example.com'), <String, Object>{
          'directive': 'PROXY 127.0.0.1:7890',
          'username': 'alice',
          'password': 'secret',
        });
        expect(await policy('http://192.168.1.34'), <String, Object>{
          'directive': 'DIRECT',
        });
        mode = kProxyModeDirect;
        expect(await policy('https://example.com'), <String, Object>{
          'directive': 'DIRECT',
        });
        mode = kProxyModeAuto;
        final Map<String, dynamic> automatic = await policy(
          'https://example.com',
        );
        expect(
          automatic['directive'],
          resolveAppProxyDirective(Uri.parse('https://example.com')),
        );
        expect(automatic.containsKey('password'), isFalse);
      } finally {
        client.close(force: true);
        await server.close();
        appUserProxyModeReader = oldMode;
        appUserProxyReader = oldProxy;
        appUserProxyUsernameReader = oldUsername;
        appUserProxyPasswordReader = oldPassword;
      }
    },
  );
}
