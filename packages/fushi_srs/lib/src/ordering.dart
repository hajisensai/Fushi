/// 排序键 sortKey 与发布时服务器时间 S（铁律 F）。
///
/// - 事件创建即不可变；S 是带外元数据（批次信封 + 快照映射），不进事件内容。
/// - S(e) = 所有已见到的、包含 e 的批次的 S 的最小值，与收到顺序无关。
/// - 钳位只影响排序：HLC 物理部分超过 S(e) + 10 分钟时换成 S(e) + 10 分钟，计数器不变。
///
/// 第六轮审查第 4 条（把保证写准确）：钳位保证的是「事件在排序里领先它被发布的时刻最多 10 分钟」，
/// **不是**「领先真实发生时刻最多 10 分钟」。一台时钟快 1 天的设备离线 5 天才发布，S 比它的错时间还晚，
/// 钳位不起作用：它的事件会排在其它设备那 1 天内的真实事件前面。真实的领先量上限是
/// min(时钟偏差, 发布延迟 + 10 分钟)。缓解：
/// - 时间来源是 anchored（本次开机已与服务器校时）的事件时间本身可信，不受这条影响；
/// - wall 来源且与写入者上一批次 S 矛盾的事件判为 timeUncertain（见 [srsTimeUncertain]），不进优化器；
/// - 同步状态里提示「系统时间不准」。
library;

import 'hlc.dart';

/// 事件在排序里的身份：钳位后的物理时间、计数器、writerId、eventId（兜底，同毫秒的导入事件也有确定先后）。
class SrsSortKey implements Comparable<SrsSortKey> {
  const SrsSortKey(this.physical, this.counter, this.writerId, this.eventId);

  final int physical;
  final int counter;
  final String writerId;
  final String eventId;

  @override
  int compareTo(SrsSortKey other) {
    int c = physical.compareTo(other.physical);
    if (c != 0) return c;
    c = counter.compareTo(other.counter);
    if (c != 0) return c;
    c = writerId.compareTo(other.writerId);
    if (c != 0) return c;
    return eventId.compareTo(other.eventId);
  }

  bool operator >(SrsSortKey other) => compareTo(other) > 0;
  bool operator <(SrsSortKey other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is SrsSortKey && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(physical, counter, writerId, eventId);

  @override
  String toString() => 'SortKey($physical:$counter:$writerId:$eventId)';
}

/// 由 HLC 与 S(e) 算排序键。[serverTimeMs] 为 null（只经备份 / 快照拿到、还没见到批次）时按原始 HLC。
SrsSortKey srsSortKey(Hlc hlc, String eventId, int? serverTimeMs) {
  int physical = hlc.physical;
  if (serverTimeMs != null) {
    final int bound = serverTimeMs + srsClockToleranceMs;
    if (physical > bound) physical = bound;
  }
  return SrsSortKey(physical, hlc.counter, hlc.writerId, eventId);
}

/// 合并两个 S 观察值：取最小（null = 未知）。
int? srsMergeServerTime(int? a, int? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a < b ? a : b;
}

/// timeUncertain 是派生值，不存进事件：时间来源是墙钟，并且
/// 物理时间超过 S(e) + 10 分钟，或早于该写入者上一批次的 S —— 可证明时间有错。这类事件不进优化器训练集。
bool srsTimeUncertain({
  required SrsTimeSource timeSource,
  required int physicalMs,
  required int? serverTimeMs,
  required int? previousBatchServerTimeMs,
}) {
  if (timeSource != SrsTimeSource.wall) return false;
  if (serverTimeMs != null && physicalMs > serverTimeMs + srsClockToleranceMs) {
    return true;
  }
  if (previousBatchServerTimeMs != null &&
      physicalMs < previousBatchServerTimeMs) {
    return true;
  }
  return false;
}
