/// 定时备份的到期判定（纯函数，不碰文件、不读设置）：app 的定时还原点
/// （`fushi/lib/src/sync/auto_backup/auto_backup_schedule.dart`）与服务端的自动整机备份
/// （`packages/fushi_server/lib/src/backup/server_backup_service.dart`）共用这一份。
///
/// - **偏好时刻 T、间隔 N 天**：最近一个已经过去的 T 时刻记作 S（今天的 T 还没到就是昨天的）。
///   上次「满足」（成功或「没变化、跳过」）早于 `S - (N-1) 天` 就到期。错过了 T（app 关着 /
///   服务端停着），下次检查立刻补跑（catch-up）；补跑之后下一次重新对齐到 T。
/// - **没有偏好时刻**：按本地日历日算，等同 T = 0:00。每日 = 当天第一次检查就跑，不要求距上次
///   满 24 小时（否则每天检查时间稍早一点就会隔天才备份一次）。
/// - 从没满足过：立刻到期。
/// - 时钟被往回调过、上次满足的时刻在「现在」之后：到期一次（跑完就落回正常时刻）。
/// - 上次运行写到一半进程就没了（[lastInterrupted]）：这一时段不再重跑，等下一个时段过去再试——
///   免得每次启动都在同一处被杀掉。
/// - 天数按本地日历算（`DateTime(y, m, d - n)`），跨夏令时不漂一小时。
library;

/// 最近一个已经过去（`<= now`）的偏好时刻（本地时间）。[minuteOfDay] = 当天第几分钟（0–1439）。
DateTime latestBackupSlot(DateTime now, int minuteOfDay) {
  final DateTime local = now.toLocal();
  final int h = minuteOfDay ~/ 60;
  final int m = minuteOfDay % 60;
  final DateTime today = DateTime(local.year, local.month, local.day, h, m);
  if (!today.isAfter(local)) return today;
  return DateTime(local.year, local.month, local.day - 1, h, m);
}

/// 间隔 [intervalDays] 天（≤ 0 = 关）、偏好时刻 [preferredMinuteOfDay]（null = 本地零点）下现在该不该跑。
/// [lastSatisfied] = 上次成功或「没变化、跳过」的时刻（null = 从没有）；[lastInterrupted] = 上次被打断的那次
/// 运行的开始时刻（null = 没有）。
bool isBackupSlotDue({
  required int intervalDays,
  required DateTime now,
  required DateTime? lastSatisfied,
  int? preferredMinuteOfDay,
  DateTime? lastInterrupted,
}) {
  if (intervalDays <= 0) return false;
  final DateTime slot = latestBackupSlot(now, preferredMinuteOfDay ?? 0);
  if (lastInterrupted != null &&
      !lastInterrupted.isAfter(now) &&
      !lastInterrupted.isBefore(slot)) {
    return false;
  }
  if (lastSatisfied == null) return true;
  if (lastSatisfied.isAfter(now)) return true;
  final DateTime threshold = DateTime(
    slot.year,
    slot.month,
    slot.day - (intervalDays - 1),
    slot.hour,
    slot.minute,
  );
  return lastSatisfied.toLocal().isBefore(threshold);
}
