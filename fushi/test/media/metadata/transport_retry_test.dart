import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/metadata/bangumi_api_client.dart';
import 'package:fushi/src/media/metadata/transport_retry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-1272：刮削链路对「拿不到 HTTP 响应」的失败必须重试，且**只**对这种失败重试。
void main() {
  /// 不真实等待：把退避折叠成同步完成，单测才不会被 400ms×N 拖慢。
  Future<void> noSleep(Duration _) async {}

  group('runWithTransportRetry', () {
    test('首次失败、第二次成功 → 返回成功值，共发 2 次', () async {
      int calls = 0;
      final String result = await runWithTransportRetry<String>(
        () async {
          calls++;
          if (calls == 1) throw const SocketExceptionStub();
          return 'ok';
        },
        sleep: noSleep,
      );

      expect(result, 'ok');
      expect(calls, 2);
    });

    test('全部失败 → 原样抛最后一次异常，且恰好尝试 maxAttempts 次', () async {
      int calls = 0;
      await expectLater(
        runWithTransportRetry<String>(
          () async {
            calls++;
            throw StateError('boom $calls');
          },
          maxAttempts: 3,
          sleep: noSleep,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            // 抛的必须是**最后一次**的异常，不是第一次的。
            'boom 3',
          ),
        ),
      );
      expect(calls, 3);
    });

    test('首次即成功 → 不重试，只发 1 次', () async {
      int calls = 0;
      await runWithTransportRetry<String>(
        () async {
          calls++;
          return 'ok';
        },
        sleep: noSleep,
      );
      expect(calls, 1);
    });

    test('maxAttempts=1 退回「一次定生死」的旧行为', () async {
      int calls = 0;
      await expectLater(
        runWithTransportRetry<String>(
          () async {
            calls++;
            throw const SocketExceptionStub();
          },
          maxAttempts: 1,
          sleep: noSleep,
        ),
        throwsA(isA<SocketExceptionStub>()),
      );
      expect(calls, 1);
    });

    test('退避按 backoff * n 递增', () async {
      final List<Duration> waited = <Duration>[];
      await expectLater(
        runWithTransportRetry<String>(
          () async => throw const SocketExceptionStub(),
          maxAttempts: 3,
          backoff: const Duration(milliseconds: 100),
          sleep: (Duration d) async => waited.add(d),
        ),
        throwsA(isA<SocketExceptionStub>()),
      );
      expect(waited, <Duration>[
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 200),
      ]);
    });
  });

  group('BangumiApiClient 重试语义（BUG-1272）', () {
    test('搜索：传输失败后重试并最终成功', () async {
      int calls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        if (calls == 1) {
          throw http.ClientException('Connection closed', req.url);
        }
        return http.Response.bytes(utf8.encode('{"data":[]}'), 200);
      });

      final BangumiRawResponse res = await BangumiApiClient(
        client: client,
        userAgent: 'ua/test',
        retrySleep: noSleep,
      ).searchSubjects('x', subjectType: kBangumiSubjectTypeAnime);

      expect(res.statusCode, 200);
      expect(calls, 2);
    });

    test('详情：传输失败后重试并最终成功', () async {
      int calls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        if (calls < 3) {
          throw http.ClientException('Connection reset', req.url);
        }
        return http.Response.bytes(utf8.encode('{"id":8}'), 200);
      });

      final BangumiRawResponse res = await BangumiApiClient(
        client: client,
        userAgent: 'ua/test',
        retrySleep: noSleep,
      ).fetchSubject('8');

      expect(res.statusCode, 200);
      expect(calls, 3);
    });

    test('用尽次数仍失败 → 抛 BangumiTransportException（异常契约不变）', () async {
      int calls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        throw http.ClientException('Connection closed', req.url);
      });

      await expectLater(
        BangumiApiClient(
          client: client,
          userAgent: 'ua/test',
          retrySleep: noSleep,
        ).fetchSubject('8'),
        throwsA(isA<BangumiTransportException>()),
      );
      expect(calls, kTransportMaxAttempts);
    });

    test('超时同样重试，最终仍抛 request timed out', () async {
      int calls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        throw TimeoutException('slow');
      });

      await expectLater(
        BangumiApiClient(
          client: client,
          userAgent: 'ua/test',
          retrySleep: noSleep,
        ).fetchSubject('8'),
        throwsA(
          isA<BangumiTransportException>().having(
            (BangumiTransportException e) => e.message,
            'message',
            'request timed out',
          ),
        ),
      );
      expect(calls, kTransportMaxAttempts);
    });

    // —— 负向断言：服务端已经回话的结果绝不能被重放 ——
    test('403 不重试：只发 1 次，状态码原样返回', () async {
      int calls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        return http.Response.bytes(utf8.encode('{"title":"Forbidden"}'), 403);
      });

      final BangumiRawResponse res = await BangumiApiClient(
        client: client,
        userAgent: 'ua/test',
        retrySleep: noSleep,
      ).fetchSubject('8');

      expect(res.statusCode, 403);
      expect(calls, 1, reason: '403 是服务端明确回话，重放没有意义');
    });

    test('429 不重试：重放只会加重限流', () async {
      int calls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        return http.Response.bytes(utf8.encode('{}'), 429);
      });

      final BangumiRawResponse res = await BangumiApiClient(
        client: client,
        userAgent: 'ua/test',
        retrySleep: noSleep,
      ).fetchSubject('8');

      expect(res.statusCode, 429);
      expect(calls, 1);
    });

    test('404 不重试：条目不存在是确定结论', () async {
      int calls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        return http.Response.bytes(utf8.encode('{}'), 404);
      });

      final BangumiRawResponse res = await BangumiApiClient(
        client: client,
        userAgent: 'ua/test',
        retrySleep: noSleep,
      ).fetchSubject('404404');

      expect(res.statusCode, 404);
      expect(calls, 1);
    });

    test('重试穿过限流 gate：每次尝试都过一遍闸门', () async {
      int calls = 0;
      int gateCalls = 0;
      final MockClient client = MockClient((http.Request req) async {
        calls++;
        if (calls < 3) {
          throw http.ClientException('Connection closed', req.url);
        }
        return http.Response.bytes(utf8.encode('{"id":8}'), 200);
      });

      await BangumiApiClient(
        client: client,
        userAgent: 'ua/test',
        retrySleep: noSleep,
        gate: (Future<http.Response> Function() send) {
          gateCalls++;
          return send();
        },
      ).fetchSubject('8');

      expect(calls, 3);
      expect(
        gateCalls,
        3,
        reason: '重试若绕过限流器，链路抖动会变成对公益 API 的连打',
      );
    });
  });
}

/// 传输层失败的替身（不依赖 dart:io，widget 测试里可用）。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
