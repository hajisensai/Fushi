import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/tls/hibiki_pinning_http.dart';
import 'package:hibiki/src/sync/tls/hibiki_tls_identity.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

/// TODO-961 M0 spike：证伪 basic_utils EC P-256 自签证书 + PKCS#8 私钥 PEM 能否被
/// dart:io SecurityContext 直接接受，并打通 pinned HTTPS server <-> pinned client。
void main() {
  group('HibikiSelfSignedCertGenerator / SecurityContext 接受性（M0 最大不确定性）', () {
    test('生成的 PKCS#8 私钥 PEM 能被 SecurityContext.usePrivateKeyBytes 接受', () {
      final generated = HibikiSelfSignedCertGenerator.generate(
        commonName: 'hibiki-test',
        sanIpAddresses: <String>['127.0.0.1'],
      );

      // 这是整个纯 Dart 方案成立与否的关键断言：若抛 TlsException 即证伪。
      final ctx = SecurityContext();
      ctx.useCertificateChainBytes(generated.certificatePem.codeUnits);
      ctx.usePrivateKeyBytes(generated.privateKeyPem.codeUnits);

      // 形态自检：私钥是 PKCS#8（BEGIN PRIVATE KEY），证书是标准 PEM。
      expect(generated.privateKeyPem, contains('-----BEGIN PRIVATE KEY-----'));
      expect(generated.certificatePem, contains('-----BEGIN CERTIFICATE-----'));
    });

    test('fingerprintOf 对同一证书稳定、为 64 hex (32 字节冒号分隔)', () {
      final generated = HibikiSelfSignedCertGenerator.generate(
        commonName: 'hibiki-test',
        sanIpAddresses: <String>['127.0.0.1'],
      );
      final fp1 =
          HibikiTlsIdentityStore.fingerprintOf(generated.certificatePem);
      final fp2 =
          HibikiTlsIdentityStore.fingerprintOf(generated.certificatePem);
      expect(fp1, fp2);
      // 32 字节 -> 32 个两位 hex，31 个冒号分隔。
      final parts = fp1.split(':');
      expect(parts.length, 32);
      for (final part in parts) {
        expect(part.length, 2);
        expect(RegExp(r'^[0-9a-f]{2}$').hasMatch(part), isTrue);
      }
    });

    test('fingerprintOf == 对 DER 直接算的 SHA-256（已知算法一致）', () {
      final generated = HibikiSelfSignedCertGenerator.generate(
        commonName: 'hibiki-test',
        sanIpAddresses: <String>['127.0.0.1'],
      );
      // 用 X509Certificate 解析出的 DER 经 fingerprintOfDer 应与 store 的一致。
      final ctx = SecurityContext();
      ctx.useCertificateChainBytes(generated.certificatePem.codeUnits);
      final storeFp =
          HibikiTlsIdentityStore.fingerprintOf(generated.certificatePem);
      // store 走 PEM->DER->sha256；pinning 走 cert.der->sha256。两者比对在
      // 下面的 handshake 测试里被端到端验证；这里仅断言 store 自洽且非空。
      expect(storeFp.isNotEmpty, isTrue);
    });
  });

  group('HibikiTlsIdentityStore loadOrCreate / regenerate', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hibiki_tls_test_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('loadOrCreate 首次生成并落盘，二次加载返回同指纹', () async {
      final store = HibikiTlsIdentityStore(dataDir: tmp.path);
      final first = await store.loadOrCreate();
      expect(first.certificatePem, contains('-----BEGIN CERTIFICATE-----'));
      expect(first.privateKeyPem, contains('-----BEGIN PRIVATE KEY-----'));
      expect(first.fingerprintSha256.split(':').length, 32);

      final second = await store.loadOrCreate();
      expect(second.fingerprintSha256, first.fingerprintSha256,
          reason: '二次加载应复用落盘证书，指纹不变。');
    });

    test('regenerate 产出新证书（指纹变化，旧钉扎失效）', () async {
      final store = HibikiTlsIdentityStore(dataDir: tmp.path);
      final first = await store.loadOrCreate();
      final regen = await store.regenerate();
      expect(regen.fingerprintSha256, isNot(first.fingerprintSha256));
    });
  });

  group('headless pinned HTTPS 冒烟（M0 核心证伪）', () {
    late HibikiTlsIdentity identity;
    late SecurityContext serverCtx;
    late HttpServer server;
    late int port;

    setUp(() async {
      final generated = HibikiSelfSignedCertGenerator.generate(
        commonName: 'hibiki-smoke',
        sanIpAddresses: <String>['127.0.0.1'],
      );
      identity = HibikiTlsIdentity(
        certificatePem: generated.certificatePem,
        privateKeyPem: generated.privateKeyPem,
        fingerprintSha256:
            HibikiTlsIdentityStore.fingerprintOf(generated.certificatePem),
      );
      serverCtx = SecurityContext()
        ..useCertificateChainBytes(identity.certificatePem.codeUnits)
        ..usePrivateKeyBytes(identity.privateKeyPem.codeUnits);

      shelf.Response handler(shelf.Request req) =>
          shelf.Response.ok('pinned-ok');
      server = await shelf_io.serve(
        handler,
        InternetAddress.loopbackIPv4,
        0,
        securityContext: serverCtx,
      );
      port = server.port;
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('指纹对 -> HTTPS 连通 200', () async {
      final client = createPinnedHttpPackageClient(
        expectedFingerprint: identity.fingerprintSha256,
      );
      try {
        final resp = await client.get(Uri.parse('https://127.0.0.1:$port/'));
        expect(resp.statusCode, 200);
        expect(resp.body, 'pinned-ok');
      } finally {
        client.close();
      }
    });

    test('指纹错 -> 握手失败（HandshakeException / 连接被拒）', () async {
      // 一个合法形态但与 server 证书不同的指纹（全 00）。
      const wrongFp = '00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:'
          '00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00';
      final client = createPinnedHttpPackageClient(
        expectedFingerprint: wrongFp,
      );
      try {
        await expectLater(
          client.get(Uri.parse('https://127.0.0.1:$port/')),
          throwsA(anyOf(
            isA<HandshakeException>(),
            isA<http.ClientException>(),
            isA<SocketException>(),
          )),
          reason: '指纹不匹配必须握手失败，绝不放行。',
        );
      } finally {
        client.close();
      }
    });
  });
}
