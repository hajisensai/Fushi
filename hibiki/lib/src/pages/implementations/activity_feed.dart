import 'package:fushi/src/utils/misc/hibiki_time_format.dart';
import 'package:fushi_core/fushi_core.dart';

/// 首页 Activity 时间轴的纯数据层：把 [ActivityEventRow] 事件流聚合成「按日期分组、
/// 每组内按 (标题, 事件类型) 合并」的时间线条目，并把「相对时间」算成结构化描述
/// 供 widget 层用 i18n 格式化（保持纯函数可单测、跨 17 语言一致）。
///
/// 事件流两侧写入粒度不同：视频每次观看 session 落 1 行；阅读每次 flush（换章/导航）
/// 落 1 行，一坐可能多行。故 session 数不能直接取行数——用 [kActivitySessionGap]
/// 时间间隔归并（>gap 才算新 session），两侧统一。

/// 相对时间单位。i18n 在 widget 层按此 + [ActivityRelativeTime.value] 选串。
enum ActivityRelativeUnit { justNow, minutesAgo, hoursAgo, daysAgo }

/// 相对时间的结构化结果（如「3 小时前」= hoursAgo, 3）。
class ActivityRelativeTime {
  const ActivityRelativeTime(this.unit, this.value);

  final ActivityRelativeUnit unit;
  final int value;

  @override
  bool operator ==(Object other) =>
      other is ActivityRelativeTime &&
      other.unit == unit &&
      other.value == value;

  @override
  int get hashCode => Object.hash(unit, value);

  @override
  String toString() => 'ActivityRelativeTime($unit, $value)';
}

/// 相邻两次活动间隔超过此值才算两个 session（否则归并成一次连续活动）。
const Duration kActivitySessionGap = Duration(minutes: 30);

/// 纯函数：[timestampMs]（epoch 毫秒）相对 [now] 的相对时间描述。
/// <1 分钟 = justNow；<60 分钟 = minutesAgo；<24 小时 = hoursAgo；否则 daysAgo。
ActivityRelativeTime activityRelativeTime(int timestampMs, DateTime now) {
  final int deltaMs = now.millisecondsSinceEpoch - timestampMs;
  if (deltaMs < const Duration(minutes: 1).inMilliseconds) {
    return const ActivityRelativeTime(ActivityRelativeUnit.justNow, 0);
  }
  if (deltaMs < const Duration(hours: 1).inMilliseconds) {
    return ActivityRelativeTime(
        ActivityRelativeUnit.minutesAgo, deltaMs ~/ 60000);
  }
  if (deltaMs < const Duration(days: 1).inMilliseconds) {
    return ActivityRelativeTime(
        ActivityRelativeUnit.hoursAgo, deltaMs ~/ 3600000);
  }
  return ActivityRelativeTime(
      ActivityRelativeUnit.daysAgo, deltaMs ~/ 86400000);
}

/// 一条聚合后的时间线条目：同一天 + 同标题 + 同事件类型的多个事件合并成一条。
class ActivityEntry {
  const ActivityEntry({
    required this.title,
    required this.eventType,
    required this.mediaType,
    required this.mediaKey,
    required this.dateKey,
    required this.latestTimestampMs,
    required this.totalDurationMs,
    required this.totalChars,
    required this.sessionCount,
    this.sourceDevice,
  });

  final String title;
  final String eventType;
  final String mediaType;

  /// 点击打开媒体用的稳定身份（书=bookKey，视频=bookUid），可能为 null。
  final String? mediaKey;
  final String dateKey;

  /// 该条目内最近一次活动的精确时刻（排序 + 相对时间用）。
  final int latestTimestampMs;

  /// 合并后的总时长/总字数（added 事件恒 0）。
  final int totalDurationMs;
  final int totalChars;

  /// 归并后的 session 次数（见 [kActivitySessionGap]）。
  final int sessionCount;

  /// 事件来源设备显示名（互联对端事件带 host 设备名；null = 本机）。同一
  /// (日期,类型,标题) 的双端 session **不合并**——provenance 优先，分设备各一条。
  final String? sourceDevice;
}

/// 一个日期分组（dateKey + 该日的条目，按最近时刻倒序）。
class ActivityDateGroup {
  const ActivityDateGroup({required this.dateKey, required this.entries});

  final String dateKey;
  final List<ActivityEntry> entries;
}

/// 纯函数：把事件流聚合成「按日期倒序分组、每组内条目按最近时刻倒序」的时间线。
///
/// 分组键 = (设备, dateKey, eventType, mediaType, mediaKey??title)。同键事件合并：
/// 时长/字数求和；session 数按 [sessionGap] 归并；latestTimestampMs 取最大。added
/// 事件无时长，session 数按同样归并（通常 1）。输入不要求有序。
///
/// BUG-1350：合并身份必须优先 mediaKey（书=bookKey / 视频=bookUid / 游戏=id）——
/// title 只是落库时的显示快照，拆集后的视频行标题是裸集号（`S01E01`），同日看两部
/// 不同作品的第一集会被 title 键错误合并成一条、mediaKey 取最晚事件，先看的那部在
/// 时间轴上整条消失。老行 / 远端旧 host 行无 mediaKey 时回退 title（真实数据里同组
/// 不混 null 与非 null——同一媒体同一天的行来自同一写入端）。
List<ActivityDateGroup> aggregateActivityEvents(
  List<ActivityEventRow> events, {
  Duration sessionGap = kActivitySessionGap,
  String? Function(ActivityEventRow event)? sourceDeviceOf,
}) {
  // 分组键 → 该键的全部事件。
  final Map<String, List<ActivityEventRow>> byKey =
      <String, List<ActivityEventRow>>{};
  final Map<String, String?> deviceByKey = <String, String?>{};
  for (final ActivityEventRow e in events) {
    // 设备来源进分组键：互联对端事件与本机事件**不合并**（provenance 优先——
    // 标明设备来源后混并无法归属），各自成条各带标签。分隔符沿用 NUL（标题可含任意可见字符）。
    final String? device = sourceDeviceOf?.call(e);
    final String key = '${device ?? ''}\u0000${e.dateKey}\u0000${e.eventType}'
        '\u0000${e.mediaType}\u0000${e.mediaKey ?? e.title}';
    (byKey[key] ??= <ActivityEventRow>[]).add(e);
    deviceByKey[key] = device;
  }

  // 每个分组键 → 一条聚合条目。
  final List<ActivityEntry> entries = <ActivityEntry>[];
  for (final MapEntry<String, List<ActivityEventRow>> kv in byKey.entries) {
    final List<ActivityEventRow> group = kv.value;
    group.sort((ActivityEventRow a, ActivityEventRow b) =>
        a.timestampMs.compareTo(b.timestampMs));
    int totalDuration = 0;
    int totalChars = 0;
    int latest = group.first.timestampMs;
    String? mediaKey;
    int mediaKeyStamp = -1;
    final List<int> stamps = <int>[];
    for (final ActivityEventRow e in group) {
      totalDuration += e.durationMs ?? 0;
      totalChars += e.charsDelta ?? 0;
      if (e.timestampMs > latest) latest = e.timestampMs;
      // 取最近一次事件的 mediaKey（可能有的行没有 key）。
      if (e.mediaKey != null && e.timestampMs >= mediaKeyStamp) {
        mediaKey = e.mediaKey;
        mediaKeyStamp = e.timestampMs;
      }
      stamps.add(e.timestampMs);
    }
    entries.add(ActivityEntry(
      // 标题快照与 mediaKey 同取向：都取组内最新一行（改名当天显示新名）。
      title: group.last.title,
      eventType: group.first.eventType,
      mediaType: group.first.mediaType,
      mediaKey: mediaKey,
      dateKey: group.first.dateKey,
      latestTimestampMs: latest,
      totalDurationMs: totalDuration,
      totalChars: totalChars,
      sessionCount: _countSessions(stamps, sessionGap),
      sourceDevice: deviceByKey[kv.key],
    ));
  }

  // 按 dateKey 分组（dateKey 形如 2026-07-18，可字典序倒序）。
  final Map<String, List<ActivityEntry>> byDate =
      <String, List<ActivityEntry>>{};
  for (final ActivityEntry e in entries) {
    (byDate[e.dateKey] ??= <ActivityEntry>[]).add(e);
  }
  final List<String> dateKeys = byDate.keys.toList()
    ..sort((String a, String b) => b.compareTo(a));
  return <ActivityDateGroup>[
    for (final String dk in dateKeys)
      ActivityDateGroup(
        dateKey: dk,
        entries: byDate[dk]!
          ..sort((ActivityEntry a, ActivityEntry b) =>
              b.latestTimestampMs.compareTo(a.latestTimestampMs)),
      ),
  ];
}

/// 首页顶部统计卡的时长窗口聚合结果（毫秒）。
class DashboardTimeStats {
  const DashboardTimeStats({
    required this.today,
    required this.week,
    required this.month,
    required this.all,
  });

  final int today;
  final int week;
  final int month;
  final int all;
}

/// 纯函数：把 (dateKey, 时长毫秒) 事件按 [now] 的今日/近7天/近30天/全部窗口求和。
/// 与 [bucketActivityByDateKey]（stat_activity）同一套 dateKey 阈值语义，只是聚合的是
/// 时长而非计数。阅读统计与视频观看统计的行都可喂进来（首页「总时长/今日/本周/本月」）。
DashboardTimeStats sumTimeWindowsByDateKey(
  Iterable<(String dateKey, int ms)> rows,
  DateTime now,
) {
  final String todayKey = _dayKey(now);
  final String weekAgoKey = _dayKey(now.subtract(const Duration(days: 7)));
  final String monthAgoKey = _dayKey(now.subtract(const Duration(days: 30)));
  int today = 0;
  int week = 0;
  int month = 0;
  int all = 0;
  for (final (String dateKey, int ms) in rows) {
    if (ms <= 0) continue;
    all += ms;
    if (dateKey == todayKey) today += ms;
    if (dateKey.compareTo(weekAgoKey) >= 0) week += ms;
    if (dateKey.compareTo(monthAgoKey) >= 0) month += ms;
  }
  return DashboardTimeStats(today: today, week: week, month: month, all: all);
}

/// `yyyy-MM-dd`（与统计行 dateKey 同格式，可字典序比较）。委托
/// [HibikiTimeFormat.dayKey]（G5 收敛；不引 UI 层的 statDateKey，保持纯数据层）。
String _dayKey(DateTime d) => HibikiTimeFormat.dayKey(d);

/// 把已按升序排好的时间戳按 [gap] 归并成 session 数：相邻间隔 > gap 记一个新 session。
int _countSessions(List<int> sortedAscTimestamps, Duration gap) {
  if (sortedAscTimestamps.isEmpty) return 0;
  final int gapMs = gap.inMilliseconds;
  int sessions = 1;
  for (int i = 1; i < sortedAscTimestamps.length; i++) {
    if (sortedAscTimestamps[i] - sortedAscTimestamps[i - 1] > gapMs) {
      sessions++;
    }
  }
  return sessions;
}
