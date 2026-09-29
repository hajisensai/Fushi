import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:http/http.dart' as http;

/// 互联主机 IPv6 双栈监听（docs/specs/2026-09-28-interconnect-remote-reach.md §3）。
///
/// 双栈 socket 把 v4 对端报成 `::ffff:a.b.c.d`：不还原的话 LAN 免 PIN 整个失效、
/// 限速来源 key 与 `lastSeenIp` 也会分裂成两种写法。
void main() {
  group('unmapIPv4MappedAddress', () {
    test('还原 v4 映射地址', () {
      expect(
        FushiPairingProtocol.unmapIPv4MappedAddress('::ffff:192.168.1.5'),
        '192.168.1.5',
      );
      expect(
        FushiPairingProtocol.unmapIPv4MappedAddress('::FFFF:127.0.0.1'),
        '127.0.0.1',
      );
    });

    test('非映射地址原样返回', () {
      expect(FushiPairingProtocol.unmapIPv4MappedAddress('::1'), '::1');
      expect(
        FushiPairingProtocol.unmapIPv4MappedAddress('2408:8207::1'),
        '2408:8207::1',
      );
      expect(
        FushiPairingProtocol.unmapIPv4MappedAddress('10.0.0.2'),
        '10.0.0.2',
      );
      // `::ffff:` 后不是点分 v4（纯十六进制写法）——不猜，原样。
      expect(
        FushiPairingProtocol.unmapIPv4MappedAddress('::ffff:c0a8:105'),
        '::ffff:c0a8:105',
      );
    });

    test('isPrivateLanAddress 认映射后的私网 v4、拒公网 v4 与公网 v6', () {
      expect(
        FushiPairingProtocol.isPrivateLanAddress('::ffff:192.168.1.5'),
        isTrue,
      );
      expect(
        FushiPairingProtocol.isPrivateLanAddress('::ffff:8.8.8.8'),
        isFalse,
      );
      expect(FushiPairingProtocol.isPrivateLanAddress('2408:8207::1'), isFalse);
    });
  });

  group('双栈监听', () {
    late Directory tempDir;
    late FushiSyncServer server;
    late List<String?> approvalRemotes;

    Future<void> start({required bool tls}) async {
      approvalRemotes = <String?>[];
      tempDir = Directory.systemTemp.createTempSync('fushi_dual_stack_test');
      SecurityContext? ctx;
      if (tls) {
        final FushiTlsIdentity id =
            await FushiTlsIdentityStore(dataDir: tempDir.path).loadOrCreate();
        ctx = SecurityContext()
          ..useCertificateChainBytes(utf8.encode(id.certificatePem))
          ..usePrivateKeyBytes(utf8.encode(id.privateKeyPem));
      }
      server = FushiSyncServer(
        syncDataDir: tempDir.path,
        port: 0,
        token: 'dual-stack-token',
        allowLan: true,
        securityContext: ctx,
      )
        ..onPairRequest = ((FushiPairRequest r) async {
          approvalRemotes.add(r.remoteAddress);
          return true;
        })
        ..lanRequiresPinProvider = (() async => false);
      await server.start();
    }

    tearDown(() async {
      await server.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// 自签证书的测试 client（生产走指纹钉扎，这里只验监听面）。
    Future<Map<String, dynamic>> pairV2(String host, {required bool tls}) async {
      final HttpClient client = HttpClient()
        ..badCertificateCallback = (X509Certificate c, String h, int p) => true;
      try {
        final HttpClientRequest req = await client.postUrl(Uri.parse(
            '${tls ? 'https' : 'http'}://$host:${server.port}/api/pair/v2'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(<String, String>{'clientNonce': 'cn-dual'}));
        final HttpClientResponse resp = await req.close();
        expect(resp.statusCode, 200);
        return jsonDecode(await resp.transform(utf8.decoder).join())
            as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    }

    test('明文 host 维持只监听 v4（不在全局 IPv6 上裸奔）', () async {
      await start(tls: false);
      expect((await pairV2('127.0.0.1', tls: false))['pinRequired'], isFalse);
      await expectLater(
        http.get(Uri.parse('http://[::1]:${server.port}/api/ping')),
        throwsA(anything),
        reason: '明文 host 不该出现在 v6 上',
      );
    });

    test('TLS host 双栈：v4 对端经双栈 socket 仍判 LAN（免 PIN）', () async {
      await start(tls: true);
      expect((await pairV2('127.0.0.1', tls: true))['pinRequired'], isFalse);
    });

    test('TLS host 双栈：v6 回环可达且判 LAN', () async {
      await start(tls: true);
      expect((await pairV2('[::1]', tls: true))['pinRequired'], isFalse);
    });

    test('审批里的来源地址是还原后的 v4，而不是 ::ffff: 写法', () async {
      await start(tls: true);
      final Map<String, dynamic> body = await pairV2('127.0.0.1', tls: true);
      final HttpClient client = HttpClient()
        ..badCertificateCallback = (X509Certificate c, String h, int p) => true;
      try {
        final HttpClientRequest req = await client.postUrl(Uri.parse(
            'https://127.0.0.1:${server.port}/api/pair/v2/confirm'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(<String, String>{'sessionId': body['sessionId']}));
        final HttpClientResponse resp = await req.close();
        await resp.drain<void>();
        expect(resp.statusCode, 200);
      } finally {
        client.close(force: true);
      }
      expect(approvalRemotes, <String?>['127.0.0.1']);
    });
  });
}
