import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/utils/misc/log_uploader.dart';

void main() {
  const String endpoint = 'https://logs.example.com/api/logs';
  const String token = 'test-token';

  Future<LogUploadOutcome> run(MockClient client, {String log = 'hello log'}) {
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
      retryBackoff: const <Duration>[Duration.zero, Duration.zero],
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

  // 反馈 4k7x0-1MHe：接收端（CF Worker 版 512 KiB）限的是整个请求体。旧实现只把日志
  // 原文截到 512 KiB 再套 JSON，Windows 错误日志里的换行 / 反斜杠 / 引号转义后膨胀，
  // 请求体必然超限 → 413 →「日志过大，无法上传」。
  test('整个请求体（JSON 转义 + 元信息）都在上限内，而不只是日志原文', () async {
    late http.Request seen;
    final MockClient client = MockClient((http.Request req) async {
      seen = req;
      return http.Response('{"id":"x"}', 200);
    });
    const String line =
        r'[2026-10-28] C:\Users\u\AppData\Local\Fushi "NetworkError { info: '
        '"429" }"\n\t#0 frame\n';
    final String big = line * (2 * 1024 * 1024 ~/ line.length);

    final LogUploadOutcome out = await run(client, log: big);

    expect(out.kind, LogUploadStatus.success);
    expect(seen.bodyBytes.length, lessThanOrEqualTo(512 * 1024));
    final Map<String, dynamic> body =
        jsonDecode(seen.body) as Map<String, dynamic>;
    final String sentLog = body['log'] as String;
    expect(sentLog, startsWith('[truncated]'));
    expect(
      big.endsWith(sentLog.substring(sentLog.indexOf('\n') + 1)),
      isTrue,
      reason: '保留的是最近的尾部',
    );
    expect(body['app_version'], '1.0.0+1');
  });

  test('多字节日志截断后字节数仍严格 <= 上限（不被 U+FFFD 膨胀顶破）', () async {
    late http.Request seen;
    final MockClient client = MockClient((http.Request req) async {
      seen = req;
      return http.Response('{"id":"x"}', 200);
    });
    // 全日文（每字符 3 字节），让切点必然落在多字节字符中间，
    // 遍历所有相位都要保证截断结果不超限、且不含替换符 U+FFFD。
    for (int pad = 0; pad < 4; pad++) {
      final String big = ('x' * pad) + ('あ' * (1024 * 1024));
      final LogUploadOutcome out = await run(client, log: big);
      expect(out.kind, LogUploadStatus.success);
      final Map<String, dynamic> body =
          jsonDecode(seen.body) as Map<String, dynamic>;
      final String sentLog = body['log'] as String;
      expect(
        utf8.encode(sentLog).length,
        lessThanOrEqualTo(512 * 1024),
        reason: 'pad=$pad 时截断结果超限',
      );
      expect(
        sentLog.contains('�'),
        isFalse,
        reason: 'pad=$pad 时出现替换符，说明切点没对齐字符边界',
      );
      expect(sentLog, contains('[truncated]'));
    }
  });

  test('401 → unauthorized', () async {
    final MockClient client = MockClient(
      (http.Request req) async => http.Response('no', 401),
    );
    expect((await run(client)).kind, LogUploadStatus.unauthorized);
  });

  test('413 → tooLarge', () async {
    final MockClient client = MockClient(
      (http.Request req) async => http.Response('too big', 413),
    );
    expect((await run(client)).kind, LogUploadStatus.tooLarge);
  });

  test('网络异常重试用尽 → networkError，共尝试 1 + 退避次数', () async {
    int calls = 0;
    final MockClient client = MockClient((http.Request req) async {
      calls++;
      throw const SocketException('connect timed out');
    });
    expect((await run(client)).kind, LogUploadStatus.networkError);
    expect(calls, 3);
  });

  test('瞬时失败（建连超时 / 5xx / 429）后重试成功', () async {
    final List<Future<http.Response> Function()> replies =
        <Future<http.Response> Function()>[
          () async => throw const SocketException('connect timed out'),
          () async => http.Response('bad gateway', 502),
          () async => http.Response('{"id":"ok"}', 200),
        ];
    int calls = 0;
    final MockClient client = MockClient(
      (http.Request req) => replies[calls++](),
    );
    final LogUploadOutcome out = await run(client);
    expect(out.kind, LogUploadStatus.success);
    expect(out.id, 'ok');
    expect(calls, 3);

    calls = 0;
    final MockClient limited = MockClient(
      (http.Request req) async =>
          calls++ == 0 ? http.Response('slow', 429) : http.Response('{}', 200),
    );
    expect((await run(limited)).kind, LogUploadStatus.success);
    expect(calls, 2);
  });

  test('鉴权失败与超限不重试', () async {
    for (final int code in <int>[401, 403, 413]) {
      int calls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        return http.Response('no', code);
      });
      await run(client);
      expect(calls, 1, reason: 'HTTP $code 不应重发');
    }
  });
}
