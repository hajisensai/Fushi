import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi_engine/stats/stat_facts.dart';

/// 学习字数目标的周期（反馈 CjIr9RGSCe：日目标与周目标二选一）。
///
/// 两个目标值各自持久化（`reading_goal_daily_chars` / `reading_goal_weekly_chars`），
/// 本枚举只决定**哪一个生效**：首页目标行、阅读统计页「今天」环、桌面小组件的
/// 字数目标都按它取目标值与分子。切换周期不清另一份数值，切回来原值还在。
enum StudyGoalPeriod {
  /// 每日目标：分子 = 今日学习字数（[studyGoalCharsForDay]）。
  daily('daily'),

  /// 每周目标：分子 = 本自然周（周一起，[StatWindow.weekFromKey]）学习字数
  /// （[studyGoalCharsForWeek]）。
  weekly('weekly');

  const StudyGoalPeriod(this.wire);

  /// 偏好里存的值（`reading_goal_period`）。
  final String wire;

  /// 未知 / 缺省值一律回落 [daily]（存量用户没有这个键，行为与之前一致）。
  static StudyGoalPeriod fromWire(String? wire) {
    for (final StudyGoalPeriod p in values) {
      if (p.wire == wire) return p;
    }
    return daily;
  }
}

/// 本自然周（[StatWindow.inWeek]：本周一至今日）的学习字数合计。口径与
/// [studyGoalCharsForDay] 相同——只按 dateKey 筛选求和，**域由调用方传的行集决定**
/// （首页 / 统计页都传完整日面，BUG-1993）。
int studyGoalCharsForWeek(Iterable<StatFact> daily, StatWindow window) {
  int total = 0;
  for (final StatFact f in daily) {
    if (window.inWeek(f.dateKey)) total += f.chars;
  }
  return total;
}
