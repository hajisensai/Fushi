import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/pairing/fushi_pair_v2_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-1553 守卫：配对失败的**分型**必须一路走到 UI。
///
/// server 侧 PIN 爆破限速（429 `{"reason":"rate_limited"}`）、TLS 钉扎失败、超时，
/// 此前在 client 里全被压成 `'error'` → UI 一律显示「配对失败」。用户被 host 锁了
/// 15 分钟看不出来，只会一遍遍重试（每次还要对方再审批一遍 PIN）；证书指纹不符
/// 这种安全事件也说成同一句话，且一行日志都不留。
void main() {
  const String base = 'https://peer.local:8765';

  Future<FushiPairV2Outcome> pairWith(MockClient client) {
    return FushiPairV2Client(
      baseUrl: base,
      expectedFingerprint: 'aa:bb',
      httpClient: client,
      timeout: const Duration(seconds: 2),
    ).pair(deviceName: 'Tester', pinProvider: () async => '000000');
  }

  String reasonOf(FushiPairV2Outcome outcome) {
    expect(outcome, isA<FushiPairV2Failure>());
    return (outcome as FushiPairV2Failure).reason;
  }

  http.Response sessionOk({required bool pinRequired}) => http.Response(
        jsonEncode(<String, dynamic>{
          'sessionId': 'sid',
          'pinRequired': pinRequired,
          'hostNonce': 'hn',
        }),
        200,
        headers: <String, String>{'Content-Type': 'application/json'},
      );

  test('confirm 的 429 解析成 rate_limited（不再退化成 error）', () async {
    final MockClient client = MockClient((http.Request req) async {
      if (req.url.path == '/api/pair/v2') {
        return sessionOk(pinRequired: true);
      }
      return http.Response(
        jsonEncode(<String, String>{'reason': 'rate_limited'}),
        429,
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    });

    expect(reasonOf(await pairWith(client)), 'rate_limited');
  });

  test('创建会话阶段的 429 同样解析成 rate_limited', () async {
    final MockClient client = MockClient((http.Request req) async {
      return http.Response(
        jsonEncode(<String, String>{'reason': 'rate_limited'}),
        429,
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    });

    expect(reasonOf(await pairWith(client)), 'rate_limited');
  });

  test('TLS 握手失败报 tls，而不是含糊的 error', () async {
    final MockClient client = MockClient((http.Request req) async {
      throw const HandshakeException('certificate pin mismatch');
    });

    expect(reasonOf(await pairWith(client)), 'tls');
  });

  test('超时报 timeout', () async {
    final MockClient client = MockClient((http.Request req) async {
      throw TimeoutException('too slow');
    });

    expect(reasonOf(await pairWith(client)), 'timeout');
  });

  test('其余传输失败仍是 error（不过度分型）', () async {
    final MockClient client = MockClient((http.Request req) async {
      throw const SocketException('connection refused');
    });

    expect(reasonOf(await pairWith(client)), 'error');
  });

  test('既有 401/403 语义不变（向后兼容）', () async {
    final MockClient denied = MockClient((http.Request req) async {
      if (req.url.path == '/api/pair/v2') return sessionOk(pinRequired: false);
      return http.Response(
        jsonEncode(<String, String>{'reason': 'declined'}),
        403,
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    });
    expect(reasonOf(await pairWith(denied)), 'declined');

    final MockClient badPin = MockClient((http.Request req) async {
      if (req.url.path == '/api/pair/v2') return sessionOk(pinRequired: true);
      return http.Response(
        jsonEncode(<String, String>{'reason': 'pin'}),
        401,
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    });
    expect(reasonOf(await pairWith(badPin)), 'pin');
  });
}
