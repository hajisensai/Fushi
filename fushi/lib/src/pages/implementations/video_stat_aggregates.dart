import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi_core/fushi_core.dart';

/// 单个视频在「按视频排行」里的聚合数据。
///
/// v76：一张 tile = 一个身份组，观看时长 / 查词 / 制卡 / 收藏都由**同一次**
/// 身份分组（[groupStatRowsByIdentity] 跑在 watch + counter + 收藏三个行宇宙
/// 的并集上）解析后挂到 tile 上——绝不对不同行宇宙各跑一遍分组再拼接：那会让
/// 无身份行的吸收判据在两个宇宙里得出不同答案，计数在同名 tile 间游走
/// （code review 2026-08 finding 2/3/4 的共同根因）。
///
/// [bookUid] null = 无身份遗留组（同名多视频的 v39 前旧行 / sync 降级行，
/// 归属不可判）；[absorbedUnattributed] = 本组吸收了同 title 的无身份行
/// （删除时连带的判据）。
class VideoStatBookData {
  VideoStatBookData(this.title, {this.bookUid});
  final String title;
  final String? bookUid;
  bool absorbedUnattributed = false;
  int chars = 0;
  int ms = 0;
  int lookups = 0;
  int mines = 0;
  int favorites = 0;
}

/// 视频统计聚合结果（今日 / 本周 / 本月 / 全部 + 30 天图 + 按视频排行 + 完成数）。
class VideoStatsAggregate {
  int todayChars = 0, todayMs = 0, todayCompleted = 0;
  int weekChars = 0, weekMs = 0, weekCompleted = 0;
  int monthChars = 0, monthMs = 0, monthCompleted = 0;
  int allChars = 0, allMs = 0, allCompleted = 0;
  List<StatDayData> daily = <StatDayData>[];
  List<VideoStatBookData> byVideo = <VideoStatBookData>[];
}

/// 统一身份行：三个行宇宙映射到同一形状，喂一次分组。
typedef _IdentityRow = ({
  String identity,
  String title,
  VideoWatchStatisticRow? watch,
  LookupMiningCounterRow? counter,
  FavoriteWordRow? favorite,
});

/// 纯函数：把视频观看统计行 + 查词/制卡计数行 + 收藏行 + 完成时间戳列表聚合成
/// [VideoStatsAggregate]。与 reading_statistics_page 的 `_computeAggregates`
/// 同构，但抽成纯函数可单测。
///
/// tile 契约（v76）：
///  - tile 由**观看行**驱动（有 watch 行才有 tile；只有计数/收藏的身份不成 tile，
///    其数字只进汇总面板——与 v76 前一致）；
///  - 无身份行（watch 的 NULL uid / counter 的 '' / 收藏的 null bookKey）在
///    **三宇宙并集**上找 unique-title 归属：唯一身份组 → 并入（主流场景
///    「一个视频跨新旧数据」仍是单 tile）；歧义（0 或 ≥2 个身份组同 title）→
///    watch 无身份行独立成 null-identity tile，counter/收藏无身份行只挂该
///    null-identity tile（没有就不进任何 tile，绝不瞎归属、绝不双计）。
VideoStatsAggregate computeVideoStats({
  required List<VideoWatchStatisticRow> stats,
  required List<DateTime> completed,
  required DateTime now,
  List<LookupMiningCounterRow> counters = const <LookupMiningCounterRow>[],
  List<FavoriteWordRow> favorites = const <FavoriteWordRow>[],

  /// 库表（video_books）判为多身份的 title 集合：这些 title 的无身份行**禁止**
  /// 吸收进任何身份组（review-2：行宇宙判据会被「同名双视频只有一方查过词」
  /// 骗过，把混着两者历史的遗留行整体吸给先动的那个）。与迁移回填的库表唯一
  /// 匹配判据同源。
  Set<String> ambiguousTitles = const <String>{},
}) {
  final agg = VideoStatsAggregate();
  final todayKey = statDateKey(now);
  final weekAgoKey = statDateKey(now.subtract(const Duration(days: 7)));
  final monthAgoKey = statDateKey(now.subtract(const Duration(days: 30)));

  final dailyMap = <String, StatDayData>{};

  for (final s in stats) {
    agg.allChars += s.subtitleChars;
    agg.allMs += s.watchTimeMs;
    if (s.dateKey == todayKey) {
      agg.todayChars += s.subtitleChars;
      agg.todayMs += s.watchTimeMs;
    }
    if (s.dateKey.compareTo(weekAgoKey) >= 0) {
      agg.weekChars += s.subtitleChars;
      agg.weekMs += s.watchTimeMs;
    }
    if (s.dateKey.compareTo(monthAgoKey) >= 0) {
      agg.monthChars += s.subtitleChars;
      agg.monthMs += s.watchTimeMs;
    }
    final day =
        dailyMap.putIfAbsent(s.dateKey, () => StatDayData(dateKey: s.dateKey));
    day.chars += s.subtitleChars;
    day.ms += s.watchTimeMs;
  }

  // 最近 30 天补齐空日期，按日期升序。
  final thirtyDaysAgo = now.subtract(const Duration(days: 29));
  for (int i = 0; i < 30; i++) {
    final key = statDateKey(thirtyDaysAgo.add(Duration(days: i)));
    agg.daily.add(dailyMap[key] ?? StatDayData(dateKey: key));
  }

  // v76：按视频排行改身份分组（v39 只修了存储层，展示层此前仍按 title 合并同名
  // 视频——互串的另一半）。三个行宇宙并成统一身份行、跑**一次**分组，吸收判据
  // 全局一致（分组契约见 [groupStatRowsByIdentity]）。
  final List<_IdentityRow> unified = <_IdentityRow>[
    for (final VideoWatchStatisticRow s in stats)
      (
        identity: s.bookUid ?? '',
        title: s.title,
        watch: s,
        counter: null,
        favorite: null,
      ),
    for (final LookupMiningCounterRow c in counters)
      if (c.title.isNotEmpty)
        (
          identity: c.bookKey,
          title: c.title,
          watch: null,
          counter: c,
          favorite: null,
        ),
    for (final FavoriteWordRow f in favorites)
      if (f.title.isNotEmpty)
        (
          identity: f.bookKey ?? '',
          title: f.title,
          watch: null,
          counter: null,
          favorite: f,
        ),
  ];
  agg.byVideo = <VideoStatBookData>[];
  for (final StatIdentityGroup<_IdentityRow> g in groupStatRowsByIdentity(
    unified,
    identityOf: (_IdentityRow r) => r.identity,
    titleOf: (_IdentityRow r) => r.title,
    ambiguousTitles: ambiguousTitles,
  )) {
    final VideoStatBookData book =
        VideoStatBookData(g.title, bookUid: g.identity)
          ..absorbedUnattributed = g.absorbedUnattributed;
    bool hasWatch = false;
    for (final _IdentityRow r in g.rows) {
      final VideoWatchStatisticRow? s = r.watch;
      if (s != null) {
        hasWatch = true;
        book.chars += s.subtitleChars;
        book.ms += s.watchTimeMs;
      }
      final LookupMiningCounterRow? c = r.counter;
      if (c != null) {
        book.lookups += c.lookupCount;
        book.mines += c.mineCount;
      }
      if (r.favorite != null) book.favorites++;
    }
    // tile 由观看行驱动：只有计数/收藏的组不成 tile（数字只进汇总面板）。
    if (hasWatch) agg.byVideo.add(book);
  }
  agg.byVideo.sort((a, b) => b.ms.compareTo(a.ms));
  // 删字数后按观看时长排行（字数仍在 DB/聚合里保留，只是不再展示/排序）。

  // 完成数按时间戳落入区间（天然去重：completedAt 只记首次）。
  for (final c in completed) {
    final key = statDateKey(c);
    agg.allCompleted++;
    if (key == todayKey) agg.todayCompleted++;
    if (key.compareTo(weekAgoKey) >= 0) agg.weekCompleted++;
    if (key.compareTo(monthAgoKey) >= 0) agg.monthCompleted++;
  }
  return agg;
}
