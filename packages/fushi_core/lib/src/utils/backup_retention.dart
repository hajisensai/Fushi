/// 备份保留策略（纯函数层，不碰文件）：给一串按新 → 旧排好的备份，算出哪些可以删。
///
/// 一条备份只要被下面任何一条规则留下就不删：
/// 1. 排在最新 [BackupRetentionPolicy.keepMinimum] 份之内；
/// 2. 时刻读不出（年龄不可判定 = 永不删）；
/// 3. 年龄不超过 [BackupRetentionPolicy.keepAllWithin]（`<=`，正好等于也留）；
/// 4. 分层：最近 [BackupRetentionPolicy.dailyDays] 天每天留最新一份、最近
///    [BackupRetentionPolicy.weeklyWeeks] 周每周一份、最近
///    [BackupRetentionPolicy.monthlyMonths] 个月每月一份。桶按年龄切（第 n 天 = 年龄整天数 n，
///    一周 = 7 天，一个月 = 30 天），与时区、夏令时无关。
///
/// 之后若设了 [BackupRetentionPolicy.maxTotalBytes]，在留下的那些里从最旧的开始删，直到总大小
/// 不超过上限；[protect] 认出的（例如刚写好的那一份）和最新 [keepMinimum] 份不参与。
///
/// Lapis 模板备份（`fushi/lib/src/anki/lapis_backup_retention.dart`）与定时还原点
/// （`restore_points.dart`）共用这一份实现，只是参数不同。
library;

/// 一套保留参数。
class BackupRetentionPolicy {
  const BackupRetentionPolicy({
    this.keepMinimum = 0,
    this.keepAllWithin = Duration.zero,
    this.dailyDays = 0,
    this.weeklyWeeks = 0,
    this.monthlyMonths = 0,
    this.maxTotalBytes,
  });

  /// 无论多旧都留的最新份数。
  final int keepMinimum;

  /// 这个年龄以内的全部留下。
  final Duration keepAllWithin;

  /// 最近多少天每天留最新一份（0 = 不按天分层）。
  final int dailyDays;

  /// 最近多少周每周留最新一份。
  final int weeklyWeeks;

  /// 最近多少个月（30 天一桶）每月留最新一份。
  final int monthlyMonths;

  /// 总大小上限（字节）；null = 不限。
  final int? maxTotalBytes;
}

/// 规划要删除的条目，顺序与输入一致。[newestFirst] 必须新 → 旧。
///
/// [timestampOf] 返回 null = 时刻不可判定，一律保留；[sizeOf] 只在设了
/// [BackupRetentionPolicy.maxTotalBytes] 时用；[protect] 返回 true 的条目永不删。
List<T> planBackupRetention<T>(
  List<T> newestFirst, {
  required DateTime? Function(T item) timestampOf,
  required DateTime now,
  required BackupRetentionPolicy policy,
  int Function(T item)? sizeOf,
  bool Function(T item)? protect,
}) {
  final int n = newestFirst.length;
  final List<bool> keep = List<bool>.filled(n, false);
  final Set<int> dayBuckets = <int>{};
  final Set<int> weekBuckets = <int>{};
  final Set<int> monthBuckets = <int>{};
  for (int i = 0; i < n; i++) {
    final T item = newestFirst[i];
    if (i < policy.keepMinimum || (protect?.call(item) ?? false)) {
      keep[i] = true;
    }
    final DateTime? at = timestampOf(item);
    if (at == null) {
      keep[i] = true;
      continue;
    }
    final Duration age = now.difference(at);
    if (age <= policy.keepAllWithin) keep[i] = true;
    final int days = age.inDays;
    // 新 → 旧遍历：每个桶第一次出现的就是那个桶里最新的一份。不管这一份是因为哪条规则
    // 留下的，它都占住自己的桶（同一天里已经有更新的一份留着，更旧的就不必再留）。
    if (days < policy.dailyDays && dayBuckets.add(days)) keep[i] = true;
    if (days < policy.weeklyWeeks * 7 && weekBuckets.add(days ~/ 7)) {
      keep[i] = true;
    }
    if (days < policy.monthlyMonths * 30 && monthBuckets.add(days ~/ 30)) {
      keep[i] = true;
    }
  }
  final int? cap = policy.maxTotalBytes;
  if (cap != null && sizeOf != null) {
    int total = 0;
    for (int i = 0; i < n; i++) {
      if (keep[i]) total += sizeOf(newestFirst[i]);
    }
    for (int i = n - 1; i >= 0 && total > cap; i--) {
      if (!keep[i]) continue;
      final T item = newestFirst[i];
      if (i < policy.keepMinimum || (protect?.call(item) ?? false)) continue;
      keep[i] = false;
      total -= sizeOf(item);
    }
  }
  return <T>[
    for (int i = 0; i < n; i++)
      if (!keep[i]) newestFirst[i],
  ];
}
