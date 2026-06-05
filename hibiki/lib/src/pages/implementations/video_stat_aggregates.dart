import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 单个视频在「按视频排行」里的聚合数据。
class VideoStatBookData {
  VideoStatBookData(this.title);
  final String title;
  int chars = 0;
  int ms = 0;
}

/// 视频统计聚合结果（今日 / 本周 / 本月 / 全部 + 30 天图 + 按视频排行 + 完成数）。
class VideoStatsAggregate {
  int todayChars = 0, todayMs = 0, todayCompleted = 0;
  int weekChars = 0, weekMs = 0, weekCompleted = 0;
  int monthChars = 0, monthMs = 0, monthCompleted = 0;
  int allChars = 0, allMs = 0, allCompleted = 0;
  List<StatDayData> daily = <StatDayData>[];
  List<VideoStatBookData> byVideo = <VideoStatBookData>[];
}

String _dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 纯函数：把视频观看统计行 + 完成时间戳列表聚合成 [VideoStatsAggregate]。
/// 与 reading_statistics_page 的 `_computeAggregates` 同构，但抽成纯函数可单测。
VideoStatsAggregate computeVideoStats({
  required List<VideoWatchStatisticRow> stats,
  required List<DateTime> completed,
  required DateTime now,
}) {
  final agg = VideoStatsAggregate();
  final todayKey = _dateKey(now);
  final weekAgoKey = _dateKey(now.subtract(const Duration(days: 7)));
  final monthAgoKey = _dateKey(now.subtract(const Duration(days: 30)));

  final dailyMap = <String, StatDayData>{};
  final bookMap = <String, VideoStatBookData>{};

  for (final s in stats) {
    agg.allChars += s.subtitleChars;
    agg.allMs += s.watchTimeMs;
    if (s.dateKey == todayKey) {
      agg.todayChars += s.subtitleChars;
      agg.todayMs += s.watchTimeMs;
    }
    if (s.dateKey.compareTo(weekAgoKey) >= 0) {
      agg.weekChars += s.subtitleChars;
      agg.weekMs += s.watchTimeMs;
    }
    if (s.dateKey.compareTo(monthAgoKey) >= 0) {
      agg.monthChars += s.subtitleChars;
      agg.monthMs += s.watchTimeMs;
    }
    final day =
        dailyMap.putIfAbsent(s.dateKey, () => StatDayData(dateKey: s.dateKey));
    day.chars += s.subtitleChars;
    day.ms += s.watchTimeMs;
    final book = bookMap.putIfAbsent(s.title, () => VideoStatBookData(s.title));
    book.chars += s.subtitleChars;
    book.ms += s.watchTimeMs;
  }

  // 最近 30 天补齐空日期，按日期升序。
  final thirtyDaysAgo = now.subtract(const Duration(days: 29));
  for (int i = 0; i < 30; i++) {
    final key = _dateKey(thirtyDaysAgo.add(Duration(days: i)));
    agg.daily.add(dailyMap[key] ?? StatDayData(dateKey: key));
  }
  agg.byVideo = bookMap.values.toList()
    ..sort((a, b) => b.chars.compareTo(a.chars));

  // 完成数按时间戳落入区间（天然去重：completedAt 只记首次）。
  for (final c in completed) {
    final key = _dateKey(c);
    agg.allCompleted++;
    if (key == todayKey) agg.todayCompleted++;
    if (key.compareTo(weekAgoKey) >= 0) agg.weekCompleted++;
    if (key.compareTo(monthAgoKey) >= 0) agg.monthCompleted++;
  }
  return agg;
}
