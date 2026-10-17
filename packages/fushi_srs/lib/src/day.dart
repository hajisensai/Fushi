/// 到期日与翻日（铁律 G）。
///
/// - dueDay 是「日历日序号」（1970-01-01 起的天数），不相对任何纪元日。
/// - 时区与翻日时间只用来回答「现在算哪一个日历日」。
/// - 时区存成固定 UTC 偏移（分钟）：Dart 没有内建时区库，夏令时切换当天会差一小时，接受。
library;

const int _dayMs = 24 * 60 * 60 * 1000;

/// 「今天」的计算口径：profile 的 UTC 偏移与翻日时刻。
class SrsDayContext {
  const SrsDayContext({required this.utcOffsetMin, required this.rolloverHour})
    : assert(rolloverHour >= 0 && rolloverHour <= 23);

  /// 默认翻日 4 点（与 Anki 一致，熬夜复习算前一天）。
  static const int defaultRolloverHour = 4;

  final int utcOffsetMin;
  final int rolloverHour;

  /// 某一时刻属于哪个日历日（已扣掉翻日时刻）。
  int dayIndexOf(int ms) {
    final int local = ms + utcOffsetMin * 60000 - rolloverHour * 3600000;
    return (local / _dayMs).floor();
  }

  /// 某日历日的翻日起点（毫秒）。
  int dayStartMs(int dayIndex) =>
      dayIndex * _dayMs + rolloverHour * 3600000 - utcOffsetMin * 60000;

  /// 本机当前偏移（profile 没设时区时用）。
  static int localOffsetMin([DateTime? at]) =>
      (at ?? DateTime.now()).timeZoneOffset.inMinutes;
}

/// 日历日序号 → 日期（UTC 字段即本地日期）。
DateTime srsDayToDate(int dayIndex) =>
    DateTime.fromMillisecondsSinceEpoch(dayIndex * _dayMs, isUtc: true);

/// 日期（年月日）→ 日历日序号。
int srsDateToDay(int year, int month, int day) =>
    DateTime.utc(year, month, day).millisecondsSinceEpoch ~/ _dayMs;
