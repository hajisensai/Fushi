import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/pairing/hibiki_pair_v2_client.dart';
import 'package:fushi/src/sync/pairing/hibiki_pairing_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// TODO-961 M1: v2 client 驱动测试。用 MockClient 模拟 host，验证 client 正确地
/// 算 pinProof 并在 confirm 拿到 token；错误 PIN / host 拒绝 / 免 PIN 分支。
void main() {
  // host 固定 PIN / nonce 以便断言 client 重算的 proof。
  const String hostPin = '482913';
  const String hostNonce = 'host-nonce-fixed';

  MockClient buildHost({
    required bool pinRequired,
    required bool approve,
  }) {
    String? capturedClientNonce;
    return MockClient((http.Request req) async {
      if (req.url.path == '/api/pair/v2') {
        final Map<String, dynamic> body =
            jsonDecode(req.body) as Map<String, dynamic>;
        capturedClientNonce = body['clientNonce'] as String;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'sessionId': 'sid-1',
            'pinRequired': pinRequired,
            'hostNonce': hostNonce,
          }),
          200,
          headers: <String, String>{'Content-Type': 'application/json'},
        );
      }
      if (req.url.path == '/api/pair/v2/confirm') {
        if (pinRequired) {
          final Map<String, dynamic> body =
              jsonDecode(req.body) as Map<String, dynamic>;
          final String? proof = body['pinProof'] as String?;
          final String expected = HibikiPairingProtocol.computePinProof(
            pin: hostPin,
            clientNonce: capturedClientNonce!,
            hostNonce: hostNonce,
          );
          if (proof != expected) {
            return http.Response(
              jsonEncode(<String, String>{'reason': 'pin'}),
              401,
              headers: <String, String>{'Content-Type': 'application/json'},
            );
          }
        }
        if (!approve) {
          return http.Response(
            jsonEncode(<String, String>{'reason': 'declined'}),
            403,
            headers: <String, String>{'Content-Type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'token': 'granted-token',
            'hostFingerprint': 'aa:bb:cc',
          }),
          200,
          headers: <String, String>{'Content-Type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });
  }

  HibikiPairV2Client client(http.Client mock) => HibikiPairV2Client(
        baseUrl: 'https://host:38765',
        expectedFingerprint: 'aa:bb:cc',
        httpClient: mock,
      );

  test('PIN required correct PIN yields success with token', () async {
    final HibikiPairV2Outcome outcome = await client(
      buildHost(pinRequired: true, approve: true),
    ).pair(deviceName: 'My Phone', pinProvider: () async => hostPin);
    expect(outcome, isA<HibikiPairV2Success>());
    final HibikiPairV2Success success = outcome as HibikiPairV2Success;
    expect(success.token, 'granted-token');
    expect(success.hostFingerprint, 'aa:bb:cc');
  });

  test('PIN required wrong PIN yields failure pin', () async {
    final HibikiPairV2Outcome outcome = await client(
      buildHost(pinRequired: true, approve: true),
    ).pair(deviceName: 'My Phone', pinProvider: () async => '000000');
    expect(outcome, isA<HibikiPairV2Failure>());
    expect((outcome as HibikiPairV2Failure).reason, 'pin');
  });

  test('PIN required but no pinProvider yields failure pin', () async {
    // host 要 PIN 但调用方没接 pinProvider → 无从取得 PIN → 'pin'（非 'cancelled'）。
    final HibikiPairV2Outcome outcome = await client(
      buildHost(pinRequired: true, approve: true),
    ).pair(deviceName: 'My Phone');
    expect((outcome as HibikiPairV2Failure).reason, 'pin');
  });

  test('PIN-free LAN session succeeds without PIN', () async {
    final HibikiPairV2Outcome outcome = await client(
      buildHost(pinRequired: false, approve: true),
    ).pair(deviceName: 'My Phone');
    expect(outcome, isA<HibikiPairV2Success>());
    expect((outcome as HibikiPairV2Success).token, 'granted-token');
  });

  test('host declines yields failure declined', () async {
    final HibikiPairV2Outcome outcome = await client(
      buildHost(pinRequired: false, approve: false),
    ).pair(deviceName: 'My Phone');
    expect((outcome as HibikiPairV2Failure).reason, 'declined');
  });

  // TODO-1273 回归守卫：用户报「LAN 配对被要求输入对方 PIN，但对方根本没 PIN，且我
  // 没输 PIN 却还是把地址配上了」。根因是 client 在得到 host 的 pinRequired 响应前就
  // 盲目弹 PIN 输入框。修复后：pinRequired:false 的会话**绝不**调用 pinProvider。
  test('LAN pinRequired:false never invokes pinProvider (TODO-1273)', () async {
    bool pinAsked = false;
    final HibikiPairV2Outcome outcome = await client(
      buildHost(pinRequired: false, approve: true),
    ).pair(
      deviceName: 'My Phone',
      pinProvider: () async {
        pinAsked = true;
        return '000000';
      },
    );
    expect(outcome, isA<HibikiPairV2Success>());
    expect(pinAsked, isFalse, reason: 'LAN 免 PIN 会话绝不能弹 PIN 输入框');
  });

  // pinRequired:true 时才调用 pinProvider（一次），确认回调确实按需触发。
  test('PIN required invokes pinProvider exactly once (TODO-1273)', () async {
    int calls = 0;
    final HibikiPairV2Outcome outcome = await client(
      buildHost(pinRequired: true, approve: true),
    ).pair(
      deviceName: 'My Phone',
      pinProvider: () async {
        calls++;
        return hostPin;
      },
    );
    expect(outcome, isA<HibikiPairV2Success>());
    expect(calls, 1);
  });

  // 用户在 PIN 输入框点取消（pinProvider 返回 null）→ 'cancelled'，与 'pin' 区分，
  // 调用方据此静默收场不弹「PIN 错误」提示。
  test('pinProvider returning null yields cancelled (TODO-1273)', () async {
    final HibikiPairV2Outcome outcome = await client(
      buildHost(pinRequired: true, approve: true),
    ).pair(deviceName: 'My Phone', pinProvider: () async => null);
    expect((outcome as HibikiPairV2Failure).reason, 'cancelled');
  });

  // 空串（点了继续但没填）→ 'pin'（视为未输入，非取消）。
  test('pinProvider returning empty yields pin (TODO-1273)', () async {
    final HibikiPairV2Outcome outcome = await client(
      buildHost(pinRequired: true, approve: true),
    ).pair(deviceName: 'My Phone', pinProvider: () async => '');
    expect((outcome as HibikiPairV2Failure).reason, 'pin');
  });
}
