import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';
import 'package:http/http.dart' as http;

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
        gameStreamService: service,
      )..pairedPeerTokensProvider = (() async => <String>{'phone', 'tablet'});
      final http.Client client = http.Client();
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
        Uri.parse('http://127.0.0.1:${server.port}/api/game-stream/$suffix'),
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
}
