import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 单次 flush 允许的最大阅读窗口。阅读时长由 [ReadingTimeTracker] 的 60s 定时器驱动，
/// 正常窗口 ≈ 60s。超过此上限说明定时器跨越了**非连续前台阅读窗口**（app 后台挂起 /
/// 系统睡眠 / 熄屏 / 长 GC 停顿致定时器被冻结后一次性补发），该段用户是否真在阅读未知。
///
/// 对照 `hibiki/lib/src/media/video/video_watch_tracker.dart` 的 `kMaxWatchGap`——视频侧
/// 早已有此守卫，阅读侧此前缺失，导致整夜后台挂起被一次性计入阅读时长（BUG-892）。
const Duration kMaxReadingGap = Duration(seconds: 120);

/// 纯谓词：[start]..[now] 是否是一次正常的连续阅读窗口。
///
/// 过滤异常大间隔（见 [kMaxReadingGap]）：返回 false 时调用方应整窗丢弃、不累加阅读
/// 时长，避免把后台挂起 / 熄屏 / 睡眠时长凭空计入。同时保证 [splitReadingTime] 永远只
/// 看到 ≤ [kMaxReadingGap] 的输入——单次至多跨一个小时/天边界，其单边界拆桶假设始终成立。
bool isContinuousReadingGap(DateTime start, DateTime now) {
  final Duration d = now.difference(start);
  return d > Duration.zero && d <= kMaxReadingGap;
}

/// 把 [start]..[now] 的阅读时长按小时/天边界拆成 (dateKey, hour, ms) 桶。
///
/// 抽成纯函数便于单测。调用方须先用 [isContinuousReadingGap] 门控，保证输入
/// ≤ [kMaxReadingGap]（单次至多跨一个边界，单边界拆桶假设成立）。
List<(String, int, int)> splitReadingTime(DateTime start, DateTime now) {
  final int elapsed = now.difference(start).inMilliseconds;
  if (elapsed <= 0) return const <(String, int, int)>[];
  if (start.hour != now.hour || start.day != now.day) {
    final DateTime boundary =
        DateTime(start.year, start.month, start.day, start.hour + 1);
    final int firstMs = boundary.difference(start).inMilliseconds;
    final int secondMs = now.difference(boundary).inMilliseconds;
    return <(String, int, int)>[
      if (firstMs > 0) (_formatDateKey(start), start.hour, firstMs),
      if (secondMs > 0) (_formatDateKey(now), now.hour, secondMs),
    ];
  }
  return <(String, int, int)>[(_formatDateKey(start), start.hour, elapsed)];
}

String _formatDateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 一次已确认的连续阅读增量（[ReadingTimeTracker] 的 tick 产物）。
typedef ReadingTimeDelta = void Function(int deltaMs);

class ReadingTimeTracker {
  /// [onDelta]：每次 tick 确认一段连续阅读窗口时，把**同一份**毫秒增量回吐给调用方。
  ///
  /// BUG-1052：每书/每日阅读时长（`reading_statistics.reading_time_ms`）此前自己拿
  /// `now - _sessionStartTime` 算墙钟差，与本 tracker 各算各的；而 `_sessionStartTime`
  /// 被生命周期 resumed / 章节恢复完成等多处无条件重置，重置前那段前台阅读时长直接蒸发。
  /// 现在两条账目共用**同一个**带 [isContinuousReadingGap] 守卫的时钟：本 tracker 记小时
  /// 桶，[onDelta] 把同一增量喂给会话累计器，任何重置都不再能吃掉时长。
  ReadingTimeTracker(this._database, {ReadingTimeDelta? onDelta})
      : _onDelta = onDelta;

  final HibikiDatabase _database;
  final ReadingTimeDelta? _onDelta;
  Timer? _timer;
  DateTime? _tickStart;

  static const _interval = Duration(seconds: 60);

  /// 计时中（已 [start] 且未 [stop]）。后台期间恒 false，故后台时长永不入账。
  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    _tickStart = DateTime.now();
    _timer = Timer.periodic(_interval, (_) => _flush());
  }

  void stop() {
    _flush();
    _timer?.cancel();
    _timer = null;
    _tickStart = null;
  }

  void dispose() {
    stop();
  }

  /// 立刻结算当前这段未满一个 tick 的窗口（不停表）。
  ///
  /// 供每书/每日统计在落库前把「上一次 tick 到现在」这段补进 [onDelta]——否则每次
  /// 落库都会漏掉最多一个 tick 间隔的时长。守卫与定时 tick 完全一致。
  void sampleNow() => _flush();

  void _flush() {
    final start = _tickStart;
    if (start == null) return;
    final now = DateTime.now();
    _tickStart = now;

    // 仅在连续前台阅读窗口内累加：[isContinuousReadingGap] 过滤异常大间隔（后台挂起 /
    // 熄屏 / 睡眠 / 长 GC 停顿致定时器跨越非阅读窗口），整窗丢弃而非凭空计入阅读时长，
    // 并保证 [splitReadingTime] 输入恒 ≤ kMaxReadingGap（单次至多跨一个边界）。BUG-892。
    if (!isContinuousReadingGap(start, now)) return;
    int accepted = 0;
    for (final (String dateKey, int hour, int ms)
        in splitReadingTime(start, now)) {
      _write(dateKey, hour, ms);
      accepted += ms;
    }
    if (accepted > 0) _onDelta?.call(accepted);
  }

  void _write(String dateKey, int hour, int deltaMs) {
    _database
        .addHourlyReadingTime(dateKey: dateKey, hour: hour, deltaMs: deltaMs)
        .catchError((Object e, StackTrace stack) {
      debugPrint('ReadingTimeTracker.write: $e\n$stack');
      debugPrint('[reading-time-tracker] write error: $e');
    });
  }
}
