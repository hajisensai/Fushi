import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/tls/hibiki_tls_identity.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

/// TODO-1330 / BUG-616：互联「测试连接」对已配对 https host 必须带上钉扎指纹。
///
/// 新版 host 首次启用默认开 TLS（applyFirstHostingTlsDefault），刚配对的地址就是
/// `https://` + 自签证书。真正的 sync 走 pinned client 可达，但「测试连接」按钮此前
/// 用裸 WebDavOps（无指纹）→ 自签 TLS 握手必失败 → 把可连 host 误报「连接失败」。
/// 本测试用真实自签 HTTPS server 端到端证明：带指纹 → 通；不带指纹 → 握手失败。
void main() {
  late HibikiTlsIdentity identity;
  late HttpServer server;
  late String baseUrl;
  const String token = 'peer-token-abc';

  setUp(() async {
    final ({String certificatePem, String privateKeyPem}) generated =
        HibikiSelfSignedCertGenerator.generate(
      commonName: 'hibiki-testconn',
      sanIpAddresses: <String>['127.0.0.1'],
    );
    identity = HibikiTlsIdentity(
      certificatePem: generated.certificatePem,
      privateKeyPem: generated.privateKeyPem,
      fingerprintSha256:
          HibikiTlsIdentityStore.fingerprintOf(generated.certificatePem),
    );
    final SecurityContext serverCtx = SecurityContext()
      ..useCertificateChainBytes(identity.certificatePem.codeUnits)
      ..usePrivateKeyBytes(identity.privateKeyPem.codeUnits);

    // 极简 WebDAV 面：Basic 鉴权正确回 207（testConnection 视 <400 且非 401/403 为
    // 成功），否则 401（映射 SyncAuthError）。
    shelf.Response handler(shelf.Request req) {
      final String expected =
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';
      if (req.headers['authorization'] != expected) {
        return shelf.Response(401);
      }
      return shelf.Response(207, body: '<multistatus/>');
    }

    server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
      securityContext: serverCtx,
    );
    baseUrl = 'https://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('带正确指纹 + 正确 token → 测试连接成功（不抛）', () async {
    await InterconnectSyncBackend.instance.testConnection(
      url: baseUrl,
      token: token,
      fingerprint: identity.fingerprintSha256,
    );
  });

  test('漏传指纹（旧行为）→ 自签 TLS 握手失败（回归守卫）', () async {
    await expectLater(
      InterconnectSyncBackend.instance.testConnection(
        url: baseUrl,
        token: token,
        // fingerprint 省略：裸 client 不接受自签证书 → 握手失败。
      ),
      throwsA(isA<Object>()),
      reason: '不带指纹时自签 https 必须失败——这正是修复前测试连接恒失败的根因。',
    );
  });

  test('指纹对但 token 错 → 鉴权失败（钉扎不放水鉴权）', () async {
    await expectLater(
      InterconnectSyncBackend.instance.testConnection(
        url: baseUrl,
        token: 'wrong-token',
        fingerprint: identity.fingerprintSha256,
      ),
      throwsA(isA<Object>()),
    );
  });
}
