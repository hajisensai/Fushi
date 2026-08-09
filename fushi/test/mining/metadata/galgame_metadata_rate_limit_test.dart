/// 令牌桶限流 + `Retry-After` 的确定性测试：时钟与 sleep 全部注入，**不等真实时间**。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_rate_limit.dart';

/// 虚拟时钟：`sleep` 直接把时间快进过去，测试零真实耗时。
class _FakeClock {
  DateTime now = DateTime.utc(2026, 1, 1, 12);

  Future<void> sleep(Duration delay) async {
    if (delay > Duration.zero) {
      now = now.add(delay);
    }
    // 让出一次事件循环，模拟真实 sleep 的异步语义。
    await Future<void>.delayed(Duration.zero);
  }

  void advance(Duration delta) => now = now.add(delta);
}

GalgameRateLimiter _limiter(
  _FakeClock clock, {
  int capacity = 2,
  Duration refill = const Duration(seconds: 1),
  Duration maxRetryAfter = const Duration(minutes: 5),
}) {
  return GalgameRateLimiter(
    capacity: capacity,
    refillInterval: refill,
    maxRetryAfter: maxRetryAfter,
    now: () => clock.now,
    sleep: clock.sleep,
  );
}

void main() {
  group('令牌桶', () {
    test('桶内令牌够时不等待，耗尽后按 refillInterval 逐枚放行', () async {
      final _FakeClock clock = _FakeClock();
      final GalgameRateLimiter limiter = _limiter(clock, capacity: 2);
      final DateTime t0 = clock.now;
      final List<Duration> startedAt = <Duration>[];

      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < 4; i++)
          limiter.run(() async => startedAt.add(clock.now.difference(t0))),
      ]);

      expect(startedAt, <Duration>[
        Duration.zero, // 用掉第 1 枚
        Duration.zero, // 用掉第 2 枚
        const Duration(seconds: 1), // 等 1 枚回充
        const Duration(seconds: 2), // 再等 1 枚
      ]);
      expect(limiter.availableTokens, 0);
    });

    test('空闲时回充但不超过容量（不积攒突发额度）', () async {
      final _FakeClock clock = _FakeClock();
      final GalgameRateLimiter limiter = _limiter(clock, capacity: 2);

      await limiter.run(() async {});
      await limiter.run(() async {});
      expect(limiter.availableTokens, 0);

      clock.advance(const Duration(seconds: 30)); // 远超 2 枚的回充时间
      final DateTime t0 = clock.now;
      await limiter.run(() async {});
      await limiter.run(() async {});
      await limiter.run(() async {});
      // 前两枚立即放行，第三枚必须再等 1 个 refill —— 桶没有攒出 30 枚。
      expect(clock.now.difference(t0), const Duration(seconds: 1));
    });

    test('任务按入队顺序串行执行', () async {
      final _FakeClock clock = _FakeClock();
      final GalgameRateLimiter limiter = _limiter(clock, capacity: 10);
      final List<int> order = <int>[];
      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < 5; i++)
          limiter.run(() async {
            await Future<void>.delayed(Duration.zero);
            order.add(i);
          }),
      ]);
      expect(order, <int>[0, 1, 2, 3, 4]);
    });

    test('任务抛异常原样透出，且不毒化队列', () async {
      final _FakeClock clock = _FakeClock();
      final GalgameRateLimiter limiter = _limiter(clock, capacity: 10);

      await expectLater(
        limiter.run<void>(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      expect(await limiter.run<int>(() async => 42), 42);
    });
  });

  group('Retry-After', () {
    test('applyRetryAfter 期间的任务等到解禁才跑', () async {
      final _FakeClock clock = _FakeClock();
      final GalgameRateLimiter limiter = _limiter(clock, capacity: 10);
      limiter.applyRetryAfter(const Duration(seconds: 30));
      expect(limiter.blockedUntil, isNotNull);

      final DateTime t0 = clock.now;
      await limiter.run(() async {});
      expect(clock.now.difference(t0), const Duration(seconds: 30));
      expect(limiter.blockedUntil, isNull);
    });

    test('较长的封禁不会被随后较短的顶掉', () async {
      final _FakeClock clock = _FakeClock();
      final GalgameRateLimiter limiter = _limiter(clock, capacity: 10);
      limiter.applyRetryAfter(const Duration(seconds: 60));
      limiter.applyRetryAfter(const Duration(seconds: 5));

      final DateTime t0 = clock.now;
      await limiter.run(() async {});
      expect(clock.now.difference(t0), const Duration(seconds: 60));
    });

    test('超过 maxRetryAfter 被截断，不把 UI 挂死', () async {
      final _FakeClock clock = _FakeClock();
      final GalgameRateLimiter limiter = _limiter(
        clock,
        capacity: 10,
        maxRetryAfter: const Duration(minutes: 5),
      );
      limiter.applyRetryAfter(const Duration(hours: 3));

      final DateTime t0 = clock.now;
      await limiter.run(() async {});
      expect(clock.now.difference(t0), const Duration(minutes: 5));
    });

    test('非正数的 Retry-After 被忽略', () {
      final _FakeClock clock = _FakeClock();
      final GalgameRateLimiter limiter = _limiter(clock);
      limiter.applyRetryAfter(Duration.zero);
      limiter.applyRetryAfter(const Duration(seconds: -5));
      expect(limiter.blockedUntil, isNull);
    });

    test('noteResponse 只对 429/503 生效', () async {
      final _FakeClock clock = _FakeClock();
      final GalgameRateLimiter limiter = _limiter(clock, capacity: 10);

      limiter.noteResponse(200, <String, String>{'retry-after': '120'});
      expect(limiter.blockedUntil, isNull);

      limiter.noteResponse(429, <String, String>{'retry-after': '120'});
      expect(limiter.blockedUntil, clock.now.add(const Duration(seconds: 120)));

      final DateTime t0 = clock.now;
      await limiter.run(() async {});
      expect(clock.now.difference(t0), const Duration(seconds: 120));
    });

    test('503 无 Retry-After 头 → 退回保守冷却（capacity × refill）', () async {
      final _FakeClock clock = _FakeClock();
      final GalgameRateLimiter limiter = _limiter(
        clock,
        capacity: 3,
        refill: const Duration(seconds: 2),
      );
      limiter.noteResponse(503, const <String, String>{});
      final DateTime t0 = clock.now;
      await limiter.run(() async {});
      expect(clock.now.difference(t0), const Duration(seconds: 6));
    });
  });

  group('parseRetryAfter', () {
    test('秒数形式（含空白）', () {
      expect(parseRetryAfter('120'), const Duration(seconds: 120));
      expect(parseRetryAfter('  5  '), const Duration(seconds: 5));
    });

    test('非法 / 空 / 非正 → null', () {
      expect(parseRetryAfter(null), isNull);
      expect(parseRetryAfter(''), isNull);
      expect(parseRetryAfter('   '), isNull);
      expect(parseRetryAfter('soon'), isNull);
      expect(parseRetryAfter('0'), isNull);
      expect(parseRetryAfter('-3'), isNull);
    });

    test('HTTP-date 形式按 now 求差', () {
      final DateTime now = DateTime.utc(1994, 11, 6, 8, 49, 7);
      expect(
        parseRetryAfter('Sun, 06 Nov 1994 08:49:37 GMT', now: now),
        const Duration(seconds: 30),
      );
    });

    test('已过期的 HTTP-date → null；月份非法 → null', () {
      final DateTime now = DateTime.utc(2026, 1, 1);
      expect(
          parseRetryAfter('Sun, 06 Nov 1994 08:49:37 GMT', now: now), isNull);
      expect(
          parseRetryAfter('Sun, 06 Xxx 2030 08:49:37 GMT', now: now), isNull);
      expect(parseRetryAfter('2030-01-01T00:00:00Z', now: now), isNull);
    });
  });
}
