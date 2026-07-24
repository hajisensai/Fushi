/// 元数据源限流：**每源一个独立令牌桶 + 串行队列**，并尊重 HTTP `Retry-After`（契约 §2.3）。
///
/// 纯 Dart，无 Flutter / IO 依赖：时钟与 sleep 都可注入，单测里用假时钟即可确定性验证。
library;

import 'dart:async';
import 'dart:math' as math;

/// 令牌桶限流器：桶容量 [capacity]，每 [refillInterval] 回一枚令牌。
///
/// 所有 [run] 进来的任务在**同一条串行链**上依次执行——对同一个站点并发打请求本来就
/// 没有意义，串行还顺带让令牌消耗时序变得可预测（否则多个 waiter 会一起醒来抢同一枚）。
class GalgameRateLimiter {
  GalgameRateLimiter({
    this.capacity = 3,
    this.refillInterval = const Duration(milliseconds: 700),
    this.maxRetryAfter = const Duration(minutes: 5),
    DateTime Function()? now,
    Future<void> Function(Duration delay)? sleep,
  })  : assert(capacity > 0, 'capacity 必须为正'),
        assert(refillInterval > Duration.zero, 'refillInterval 必须为正'),
        _now = now ?? DateTime.now,
        _sleep = sleep ?? _defaultSleep {
    _tokens = capacity;
    _lastRefill = _now();
  }

  /// 桶容量（允许的突发请求数）。
  final int capacity;

  /// 令牌回充间隔（稳态速率 = 1 / refillInterval）。
  final Duration refillInterval;

  /// `Retry-After` 的上限：服务端给个离谱的值不能把 UI 挂死，超过就截断。
  final Duration maxRetryAfter;

  final DateTime Function() _now;
  final Future<void> Function(Duration delay) _sleep;

  late int _tokens;
  late DateTime _lastRefill;
  DateTime? _blockedUntil;
  Future<void> _tail = Future<void>.value();

  static Future<void> _defaultSleep(Duration delay) =>
      Future<void>.delayed(delay);

  /// 当前可用令牌数（测试与诊断用）。
  int get availableTokens => _tokens;

  /// 因 `Retry-After` 被封禁到的时刻；null = 未被封。
  DateTime? get blockedUntil => _blockedUntil;

  /// 排队执行 [job]：先等到拿得到令牌（且不在 `Retry-After` 封禁期内）再跑。
  ///
  /// [job] 抛出的异常原样透给调用方，**且不会毒化串行链**（后续任务照常执行）。
  Future<T> run<T>(Future<T> Function() job) {
    final Completer<T> completer = Completer<T>();
    void fail(Object error, StackTrace stack) {
      if (!completer.isCompleted) {
        completer.completeError(error, stack);
      }
    }

    _tail = _tail.then((_) async {
      try {
        await _acquire();
        final T result = await job();
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (error, stack) {
        fail(error, stack);
      }
    }).catchError((Object error, StackTrace stack) {
      // 显式的 (Object, StackTrace) -> void 闭包：直接传 `fail` 会被分析器判为
      // `invalid_return_type_for_catch_error`（void 不满足 FutureOr<Null>），
      // 且 CI 把 warning 当致命。
      fail(error, stack);
    });
    return completer.future;
  }

  /// 记录服务端下发的 `Retry-After`：在此期间 [run] 一律等待。
  ///
  /// 取「已有封禁期」与「新封禁期」的**较晚者**，避免一个短的把长的顶掉。
  void applyRetryAfter(Duration delay) {
    if (delay <= Duration.zero) {
      return;
    }
    final Duration capped = delay > maxRetryAfter ? maxRetryAfter : delay;
    final DateTime until = _now().add(capped);
    final DateTime? current = _blockedUntil;
    if (current == null || until.isAfter(current)) {
      _blockedUntil = until;
    }
  }

  /// 从一次响应里提取限流信号：429 / 503 带 `Retry-After` 时进入封禁期。
  /// [headers] 直接传 `http.Response.headers`（key 已被 package:http 小写化）。
  void noteResponse(int statusCode, Map<String, String> headers) {
    if (statusCode != 429 && statusCode != 503) {
      return;
    }
    final Duration? delay = parseRetryAfter(
      headers['retry-after'] ?? headers['Retry-After'],
      now: _now(),
    );
    // 服务端只说「限流了」没给 Retry-After 时，退回一个保守的固定冷却。
    applyRetryAfter(delay ?? refillInterval * capacity);
  }

  /// 拿一枚令牌；不够就 sleep 到够为止。只在串行链内部调用。
  Future<void> _acquire() async {
    // 循环而非一次性计算：sleep 期间可能又被 applyRetryAfter 延长封禁。
    while (true) {
      final DateTime now = _now();
      final DateTime? blocked = _blockedUntil;
      if (blocked != null && blocked.isAfter(now)) {
        await _sleep(blocked.difference(now));
        continue;
      }
      _blockedUntil = null;
      _refill(now);
      if (_tokens > 0) {
        _tokens -= 1;
        return;
      }
      final Duration wait = _lastRefill.add(refillInterval).difference(now);
      await _sleep(wait > Duration.zero ? wait : refillInterval);
    }
  }

  /// 按流逝时间回充令牌。整倍数推进 [_lastRefill]，不足一枚的零头留到下次累积。
  void _refill(DateTime now) {
    final int elapsedUs = now.difference(_lastRefill).inMicroseconds;
    if (elapsedUs <= 0) {
      return;
    }
    final int intervalUs = refillInterval.inMicroseconds;
    final int gained = elapsedUs ~/ intervalUs;
    if (gained <= 0) {
      return;
    }
    _tokens = math.min(capacity, _tokens + gained);
    if (_tokens >= capacity) {
      // 桶满后不再积攒「欠账」，否则长时间空闲会换来一大串瞬时突发。
      _lastRefill = now;
    } else {
      _lastRefill = _lastRefill.add(refillInterval * gained);
    }
  }
}

/// 解析 HTTP `Retry-After` 头：支持「秒数」与「HTTP-date」两种形式。
///
/// 非法 / 缺失 / 已过期 → null。[now] 用于 HTTP-date 求差值，便于单测注入。纯函数。
Duration? parseRetryAfter(String? header, {DateTime? now}) {
  if (header == null) {
    return null;
  }
  final String raw = header.trim();
  if (raw.isEmpty) {
    return null;
  }
  final int? seconds = int.tryParse(raw);
  if (seconds != null) {
    return seconds <= 0 ? null : Duration(seconds: seconds);
  }
  final DateTime? at = _tryParseHttpDate(raw);
  if (at == null) {
    return null;
  }
  final Duration delta = at.difference((now ?? DateTime.now()).toUtc());
  return delta <= Duration.zero ? null : delta;
}

/// 解析 RFC 7231 的 IMF-fixdate（`Sun, 06 Nov 1994 08:49:37 GMT`）。
/// 失败返回 null；不引新依赖，手写月份表即可。
DateTime? _tryParseHttpDate(String value) {
  final RegExpMatch? m = RegExp(
    r'^[A-Za-z]{3},\s+(\d{2})\s+([A-Za-z]{3})\s+(\d{4})\s+'
    r'(\d{2}):(\d{2}):(\d{2})\s+GMT$',
  ).firstMatch(value);
  if (m == null) {
    return null;
  }
  const List<String> months = <String>[
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  final int month = months.indexOf(m.group(2)!.toLowerCase()) + 1;
  if (month == 0) {
    return null;
  }
  return DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
}
