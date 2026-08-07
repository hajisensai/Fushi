import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:http/http.dart' as http;

/// TODO-961 M1b: per-peer token 派发 / 鉴权 / 吊销的 server 行为测试。
///
/// 用一个内存态的 fake「peer 表」（Map<peerId, token>）代替真 DB，验证：
/// (1) confirm 携带 clientDeviceId + 接线 onPeerPaired -> 派发 per-peer token（!= 共享
///     token）并经回调落库；
/// (2) auth：per-peer token（经 pairedPeerTokensProvider 供给）与共享 token 都受理；
/// (3) 吊销（从 fake 表删行 + invalidatePeerTokenCache）后该 token 立即被 401 拒绝；
/// (4) 向后兼容：confirm 不带 clientDeviceId（旧 client）-> 回退共享 token，不落 per-peer 行。
void main() {
  late Directory tempDir;
  late FushiSyncServer server;
  // Fake per-peer 表：peerId -> token。onPeerPaired 写入、provider 读出全部 token。
  late Map<String, String> peerTable;

  Future<void> startServer({bool wirePeerCallbacks = true}) async {
    tempDir = Directory.systemTemp.createTempSync('hibiki_peer_token_test');
    peerTable = <String, String>{};
    server = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: 'shared-token',
      allowLan: true,
    )
      ..onPairRequest = ((FushiPairRequest _) async => true)
      ..lanRequiresPinProvider = (() async => false);
    if (wirePeerCallbacks) {
      server
        ..onPeerPaired = ((FushiPairedPeerRegistration reg) async {
          peerTable[reg.peerId] = reg.token;
        })
        ..pairedPeerTokensProvider = (() async => peerTable.values.toSet());
    }
    await server.start();
  }

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Uri v2Uri() => Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2');
  Uri confirmUri() =>
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2/confirm');
  Uri capabilitiesUri() =>
      Uri.parse('http://127.0.0.1:${server.port}/api/capabilities');
  Uri serviceConfigUri() => Uri.parse(
      'http://127.0.0.1:${server.port}/api/interconnect/service-config');

  Future<String> startSession(String clientNonce,
      {String? clientDeviceId}) async {
    final http.Response resp = await http.post(
      v2Uri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'name': 'Galaxy S21',
        'clientNonce': clientNonce,
        if (clientDeviceId != null) 'clientDeviceId': clientDeviceId,
      }),
    );
    expect(resp.statusCode, 200);
    return (jsonDecode(resp.body) as Map<String, dynamic>)['sessionId']
        as String;
  }

  Future<String> confirm(String sessionId) async {
    final http.Response resp = await http.post(
      confirmUri(),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'sessionId': sessionId}),
    );
    expect(resp.statusCode, 200);
    return (jsonDecode(resp.body) as Map<String, dynamic>)['token'] as String;
  }

  /// GET /api/capabilities with Basic (hibiki:<token>) — a convenient
  /// authenticated endpoint to probe whether [token] is accepted.
  Future<int> authProbe(String token) async {
    final http.Response resp = await http.get(
      capabilitiesUri(),
      headers: <String, String>{
        'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      },
    );
    return resp.statusCode;
  }

  test('confirm with clientDeviceId mints a per-peer token and persists it',
      () async {
    await startServer();
    final String sid = await startSession('cn-1', clientDeviceId: 'device-aaa');
    final String issued = await confirm(sid);

    // 派发的是 per-peer token，绝非共享 token。
    expect(issued, isNot('shared-token'));
    // 经 onPeerPaired 落库：fake 表里 device-aaa 的 token 正是回给 client 的那个。
    expect(peerTable['device-aaa'], issued);
  });

  test('per-peer token authenticates; shared token still works too', () async {
    await startServer();
    final String sid = await startSession('cn-2', clientDeviceId: 'device-bbb');
    final String peerToken = await confirm(sid);

    // per-peer token 受理。
    expect(await authProbe(peerToken), 200);
    // 共享 token 兼容路径仍受理（未重新配对的老设备继续可用）。
    expect(await authProbe('shared-token'), 200);
    // 随机错误 token 被拒。
    expect(await authProbe('bogus-token'), 401);
  });

  test('service config refuses plaintext HTTP even for a paired peer',
      () async {
    await startServer();
    final String sid =
        await startSession('cn-secure', clientDeviceId: 'device-secure');
    final String peerToken = await confirm(sid);

    final http.Response response = await http.get(
      serviceConfigUri(),
      headers: <String, String>{
        'Authorization':
            'Basic ${base64Encode(utf8.encode('hibiki:$peerToken'))}',
      },
    );
    expect(response.statusCode, 403);
    expect(response.body, contains('HTTPS required'));
  });

  test('revoking a peer token rejects it on the next request', () async {
    await startServer();
    final String sid = await startSession('cn-3', clientDeviceId: 'device-ccc');
    final String peerToken = await confirm(sid);
    expect(await authProbe(peerToken), 200);

    // 吊销：从 fake 表删行 + 清 server token 缓存（controller.revokePeer 的等价动作）。
    peerTable.remove('device-ccc');
    server.invalidatePeerTokenCache();

    // 吊销即时生效：同一 token 现在被 401 拒绝。
    expect(await authProbe(peerToken), 401);
    // 共享 token 不受吊销影响。
    expect(await authProbe('shared-token'), 200);
  });

  test('confirm without clientDeviceId falls back to shared token (compat)',
      () async {
    await startServer();
    final String sid = await startSession('cn-4'); // 无 clientDeviceId
    final String issued = await confirm(sid);

    // 旧 client 无稳定身份 -> 回退共享 token，不落 per-peer 行。
    expect(issued, 'shared-token');
    expect(peerTable, isEmpty);
  });

  test('no peer callbacks wired: confirm always returns shared token',
      () async {
    await startServer(wirePeerCallbacks: false);
    final String sid = await startSession('cn-5', clientDeviceId: 'device-ddd');
    final String issued = await confirm(sid);

    // 无 onPeerPaired 接线（如纯协议单测 / 无 DB）-> 共享 token，行为零变化。
    expect(issued, 'shared-token');
    expect(peerTable, isEmpty);
  });

  test('re-pairing the same device rotates its token (peerId is stable id)',
      () async {
    await startServer();
    final String sid1 =
        await startSession('cn-6a', clientDeviceId: 'device-eee');
    final String token1 = await confirm(sid1);
    final String sid2 =
        await startSession('cn-6b', clientDeviceId: 'device-eee');
    final String token2 = await confirm(sid2);

    // 同一 deviceId 二次配对派新 token；fake 表按 peerId upsert，仍只有一行。
    expect(token2, isNot(token1));
    expect(peerTable.length, 1);
    expect(peerTable['device-eee'], token2);
  });
}
