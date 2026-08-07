import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/pairing/fushi_ping_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// TODO-963 M2: fetchFushiPing 解析 /api/ping 响应的单元测试（注入 MockClient）。
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
        await fetchFushiPing('https://host:38765', httpClient: mock);
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
        await fetchFushiPing('http://host:8080', httpClient: mock);
    expect(r, isNull);
  });

  test('非 200 → null', () async {
    final MockClient mock =
        MockClient((http.Request req) async => http.Response('nope', 404));
    final FushiPingResult? r =
        await fetchFushiPing('http://host:8080', httpClient: mock);
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
        await fetchFushiPing('http://host:38765', httpClient: mock);
    expect(r, isNotNull);
    expect(r!.tlsEnabled, isFalse);
    expect(r.fingerprint, isNull);
  });
}
