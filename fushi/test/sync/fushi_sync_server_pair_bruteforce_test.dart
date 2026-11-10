import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// BUG-4280：PIN 防爆破。来源键不认自报 deviceId（IP，IPv6 按 /64 聚合）；按来源类别
/// 有总失败预算；会话上限按类别分区、单一来源只能挤掉自己的会话，票据会话不被挤掉。
/// 装配仿无头端：免 PIN 审批自动放行、pinRequired 会话无人工环节。
class _FakeConnectionInfo implements HttpConnectionInfo {
  _FakeConnectionInfo(String address)
    : remoteAddress = InternetAddress(address);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 40000;

  @override
  int get localPort => 8765;
}

const String _pin = '482913';
const String _wrongPin = '000000';

void main() {
  late Directory tempDir;
  late FushiSyncServer server;
  DateTime fakeNow = DateTime.utc(2026, 11, 10, 12);
  int nonceSeq = 0;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_pair_bruteforce_');
    fakeNow = DateTime.utc(2026, 11, 10, 12);
    server =
        FushiSyncServer(
            syncDataDir: tempDir.path,
            port: 0,
            token: 'super-secret-token',
            allowLan: true,
            now: () => fakeNow,
          )
          ..onPairRequest = ((FushiPairRequest _) async => true)
          ..onPairPinGenerated = ((FushiPairSession _) => _pin)
          ..lanRequiresPinProvider = (() async => false)
          ..loopbackPeerIsLan = false
          ..pinApprovalIsManual = false;
  });

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> post(
    String path,
    String peer,
    Map<String, Object?> body,
  ) async {
    final shelf.Response resp = await server.handleInProcess(
      shelf.Request(
        'POST',
        Uri.parse('http://fushi.test$path'),
        headers: <String, String>{'content-type': 'application/json'},
        body: jsonEncode(body),
        context: <String, Object>{
          'shelf.io.connection_info': _FakeConnectionInfo(peer),
        },
      ),
    );
    final String text = await resp.readAsString();
    final Object? decoded = text.isEmpty ? null : jsonDecode(text);
    return (
      resp.statusCode,
      decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
    );
  }

  /// 开一个会话；返回 (状态码, sessionId, clientNonce, hostNonce)。
  Future<(int, String?, String, String?)> open(
    String peer, {
    String? deviceId,
    String? ticket,
  }) async {
    final String cn = 'cn-${nonceSeq++}';
    final (
      int code,
      Map<String, dynamic> json,
    ) = await post('/api/pair/v2', peer, <String, Object?>{
      'name': 'Phone',
      'clientNonce': cn,
      'clientDeviceId': ?deviceId,
      'ticket': ?ticket,
    });
    return (
      code,
      json['sessionId'] as String?,
      cn,
      json['hostNonce'] as String?,
    );
  }

  Future<int> confirm(
    String peer,
    String sessionId,
    String cn,
    String hostNonce,
    String pin,
  ) async {
    final (
      int code,
      _,
    ) = await post('/api/pair/v2/confirm', peer, <String, Object?>{
      'sessionId': sessionId,
      'pinProof': FushiPairingProtocol.computePinProof(
        pin: pin,
        clientNonce: cn,
        hostNonce: hostNonce,
      ),
    });
    return code;
  }

  /// 「开会话 → 猜一次」；返回 confirm 的状态码（pair/v2 被拒时返回 pair/v2 的码）。
  Future<int> guess(
    String peer, {
    String? deviceId,
    String pin = _wrongPin,
  }) async {
    final (int code, String? sid, String cn, String? hn) = await open(
      peer,
      deviceId: deviceId,
    );
    if (code != 200) return code;
    return confirm(peer, sid!, cn, hn!, pin);
  }

  test(
    '例 1：同一 IP 每次换 clientDeviceId，第 5 次 confirm 起 429，pair/v2 也 429',
    () async {
      for (int i = 1; i <= 4; i++) {
        expect(
          await guess('203.0.113.5', deviceId: 'dev-$i'),
          401,
          reason: '第 $i 次',
        );
      }
      expect(await guess('203.0.113.5', deviceId: 'dev-5'), 429);
      final (int code, _, _, _) = await open('203.0.113.5', deviceId: 'dev-6');
      expect(code, 429, reason: '锁定期间不再开会话、不生成 PIN');
    },
  );

  test('例 2：20 个公网 IP 轮流猜，第 10 次失败锁住整个公网类别；解除后能配上', () async {
    final List<int> codes = <int>[
      for (int i = 1; i <= 10; i++) await guess('203.0.113.$i'),
    ];
    expect(codes.take(9), everyElement(401));
    expect(codes.last, 429);
    for (int i = 11; i <= 20; i++) {
      final (int code, _, _, _) = await open('203.0.113.$i');
      expect(code, 429, reason: '203.0.113.$i');
    }
    expect(server.pairingLockouts.keys, contains(FushiPairOriginClass.public));

    server.resetPairingLockout();
    expect(server.pairingLockouts, isEmpty);
    expect(await guess('203.0.113.21', pin: _pin), 200);
  });

  test('例 3：公网类别被锁时，局域网来源照常配对', () async {
    for (int i = 1; i <= 10; i++) {
      await guess('203.0.113.$i');
    }
    expect(server.pairingLockouts.keys, contains(FushiPairOriginClass.public));
    final (int code, String? sid, String cn, String? hn) = await open(
      '192.168.1.30',
    );
    expect(code, 200);
    // 局域网且 host 不要求 PIN：免 PIN 会话直接 confirm。
    expect(await confirm('192.168.1.30', sid!, cn, hn!, _wrongPin), 200);
  });

  test('例 4：冒报受害者 deviceId 失败 5 次，不会锁住受害者', () async {
    for (int i = 0; i < 5; i++) {
      await guess('203.0.113.66', deviceId: 'victim-device');
    }
    expect(
      await guess('198.51.100.7', deviceId: 'victim-device', pin: _pin),
      200,
    );
  });

  test('例 5：同一 IPv6 /64 内换地址仍是同一来源', () async {
    for (int i = 1; i <= 4; i++) {
      expect(await guess('2001:db8::$i'), 401);
    }
    expect(await guess('2001:db8::5'), 429);
    final (int code, _, _, _) = await open('2001:db8::6');
    expect(code, 429);
  });

  test('例 6：公网灌满会话挤不掉局域网会话；单一来源名下最多 4 个', () async {
    final (int lanCode, String? lanSid, String lanCn, String? lanHn) =
        await open('192.168.1.30');
    expect(lanCode, 200);
    final (int c0, String? earlySid, String earlyCn, String? earlyHn) =
        await open('203.0.113.7');
    expect(c0, 200);
    for (int i = 1; i <= 40; i++) {
      final (int code, _, _, _) = await open('198.51.100.$i');
      expect(code, 200);
    }
    expect(
      await confirm('192.168.1.30', lanSid!, lanCn, lanHn!, _wrongPin),
      200,
      reason: '局域网会话不受公网类别上限影响',
    );
    // 公网类别满 32 后淘汰的是会话最多的来源；各来源都只有 1 个时淘汰最旧的。
    expect(
      await confirm('203.0.113.7', earlySid!, earlyCn, earlyHn!, _pin),
      403,
      reason: '最早的公网会话已被同类别上限淘汰',
    );

    final int before = server.pendingPairSessionCount;
    for (int i = 0; i < 6; i++) {
      final (int code, _, _, _) = await open('192.168.1.77');
      expect(code, 200);
    }
    expect(server.pendingPairSessionCount - before, 4);
  });

  test('例 7：票据会话不被公网灌满的会话挤掉', () async {
    final FushiPairTicket ticket = server.issuePairTicket();
    final (int code, String? sid, String cn, String? hn) = await open(
      '203.0.113.200',
      ticket: ticket.id,
    );
    expect(code, 200);
    // 70 个来源：既超过公网类别上限 32，也超过修复前的全局上限 64。
    for (int i = 1; i <= 70; i++) {
      final (int c, _, _, _) = await open('198.51.100.$i');
      expect(c, 200);
    }
    expect(await confirm('203.0.113.200', sid!, cn, hn!, ticket.secret), 200);
  });

  test('例 8：类别里全是受保护会话时不再建会话，回 429', () async {
    server.pinApprovalIsManual = true;
    for (int i = 1; i <= 32; i++) {
      final (int c, _, _, _) = await open('198.51.100.$i');
      expect(c, 200);
    }
    final (int code, _, _, _) = await open('198.51.100.33');
    expect(code, 429);
  });
}
