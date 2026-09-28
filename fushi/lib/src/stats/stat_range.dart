import 'package:fushi_core/fushi_core.dart';

/// 统计中心「范围」的粒度（对齐 Niratan 统计面板的年 / 月 / 周 / 日 + 全部历史）。
enum StatRangeMode { day, week, month, year, all }

/// 用户在范围条上的选择：粒度 + 锚点日（null = 今日）。这是统计中心四个 tab
/// **共享**的那份状态——每个 tab 用自己的数据最早日另行解析成 [StatRange]
/// （「全部」的起点因域而异），所以共享的只能是选择，不是解析结果。
class StatRangeSelection {
  const StatRangeSelection({this.mode = StatRangeMode.month, this.anchorKey});

  final StatRangeMode mode;

  /// 锚点统计日（`yyyy-MM-dd`）；null = 跟随今日（跨日重聚合后自动前移）。
  final String? anchorKey;

  StatRangeSelection copyWith({StatRangeMode? mode, String? anchorKey}) =>
      StatRangeSelection(
        mode: mode ?? this.mode,
        anchorKey: anchorKey ?? this.anchorKey,
      );

  @override
  bool operator ==(Object other) =>
      other is StatRangeSelection &&
      other.mode == mode &&
      other.anchorKey == anchorKey;

  @override
  int get hashCode => Object.hash(mode, anchorKey);
}

/// 已解析的统计范围：闭区间 `[fromKey, toKey]`（零填充 dateKey，字典序即时间序）。
///
/// 与 [StatWindow] 同一套 key 算术（今日 = [FushiDatabase.statDateKeyOf]，窗口
/// 边界走 [FushiDatabase.statDateKeyPlusDays]），不合成本地午夜。区间**不越过
/// 今日**：本周 / 本月 / 今年只算到今天为止，未来日不进聚合也不进图表。
///
/// - 日：锚点那一天；
/// - 周：锚点所在自然周（周一起，与 Niratan / ISO 周同口径）；
/// - 月：锚点所在自然月；
/// - 年：锚点所在自然年；
/// - 全部：`[earliestKey, 今日]`（该域最早有数据的一天；无数据时退化成今日）。
class StatRange {
  StatRange._({
    required this.mode,
    required this.anchorKey,
    required this.fromKey,
    required this.toKey,
    required this.todayKey,
    required this.earliestKey,
  });

  /// 把 [selection] 解析成区间。[todayKey] 由调用方的 [StatWindow] 给出（同一轮
  /// 加载只有一个「今日」，BUG-2219）；[earliestKey] 是该域最早有数据的统计日，
  /// 只影响「全部」的起点与「上一段」按钮能退到哪里。
  factory StatRange.resolve(
    StatRangeSelection selection, {
    required String todayKey,
    String? earliestKey,
  }) {
    String anchor = selection.anchorKey ?? todayKey;
    if (anchor.compareTo(todayKey) > 0) anchor = todayKey;
    final String earliest =
        earliestKey == null || earliestKey.compareTo(todayKey) > 0
        ? todayKey
        : earliestKey;
    final DateTime day = FushiDatabase.statDateKeyToDay(anchor);
    late String from;
    late String to;
    switch (selection.mode) {
      case StatRangeMode.day:
        from = anchor;
        to = anchor;
      case StatRangeMode.week:
        from = FushiDatabase.statDateKeyPlusDays(
          anchor,
          -(day.weekday - DateTime.monday),
        );
        to = FushiDatabase.statDateKeyPlusDays(from, 6);
      case StatRangeMode.month:
        from = FushiDatabase.statCalendarDayKeyOf(
          DateTime(day.year, day.month),
        );
        to = FushiDatabase.statCalendarDayKeyOf(
          DateTime(day.year, day.month + 1, 0),
        );
      case StatRangeMode.year:
        from = FushiDatabase.statCalendarDayKeyOf(DateTime(day.year));
        to = FushiDatabase.statCalendarDayKeyOf(DateTime(day.year, 12, 31));
      case StatRangeMode.all:
        from = earliest;
        to = todayKey;
    }
    if (to.compareTo(todayKey) > 0) to = todayKey;
    return StatRange._(
      mode: selection.mode,
      anchorKey: anchor,
      fromKey: from,
      toKey: to,
      todayKey: todayKey,
      earliestKey: earliest,
    );
  }

  final StatRangeMode mode;
  final String anchorKey;

  /// 区间起点（含）。
  final String fromKey;

  /// 区间终点（含），恒 ≤ [todayKey]。
  final String toKey;
  final String todayKey;
  final String earliestKey;

  bool contains(String dateKey) =>
      dateKey.compareTo(fromKey) >= 0 && dateKey.compareTo(toKey) <= 0;

  /// 区间内的自然日数（含首尾）。
  int get dayCount =>
      FushiDatabase.statDateKeyToDay(
        toKey,
      ).difference(FushiDatabase.statDateKeyToDay(fromKey)).inDays +
      1;

  /// 区间内全部 dateKey，升序（图表补齐空日期用）。
  List<String> get dayKeys => <String>[
    for (int i = 0; i < dayCount; i++)
      FushiDatabase.statDateKeyPlusDays(fromKey, i),
  ];

  /// 能否翻到下一段：本段没到今天。「全部」恒不能翻。
  bool get canGoNext => mode != StatRangeMode.all && toKey != todayKey;

  /// 能否翻到上一段：本段起点还晚于该域最早有数据的日子。
  bool get canGoPrevious =>
      mode != StatRangeMode.all && fromKey.compareTo(earliestKey) > 0;

  /// 前后翻一段（[step] = -1 上一段 / +1 下一段）后的选择。锚点落到目标段的
  /// 第一天（日 = 那一天），再由 [resolve] 夹到今日。
  StatRangeSelection shifted(int step) {
    final DateTime day = FushiDatabase.statDateKeyToDay(anchorKey);
    final DateTime target = switch (mode) {
      StatRangeMode.day => DateTime(day.year, day.month, day.day + step),
      StatRangeMode.week => FushiDatabase.statDateKeyToDay(
        fromKey,
      ).add(Duration(days: 7 * step)),
      StatRangeMode.month => DateTime(day.year, day.month + step),
      StatRangeMode.year => DateTime(day.year + step),
      StatRangeMode.all => day,
    };
    final String key = FushiDatabase.statCalendarDayKeyOf(
      DateTime(target.year, target.month, target.day),
    );
    // 翻回含今日的那一段时回到「跟随今日」，跨日后仍停在当前段。
    final StatRange next = StatRange.resolve(
      StatRangeSelection(mode: mode, anchorKey: key),
      todayKey: todayKey,
      earliestKey: earliestKey,
    );
    return StatRangeSelection(
      mode: mode,
      anchorKey: next.toKey == todayKey ? null : key,
    );
  }

  /// 图表的聚合粒度：一段 ≤ 62 天按日画柱；≤ 一年零一月按周；更长（全部历史）按月。
  StatRangeChartGrain get chartGrain {
    final int days = dayCount;
    if (days <= 62) return StatRangeChartGrain.day;
    if (days <= 400) return StatRangeChartGrain.week;
    return StatRangeChartGrain.month;
  }
}

/// 范围图表的柱粒度。
enum StatRangeChartGrain { day, week, month }

/// 纯函数：一批 dateKey 里最早的一个（「全部」的起点）；空集合返回 null。
String? earliestStatDateKey(Iterable<String> dateKeys) {
  String? earliest;
  for (final String k in dateKeys) {
    if (k.isEmpty) continue;
    if (earliest == null || k.compareTo(earliest) < 0) earliest = k;
  }
  return earliest;
}
