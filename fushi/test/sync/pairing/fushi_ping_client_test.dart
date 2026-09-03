import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/pairing/fushi_ping_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// TODO-963 M2: probeFushiPing 解析 /api/ping 响应的单元测试（注入 MockClient）。
// BUG-1741 收尾（PR#912 审查）：丢原因的薄封装 fetchFushiPing 已删除，本组
// 「只关心解析结果」的用例直接读 FushiPingOutcome.result。
void main() {
  test('解析 fushi host：v2 配对 + 展示名 + 指纹', () async {
    final MockClient mock = MockClient((http.Request req) async {
      expect(req.url.path, '/api/ping');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'app': 'fushi',
          'pairing': <String, dynamic>{'v2': true},
          'tls': <String, dynamic>{'enabled': true, 'fingerprint': 'aa:bb'},
          'deviceName': 'Hibiki · mac',
        }),
        200,
      );
    });

    final FushiPingResult? r =
        (await probeFushiPing('https://host:38765', httpClient: mock)).result;
    expect(r, isNotNull);
    expect(r!.isFushi, isTrue);
    expect(r.supportsPairV2, isTrue);
    expect(r.tlsEnabled, isTrue);
    expect(r.fingerprint, 'aa:bb');
    expect(r.deviceName, 'Hibiki · mac');
  });

  test('非 fushi 响应（app 字段缺失）→ null', () async {
    final MockClient mock = MockClient((http.Request req) async {
      return http.Response(jsonEncode(<String, dynamic>{'app': 'other'}), 200);
    });
    final FushiPingResult? r =
        (await probeFushiPing('http://host:8080', httpClient: mock)).result;
    expect(r, isNull);
  });

  test('非 200 → null', () async {
    final MockClient mock =
        MockClient((http.Request req) async => http.Response('nope', 404));
    final FushiPingResult? r =
        (await probeFushiPing('http://host:8080', httpClient: mock)).result;
    expect(r, isNull);
  });

  test('明文 http host（tls 关）解析 tlsEnabled=false 且无指纹', () async {
    final MockClient mock = MockClient((http.Request req) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'app': 'fushi',
          'pairing': <String, dynamic>{'v2': true},
          'tls': <String, dynamic>{'enabled': false},
        }),
        200,
      );
    });
    final FushiPingResult? r =
        (await probeFushiPing('http://host:38765', httpClient: mock)).result;
    expect(r, isNotNull);
    expect(r!.tlsEnabled, isFalse);
    expect(r.fingerprint, isNull);
  });

  // BUG-1741：探测失败必须带出原因。此前整个函数是 `on Object { return null; }`，
  // 「证书指纹对不上」（安全事件）、「对端超时」、「端口没人」和「那不是 Hibiki」
  // 在调用方眼里长得一模一样，UI 只能挑最含糊的一句说。
  group('probeFushiPing 失败分型', () {
    test('钉扎指纹不符（TlsException）→ tls，而不是裸 null', () async {
      final MockClient mock = MockClient((http.Request req) async {
        throw const TlsException('pinned fingerprint mismatch');
      });
      final FushiPingOutcome o =
          await probeFushiPing('https://host:38765', httpClient: mock);
      expect(o.isOk, isFalse);
      expect(o.failure, FushiPingFailure.tls);
    });

    test('HandshakeException 也归 tls（它 implements TlsException）', () async {
      final MockClient mock = MockClient((http.Request req) async {
        throw const HandshakeException('handshake failed');
      });
      final FushiPingOutcome o =
          await probeFushiPing('https://host:38765', httpClient: mock);
      expect(o.failure, FushiPingFailure.tls);
    });

    test('超时 → timeout', () async {
      final MockClient mock = MockClient((http.Request req) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response('{}', 200);
      });
      final FushiPingOutcome o = await probeFushiPing(
        'http://host:38765',
        httpClient: mock,
        timeout: const Duration(milliseconds: 10),
      );
      expect(o.failure, FushiPingFailure.timeout);
    });

    test('连不上（SocketException）→ unreachable', () async {
      final MockClient mock = MockClient((http.Request req) async {
        throw const SocketException('connection refused');
      });
      final FushiPingOutcome o =
          await probeFushiPing('http://host:38765', httpClient: mock);
      expect(o.failure, FushiPingFailure.unreachable);
    });

    test('连上但不是 Hibiki → notFushi（与 unreachable 必须可分辨）', () async {
      final MockClient mock = MockClient(
        (http.Request req) async =>
            http.Response(jsonEncode(<String, dynamic>{'app': 'other'}), 200),
      );
      final FushiPingOutcome o =
          await probeFushiPing('http://host:8080', httpClient: mock);
      expect(o.failure, FushiPingFailure.notFushi);
    });

    test('非 200 → notFushi 并保留状态码供日志定位', () async {
      final MockClient mock =
          MockClient((http.Request req) async => http.Response('nope', 403));
      final FushiPingOutcome o =
          await probeFushiPing('http://host:8080', httpClient: mock);
      expect(o.failure, FushiPingFailure.notFushi);
      expect(o.statusCode, 403);
    });

    test('成功时 failure 为 null', () async {
      final MockClient mock = MockClient(
        (http.Request req) async => http.Response(
          jsonEncode(<String, dynamic>{
            'app': 'fushi',
            'pairing': <String, dynamic>{'v2': true},
          }),
          200,
        ),
      );
      final FushiPingOutcome o =
          await probeFushiPing('http://host:38765', httpClient: mock);
      expect(o.isOk, isTrue);
      expect(o.failure, isNull);
      expect(o.result!.supportsPairV2, isTrue);
    });
  });

  group('classifyFushiProbeFailure', () {
    test('TLS 判定必须排在最前（IOClient 让 TLS 异常原样穿透）', () {
      expect(
        classifyFushiProbeFailure(const TlsException('x')),
        FushiPingFailure.tls,
      );
      expect(
        classifyFushiProbeFailure(TimeoutException('x')),
        FushiPingFailure.timeout,
      );
      expect(
        classifyFushiProbeFailure(const SocketException('x')),
        FushiPingFailure.unreachable,
      );
      expect(
        classifyFushiProbeFailure(Exception('x')),
        FushiPingFailure.unreachable,
      );
    });
  });
}
