import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/src/sync/pairing/hibiki_pair_v2_client.dart';
import 'package:fushi/src/sync/tls/hibiki_tls_identity.dart';

/// TODO-1330：互联「测试连接」端到端回归——复现用户的内网场景整链：
///   1. host 起真 HibikiSyncServer（默认开 TLS，自签证书）+ per-peer token 存储。
///   2. client 用真实 v2 配对客户端做 LAN 免 PIN 配对，拿回 host 签发的 per-peer token。
///   3. client 用「该 per-peer token + host 指纹」调 testConnection（「测试连接」按钮路径）。
///
/// 这把三段既有测试（pair_v2 契约 / testConnection TLS 指纹 / per-peer token 鉴权）串成
/// 一条真实端到端链，钉住「刚在内网配对成功的地址，点测试连接必须通」——即用户报的
/// Problem ①「刚绑定的内网互联点测试连接还是失败」的根因回归守卫。同时证明 client 显示的
/// per-peer token 与 host 共享 token 天生不同（Problem ③）却都能鉴权。
void main() {
  test('LAN 免PIN 配对 → per-peer token（≠共享）+ 指纹 → 测试连接成功', () async {
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_e2e_lan_pair');
    final ({String certificatePem, String privateKeyPem}) gen =
        HibikiSelfSignedCertGenerator.generate(
      commonName: 'hibiki-e2e',
      sanIpAddresses: <String>['127.0.0.1'],
    );
    final String fingerprint =
        HibikiTlsIdentityStore.fingerprintOf(gen.certificatePem);
    final SecurityContext serverCtx = SecurityContext()
      ..useCertificateChainBytes(gen.certificatePem.codeUnits)
      ..usePrivateKeyBytes(gen.privateKeyPem.codeUnits);

    const String sharedToken = 'host-shared-token';
    final Set<String> peerTokens = <String>{};
    final HibikiSyncServer server = HibikiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: sharedToken,
      allowLan: true,
      securityContext: serverCtx,
      hostFingerprint: fingerprint,
    )
      ..onPairRequest = ((HibikiPairRequest r) async => true)
      ..lanRequiresPinProvider = (() async => false)
      ..onPeerPaired = ((HibikiPairedPeerRegistration reg) async {
        peerTokens.add(reg.token);
      })
      ..pairedPeerTokensProvider = (() async => peerTokens);
    await server.start();
    final String baseUrl = 'https://127.0.0.1:${server.port}';

    try {
      // Step 2: 真实 v2 配对（LAN 免 PIN）。client 上报 deviceId → host 签发 per-peer
      // token（即 client「访问令牌」框显示的值）。
      final HibikiPairV2Client client = HibikiPairV2Client(
        baseUrl: baseUrl,
        expectedFingerprint: fingerprint,
      );
      final HibikiPairV2Outcome outcome = await client.pair(
        deviceName: 'Galaxy S21',
        clientDeviceId: 'device-abc-123',
      );
      expect(outcome, isA<HibikiPairV2Success>(), reason: 'LAN 免PIN 配对应成功');
      final String perPeerToken = (outcome as HibikiPairV2Success).token;
      // Problem ③：per-peer token 与 host 共享 token 天生不同（设计），且被 host 受理。
      expect(perPeerToken, isNot(sharedToken),
          reason: 'client 显示的是 host 按本设备签发的专属 token，≠ host 共享 token');
      expect(peerTokens.contains(perPeerToken), isTrue,
          reason: 'host 应已把该 per-peer token 落库并受理鉴权');

      // Step 3：Problem ①——「测试连接」用「存下的 per-peer token + host 指纹」必须通。
      await InterconnectSyncBackend.instance.testConnection(
        url: baseUrl,
        token: perPeerToken,
        fingerprint: fingerprint,
      );
      // 无异常抛出即通过（testConnection 视 <400 且非 401/403 为成功）。
    } finally {
      await server.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  });
}
