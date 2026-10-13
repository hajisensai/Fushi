import 'dart:async';

import 'package:fushi_engine/ai/ai_provider_config.dart';

/// 按提供商限频：同一家（[AiProviderConfig.id]）的请求按
/// [AiProviderConfig.requestsPerMinute] 均匀排开，不突发——提供商的额度按账号 / key
/// 计，几个功能（OCR 纠错、视频识别、样式生成…）共用一家时必须一起计数，所以
/// 限频挂在提供商上、由 `AiChatClient.complete` 统一排队，而不是各功能各自节流。
///
/// 另一个输入是提供商自己说的「等多久」：429 回复带 `Retry-After` 时
/// [backOff] 把这家的下一个可发时刻推到那之后，不限频的提供商也照样遵守——否则
/// 并发在途的批次会一起撞墙、越拦越多。
///
/// 进程内单例 [shared]；状态只是「每家下一个可发时刻」，不落盘。
class AiRateLimiter {
  AiRateLimiter({
    DateTime Function()? now,
    Future<void> Function(Duration delay)? sleep,
  }) : _now = now ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed;

  /// 全应用共用的一份（同一家提供商跨功能一起计数）。
  static final AiRateLimiter shared = AiRateLimiter();

  final DateTime Function() _now;
  final Future<void> Function(Duration delay) _sleep;

  /// 每家提供商下一个可发请求的时刻；没有记录 = 现在就能发。
  ///
  /// 只在某个请求**真正轮到**时才往后推（见 [acquire]），排队中的请求不预占：
  /// 排队的请求被取消时没有要归还的槽，也不会把后来的请求推到一串早已作废的
  /// 预约之后。
  final Map<String, DateTime> _nextSlot = <String, DateTime>{};

  /// 等到这家的下一个空位、占下它再返回 true。不限频（`requestsPerMinute <= 0`）
  /// 时只等 [backOff] 留下的暂停。
  ///
  /// 每次醒来都重新看一遍「下一个可发时刻」：等待期间别的请求先占了空位，或
  /// [backOff] 把这家往后推了，就接着等，直到真正轮到——不会在退避窗口里发出。
  ///
  /// [cancellation] 被取消时立即醒来并返回 false（进来时已取消也一样），不占任何
  /// 空位；调用方据此放弃这次请求。
  Future<bool> acquire(
    AiProviderConfig provider, {
    AiRateLimitCancellation? cancellation,
  }) async {
    while (cancellation == null || !cancellation.isCancelled) {
      final DateTime now = _now();
      final DateTime? next = _nextSlot[provider.id];
      if (next == null || !next.isAfter(now)) {
        _take(provider, now);
        return true;
      }
      await Future.any(<Future<void>>[
        _sleep(next.difference(now)),
        if (cancellation != null) cancellation.whenCancelled,
      ]);
    }
    return false;
  }

  /// 在 [now] 占下这家的空位：限频时把下一个可发时刻推后一个间隔，不限频时清掉
  /// 已过期的暂停记录。
  void _take(AiProviderConfig provider, DateTime now) {
    final int perMinute = provider.requestsPerMinute;
    if (perMinute > 0) {
      _nextSlot[provider.id] = now.add(
        Duration(microseconds: Duration.microsecondsPerMinute ~/ perMinute),
      );
    } else {
      _nextSlot.remove(provider.id);
    }
  }

  /// 提供商要求暂停 [delay]（`Retry-After`）：这家在那之前不再发。只会往后推，
  /// 不会把已排好的更晚时刻提前。已经在 [acquire] 里排队的请求醒来时会看到它。
  void backOff(AiProviderConfig provider, Duration delay) {
    if (delay <= Duration.zero) return;
    final DateTime until = _now().add(delay);
    final DateTime? next = _nextSlot[provider.id];
    if (next == null || next.isBefore(until)) _nextSlot[provider.id] = until;
  }
}

/// [AiRateLimiter.acquire] 的取消信号：一个客户端（`AiChatClient`）持有一份，
/// 关闭时 [cancel]，它所有还在排队的请求立即放弃排队。只能取消一次，不能复位。
class AiRateLimitCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// 取消时完成；[AiRateLimiter.acquire] 用它叫醒正在睡的等待。
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
