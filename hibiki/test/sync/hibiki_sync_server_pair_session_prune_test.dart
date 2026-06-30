import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/pairing/hibiki_pairing_protocol.dart';
import 'package:http/http.dart' as http;

// TODO-961 M1 prereq #2: /api/pair/v2 配对会话的 TTL / 上限 / prune 行为。
// 只发 pair/v2 不 confirm 的攻击者不得让 _pairSessions 永久堆积（慢速 DoS）。
void main() {
  late Directory tempDir;
  late HibikiSyncServer server;
  // 可控时钟：测试通过推进它模拟会话过期。
  DateTime fakeNow = DateTime.utc(2026, 1, 1, 12, 0, 0);

  Future<void> startServer() async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_prune_test');
    server = HibikiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'tok',
      allowLan: true,
      now: () => fakeNow,
    )
      ..onPairRequest = ((HibikiPairRequest _) async => true)
      ..onPairPinGenerated = ((HibikiPairSession s) => '000000')
      ..lanRequiresPinProvider = (() async => false);
    await server.start();
  }

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    fakeNow = DateTime.utc(2026, 1, 1, 12, 0, 0);
  });

  Future<String> startSession(String clientNonce) async {
    final http.Response resp = await http.post(
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'name': 'peer',
        'clientNonce': clientNonce,
      }),
    );
    expect(resp.statusCode, 200);
    return (jsonDecode(resp.body) as Map<String, dynamic>)['sessionId']
        as String;
  }

  test('会话在 TTL 之后被 prune：超时 confirm 当未知会话拒绝', () async {
    await startServer();
    final String sid = await startSession('cn-ttl');
    expect(server.pendingPairSessionCount, 1);

    // 推进时钟超过 90s TTL，再开一个新会话触发 prune。
    fakeNow = fakeNow.add(const Duration(seconds: 91));
    await startSession('cn-fresh'); // 创建路径会 prune 掉过期的 cn-ttl 会话。

    // 过期会话已被清掉 → 对它 confirm 返回 403 declined（未知会话）。
    final http.Response resp = await http.post(
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2/confirm'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'sessionId': sid}),
    );
    expect(resp.statusCode, 403);
  });

  test('confirm 路径也 prune 过期会话（不靠后续 create 触发）', () async {
    await startServer();
    final String sid = await startSession('cn-confirm-ttl');
    fakeNow = fakeNow.add(const Duration(seconds: 91));
    // 不再创建新会话，直接 confirm —— confirm 内的 prune 应已清掉它。
    final http.Response resp = await http.post(
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2/confirm'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'sessionId': sid}),
    );
    expect(resp.statusCode, 403);
  });

  test('会话数受上限约束：高频发起 pair/v2 不会无界堆积', () async {
    await startServer();
    // 连发远超上限（64）的会话，全在 TTL 内（时钟不动）。
    for (int i = 0; i < 200; i++) {
      await startSession('cn-flood-$i');
    }
    // 不应无界增长：被上限 + 淘汰最旧者控制住（<= 64）。
    expect(server.pendingPairSessionCount, lessThanOrEqualTo(64));
  });

  test('TTL 内未过期会话仍可正常 confirm（不误杀活跃会话）', () async {
    await startServer();
    final String sid = await startSession('cn-live');
    // 只推进一点点（远小于 TTL）。
    fakeNow = fakeNow.add(const Duration(seconds: 5));
    final http.Response resp = await http.post(
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2/confirm'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'sessionId': sid}),
    );
    expect(resp.statusCode, 200);
    expect((jsonDecode(resp.body) as Map<String, dynamic>)['token'], 'tok');
  });
}
