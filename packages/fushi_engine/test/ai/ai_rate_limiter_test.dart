import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// 提供商限频（2026-10-13：免费档 / 低档 API 超频会被 429 拦下）。全用假时钟，
/// 不真的等。
void main() {
  AiProviderConfig provider({String id = 'p', int rpm = 0}) => AiProviderConfig(
    id: id,
    presetId: kAiCustomPresetId,
    name: id,
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKey: 'k',
    model: 'm',
    requestsPerMinute: rpm,
  );

  /// 假时钟：sleep 只把时间往前拨，并记下每次等了多久。
  ({AiRateLimiter limiter, List<Duration> waits, void Function(Duration) tick})
  fakeClock() {
    DateTime now = DateTime.utc(2026, 10, 13);
    final List<Duration> waits = <Duration>[];
    final AiRateLimiter limiter = AiRateLimiter(
      now: () => now,
      sleep: (Duration d) async {
        waits.add(d);
        now = now.add(d);
      },
    );
    return (
      limiter: limiter,
      waits: waits,
      tick: (Duration d) => now = now.add(d),
    );
  }

  test('每分钟 N 次：请求按 60/N 秒均匀排开，不突发', () async {
    final c = fakeClock();
    final AiProviderConfig p = provider(rpm: 30);
    for (int i = 0; i < 3; i++) {
      await c.limiter.acquire(p);
    }
    expect(c.waits, <Duration>[
      const Duration(seconds: 2),
      const Duration(seconds: 2),
    ]);
  });

  test('空闲够久后不再等；不同提供商各算各的', () async {
    final c = fakeClock();
    final AiProviderConfig a = provider(id: 'a', rpm: 6);
    final AiProviderConfig b = provider(id: 'b', rpm: 6);
    await c.limiter.acquire(a);
    await c.limiter.acquire(b);
    expect(c.waits, isEmpty, reason: '两家互不占对方的额度');
    c.tick(const Duration(seconds: 30));
    await c.limiter.acquire(a);
    expect(c.waits, isEmpty, reason: '间隔 10 秒，已空闲 30 秒');
  });

  test('不限频：从不等待；但 Retry-After 的暂停照样遵守', () async {
    final c = fakeClock();
    final AiProviderConfig p = provider();
    await c.limiter.acquire(p);
    await c.limiter.acquire(p);
    expect(c.waits, isEmpty);
    c.limiter.backOff(p, const Duration(seconds: 7));
    await c.limiter.acquire(p);
    expect(c.waits, <Duration>[const Duration(seconds: 7)]);
    await c.limiter.acquire(p);
    expect(c.waits, hasLength(1), reason: '暂停过后恢复不限');
  });

  test('backOff 只往后推，不把更晚的空位提前', () async {
    final c = fakeClock();
    final AiProviderConfig p = provider(rpm: 1);
    await c.limiter.acquire(p);
    c.limiter.backOff(p, const Duration(seconds: 5));
    await c.limiter.acquire(p);
    expect(c.waits, <Duration>[const Duration(minutes: 1)]);
  });

  test('配置往返：rpm 只在大于 0 时落盘，坏值按不限', () {
    final AiProviderConfig limited = provider(rpm: 15);
    expect(limited.toJson()['rpm'], 15);
    expect(AiProviderConfig.fromJson(limited.toJson()).requestsPerMinute, 15);
    expect(provider().toJson().containsKey('rpm'), isFalse);
    final Map<String, Object?> negative = provider().toJson()..['rpm'] = -3;
    expect(AiProviderConfig.fromJson(negative).requestsPerMinute, 0);
  });

  group('AiChatClient 临时性失败重试', () {
    final List<AiChatMessage> messages = <AiChatMessage>[
      const AiChatMessage.user('hi'),
    ];

    http.Response ok() => http.Response(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'ok'},
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

    /// 按顺序回 [responses]（null = 抛网络异常），记下调了几次。
    (AiChatClient, List<int>) scripted(
      AiRateLimiter limiter,
      List<http.Response? Function()> responses,
    ) {
      final List<int> calls = <int>[0];
      final AiChatClient client = AiChatClient(
        rateLimiter: limiter,
        client: MockClient((http.Request request) async {
          final http.Response? r = responses[calls[0]++]();
          if (r == null) throw const SocketLikeException();
          return r;
        }),
      );
      return (client, calls);
    }

    Matcher failsWith(String message) => throwsA(
      isA<AiChatFailure>().having(
        (AiChatFailure f) => f.message,
        'message',
        message,
      ),
    );

    test('网络抖动 / 5xx：指数退避（2 秒、4 秒）后重试成功', () async {
      final c = fakeClock();
      final (AiChatClient client, List<int> calls) = scripted(
        c.limiter,
        <http.Response? Function()>[
          () => null,
          () => http.Response('', 503),
          ok,
        ],
      );
      expect(
        await client.complete(provider: provider(), messages: messages),
        'ok',
      );
      expect(calls.single, 3);
      expect(c.waits, <Duration>[
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
    });

    test('429 按 Retry-After 等待后重试', () async {
      final c = fakeClock();
      final (AiChatClient client, List<int> calls) = scripted(
        c.limiter,
        <http.Response? Function()>[
          () => http.Response(
            '',
            429,
            headers: <String, String>{'retry-after': '20'},
          ),
          ok,
        ],
      );
      expect(
        await client.complete(provider: provider(), messages: messages),
        'ok',
      );
      expect(calls.single, 2);
      expect(c.waits, <Duration>[const Duration(seconds: 20)]);
    });

    test('最多试 3 次，仍失败就抛最后一次的错', () async {
      final c = fakeClock();
      final (
        AiChatClient client,
        List<int> calls,
      ) = scripted(c.limiter, <http.Response? Function()>[
        () => http.Response('', 500),
        () => http.Response('', 502),
        () => http.Response('', 503),
      ]);
      await expectLater(
        client.complete(provider: provider(), messages: messages),
        failsWith('http_503'),
      );
      expect(calls.single, kAiChatMaxAttempts);
    });

    test('鉴权 / 4xx 不重试', () async {
      final c = fakeClock();
      final (AiChatClient client, List<int> calls) = scripted(
        c.limiter,
        <http.Response? Function()>[() => http.Response('', 401), ok],
      );
      await expectLater(
        client.complete(provider: provider(), messages: messages),
        failsWith('unauthorized'),
      );
      expect(calls.single, 1);
      expect(c.waits, isEmpty);
    });

    test('要求等超过 60 秒（额度耗尽）就不在后台干等', () async {
      final c = fakeClock();
      final (AiChatClient client, List<int> calls) = scripted(
        c.limiter,
        <http.Response? Function()>[
          () => http.Response(
            '',
            429,
            headers: <String, String>{'retry-after': '600'},
          ),
          ok,
        ],
      );
      await expectLater(
        client.complete(provider: provider(), messages: messages),
        failsWith('rate_limited'),
      );
      expect(calls.single, 1);
    });

    test('调用方关闭客户端后不再重试', () async {
      final c = fakeClock();
      late final AiChatClient client;
      final List<int> calls = <int>[0];
      client = AiChatClient(
        rateLimiter: c.limiter,
        client: MockClient((http.Request request) async {
          calls[0]++;
          client.close();
          return http.Response('', 503);
        }),
      );
      await expectLater(
        client.complete(provider: provider(), messages: messages),
        failsWith('http_503'),
      );
      expect(calls.single, 1);
    });
  });
}

/// MockClient 里模拟连接断开（`AiChatClient` 把任何发送异常归成 `network_error`）。
class SocketLikeException implements Exception {
  const SocketLikeException();
}
