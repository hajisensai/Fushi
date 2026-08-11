import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/pairing/fushi_pairing_protocol.dart';
import 'package:http/http.dart' as http;

/// BUG-1556：配对会话的 90s TTL 从**请求入口**起算，而 pinRequired 会话在同一个
/// handler 里还要 `await` host 的人工审批（用户去拿手机、正在忙）。审批一慢，会话在被
/// 写进 `_pairSessions` 的那一刻就已经过期，client 紧接着的 confirm 必被 prune 掉 ——
/// 而且当时还被报成 403 `declined`「对端拒绝」，可 host 分明刚点了允许，用户照着这个
/// 错误方向能排查一晚上。
///
/// 修复：TTL 从**审批通过**（会话真正可用）那一刻起算；过期返回专用 reason `expired`。
void main() {
  late Directory tempDir;
  late FushiSyncServer server;
  DateTime fakeNow = DateTime.utc(2026, 1, 1, 12, 0, 0);
  const String kPin = '424242';

  Future<void> startServer({
    required bool lanRequiresPin,
    Duration approvalDelay = Duration.zero,
  }) async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_pair_ttl_test');
    server = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'tok',
      allowLan: true,
      now: () => fakeNow,
    )
      // host 审批「慢」= 审批期间墙上时钟推进（真实世界里就是用户去够手机的那段时间）。
      ..onPairRequest = ((FushiPairRequest _) async {
        fakeNow = fakeNow.add(approvalDelay);
        return true;
      })
      ..onPairPinGenerated = ((FushiPairSession _) => kPin)
      ..lanRequiresPinProvider = (() async => lanRequiresPin);
    await server.start();
  }

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    fakeNow = DateTime.utc(2026, 1, 1, 12, 0, 0);
  });

  Future<(String sessionId, String hostNonce)> startSession(
    String clientNonce,
  ) async {
    final http.Response resp = await http.post(
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'name': 'peer',
        'clientNonce': clientNonce,
      }),
    );
    expect(resp.statusCode, 200, reason: 'pair/v2 应创建会话');
    final Map<String, dynamic> body =
        jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['sessionId'] as String, body['hostNonce'] as String);
  }

  Future<http.Response> confirm(String sessionId, {String? pinProof}) {
    return http.post(
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2/confirm'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': sessionId,
        if (pinProof != null) 'pinProof': pinProof,
      }),
    );
  }

  test('host 审批耗时超过整个 TTL，配对仍能完成（TTL 从审批通过起算）', () async {
    // 审批耗掉 120s > 90s TTL：修复前会话一落地就过期，confirm 必失败。
    await startServer(
      lanRequiresPin: true,
      approvalDelay: const Duration(seconds: 120),
    );
    const String clientNonce = 'cn-slow-approval';
    final (String sid, String hostNonce) = await startSession(clientNonce);

    final http.Response resp = await confirm(
      sid,
      pinProof: FushiPairingProtocol.computePinProof(
        pin: kPin,
        clientNonce: clientNonce,
        hostNonce: hostNonce,
      ),
    );

    expect(resp.statusCode, 200,
        reason: 'BUG-1556：host 审批慢不该让配对必然失败——TTL 该从审批通过那一刻起算');
    expect((jsonDecode(resp.body) as Map<String, dynamic>)['token'], 'tok');
  });

  test('审批后仍旧超时的会话被拒，且原因是 expired 而不是 declined', () async {
    await startServer(lanRequiresPin: true);
    const String clientNonce = 'cn-expire-after-approval';
    final (String sid, String hostNonce) = await startSession(clientNonce);

    // 审批已过（瞬时），此后用户输 PIN 输了 91s。
    fakeNow = fakeNow.add(const Duration(seconds: 91));
    final http.Response resp = await confirm(
      sid,
      pinProof: FushiPairingProtocol.computePinProof(
        pin: kPin,
        clientNonce: clientNonce,
        hostNonce: hostNonce,
      ),
    );

    expect(resp.statusCode, 403);
    expect(
      (jsonDecode(resp.body) as Map<String, dynamic>)['reason'],
      'expired',
      reason: 'BUG-1556：会话超时必须自成一类——报成 declined 会让用户以为对方拒绝了自己',
    );
  });

  test('免 PIN（LAN）会话的 TTL 语义不变：TTL 内可 confirm、超时报 expired', () async {
    await startServer(lanRequiresPin: false);
    final (String live, _) = await startSession('cn-lan-live');
    fakeNow = fakeNow.add(const Duration(seconds: 5));
    expect((await confirm(live)).statusCode, 200);

    final (String stale, _) = await startSession('cn-lan-stale');
    fakeNow = fakeNow.add(const Duration(seconds: 91));
    final http.Response resp = await confirm(stale);
    expect(resp.statusCode, 403);
    expect(
      (jsonDecode(resp.body) as Map<String, dynamic>)['reason'],
      'expired',
    );
  });

  test('伪造的 sessionId 仍报 declined（未知 ≠ 过期，不给攻击者额外信息）', () async {
    await startServer(lanRequiresPin: false);
    final http.Response resp = await confirm('never-existed');
    expect(resp.statusCode, 403);
    expect(
      (jsonDecode(resp.body) as Map<String, dynamic>)['reason'],
      'declined',
    );
  });
}
