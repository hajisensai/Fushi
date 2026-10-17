import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_v2_client.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:fushi_engine/sync/pairing/interconnect_device_key.dart';
import 'package:http/http.dart' as http;

/// PR #2258 审查问题 1 / 2 的回归：「我的设备」资格绑定在**单次配对会话**上，并且必须有
/// 设备私钥签名证明。
///
/// 旧实现把「审批时选了我的设备」按 client 自报的 deviceId 放进全局集合，PIN 错 / 会话
/// 过期 / 没 confirm 都不清；之后同一 deviceId 走免审批的扫码票据配对就把残留标记取走，
/// 拿到账户满权限。现在：
/// - 选择存在本会话的 [FushiPairOwnerDeviceGrant] 上，会话作废它就作废；
/// - 票据会话没有 grant，永远不是「我的设备」；
/// - 落成「我的设备」还要求 client 在 confirm 里用设备私钥签过本会话（deviceId 可冒报，
///   私钥签名冒不了）。
void main() {
  const String shownPin = '123456';
  late Directory tempDir;
  late FushiSyncServer server;
  late List<FushiPairRequest> approvals;
  late List<FushiPairedPeerRegistration> registrations;
  // 审批 UI 的选择：true = 「允许 · 这是我的设备」。
  late bool chooseOwner;

  Future<void> startServer({required bool lanRequiresPin}) async {
    tempDir = Directory.systemTemp.createTempSync('fushi_owner_binding_test');
    approvals = <FushiPairRequest>[];
    registrations = <FushiPairedPeerRegistration>[];
    chooseOwner = true;
    final Set<String> tokens = <String>{};
    server =
        FushiSyncServer(
            syncDataDir: tempDir.path,
            port: 0,
            token: 'shared-token',
            allowLan: true,
          )
          ..onPairRequest = ((FushiPairRequest r) async {
            approvals.add(r);
            final FushiPairOwnerDeviceGrant? grant = r.ownerDeviceGrant;
            if (grant != null) grant.granted = chooseOwner;
            return true;
          })
          ..onPairPinGenerated = ((FushiPairSession _) => shownPin)
          ..lanRequiresPinProvider = (() async => lanRequiresPin)
          ..onPeerPaired = ((FushiPairedPeerRegistration reg) async {
            registrations.add(reg);
            tokens.add(reg.token);
          })
          ..pairedPeerTokensProvider = (() async => tokens);
    await server.start();
  }

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  FushiPairV2Client client() => FushiPairV2Client(
    baseUrl: 'http://127.0.0.1:${server.port}',
    expectedFingerprint: '',
  );

  test('创建阶段批了「我的设备」→ PIN 错 → 同 id 扫码票据配对：不是我的设备', () async {
    await startServer(lanRequiresPin: true);
    final InterconnectDeviceKey key = InterconnectDeviceKey.generate();

    final FushiPairV2Outcome failed = await client().pair(
      deviceName: 'Phone',
      clientDeviceId: 'dev-victim',
      deviceKey: key,
      pinProvider: () async => '000000',
    );
    expect(failed, isA<FushiPairV2Failure>());
    expect((failed as FushiPairV2Failure).reason, 'pin');
    // 创建阶段确实弹了审批、并且选了「我的设备」。
    expect(approvals, hasLength(1));
    expect(approvals.single.ownerDeviceGrant?.granted, isTrue);
    expect(registrations, isEmpty);

    final FushiPairTicket ticket = server.issuePairTicket();
    final FushiPairV2Outcome viaTicket = await client().pair(
      deviceName: 'Phone',
      clientDeviceId: 'dev-victim',
      deviceKey: key,
      ticketId: ticket.id,
      pinProvider: () async => ticket.secret,
    );
    expect(viaTicket, isA<FushiPairV2Success>());
    // 票据配对不弹审批，也不继承上一次会话的选择。
    expect(approvals, hasLength(1));
    expect(registrations, hasLength(1));
    expect(registrations.single.peerId, 'dev-victim');
    expect(registrations.single.ownerDevice, isFalse);
    // 设备钥匙照样验签记指纹（供之后在列表里手动标记）。
    expect(registrations.single.deviceKeyFingerprint, key.fingerprint);
  });

  test('正常 PIN 配对 + 选「我的设备」+ 设备钥匙验签通过：是我的设备', () async {
    await startServer(lanRequiresPin: true);
    final InterconnectDeviceKey key = InterconnectDeviceKey.generate();

    final FushiPairV2Outcome outcome = await client().pair(
      deviceName: 'Phone',
      clientDeviceId: 'dev-owner',
      deviceKey: key,
      pinProvider: () async => shownPin,
    );
    expect(outcome, isA<FushiPairV2Success>());
    expect(registrations.single.ownerDevice, isTrue);
    expect(registrations.single.deviceKeyFingerprint, key.fingerprint);
  });

  test('PIN 配对选了「仅互联」：不是我的设备', () async {
    await startServer(lanRequiresPin: true);
    chooseOwner = false;
    final FushiPairV2Outcome outcome = await client().pair(
      deviceName: 'Phone',
      clientDeviceId: 'dev-plain',
      deviceKey: InterconnectDeviceKey.generate(),
      pinProvider: () async => shownPin,
    );
    expect(outcome, isA<FushiPairV2Success>());
    expect(registrations.single.ownerDevice, isFalse);
  });

  test('LAN 免 PIN（confirm 阶段审批）+ 设备钥匙：同样可授予我的设备', () async {
    await startServer(lanRequiresPin: false);
    final InterconnectDeviceKey key = InterconnectDeviceKey.generate();
    final FushiPairV2Outcome outcome = await client().pair(
      deviceName: 'Phone',
      clientDeviceId: 'dev-lan',
      deviceKey: key,
    );
    expect(outcome, isA<FushiPairV2Success>());
    expect(approvals.single.ownerDeviceGrant, isNotNull);
    expect(registrations.single.ownerDevice, isTrue);
    expect(registrations.single.deviceKeyFingerprint, key.fingerprint);
  });

  test('旧 client（没有设备钥匙）：审批不提供「我的设备」，配对照常', () async {
    await startServer(lanRequiresPin: true);
    final FushiPairV2Outcome outcome = await client().pair(
      deviceName: 'Phone',
      clientDeviceId: 'dev-legacy',
      pinProvider: () async => shownPin,
    );
    expect(outcome, isA<FushiPairV2Success>());
    expect(approvals.single.ownerDeviceGrant, isNull);
    expect(registrations.single.ownerDevice, isFalse);
    expect(registrations.single.deviceKeyFingerprint, isNull);
  });

  test('冒用别人的公钥（签名私钥对不上）：配对成功但拿不到我的设备', () async {
    await startServer(lanRequiresPin: true);
    final InterconnectDeviceKey victim = InterconnectDeviceKey.generate();
    final InterconnectDeviceKey attacker = InterconnectDeviceKey.generate();
    final Uri base = Uri.parse('http://127.0.0.1:${server.port}');
    const String clientNonce = 'attacker-client-nonce';

    final http.Response start = await http.post(
      base.resolve('/api/pair/v2'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'name': 'Phone',
        'clientNonce': clientNonce,
        'clientDeviceId': 'dev-victim',
        'devicePubkey': victim.pubkey,
      }),
    );
    expect(start.statusCode, 200);
    final Map<String, dynamic> started =
        jsonDecode(start.body) as Map<String, dynamic>;
    final String sessionId = started['sessionId'] as String;
    final String hostNonce = started['hostNonce'] as String;

    final http.Response confirm = await http.post(
      base.resolve('/api/pair/v2/confirm'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': sessionId,
        'pinProof': FushiPairingProtocol.computePinProof(
          pin: shownPin,
          clientNonce: clientNonce,
          hostNonce: hostNonce,
        ),
        'deviceProof': attacker.signPairProof(
          sessionId: sessionId,
          hostNonce: hostNonce,
          clientNonce: clientNonce,
          clientDeviceId: 'dev-victim',
        ),
      }),
    );
    expect(confirm.statusCode, 200);
    expect(registrations.single.ownerDevice, isFalse);
    expect(registrations.single.deviceKeyFingerprint, isNull);
  });

  test('设备钥匙证明绑定会话：拿别的会话的签名重放无效', () {
    final InterconnectDeviceKey key = InterconnectDeviceKey.generate();
    final String proof = key.signPairProof(
      sessionId: 's1',
      hostNonce: 'h1',
      clientNonce: 'c1',
      clientDeviceId: 'dev',
    );
    bool verify({String sessionId = 's1', String hostNonce = 'h1'}) =>
        verifyInterconnectPairDeviceProof(
          sessionId: sessionId,
          hostNonce: hostNonce,
          clientNonce: 'c1',
          clientDeviceId: 'dev',
          devicePubkey: key.pubkey,
          proof: proof,
        );
    expect(verify(), isTrue);
    expect(verify(sessionId: 's2'), isFalse);
    expect(verify(hostNonce: 'h2'), isFalse);
    // 私钥持久化往返后仍是同一把钥匙（同一指纹）。
    expect(
      InterconnectDeviceKey.decodePrivateKey(
        key.encodePrivateKey(),
      ).fingerprint,
      key.fingerprint,
    );
  });
}
