import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
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

    setUp(() async {
      approvalRemotes = <String?>[];
      tempDir = Directory.systemTemp.createTempSync('fushi_dual_stack_test');
      server =
          FushiSyncServer(
              syncDataDir: tempDir.path,
              port: 0,
              token: 'dual-stack-token',
              allowLan: true,
            )
            ..onPairRequest = ((FushiPairRequest r) async {
              approvalRemotes.add(r.remoteAddress);
              return true;
            })
            ..lanRequiresPinProvider = (() async => false);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<Map<String, dynamic>> pairV2(String host) async {
      final http.Response resp = await http.post(
        Uri.parse('http://$host:${server.port}/api/pair/v2'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, String>{'clientNonce': 'cn-dual'}),
      );
      expect(resp.statusCode, 200);
      return jsonDecode(resp.body) as Map<String, dynamic>;
    }

    test('v4 对端经双栈 socket 仍判 LAN（免 PIN）', () async {
      final Map<String, dynamic> body = await pairV2('127.0.0.1');
      expect(body['pinRequired'], isFalse);
    });

    test('v6 回环可达且判 LAN', () async {
      final http.Response ping = await http.get(
        Uri.parse('http://[::1]:${server.port}/api/ping'),
      );
      expect(ping.statusCode, 200);
      final Map<String, dynamic> body = await pairV2('[::1]');
      expect(body['pinRequired'], isFalse);
    });

    test('审批里的来源地址是还原后的 v4，而不是 ::ffff: 写法', () async {
      final Map<String, dynamic> body = await pairV2('127.0.0.1');
      final http.Response confirm = await http.post(
        Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2/confirm'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, String>{'sessionId': body['sessionId']}),
      );
      expect(confirm.statusCode, 200);
      expect(approvalRemotes, <String?>['127.0.0.1']);
    });
  });
}
