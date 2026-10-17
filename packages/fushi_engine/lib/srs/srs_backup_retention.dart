/// 复习自动备份的保留策略：照搬 Anki（rslib `collection/backup.rs` 的 `BackupFilter`）。
///
/// Anki 的默认值（桌面版「偏好设置 → 备份」，AnkiMobile 同一套 rslib）：
/// 两次自动备份至少间隔 30 分钟；**今天和昨天的备份全部保留**；再往前按天保留 12 份、按周 10 份、按月 9 份。
///
/// 规则（逐行对应 rslib）：备份按时间从新到旧排；
/// 1. 日期 ≥ 昨天 → 保留（不消耗任何名额），并把「最近保留的日 / 周 / 月」记成它的；
/// 2. 否则还有「每日」名额 → 日期早于最近保留的那一天就保留（消耗一份每日名额），同一天里更早的删掉；
/// 3. 每日名额用完后同理按周（周 = (公元日序号 - 1) / 7，周一开始），再按月（年 × 12 + 月）；
/// 4. 名额全部用完 → 删。
/// 日 / 周 / 月都按设备本地时间算。
library;

import 'dart:convert';

/// 保留份数与自动备份间隔（设置里可调；默认值 = Anki 默认值）。
class SrsBackupLimits {
  const SrsBackupLimits({
    this.daily = defaultDaily,
    this.weekly = defaultWeekly,
    this.monthly = defaultMonthly,
    this.intervalMinutes = defaultIntervalMinutes,
  });

  static const int defaultDaily = 12;
  static const int defaultWeekly = 10;
  static const int defaultMonthly = 9;
  static const int defaultIntervalMinutes = 30;

  final int daily;
  final int weekly;
  final int monthly;

  /// 两次自动备份的最短间隔（分钟）。
  final int intervalMinutes;

  @override
  bool operator ==(Object other) =>
      other is SrsBackupLimits &&
      other.daily == daily &&
      other.weekly == weekly &&
      other.monthly == monthly &&
      other.intervalMinutes == intervalMinutes;

  @override
  int get hashCode => Object.hash(daily, weekly, monthly, intervalMinutes);
}

/// 公元日序号（0001-01-01 = 1，与 chrono 的 `num_days_from_ce` 相同），只用本地日期的年月日。
int srsDaysFromCe(DateTime local) =>
    DateTime.utc(local.year, local.month, local.day).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay +
    719163;

/// 设置里每项允许的范围（越界的存值读回时夹到范围内）。
const int kSrsBackupKeepMax = 99;
const int kSrsBackupIntervalMinMinutes = 5;
const int kSrsBackupIntervalMaxMinutes = 24 * 60;

/// 偏好里存的 JSON（缺字段 / 坏值一律回落默认值）。
String srsBackupLimitsToJson(SrsBackupLimits l) => jsonEncode(<String, int>{
  'daily': l.daily,
  'weekly': l.weekly,
  'monthly': l.monthly,
  'intervalMinutes': l.intervalMinutes,
});

SrsBackupLimits srsBackupLimitsFromJson(Object? raw) {
  Map<Object?, Object?> m = const <Object?, Object?>{};
  try {
    final Object? j = raw is String && raw.isNotEmpty ? jsonDecode(raw) : raw;
    if (j is Map) m = j;
  } on FormatException {
    // 坏值：全部取默认。
  }
  int read(String key, int fallback, int min, int max) {
    final Object? v = m[key];
    return v is int ? v.clamp(min, max) : fallback;
  }

  return SrsBackupLimits(
    daily: read('daily', SrsBackupLimits.defaultDaily, 0, kSrsBackupKeepMax),
    weekly: read('weekly', SrsBackupLimits.defaultWeekly, 0, kSrsBackupKeepMax),
    monthly: read(
      'monthly',
      SrsBackupLimits.defaultMonthly,
      0,
      kSrsBackupKeepMax,
    ),
    intervalMinutes: read(
      'intervalMinutes',
      SrsBackupLimits.defaultIntervalMinutes,
      kSrsBackupIntervalMinMinutes,
      kSrsBackupIntervalMaxMinutes,
    ),
  );
}

enum _Stage { daily, weekly, monthly }

/// 按 Anki 规则选出该删的备份。[localTimeOf] 返回备份的本地时间，[now] 是本地当前时间。
/// 返回值保持输入里的对象身份，顺序为从新到旧。
List<T> srsObsoleteBackups<T>(
  Iterable<T> backups, {
  required DateTime Function(T backup) localTimeOf,
  required DateTime now,
  SrsBackupLimits limits = const SrsBackupLimits(),
}) {
  final int yesterday = srsDaysFromCe(now) - 1;
  int lastKeptDay = 1 << 62;
  int lastKeptWeek = 1 << 62;
  int lastKeptMonth = 1 << 62;
  final Map<_Stage, int> remaining = <_Stage, int>{
    _Stage.daily: limits.daily < 0 ? 0 : limits.daily,
    _Stage.weekly: limits.weekly < 0 ? 0 : limits.weekly,
    _Stage.monthly: limits.monthly < 0 ? 0 : limits.monthly,
  };
  final List<T> sorted = backups.toList()
    ..sort((T a, T b) => localTimeOf(b).compareTo(localTimeOf(a)));
  final List<T> obsolete = <T>[];

  void markFresh(_Stage? stage, int day, int week, int month) {
    if (stage != null) remaining[stage] = remaining[stage]! - 1;
    lastKeptDay = day;
    lastKeptWeek = week;
    lastKeptMonth = month;
  }

  for (final T b in sorted) {
    final DateTime t = localTimeOf(b);
    final int day = srsDaysFromCe(t);
    // 周从周一开始：(公元日序号 - 1) / 7（rslib `Backup::week`）。
    final int week = (day - 1) ~/ 7;
    final int month = t.year * 12 + t.month;
    if (day >= yesterday) {
      markFresh(null, day, week, month);
      continue;
    }
    _Stage? stage;
    for (final _Stage s in _Stage.values) {
      if (remaining[s]! > 0) {
        stage = s;
        break;
      }
    }
    if (stage == null) {
      obsolete.add(b);
      continue;
    }
    final bool keep = switch (stage) {
      _Stage.daily => day < lastKeptDay,
      _Stage.weekly => week < lastKeptWeek,
      _Stage.monthly => month < lastKeptMonth,
    };
    if (keep) {
      markFresh(stage, day, week, month);
    } else {
      obsolete.add(b);
    }
  }
  return obsolete;
}

/// 「离开复习页」触发也要隔开的最短间隔（分钟）：频繁进出复习页不堆一串全量备份。
const int kSrsBackupLeaveMinIntervalMinutes = 5;

/// 自动备份该不该跑：库有变动（指纹与最近一份不同），且距最近一份已满间隔——
/// 定时触发按设置的间隔（默认 30 分钟），离开复习页（[leavingReview]）按
/// [kSrsBackupLeaveMinIntervalMinutes]（与设置取小）。
bool srsShouldAutoBackup({
  required String currentFingerprint,
  required String? latestFingerprint,
  required int? latestCreatedAtMs,
  required int nowMs,
  required SrsBackupLimits limits,
  bool leavingReview = false,
}) {
  if (latestFingerprint == currentFingerprint) return false;
  if (latestCreatedAtMs == null) return true;
  final int minutes = leavingReview
      ? (limits.intervalMinutes < kSrsBackupLeaveMinIntervalMinutes
            ? limits.intervalMinutes
            : kSrsBackupLeaveMinIntervalMinutes)
      : limits.intervalMinutes;
  return nowMs - latestCreatedAtMs >= minutes * 60 * 1000;
}
