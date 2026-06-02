import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:http/http.dart' as http;

void main() {
  late Directory tempDir;
  late HibikiSyncServer server;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_test');
    server = HibikiSyncServer(
      syncDataDir: tempDir.path,
      port: 0, // ephemeral
      token: 'super-secret-token',
      allowLan: true,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Uri pairUri() => Uri.parse('http://127.0.0.1:${server.port}/api/pair');

  test('POST /api/pair returns 403/unavailable when no handler is wired',
      () async {
    final http.Response resp = await http.post(pairUri());
    expect(resp.statusCode, 403);
    expect(
      (jsonDecode(resp.body) as Map<String, dynamic>)['reason'],
      'unavailable',
    );
  });

  test('POST /api/pair returns the token when the host approves', () async {
    server.onPairRequest = (HibikiPairRequest _) async => true;
    final http.Response resp = await http.post(pairUri());
    expect(resp.statusCode, 200);
    final Map<String, dynamic> body =
        jsonDecode(resp.body) as Map<String, dynamic>;
    expect(body['token'], 'super-secret-token');
  });

  test('POST /api/pair returns 403/declined when the host declines', () async {
    server.onPairRequest = (HibikiPairRequest _) async => false;
    final http.Response resp = await http.post(pairUri());
    expect(resp.statusCode, 403);
    expect(
      (jsonDecode(resp.body) as Map<String, dynamic>)['reason'],
      'declined',
    );
  });

  test('the approval handler receives the client name and remote address',
      () async {
    HibikiPairRequest? seen;
    server.onPairRequest = (HibikiPairRequest req) async {
      seen = req;
      return true;
    };
    await http.post(
      pairUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'name': 'Galaxy S21'}),
    );
    expect(seen, isNotNull);
    expect(seen!.deviceName, 'Galaxy S21');
    // shelf_io attaches the connection info, so the loopback IP is resolved.
    expect(seen!.remoteAddress, isNotNull);
  });

  test('GET /api/pair is rejected with 405', () async {
    server.onPairRequest = (HibikiPairRequest _) async => true;
    final http.Response resp = await http.get(pairUri());
    expect(resp.statusCode, 405);
  });

  test('pairing endpoint needs no auth header (bypasses Basic auth)', () async {
    // No Authorization header at all, yet a normal WebDAV path returns 401.
    final http.Response davResp =
        await http.get(Uri.parse('http://127.0.0.1:${server.port}/'));
    expect(davResp.statusCode, 401);
    server.onPairRequest = (HibikiPairRequest _) async => true;
    final http.Response pairResp = await http.post(pairUri());
    expect(pairResp.statusCode, 200);
  });
}
