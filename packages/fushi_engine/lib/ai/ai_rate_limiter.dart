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
  final Map<String, DateTime> _nextSlot = <String, DateTime>{};

  /// 排到这家的下一个空位再返回。不限频（`requestsPerMinute <= 0`）时只等
  /// [backOff] 留下的暂停。
  Future<void> acquire(AiProviderConfig provider) async {
    final DateTime now = _now();
    final DateTime? next = _nextSlot[provider.id];
    final DateTime slot = next == null || next.isBefore(now) ? now : next;
    final int perMinute = provider.requestsPerMinute;
    if (perMinute > 0) {
      _nextSlot[provider.id] = slot.add(
        Duration(microseconds: Duration.microsecondsPerMinute ~/ perMinute),
      );
    } else if (next != null && !next.isAfter(now)) {
      _nextSlot.remove(provider.id);
    }
    final Duration wait = slot.difference(now);
    if (wait > Duration.zero) await _sleep(wait);
  }

  /// 提供商要求暂停 [delay]（`Retry-After`）：这家在那之前不再发。只会往后推，
  /// 不会把已排好的更晚时刻提前。
  void backOff(AiProviderConfig provider, Duration delay) {
    if (delay <= Duration.zero) return;
    final DateTime until = _now().add(delay);
    final DateTime? next = _nextSlot[provider.id];
    if (next == null || next.isBefore(until)) _nextSlot[provider.id] = until;
  }
}
