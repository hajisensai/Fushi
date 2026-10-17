import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_key_rotation.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// 提供商限频（2026-10-13：免费档 / 低档 API 超频会被 429 拦下）。全用假时钟，
/// 不真的等。
void main() {
  AiProviderConfig provider({
    String id = 'p',
    int rpm = 0,
    List<String> keys = const <String>['k'],
  }) => AiProviderConfig(
    id: id,
    presetId: kAiCustomPresetId,
    name: id,
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKeys: <AiApiKey>[for (final String key in keys) AiApiKey(key)],
    model: 'm',
    requestsPerMinute: rpm,
  );

  /// 假时钟：sleep 只把时间往前拨，并记下每次等了多久。
  ({
    AiRateLimiter limiter,
    List<Duration> waits,
    void Function(Duration) tick,
    DateTime Function() now,
  })
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
      now: () => now,
    );
  }

  test('每分钟 N 次：请求按 60/N 秒均匀排开，不突发', () async {
    final c = fakeClock();
    final AiProviderConfig p = provider(rpm: 30);
    for (int i = 0; i < 3; i++) {
      expect(await c.limiter.acquire(p), isTrue);
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

  group('排队中的等待（手动时钟）', () {
    test('等待期间被 backOff 推后：醒来重新检查，退避窗口内不放行', () async {
      final _ManualClock clock = _ManualClock();
      final AiRateLimiter limiter = clock.limiter();
      final AiProviderConfig p = provider(rpm: 1);
      await limiter.acquire(p);
      bool released = false;
      unawaited(limiter.acquire(p).then((_) => released = true));
      await pumpEventQueue();
      limiter.backOff(p, const Duration(seconds: 90));
      await clock.advance(const Duration(minutes: 1));
      expect(released, isFalse, reason: '原定的空位已被退避推到 90 秒');
      await clock.advance(const Duration(seconds: 30));
      expect(released, isTrue);
    });

    test('不限频的等待者也一样：退避被延长时一个都不提前放行', () async {
      final _ManualClock clock = _ManualClock();
      final AiRateLimiter limiter = clock.limiter();
      final AiProviderConfig p = provider();
      limiter.backOff(p, const Duration(seconds: 10));
      int released = 0;
      for (int i = 0; i < 3; i++) {
        unawaited(limiter.acquire(p).then((_) => released++));
      }
      await pumpEventQueue();
      limiter.backOff(p, const Duration(seconds: 20));
      await clock.advance(const Duration(seconds: 10));
      expect(released, 0);
      await clock.advance(const Duration(seconds: 10));
      expect(released, 3);
    });

    test('取消：排队的等待立即放弃、不占空位，后来者不被作废的预约拖住', () async {
      final _ManualClock clock = _ManualClock();
      final AiRateLimiter limiter = clock.limiter();
      final AiProviderConfig p = provider(rpm: 10);
      final AiRateLimitCancellation cancellation = AiRateLimitCancellation();
      expect(await limiter.acquire(p, cancellation: cancellation), isTrue);
      final List<Future<bool>> queued = <Future<bool>>[
        for (int i = 0; i < 20; i++)
          limiter.acquire(p, cancellation: cancellation),
      ];
      await pumpEventQueue();
      cancellation.cancel();
      expect(await Future.wait(queued), everyElement(isFalse));
      // 第一次占的空位之后 6 秒，新请求立刻能发（旧实现要等 20 个预约排完）。
      await clock.advance(const Duration(seconds: 6));
      final List<Duration> before = List<Duration>.of(clock.requested);
      expect(await limiter.acquire(p), isTrue);
      expect(clock.requested, before, reason: '没有再睡');
      expect(
        await limiter.acquire(p, cancellation: cancellation),
        isFalse,
        reason: '已取消的信号进来就放弃',
      );
    });
  });

  group('AiChatClient 临时性失败重试', () {
    final List<AiChatMessage> messages = <AiChatMessage>[
      const AiChatMessage.user('hi'),
    ];

    /// 按顺序回 [responses]（null = 抛网络异常），记下调了几次。时钟与限频器共用
    /// 一个假时钟，健康记录用独立的内存实现。
    (AiChatClient, List<int>) scripted(
      ({
        AiRateLimiter limiter,
        List<Duration> waits,
        void Function(Duration) tick,
        DateTime Function() now,
      })
      c,
      List<http.Response? Function()> responses,
    ) {
      final List<int> calls = <int>[0];
      final AiChatClient client = AiChatClient(
        rateLimiter: c.limiter,
        healthStore: InMemoryAiKeyHealthStore(),
        clock: c.now,
        client: MockClient((http.Request request) async {
          final http.Response? r = responses[calls[0]++]();
          if (r == null) throw const SocketLikeException();
          return r;
        }),
      );
      return (client, calls);
    }

    test('网络抖动 / 5xx：指数退避（2 秒、4 秒）后重试成功', () async {
      final c = fakeClock();
      final (AiChatClient client, List<int> calls) = scripted(
        c,
        <http.Response? Function()>[
          () => null,
          () => http.Response('', 503),
          _ok,
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
        c,
        <http.Response? Function()>[
          () => http.Response(
            '',
            429,
            headers: <String, String>{'retry-after': '20'},
          ),
          _ok,
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
      ) = scripted(c, <http.Response? Function()>[
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
        c,
        <http.Response? Function()>[() => http.Response('', 401), _ok],
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
        c,
        <http.Response? Function()>[
          () => http.Response(
            '',
            429,
            headers: <String, String>{'retry-after': '600'},
          ),
          _ok,
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
        healthStore: InMemoryAiKeyHealthStore(),
        clock: c.now,
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
      await expectLater(
        client.complete(provider: provider(), messages: messages),
        failsWith('cancelled'),
        reason: '关闭之后的新请求不再发出',
      );
      expect(calls.single, 1);
    });
  });

  group('重试与 key 冷却', () {
    final List<AiChatMessage> messages = <AiChatMessage>[
      const AiChatMessage.user('hi'),
    ];

    /// 按 Bearer key 回应答，记下每次请求带的 key 与发出时刻。
    ({
      AiChatClient client,
      List<String> calls,
      List<DateTime> at,
      InMemoryAiKeyHealthStore store,
    })
    server(
      ({
        AiRateLimiter limiter,
        List<Duration> waits,
        void Function(Duration) tick,
        DateTime Function() now,
      })
      c,
      Map<String, http.Response Function()> responses,
    ) {
      final List<String> calls = <String>[];
      final List<DateTime> at = <DateTime>[];
      final InMemoryAiKeyHealthStore store = InMemoryAiKeyHealthStore();
      final AiChatClient client = AiChatClient(
        rateLimiter: c.limiter,
        healthStore: store,
        clock: c.now,
        client: MockClient((http.Request request) async {
          final String key = (request.headers['authorization'] ?? '')
              .replaceFirst('Bearer ', '');
          calls.add(key);
          at.add(c.now());
          return responses[key]!();
        }),
      );
      return (client: client, calls: calls, at: at, store: store);
    }

    http.Response limited([String? retryAfter]) => http.Response(
      '{}',
      429,
      headers: <String, String>{'retry-after': ?retryAfter},
    );

    test('429 无 Retry-After：等到这把 key 冷却到期再重打，不在冷却里反复撞', () async {
      final c = fakeClock();
      final s = server(c, <String, http.Response Function()>{'k': limited});
      final DateTime start = c.now();
      await expectLater(
        s.client.complete(provider: provider(), messages: messages),
        failsWith('rate_limited'),
      );
      // 第一次失败冷却 1 分钟：等足 1 分钟（不是 2 秒）再打第二次；第二次失败
      // 冷却翻倍到 2 分钟，超过上限，不再干等。
      expect(s.calls, <String>['k', 'k']);
      expect(c.waits, <Duration>[kAiKeyBaseCooldown]);
      expect(s.at.last.difference(start), kAiKeyBaseCooldown);
      final AiKeyHealth health = s.store.read(aiKeyFingerprint('p', 'k'))!;
      expect(health.failures, 2, reason: '真正的连续两次失败，没有被冷却期内的重打放大');
    });

    test('上一轮被拒（unauthorized）的 key 本次请求不再试，重试只在限流的 key 里选', () async {
      final c = fakeClock();
      final s = server(c, <String, http.Response Function()>{
        'a': () => http.Response('{}', 401),
        'b': limited,
      });
      await expectLater(
        s.client.complete(
          provider: provider(keys: <String>['a', 'b']),
          messages: messages,
        ),
        failsWith('rate_limited'),
        reason: '最终报错是挡住请求的限流，不被失效 key 的 unauthorized 顶替',
      );
      expect(s.calls, <String>['a', 'b', 'b']);
    });

    test('重试轮次限流的 key 恢复了就成功', () async {
      final c = fakeClock();
      int bCalls = 0;
      final s = server(c, <String, http.Response Function()>{
        'a': () => http.Response('{}', 402),
        'b': () => bCalls++ == 0 ? limited() : _ok(),
      });
      expect(
        await s.client.complete(
          provider: provider(keys: <String>['a', 'b']),
          messages: messages,
        ),
        'ok',
      );
      expect(s.calls, <String>['a', 'b', 'b']);
    });

    test('等待取可重试 key 里最早的冷却到期；还在冷却的那把不去撞', () async {
      final c = fakeClock();
      int bCalls = 0;
      final s = server(c, <String, http.Response Function()>{
        'a': () => limited('30'),
        'b': () => bCalls++ == 0 ? limited('10') : _ok(),
      });
      expect(
        await s.client.complete(
          provider: provider(keys: <String>['a', 'b']),
          messages: messages,
        ),
        'ok',
      );
      expect(c.waits, <Duration>[const Duration(seconds: 10)]);
      expect(s.calls, <String>['a', 'b', 'b']);
    });

    test('不重试时最终报错：有限流就报限流，与 key 的尝试顺序无关', () async {
      final c = fakeClock();
      final s = server(c, <String, http.Response Function()>{
        'a': () => limited('600'),
        'b': () => http.Response('{}', 401),
      });
      await expectLater(
        s.client.complete(
          provider: provider(keys: <String>['a', 'b']),
          messages: messages,
        ),
        failsWith('rate_limited'),
      );
      expect(s.calls, <String>['a', 'b']);
    });
  });

  group('关闭与排队（手动时钟）', () {
    final List<AiChatMessage> messages = <AiChatMessage>[
      const AiChatMessage.user('hi'),
    ];

    test('close 取消本客户端所有排队中的请求，不留占位', () async {
      final _ManualClock clock = _ManualClock();
      final AiRateLimiter limiter = clock.limiter();
      final AiProviderConfig p = provider(rpm: 10);
      int calls = 0;
      AiChatClient newClient() => AiChatClient(
        rateLimiter: limiter,
        healthStore: InMemoryAiKeyHealthStore(),
        clock: () => clock.now,
        client: MockClient((http.Request request) async {
          calls++;
          return _ok();
        }),
      );
      final AiChatClient client = newClient();
      final List<Future<String>> pending = <Future<String>>[
        for (int i = 0; i < 20; i++)
          client.complete(provider: p, messages: messages),
      ];
      await pumpEventQueue();
      expect(calls, 1, reason: '每分钟 10 次：第一个发出，其余排队');
      // 期望先挂上再 close：被取消的 future 立刻失败，晚挂就成了未处理的异步错误。
      final List<Future<void>> cancelled = <Future<void>>[
        for (final Future<String> queued in pending.skip(1))
          expectLater(queued, failsWith('cancelled')),
      ];
      client.close();
      expect(await pending.first, 'ok');
      await Future.wait(cancelled);
      expect(calls, 1, reason: '关闭后排队的一个都没发');

      // 新会话：一个间隔之后的第一个请求不用再等（旧实现要等 19 个作废预约）。
      await clock.advance(const Duration(seconds: 6));
      final List<Duration> before = List<Duration>.of(clock.requested);
      expect(await newClient().complete(provider: p, messages: messages), 'ok');
      expect(clock.requested, before);
      expect(calls, 2);
    });

    test('排完队才读健康记录、才定 key：排队期间别处让某把 key 冷却了就换一把', () async {
      final _ManualClock clock = _ManualClock();
      final AiRateLimiter limiter = clock.limiter();
      final AiProviderConfig p = provider(rpm: 1, keys: <String>['a', 'b']);
      final InMemoryAiKeyHealthStore store = InMemoryAiKeyHealthStore();
      final List<String> calls = <String>[];
      final AiChatClient client = AiChatClient(
        rateLimiter: limiter,
        healthStore: store,
        clock: () => clock.now,
        client: MockClient((http.Request request) async {
          calls.add(
            (request.headers['authorization'] ?? '').replaceFirst(
              'Bearer ',
              '',
            ),
          );
          return _ok();
        }),
      );
      expect(await client.complete(provider: p, messages: messages), 'ok');
      final Future<String> queued = client.complete(
        provider: p,
        messages: messages,
      );
      await pumpEventQueue();
      // 排队期间，别处的请求在 a 上吃了限流。
      store.update(
        aiKeyFingerprint('p', 'a'),
        (_) => AiKeyHealth(
          cooldownUntil: clock.now.add(const Duration(minutes: 5)),
          failures: 1,
          reason: 'rate_limited',
        ),
      );
      await clock.advance(const Duration(minutes: 1));
      expect(await queued, 'ok');
      expect(calls, <String>['a', 'b']);
    });

    test('排队期间别处记下的失败不被当成同一阵限流：本次失败照常累加', () async {
      final _ManualClock clock = _ManualClock();
      final AiRateLimiter limiter = clock.limiter();
      final AiProviderConfig p = provider(rpm: 1);
      final InMemoryAiKeyHealthStore store = InMemoryAiKeyHealthStore();
      int calls = 0;
      final AiChatClient client = AiChatClient(
        rateLimiter: limiter,
        healthStore: store,
        clock: () => clock.now,
        client: MockClient((http.Request request) async {
          return calls++ == 0 ? _ok() : http.Response('{}', 429);
        }),
      );
      expect(await client.complete(provider: p, messages: messages), 'ok');
      final Future<String> queued = client.complete(
        provider: p,
        messages: messages,
      );
      await pumpEventQueue();
      final String fp = aiKeyFingerprint('p', 'k');
      store.update(
        fp,
        (_) => AiKeyHealth(
          cooldownUntil: clock.now.add(const Duration(seconds: 30)),
          failures: 1,
          reason: 'rate_limited',
        ),
      );
      // 冷却已到期，但这次请求排完队时已经看到了那条失败：再失败是第二次。
      // 第二次冷却 2 分钟超过重试上限，直接报错。期望先挂上再推进时钟（失败发生在
      // advance 期间）。
      final Future<void> failed = expectLater(
        queued,
        failsWith('rate_limited'),
      );
      await clock.advance(const Duration(minutes: 1));
      await failed;
      expect(store.read(fp)!.failures, 2);
    });
  });
}

Matcher failsWith(String message) => throwsA(
  isA<AiChatFailure>().having(
    (AiChatFailure f) => f.message,
    'message',
    message,
  ),
);

http.Response _ok() => http.Response(
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

/// 手动推进的假时钟：sleep 挂起，直到 [advance] 把时间推过它的到期时刻。用来
/// 观察「还在排队」的中间状态（自动前进的假时钟一 sleep 就醒，看不到）。
class _ManualClock {
  DateTime now = DateTime.utc(2026, 10, 13);

  /// 每次 sleep 请求的时长（按请求顺序）。
  final List<Duration> requested = <Duration>[];

  final List<({DateTime at, Completer<void> done})> _sleepers =
      <({DateTime at, Completer<void> done})>[];

  AiRateLimiter limiter() => AiRateLimiter(now: () => now, sleep: _sleep);

  Future<void> _sleep(Duration delay) {
    requested.add(delay);
    final Completer<void> done = Completer<void>();
    _sleepers.add((at: now.add(delay), done: done));
    return done.future;
  }

  /// 拨快 [delay]，叫醒到期的 sleep，并让被叫醒的代码跑完。
  Future<void> advance(Duration delay) async {
    now = now.add(delay);
    for (final ({DateTime at, Completer<void> done}) s in _sleepers) {
      if (!s.at.isAfter(now) && !s.done.isCompleted) s.done.complete();
    }
    await pumpEventQueue();
  }
}

/// MockClient 里模拟连接断开（`AiChatClient` 把任何发送异常归成 `network_error`）。
class SocketLikeException implements Exception {
  const SocketLikeException();
}
