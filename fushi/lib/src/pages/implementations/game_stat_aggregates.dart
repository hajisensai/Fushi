import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/stats/stat_window.dart';

/// 游戏统计页的窗口聚合。
///
/// 时长与次数只来自 `galgame_sessions` 的按日 GROUP BY；[games] 只提供按游戏汇总
/// 与显示信息。窗口阈值只来自 [StatWindow]。
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
  final StatWindow w = StatWindow(now);

  dailyTotals.forEach((
    String dateKey,
    (int totalSeconds, int sessionCount) totals,
  ) {
    final int ms = totals.$1 * 1000;
    result.allMs += ms;
    result.allSessions += totals.$2;
    if (w.isToday(dateKey)) {
      result.todayMs += ms;
      result.todaySessions += totals.$2;
    }
    if (w.inWeek(dateKey)) {
      result.weekMs += ms;
      result.weekSessions += totals.$2;
    }
    if (w.inMonth(dateKey)) {
      result.monthMs += ms;
      result.monthSessions += totals.$2;
    }
  });

  result.daily = <StatDayData>[
    for (final String dateKey in w.lastDayKeys(30))
      StatDayData(dateKey: dateKey)
        ..ms = (dailyTotals[dateKey]?.$1 ?? 0) * 1000,
  ];

  result.byGame =
      games.where((GalgameEntry game) => game.sessionCount > 0).toList()
        ..sort((GalgameEntry a, GalgameEntry b) {
          final int byTime = b.totalPlaySeconds.compareTo(a.totalPlaySeconds);
          if (byTime != 0) return byTime;
          return b.lastPlayedMs.compareTo(a.lastPlayedMs);
        });
  return result;
}
