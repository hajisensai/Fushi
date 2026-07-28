import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';

/// 游戏统计页的窗口聚合。
///
/// 时长与次数只来自 `galgame_sessions` 的按日 GROUP BY；[games] 只提供按游戏汇总
/// 与显示信息，不读取 `activity_events`。
class GameStatsAggregate {
  GameStatsAggregate();

  int todayMs = 0;
  int weekMs = 0;
  int monthMs = 0;
  int allMs = 0;

  int todaySessions = 0;
  int weekSessions = 0;
  int monthSessions = 0;
  int allSessions = 0;

  List<StatDayData> daily = <StatDayData>[];
  List<GalgameEntry> byGame = <GalgameEntry>[];
}

GameStatsAggregate computeGameStats({
  required List<GalgameEntry> games,
  required Map<String, (int totalSeconds, int sessionCount)> dailyTotals,
  required DateTime now,
}) {
  final GameStatsAggregate result = GameStatsAggregate();
  final String todayKey = statDateKey(now);
  final String weekAgoKey = statDateKey(now.subtract(const Duration(days: 7)));
  final String monthAgoKey =
      statDateKey(now.subtract(const Duration(days: 30)));

  dailyTotals.forEach((
    String dateKey,
    (int totalSeconds, int sessionCount) totals,
  ) {
    final int ms = totals.$1 * 1000;
    result.allMs += ms;
    result.allSessions += totals.$2;
    if (dateKey == todayKey) {
      result.todayMs += ms;
      result.todaySessions += totals.$2;
    }
    if (dateKey.compareTo(weekAgoKey) >= 0) {
      result.weekMs += ms;
      result.weekSessions += totals.$2;
    }
    if (dateKey.compareTo(monthAgoKey) >= 0) {
      result.monthMs += ms;
      result.monthSessions += totals.$2;
    }
  });

  final DateTime firstDay = now.subtract(const Duration(days: 29));
  result.daily = <StatDayData>[];
  for (int i = 0; i < 30; i++) {
    final String dateKey = statDateKey(firstDay.add(Duration(days: i)));
    final StatDayData day = StatDayData(dateKey: dateKey);
    day.ms = (dailyTotals[dateKey]?.$1 ?? 0) * 1000;
    result.daily.add(day);
  }

  result.byGame =
      games.where((GalgameEntry game) => game.sessionCount > 0).toList()
        ..sort((GalgameEntry a, GalgameEntry b) {
          final int byTime = b.totalPlaySeconds.compareTo(a.totalPlaySeconds);
          if (byTime != 0) return byTime;
          return b.lastPlayedMs.compareTo(a.lastPlayedMs);
        });
  return result;
}
