/// 自动备份的到期判定（纯函数，测试直接调）。
///
/// app 内调度、不接系统定时器：启动后（首页首帧之后的空闲时机）、回到前台、桌面端运行中每
/// [kAutoBackupDesktopCheckInterval] 各查一次，到期就跑一次。
///
/// - **有偏好时刻 T、间隔 N 天**：最近一个已经过去的 T 时刻记作 S（今天的 T 还没到就是昨天的）。
///   上次「满足」（成功或「没变化、跳过」）早于 `S - (N-1) 天` 就到期。app 关着错过了 T，下次
///   启动 / 回前台立刻补跑（catch-up）；补跑之后下一次重新对齐到 T。
/// - **没有偏好时刻**：按本地日历日算，等同偏好时刻 = 0:00。每日 = 当天第一次启动 / 回前台
///   就跑，不要求距上次满 24 小时（否则每天打开时间稍早一点就会隔天才备份一次）。
/// - 从没满足过：立刻到期。
library;

import 'package:fushi/src/sync/auto_backup/auto_backup_settings.dart';

/// 桌面端运行中的到期检查周期。
const Duration kAutoBackupDesktopCheckInterval = Duration(minutes: 15);

/// 最近一个已经过去（`<= now`）的偏好时刻（本地时间）。
DateTime latestAutoBackupSlot(DateTime now, int minuteOfDay) {
  final DateTime local = now.toLocal();
  final int h = minuteOfDay ~/ 60;
  final int m = minuteOfDay % 60;
  final DateTime today = DateTime(local.year, local.month, local.day, h, m);
  if (!today.isAfter(local)) return today;
  return DateTime(local.year, local.month, local.day - 1, h, m);
}

/// [settings] 下现在该不该跑。[lastSatisfied] = 上次成功或「没变化、跳过」的时刻（null = 从没有）。
bool isAutoBackupDue({
  required AutoBackupSettings settings,
  required DateTime now,
  required DateTime? lastSatisfied,
}) {
  if (!settings.enabled) return false;
  if (lastSatisfied == null) return true;
  final int n = settings.interval.days;
  final int minute = settings.preferredMinuteOfDay ?? 0;
  final DateTime slot = latestAutoBackupSlot(now, minute);
  final DateTime threshold = DateTime(
    slot.year,
    slot.month,
    slot.day - (n - 1),
    slot.hour,
    slot.minute,
  );
  return lastSatisfied.toLocal().isBefore(threshold);
}

/// 「上次成功太久了」的告警：上次满足早于两个间隔之前。关着时不告警。
bool isAutoBackupOverdue({
  required AutoBackupSettings settings,
  required DateTime now,
  required DateTime? lastSatisfied,
}) {
  if (!settings.enabled || lastSatisfied == null) return false;
  return now.difference(lastSatisfied) >
      Duration(days: 2 * settings.interval.days);
}
