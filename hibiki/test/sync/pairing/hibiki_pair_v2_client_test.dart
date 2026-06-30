import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/pairing/hibiki_pair_v2_client.dart';
import 'package:hibiki/src/sync/pairing/hibiki_pairing_protocol.dart';
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
    ).pair(deviceName: 'My Phone', pin: hostPin);
    expect(outcome, isA<HibikiPairV2Success>());
    final HibikiPairV2Success success = outcome as HibikiPairV2Success;
    expect(success.token, 'granted-token');
    expect(success.hostFingerprint, 'aa:bb:cc');
  });

  test('PIN required wrong PIN yields failure pin', () async {
    final HibikiPairV2Outcome outcome = await client(
      buildHost(pinRequired: true, approve: true),
    ).pair(deviceName: 'My Phone', pin: '000000');
    expect(outcome, isA<HibikiPairV2Failure>());
    expect((outcome as HibikiPairV2Failure).reason, 'pin');
  });

  test('PIN required but none provided yields failure pin before network',
      () async {
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
}
