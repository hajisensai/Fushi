import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi_core/fushi_core.dart';

/// 单个视频在「按视频排行」里的聚合数据。
///
/// v76：一张 tile = 一个身份组（[groupStatRowsByIdentity]）。[bookUid] null =
/// 无身份遗留组（同名多视频的 v39 前旧行 / sync 降级行，归属不可判）；
/// [absorbedUnattributed] = 本组吸收了同 title 的无身份行（删除时连带）。
class VideoStatBookData {
  VideoStatBookData(this.title, {this.bookUid});
  final String title;
  final String? bookUid;
  bool absorbedUnattributed = false;
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

/// 纯函数：把视频观看统计行 + 完成时间戳列表聚合成 [VideoStatsAggregate]。
/// 与 reading_statistics_page 的 `_computeAggregates` 同构，但抽成纯函数可单测。
VideoStatsAggregate computeVideoStats({
  required List<VideoWatchStatisticRow> stats,
  required List<DateTime> completed,
  required DateTime now,
}) {
  final agg = VideoStatsAggregate();
  final todayKey = statDateKey(now);
  final weekAgoKey = statDateKey(now.subtract(const Duration(days: 7)));
  final monthAgoKey = statDateKey(now.subtract(const Duration(days: 30)));

  final dailyMap = <String, StatDayData>{};

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
  }

  // 最近 30 天补齐空日期，按日期升序。
  final thirtyDaysAgo = now.subtract(const Duration(days: 29));
  for (int i = 0; i < 30; i++) {
    final key = statDateKey(thirtyDaysAgo.add(Duration(days: i)));
    agg.daily.add(dailyMap[key] ?? StatDayData(dateKey: key));
  }
  // v76：按视频排行改身份分组（v39 只修了存储层，展示层此前仍按 title 合并同名
  // 视频——互串的另一半）。分组契约见 [groupStatRowsByIdentity]。
  agg.byVideo = <VideoStatBookData>[
    for (final StatIdentityGroup<VideoWatchStatisticRow> g
        in groupStatRowsByIdentity(
      stats,
      identityOf: (VideoWatchStatisticRow s) => s.bookUid ?? '',
      titleOf: (VideoWatchStatisticRow s) => s.title,
    ))
      () {
        final VideoStatBookData book =
            VideoStatBookData(g.title, bookUid: g.identity)
              ..absorbedUnattributed = g.absorbedUnattributed;
        for (final VideoWatchStatisticRow s in g.rows) {
          book.chars += s.subtitleChars;
          book.ms += s.watchTimeMs;
        }
        return book;
      }(),
  ]..sort((a, b) => b.ms.compareTo(a.ms));
  // 删字数后按观看时长排行（字数仍在 DB/聚合里保留，只是不再展示/排序）。

  // 完成数按时间戳落入区间（天然去重：completedAt 只记首次）。
  for (final c in completed) {
    final key = statDateKey(c);
    agg.allCompleted++;
    if (key == todayKey) agg.todayCompleted++;
    if (key.compareTo(weekAgoKey) >= 0) agg.weekCompleted++;
    if (key.compareTo(monthAgoKey) >= 0) agg.monthCompleted++;
  }
  return agg;
}
