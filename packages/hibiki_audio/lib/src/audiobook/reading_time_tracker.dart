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

class ReadingTimeTracker {
  ReadingTimeTracker(this._database);

  final HibikiDatabase _database;
  Timer? _timer;
  DateTime? _tickStart;

  static const _interval = Duration(seconds: 60);

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

  void _flush() {
    final start = _tickStart;
    if (start == null) return;
    final now = DateTime.now();
    _tickStart = now;

    // 仅在连续前台阅读窗口内累加：[isContinuousReadingGap] 过滤异常大间隔（后台挂起 /
    // 熄屏 / 睡眠 / 长 GC 停顿致定时器跨越非阅读窗口），整窗丢弃而非凭空计入阅读时长，
    // 并保证 [splitReadingTime] 输入恒 ≤ kMaxReadingGap（单次至多跨一个边界）。BUG-892。
    if (!isContinuousReadingGap(start, now)) return;
    for (final (String dateKey, int hour, int ms)
        in splitReadingTime(start, now)) {
      _write(dateKey, hour, ms);
    }
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
