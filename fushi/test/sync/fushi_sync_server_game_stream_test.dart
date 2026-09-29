import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 自签一张 127.0.0.1 的证书，让被测 server 真的跑在 HTTPS 上。
SecurityContext _selfSignedContext() {
  final ({String certificatePem, String privateKeyPem}) generated =
      FushiSelfSignedCertGenerator.generate(
        commonName: 'fushi-game-stream-test',
        sanIpAddresses: <String>['127.0.0.1'],
      );
  return SecurityContext()
    ..useCertificateChainBytes(generated.certificatePem.codeUnits)
    ..usePrivateKeyBytes(generated.privateKeyPem.codeUnits);
}

http.Client _selfSignedTrustingClient() =>
    IOClient(HttpClient()..badCertificateCallback = (_, _, _) => true);

void main() {
  test(
    'actual server routes require a paired token and pin the joining peer',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'stream_routes_',
      );
      final FushiRemoteGameStreamService service =
          FushiRemoteGameStreamService();
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: root.path,
        port: 0,
        token: 'shared',
        // 串流端点强制 HTTPS（见下一条用例），所以这条也得跑在 TLS 上。
        securityContext: _selfSignedContext(),
        gameStreamService: service,
      )..pairedPeerTokensProvider = (() async => <String>{'phone', 'tablet'});
      final http.Client client = _selfSignedTrustingClient();
      addTearDown(() async {
        client.close();
        await server.stop();
        service.dispose();
        await root.delete(recursive: true);
      });
      await server.start();
      final String sessionId = service
          .createSession(windowId: 'hwnd:42')
          .sessionId;
      Future<http.Response> post(
        String suffix,
        String token,
        Map<String, Object?> body,
      ) => client.post(
        Uri.parse('https://127.0.0.1:${server.port}/api/game-stream/$suffix'),
        headers: <String, String>{
          'authorization': 'Basic ${base64Encode(utf8.encode('fushi:$token'))}',
          'content-type': 'application/json',
        },
        body: jsonEncode(body),
      );
      expect(
        (await post('sessions', 'wrong', <String, Object?>{})).statusCode,
        401,
      );
      expect(
        (await post('sessions', 'shared', <String, Object?>{})).statusCode,
        403,
      );
      expect(
        (await post('sessions', 'phone', <String, Object?>{})).statusCode,
        200,
      );
      final Map<String, Object?> identity = <String, Object?>{
        'sessionId': sessionId,
        'clientId': 'android',
      };
      expect((await post('join', 'phone', identity)).statusCode, 200);
      expect((await post('join', 'tablet', identity)).statusCode, 409);
      expect((await post('signal', 'tablet', identity)).statusCode, 403);
      expect((await post('signal', 'phone', identity)).statusCode, 200);
      expect((await post('stop', 'tablet', identity)).statusCode, 403);
      expect((await post('stop', 'phone', identity)).statusCode, 200);
      expect(service.sessions, isEmpty);
    },
  );

  // WebRTC 的 DTLS-SRTP 机密性**完全依赖信令通道的完整性**：明文 HTTP 上一个在途
  // 攻击者把 answer 里的 a=fingerprint 换掉就成了真正的对端——拿到游戏画面、回环
  // 音频，并能往主机的游戏窗口注入输入。而本仓 TLS 是可选的，存量 LAN hosting 用户
  // 升级后仍是明文（applyFirstHostingTlsDefault 只对全新设备开）。所以串流端点必须
  // 像 service-config / profile transfer 那样自己拒绝明文。
  test('明文 HTTP 下串流端点一律拒绝，连已配对 token 也不放行', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'stream_plain_',
    );
    final FushiRemoteGameStreamService service = FushiRemoteGameStreamService();
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: root.path,
      port: 0,
      token: 'shared',
      // securityContext 为 null = 明文 HTTP，本仓存量用户的默认形态。
      gameStreamService: service,
    )..pairedPeerTokensProvider = (() async => <String>{'phone'});
    final http.Client client = http.Client();
    addTearDown(() async {
      client.close();
      await server.stop();
      service.dispose();
      await root.delete(recursive: true);
    });
    await server.start();
    final String sessionId = service
        .createSession(windowId: 'hwnd:7')
        .sessionId;

    Future<http.Response> post(String suffix, Map<String, Object?> body) =>
        client.post(
          Uri.parse('http://127.0.0.1:${server.port}/api/game-stream/$suffix'),
          headers: <String, String>{
            'authorization':
                'Basic ${base64Encode(utf8.encode('fushi:phone'))}',
            'content-type': 'application/json',
          },
          body: jsonEncode(body),
        );

    final Map<String, Object?> identity = <String, Object?>{
      'sessionId': sessionId,
      'clientId': 'android',
    };
    for (final (String suffix, Map<String, Object?> body)
        in <(String, Map<String, Object?>)>[
          ('sessions', <String, Object?>{}),
          ('join', identity),
          ('signal', identity),
          ('mine', identity),
          ('stop', identity),
        ]) {
      final http.Response res = await post(suffix, body);
      expect(
        res.statusCode,
        403,
        reason: '$suffix 在明文 HTTP 上必须拒绝（WebRTC 的信任链就在这条信令上）',
      );
      expect(res.body, contains('HTTPS'), reason: '$suffix 的拒绝理由要说清是 HTTPS');
    }
    // 明文下没有任何一条请求能建立会话。
    expect(service.sessions.single.sessionId, sessionId);
  });
}
