import 'package:fushi_core/fushi_core.dart';

/// 统计中心「范围」的粒度（对齐 Niratan 统计面板的年 / 月 / 周 / 日 + 全部历史），
/// 外加用户任选起止日的「自定义」区间（[StatRangeSelection.customFromKey] ~
/// [StatRangeSelection.customToKey]，起止都含）。
enum StatRangeMode { day, week, month, year, all, custom }

/// 用户在范围条上的选择：粒度 + 锚点日（null = 今日）。这是统计中心四个 tab
/// **共享**的那份状态——每个 tab 用自己的数据最早日另行解析成 [StatRange]
/// （「全部」的起点因域而异），所以共享的只能是选择，不是解析结果。
class StatRangeSelection {
  const StatRangeSelection({
    this.mode = StatRangeMode.month,
    this.anchorKey,
    this.customFromKey,
    this.customToKey,
  });

  /// 自定义区间 `[fromKey, toKey]`（统计日 key，起止都含）。两端顺序不限，
  /// 解析时按字典序摆正并夹到今日。
  const StatRangeSelection.custom({
    required String fromKey,
    required String toKey,
  }) : this(
         mode: StatRangeMode.custom,
         customFromKey: fromKey,
         customToKey: toKey,
       );

  final StatRangeMode mode;

  /// 锚点统计日（`yyyy-MM-dd`）；null = 跟随今日（跨日重聚合后自动前移）。
  /// 自定义区间不看它。
  final String? anchorKey;

  /// 自定义区间起点（含）；只在 [StatRangeMode.custom] 下有意义，null = 今日。
  final String? customFromKey;

  /// 自定义区间终点（含）；只在 [StatRangeMode.custom] 下有意义，null = 今日。
  final String? customToKey;

  StatRangeSelection copyWith({StatRangeMode? mode, String? anchorKey}) =>
      StatRangeSelection(
        mode: mode ?? this.mode,
        anchorKey: anchorKey ?? this.anchorKey,
        customFromKey: customFromKey,
        customToKey: customToKey,
      );

  @override
  bool operator ==(Object other) =>
      other is StatRangeSelection &&
      other.mode == mode &&
      other.anchorKey == anchorKey &&
      other.customFromKey == customFromKey &&
      other.customToKey == customToKey;

  @override
  int get hashCode => Object.hash(mode, anchorKey, customFromKey, customToKey);
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
/// - 全部：`[earliestKey, 今日]`（该域最早有数据的一天；无数据时退化成今日）；
/// - 自定义：用户选的起止统计日（都含），整体夹到今日，起止颠倒时摆正。
///
/// 日界（含跨午夜）不在这里判：每条事实的 dateKey 在写入时已按
/// [FushiDatabase.statDayResetHour] 定好（凌晨 2 点、重置 = 4 时的段记在前一天），
/// 区间只按 dateKey 的字典序取舍，与日 / 周 / 月同一口径。
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
      case StatRangeMode.custom:
        String a = selection.customFromKey ?? todayKey;
        String b = selection.customToKey ?? todayKey;
        if (a.compareTo(b) > 0) (a, b) = (b, a);
        if (a.compareTo(todayKey) > 0) a = todayKey;
        from = a;
        to = b;
        // 锚点 = 区间终点：从自定义切回日 / 周 / 月时落在所选区间的末尾那段。
        anchor = b.compareTo(todayKey) > 0 ? todayKey : b;
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

  /// 区间内的自然日数（含首尾）。按日历日差计算：两个本地午夜相减在 DST 切换
  /// 段里差 1 小时（春季 6 天 23 小时 → `inDays` 少算一天），所以换到 UTC 日历
  /// 上再减，结果只取决于年月日。
  int get dayCount => statDateKeyDaysBetween(fromKey, toKey) + 1;

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
  ///
  /// 自定义区间按自身天数整段平移（选了 10 天就前后各翻 10 天）；往后翻越过
  /// 今日时整段贴住今日、天数不变。
  StatRangeSelection shifted(int step) {
    if (mode == StatRangeMode.custom) {
      final int span = dayCount;
      String from = FushiDatabase.statDateKeyPlusDays(fromKey, span * step);
      String to = FushiDatabase.statDateKeyPlusDays(toKey, span * step);
      if (to.compareTo(todayKey) > 0) {
        to = todayKey;
        from = FushiDatabase.statDateKeyPlusDays(todayKey, -(span - 1));
      }
      return StatRangeSelection.custom(fromKey: from, toKey: to);
    }
    final DateTime day = FushiDatabase.statDateKeyToDay(anchorKey);
    final DateTime target = switch (mode) {
      StatRangeMode.day => DateTime(day.year, day.month, day.day + step),
      // 按日历日加 7 天，不能给本地午夜加固定 7×24 小时：DST 切换周不是
      // 168 小时，秋季回拨周会落回本周六 23:00（翻不动）、春季拨快周往回会落到
      // 更前一周的周日 23:00（多跳一周）。
      StatRangeMode.week => FushiDatabase.statDateKeyToDay(
        FushiDatabase.statDateKeyPlusDays(fromKey, 7 * step),
      ),
      StatRangeMode.month => DateTime(day.year, day.month + step),
      StatRangeMode.year => DateTime(day.year + step),
      StatRangeMode.all || StatRangeMode.custom => day,
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

/// 纯函数：[fromKey] 到 [toKey] 相隔的日历日数（`toKey` 更早时为负）。只看年月日，
/// 在 UTC 日历上相减，与宿主时区 / DST 无关。
int statDateKeyDaysBetween(String fromKey, String toKey) {
  DateTime utcDay(String key) {
    final DateTime local = FushiDatabase.statDateKeyToDay(key);
    return DateTime.utc(local.year, local.month, local.day);
  }

  return utcDay(toKey).difference(utcDay(fromKey)).inDays;
}

/// 纯函数：一批 dateKey 里最早的一个（「全部」的起点）；空集合返回 null。
String? earliestStatDateKey(Iterable<String> dateKeys) {
  String? earliest;
  for (final String k in dateKeys) {
    if (k.isEmpty) continue;
    if (earliest == null || k.compareTo(earliest) < 0) earliest = k;
  }
  return earliest;
}
