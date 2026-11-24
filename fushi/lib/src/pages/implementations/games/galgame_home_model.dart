/// 游戏首页（[GalgameHomePage]）两套版面共用的数据与回调：
///
/// - 纯函数：游玩状态计数 / 展示顺序、「平均通关约 n 小时」、相对时间与日期头文案；
/// - [GalgameHomeViewData]：State 算好的「画什么」（指标、继续首块、最近玩过、随机
///   推荐、状态计数、时间线、会话摘要），Apple 版面（`apple/apple_galgame_home.dart`）
///   只消费它；
/// - [GalgameHomeActions]：启动 / 详情 / 菜单 / 换一个 / 带视图进库 / 工作台 / 时间线
///   筛选 / 导入 / 去发现，全部由 State 的同一份业务实现提供。
///
/// 业务（启动、详情、隐藏成人向 / 上锁过滤、时间线聚合）只在 State 一处；本文件
/// 只有数据形状与无副作用的格式化，不碰仓储、不碰 BuildContext。
library;

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart';
import 'package:fushi/src/pages/implementations/games/galgame_library_view_request.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatHeatmapDay;

/// 「游玩状态」各档的展示顺序（设计稿：在玩 → 玩过 → 想玩 → 搁置 → 弃坑 →
/// 未设置）。
const List<GalgamePlayStatus> kGalgameHomeStatusOrder = <GalgamePlayStatus>[
  GalgamePlayStatus.playing,
  GalgamePlayStatus.played,
  GalgamePlayStatus.wantToPlay,
  GalgamePlayStatus.onHold,
  GalgamePlayStatus.dropped,
  GalgamePlayStatus.unset,
];

/// 按游玩状态计数（6 档都有键，没有的为 0）。纯函数。
Map<GalgamePlayStatus, int> countGalgamePlayStatuses(
  Iterable<GalgameEntry> games,
) {
  final Map<GalgamePlayStatus, int> counts = <GalgamePlayStatus, int>{
    for (final GalgamePlayStatus s in GalgamePlayStatus.values) s: 0,
  };
  for (final GalgameEntry g in games) {
    counts[g.playStatus] = (counts[g.playStatus] ?? 0) + 1;
  }
  return counts;
}

/// 「平均通关约 n 小时」的 n：10 小时内保留一位小数，往上取整；没有或非正为 null。
String? galgameAverageHoursLabel(double? hours) {
  if (hours == null || hours <= 0 || !hours.isFinite) return null;
  return hours < 10
      ? hours.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')
      : '${hours.round()}';
}

/// 「最近玩过」货架最多几项（与原侧栏游戏速览同一口径）。
const int kGalgameHomeRecentLimit = 12;

/// 相对时间文案（刚刚 / n 分钟前 / n 小时前 / n 天前）。
String galgameHomeRelativeTime(int timestampMs, DateTime now) {
  final ActivityRelativeTime rel = activityRelativeTime(timestampMs, now);
  return switch (rel.unit) {
    ActivityRelativeUnit.justNow => t.activity_just_now,
    ActivityRelativeUnit.minutesAgo => t.activity_minutes_ago(n: rel.value),
    ActivityRelativeUnit.hoursAgo => t.activity_hours_ago(n: rel.value),
    ActivityRelativeUnit.daysAgo => t.activity_days_ago(n: rel.value),
  };
}

/// 时间线日期头文案：今天 / 昨天 / 具体日期。
String galgameHomeDayLabel(
  String dateKey,
  String todayKey,
  String yesterdayKey,
) {
  if (dateKey == todayKey) return t.home_today;
  if (dateKey == yesterdayKey) return t.home_yesterday;
  return formatStatHeatmapDay(dateKey);
}

/// 时间线一行（已按筛选与隐藏口径过滤、聚合）。
class GalgameHomeTimelineEntry {
  const GalgameHomeTimelineEntry({
    required this.key,
    required this.title,
    required this.added,
    required this.relative,
    required this.trailing,
    this.game,
  });

  /// 稳定 key（`<dateKey>-<行号>`），也是焦点站点 id 的后缀。
  final String key;

  /// 库内显示名（落库标题快照回落）。
  final String title;

  /// 「加入游戏库」事件（否则是游玩事件）。
  final bool added;

  /// 最近一次发生的相对时间。
  final String relative;

  /// 行尾说明：游玩写「n 次会话 · 时长」，新增写「加入游戏库」。
  final String trailing;

  /// 库里还在的游戏（可点进详情）；已删除为 null。
  final GalgameEntry? game;
}

/// 时间线的一天。
class GalgameHomeTimelineDay {
  const GalgameHomeTimelineDay({
    required this.dateKey,
    required this.label,
    required this.entries,
  });

  final String dateKey;
  final String label;
  final List<GalgameHomeTimelineEntry> entries;
}

/// State 交给版面的「画什么」。
class GalgameHomeViewData {
  const GalgameHomeViewData({
    required this.loaded,
    required this.totalGames,
    required this.totalSeconds,
    required this.todaySeconds,
    required this.weekSeconds,
    required this.weekDays,
    required this.hero,
    required this.heroRunning,
    required this.recent,
    required this.random,
    required this.statusCounts,
    required this.timeline,
    required this.timelineFilter,
    required this.sessionActive,
  });

  /// 首轮重算已完成（之前库为空时画骨架而不是空态）。
  final bool loaded;

  /// 可见游戏数（隐藏成人向 / 上锁过滤后）；0 = 空库态。
  final int totalGames;

  /// 可见游戏的累计游玩秒数。
  final int totalSeconds;
  final int todaySeconds;
  final int weekSeconds;

  /// 近 7 天每天的游玩秒数（最旧 → 今天）。
  final List<int> weekDays;

  /// 「继续」首块：运行中优先，否则最近玩过的；都没有退到随机推荐。
  final GalgameEntry? hero;

  /// [hero] 正是本机 Hook 会话在跑的那个。
  final bool heroRunning;

  /// 「最近玩过」货架（不含 [hero]，至多 [kGalgameHomeRecentLimit] 项）。
  final List<GalgameEntry> recent;

  /// 随机推荐（「换一个」重掷）。
  final GalgameEntry? random;

  /// 6 档游玩状态计数。
  final Map<GalgamePlayStatus, int> statusCounts;

  /// 按日分组的完整时间线（已按 [timelineFilter] 过滤）。
  final List<GalgameHomeTimelineDay> timeline;

  /// 时间线筛选：null = 全部 / [kActivityGame] / [kActivityAdded]。
  final String? timelineFilter;

  /// 本机有活动的 Hook 会话（首块画「正在捕获 · 捕获工作台 ›」）。
  final bool sessionActive;
}

/// 版面可触发的动作（全部是 State 里的同一份实现）。
class GalgameHomeActions {
  const GalgameHomeActions({
    required this.launch,
    required this.openDetail,
    required this.showMenu,
    required this.reroll,
    required this.openLibraryWith,
    required this.setTimelineFilter,
    required this.importGames,
    this.openWorkbench,
    this.discover,
  });

  /// 启动（运行中 = 继续）；与 M3E 同一条 launch 路径与结果播报。
  final void Function(GalgameEntry game) launch;

  /// 打开详情；[coverHeroTag] 非 null = 发起处的封面挂着同 tag 的 Hero。
  final void Function(GalgameEntry game, {String? coverHeroTag}) openDetail;

  /// 长按 / 右键 / 「⋯」：与游戏库同一份条目菜单；「详情」项带 [coverHeroTag]。
  final void Function(GalgameEntry game, {String? coverHeroTag}) showMenu;

  final void Function() reroll;
  final void Function(GalgameLibraryViewRequest request) openLibraryWith;
  final void Function(String? filter) setTimelineFilter;

  /// 空库态「导入游戏」。
  final void Function() importGames;

  /// 切到捕获工作台；没有 Hook 会话时为 null。
  final void Function()? openWorkbench;

  /// 空库态「去发现」；`externalDiscovery` 不可用时为 null。
  final void Function()? discover;
}
