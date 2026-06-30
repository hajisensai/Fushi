import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/pairing/hibiki_ping_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// TODO-963 M2: fetchHibikiPing 解析 /api/ping 响应的单元测试（注入 MockClient）。
void main() {
  test('解析 hibiki host：v2 配对 + 展示名 + 指纹', () async {
    final MockClient mock = MockClient((http.Request req) async {
      expect(req.url.path, '/api/ping');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'app': 'hibiki',
          'pairing': <String, dynamic>{'v2': true},
          'tls': <String, dynamic>{'enabled': true, 'fingerprint': 'aa:bb'},
          'deviceName': 'Hibiki · mac',
        }),
        200,
      );
    });

    final HibikiPingResult? r =
        await fetchHibikiPing('https://host:38765', httpClient: mock);
    expect(r, isNotNull);
    expect(r!.isHibiki, isTrue);
    expect(r.supportsPairV2, isTrue);
    expect(r.tlsEnabled, isTrue);
    expect(r.fingerprint, 'aa:bb');
    expect(r.deviceName, 'Hibiki · mac');
  });

  test('非 hibiki 响应（app 字段缺失）→ null', () async {
    final MockClient mock = MockClient((http.Request req) async {
      return http.Response(jsonEncode(<String, dynamic>{'app': 'other'}), 200);
    });
    final HibikiPingResult? r =
        await fetchHibikiPing('http://host:8080', httpClient: mock);
    expect(r, isNull);
  });

  test('非 200 → null', () async {
    final MockClient mock =
        MockClient((http.Request req) async => http.Response('nope', 404));
    final HibikiPingResult? r =
        await fetchHibikiPing('http://host:8080', httpClient: mock);
    expect(r, isNull);
  });

  test('明文 http host（tls 关）解析 tlsEnabled=false 且无指纹', () async {
    final MockClient mock = MockClient((http.Request req) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'app': 'hibiki',
          'pairing': <String, dynamic>{'v2': true},
          'tls': <String, dynamic>{'enabled': false},
        }),
        200,
      );
    });
    final HibikiPingResult? r =
        await fetchHibikiPing('http://host:38765', httpClient: mock);
    expect(r, isNotNull);
    expect(r!.tlsEnabled, isFalse);
    expect(r.fingerprint, isNull);
  });
}
