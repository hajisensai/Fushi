import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:http/http.dart' as http;

// TODO-963 M2: /api/ping 无鉴权轻量探测端点的行为测试。
void main() {
  late Directory tempDir;
  late HibikiSyncServer server;

  Future<void> startServer({String? deviceName}) async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_ping_test');
    server = HibikiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'tok',
      allowLan: true,
      deviceName: deviceName,
    );
    await server.start();
  }

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Uri pingUri() => Uri.parse('http://127.0.0.1:${server.port}/api/ping');

  test('GET /api/ping 无需鉴权即返回 hibiki 标识 + v2 配对能力', () async {
    await startServer(deviceName: 'Hibiki · mac');
    // 故意不带 Authorization 头：ping 是配对前公开面。
    final http.Response resp = await http.get(pingUri());
    expect(resp.statusCode, 200);
    final Map<String, dynamic> body =
        jsonDecode(resp.body) as Map<String, dynamic>;
    expect(body['app'], 'hibiki');
    expect((body['pairing'] as Map)['v2'], isTrue);
    expect((body['tls'] as Map)['enabled'], isFalse); // 无 securityContext。
    expect(body['deviceName'], 'Hibiki · mac');
  });

  test('GET /api/ping 不泄漏 token', () async {
    await startServer();
    final http.Response resp = await http.get(pingUri());
    expect(resp.statusCode, 200);
    expect(resp.body.contains('tok'), isFalse);
  });

  test('POST /api/ping 返回 405', () async {
    await startServer();
    final http.Response resp = await http.post(pingUri());
    expect(resp.statusCode, 405);
  });

  test('未配 deviceName 时 ping 不含该字段', () async {
    await startServer();
    final http.Response resp = await http.get(pingUri());
    final Map<String, dynamic> body =
        jsonDecode(resp.body) as Map<String, dynamic>;
    expect(body.containsKey('deviceName'), isFalse);
  });
}
