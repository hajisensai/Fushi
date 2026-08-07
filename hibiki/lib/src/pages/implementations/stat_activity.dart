import 'package:fushi/src/utils/misc/hibiki_time_format.dart';

// 统计来源标识 kStatSourceBook / kStatSourceVideo（命名统一 Phase 3.4）已挪进
// hibiki_core 的 stat_source_kind.dart（同枚举 StatSourceKind）——它们是 schema
// 值域的一部分且写入点跨层。本文件只保留分桶/日期键等纯函数。

/// 把按日期分布的活动计数分桶到「今日 / 本周 / 本月 / 全部」。
///
/// 阅读统计与视频统计共用：收藏词条（每条 count=1）和制卡计数（每行已聚合的
/// count）都经此分桶，与 [computeVideoStats] 里完成数的区间判定保持同一套阈值。
class StatActivityBuckets {
  int today = 0;
  int week = 0;
  int month = 0;
  int all = 0;
}

/// 统计行 dateKey 的权威格式器：形如 `2026-06-07`（零填充月/日，可字典序比较），
/// 与 DB 里 reading_statistics / mining_statistics / favorite_words 的 dateKey 同格式。
/// 收藏/制卡记账、活动分桶共用此一处实现（委托 [HibikiTimeFormat.dayKey]），
/// 避免各调用点各写一遍。
String statDateKey(DateTime d) => HibikiTimeFormat.dayKey(d);

/// 「今天」的统计 dateKey（按本地时区当天）。记账写入（[addMiningCount] 等）取此值。
String statTodayKey() => statDateKey(DateTime.now());

/// 纯函数：把 (dateKey, count) 事件按 [now] 的今日/本周/本月/全部窗口累加。
/// dateKey 形如 `2026-06-07`，与 DB 里统计行的 dateKey 同格式，可字典序比较。
StatActivityBuckets bucketActivityByDateKey(
  Iterable<(String dateKey, int count)> events,
  DateTime now,
) {
  final StatActivityBuckets b = StatActivityBuckets();
  final String todayKey = statDateKey(now);
  final String weekAgoKey = statDateKey(now.subtract(const Duration(days: 7)));
  final String monthAgoKey =
      statDateKey(now.subtract(const Duration(days: 30)));
  for (final (String dateKey, int count) in events) {
    b.all += count;
    if (dateKey == todayKey) b.today += count;
    if (dateKey.compareTo(weekAgoKey) >= 0) b.week += count;
    if (dateKey.compareTo(monthAgoKey) >= 0) b.month += count;
  }
  return b;
}
