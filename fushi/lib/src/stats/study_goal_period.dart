import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

/// 学习目标的周期（`StudyGoal.period`）。
///
/// 2026-11 起目标是记录列表（`study_goal_record.dart`），每条记录自带周期；
/// 旧的字数目标「日 / 周二选一」偏好 `reading_goal_period`（反馈 CjIr9RGSCe）
/// 只在迁移时读一次（[StudyGoalPeriod.fromWire]）。
enum StudyGoalPeriod {
  /// 每日：分子 = 当天。
  daily('daily'),

  /// 每周：分子 = 本自然周（起始日见 [StatWindow.weekStartDay]，[StatWindow.weekStartOf]）
  /// 至当天。
  weekly('weekly'),

  /// 每月：分子 = 本日历月 1 日至当天。
  monthly('monthly');

  const StudyGoalPeriod(this.wire);

  /// 持久化值（记录 JSON 的 `period`、旧偏好 `reading_goal_period`）。
  final String wire;

  /// 未知 / 缺省值一律回落 [daily]。
  static StudyGoalPeriod fromWire(String? wire) {
    for (final StudyGoalPeriod p in values) {
      if (p.wire == wire) return p;
    }
    return daily;
  }
}

/// [period] 下包含 [dayKey] 的窗口起点（含）。终点恒为 [dayKey] 本身（今天之后
/// 没有数据）。dateKey 是零填充 `yyyy-MM-dd`，字典序即时间序。
String studyGoalWindowStart(StudyGoalPeriod period, String dayKey) =>
    switch (period) {
      StudyGoalPeriod.daily => dayKey,
      StudyGoalPeriod.weekly => StatWindow.weekStartOf(dayKey),
      StudyGoalPeriod.monthly => '${dayKey.substring(0, 8)}01',
    };

/// [key] 是否落在 [period] 包含 [dayKey] 的窗口里（[studyGoalWindowStart] 至 [dayKey]）。
bool studyGoalWindowContains(
  StudyGoalPeriod period,
  String dayKey,
  String key,
) =>
    key.compareTo(studyGoalWindowStart(period, dayKey)) >= 0 &&
    key.compareTo(dayKey) <= 0;

/// [period] 下包含 [dayKey] 的窗口终点（含）：每日 = 当天；每周 = 本自然周最后一天
/// （起始日见 [StatWindow.weekStartDay]）；每月 = 当月最后一天。周 / 月目标的「今日
/// 份额」按窗口里剩下的生效日摊。
String studyGoalWindowEnd(StudyGoalPeriod period, String dayKey) =>
    switch (period) {
      StudyGoalPeriod.daily => dayKey,
      StudyGoalPeriod.weekly => FushiDatabase.statDateKeyPlusDays(
        StatWindow.weekStartOf(dayKey),
        6,
      ),
      StudyGoalPeriod.monthly => _lastDayOfMonthKey(dayKey),
    };

/// [period] 下包含 [dayKey] 的整个窗口（起点至终点，含今天之后的日子），按时间序。
List<String> studyGoalWindowDays(StudyGoalPeriod period, String dayKey) {
  final String end = studyGoalWindowEnd(period, dayKey);
  final List<String> keys = <String>[];
  for (
    String k = studyGoalWindowStart(period, dayKey);
    k.compareTo(end) <= 0;
    k = FushiDatabase.statDateKeyPlusDays(k, 1)
  ) {
    keys.add(k);
  }
  return keys;
}

String _lastDayOfMonthKey(String dayKey) {
  final DateTime d = FushiDatabase.statDateKeyToDay(dayKey);
  final int last = DateTime(d.year, d.month + 1, 0).day;
  return '${dayKey.substring(0, 8)}${last.toString().padLeft(2, '0')}';
}
