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

  test('parseRetryAfter：秒数与 HTTP 日期', () {
    expect(parseRetryAfter('12'), const Duration(seconds: 12));
    expect(parseRetryAfter('0'), isNull);
    expect(parseRetryAfter('soon'), isNull);
    expect(parseRetryAfter(null), isNull);
    expect(
      parseRetryAfter(
        'Tue, 13 Oct 2026 00:00:30 GMT',
        now: DateTime.utc(2026, 10, 13),
      ),
      const Duration(seconds: 30),
    );
  });

  test('配置往返：rpm 只在大于 0 时落盘，坏值按不限', () {
    final AiProviderConfig limited = provider(rpm: 15);
    expect(limited.toJson()['rpm'], 15);
    expect(AiProviderConfig.fromJson(limited.toJson()).requestsPerMinute, 15);
    expect(provider().toJson().containsKey('rpm'), isFalse);
    final Map<String, Object?> negative = provider().toJson()..['rpm'] = -3;
    expect(AiProviderConfig.fromJson(negative).requestsPerMinute, 0);
  });

  test('AiChatClient：每次 complete 先排队；429 的 Retry-After 推迟这家后续请求', () async {
    final c = fakeClock();
    int calls = 0;
    final AiChatClient client = AiChatClient(
      rateLimiter: c.limiter,
      client: MockClient((http.Request request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '',
            429,
            headers: <String, String>{'retry-after': '20'},
          );
        }
        return http.Response(
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
      }),
    );
    final AiProviderConfig p = provider();
    final List<AiChatMessage> messages = <AiChatMessage>[
      const AiChatMessage.user('hi'),
    ];
    await expectLater(
      client.complete(provider: p, messages: messages),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          'rate_limited',
        ),
      ),
    );
    expect(await client.complete(provider: p, messages: messages), 'ok');
    expect(c.waits, <Duration>[const Duration(seconds: 20)]);
  });
}
