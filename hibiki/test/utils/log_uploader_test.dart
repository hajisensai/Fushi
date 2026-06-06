import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hibiki/src/utils/misc/log_uploader.dart';

void main() {
  const String endpoint = 'https://logs.example.com/api/logs';
  const String token = 'test-token';

  Future<LogUploadOutcome> run(
    MockClient client, {
    String log = 'hello log',
  }) {
    return performLogUpload(
      log: log,
      kind: 'error',
      endpoint: endpoint,
      token: token,
      appVersion: '1.0.0+1',
      platform: 'android',
      device: 'Pixel 7 / Android 14',
      tsIso: '2026-06-06T12:34:56Z',
      client: client,
    );
  }

  test('200 → success 带 id，请求体含元信息 + 正确头', () async {
    late http.Request seen;
    final MockClient client = MockClient((http.Request req) async {
      seen = req;
      return http.Response('{"id":"20260606-123456-android-ab12cd"}', 200);
    });

    final LogUploadOutcome out = await run(client);

    expect(out.kind, LogUploadStatus.success);
    expect(out.id, '20260606-123456-android-ab12cd');
    expect(seen.method, 'POST');
    expect(seen.headers['x-upload-token'], token);
    expect(seen.headers['content-type'], contains('application/json'));
    final Map<String, dynamic> body =
        jsonDecode(seen.body) as Map<String, dynamic>;
    expect(body['kind'], 'error');
    expect(body['app_version'], '1.0.0+1');
    expect(body['platform'], 'android');
    expect(body['device'], 'Pixel 7 / Android 14');
    expect(body['ts'], '2026-06-06T12:34:56Z');
    expect(body['log'], 'hello log');
  });

  test('超大日志被截断到上限内并标记', () async {
    late http.Request seen;
    final MockClient client = MockClient((http.Request req) async {
      seen = req;
      return http.Response('{"id":"x"}', 200);
    });
    final String big = 'A' * (1024 * 1024);

    final LogUploadOutcome out = await run(client, log: big);

    expect(out.kind, LogUploadStatus.success);
    final Map<String, dynamic> body =
        jsonDecode(seen.body) as Map<String, dynamic>;
    final String sentLog = body['log'] as String;
    expect(utf8.encode(sentLog).length, lessThanOrEqualTo(512 * 1024));
    expect(sentLog, contains('[truncated]'));
  });

  test('401 → unauthorized', () async {
    final MockClient client =
        MockClient((http.Request req) async => http.Response('no', 401));
    expect((await run(client)).kind, LogUploadStatus.unauthorized);
  });

  test('413 → tooLarge', () async {
    final MockClient client =
        MockClient((http.Request req) async => http.Response('too big', 413));
    expect((await run(client)).kind, LogUploadStatus.tooLarge);
  });

  test('网络异常 → networkError', () async {
    final MockClient client =
        MockClient((http.Request req) async => throw Exception('boom'));
    expect((await run(client)).kind, LogUploadStatus.networkError);
  });
}
