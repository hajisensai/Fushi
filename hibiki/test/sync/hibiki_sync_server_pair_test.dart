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

  test('POST /api/pair returns 403 when pairing window is closed', () async {
    final http.Response resp = await http.post(pairUri());
    expect(resp.statusCode, 403);
  });

  test('POST /api/pair returns the token while the window is open', () async {
    server.openPairing(window: const Duration(seconds: 60));
    final http.Response resp = await http.post(pairUri());
    expect(resp.statusCode, 200);
    final Map<String, dynamic> body =
        jsonDecode(resp.body) as Map<String, dynamic>;
    expect(body['token'], 'super-secret-token');
  });

  test('GET /api/pair is rejected with 405', () async {
    server.openPairing(window: const Duration(seconds: 60));
    final http.Response resp = await http.get(pairUri());
    expect(resp.statusCode, 405);
  });

  test('pairing endpoint needs no auth header (bypasses Basic auth)', () async {
    // No Authorization header at all, yet a normal WebDAV path returns 401.
    final http.Response davResp =
        await http.get(Uri.parse('http://127.0.0.1:${server.port}/'));
    expect(davResp.statusCode, 401);
    server.openPairing();
    final http.Response pairResp = await http.post(pairUri());
    expect(pairResp.statusCode, 200);
  });

  test('window expires: 403 again after it elapses', () async {
    server.openPairing(window: const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final http.Response resp = await http.post(pairUri());
    expect(resp.statusCode, 403);
  });
}
