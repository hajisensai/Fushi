/// 复习首页（方案 D「今日计划」+ 热力图 / 未来 7 天）用的统计。
///
/// - 今日计划条：今天已复习多少次、最近平均每次用时（估剩余时长）、连续学习天数；
/// - 牌组行的细进度条：每个牌组今天已复习的次数（[SrsHomeStats.doneTodayIn]）；
/// - 热力图卡：逐日复习数 + 当前 / 最长连续天数；
/// - 未来 7 天卡：全库逐日到期预测；
/// - 选中牌组的详情：该牌组（含子牌组）的到期预测、保持率、新卡 / 已掌握张数
///   （[SrsHomeStats.detailFor]，按需算一次并记住）。
///
/// 数据来自统计页同一份装载（[loadSrsStats]），装载按批让出事件循环，大集合不卡界面。
/// 首页先按牌组计数画出来，这份统计到了再补上进度、时长与图表。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:fushi/src/srs/srs_providers.dart';

/// 首页预测图看几天（含今天）。
const int kSrsHomeForecastDays = 7;

/// 详情面板保持率看最近几天。
const int kSrsHomeRetentionDays = 30;

/// 一个牌组（含子牌组）的详情数据。
class SrsHomeDeckDetail {
  const SrsHomeDeckDetail({
    required this.newCards,
    required this.matureCards,
    required this.forecast,
    required this.retention,
    required this.reviewsRecent,
    required this.desiredRetention,
  });

  /// 新卡张数（未暂停 / 未搁置，与统计页「卡片状态」同口径）。
  final int newCards;

  /// 已掌握（成熟）张数。
  final int matureCards;

  /// 未来 [kSrsHomeForecastDays] 天逐日到期张数（第 0 天含已逾期，见 [srsHomeForecastOf]）。
  final List<int> forecast;

  /// 最近 [kSrsHomeRetentionDays] 天复习卡的真实保持率；没有复习时为 null。
  final double? retention;

  /// 最近 [kSrsHomeRetentionDays] 天的复习次数。
  final int reviewsRecent;

  /// 目标保持率（牌组设置的平均）；没有卡时为 null。
  final double? desiredRetention;
}

/// 首页统计快照。
class SrsHomeStats {
  SrsHomeStats({
    required this.doneToday,
    required this.averageMsPerCard,
    required this.streak,
    this.longestStreak = 0,
    this.today = 0,
    this.countsByDay = const <int, int>{},
    this.forecast = const <int>[],
    this.doneTodayByDeck = const <String, int>{},
    SrsStatsData? data,
  }) : _data = data;

  /// 今天已经评过分的次数（同一张卡重复学习按次数计，与统计页「今天」同口径）。
  final int doneToday;

  /// 最近 [recentDays] 天平均每次评分的用时（毫秒）；没有复习记录时为 0。
  final double averageMsPerCard;

  /// 截至今天的连续学习天数。
  final int streak;

  /// 历史最长连续学习天数。
  final int longestStreak;

  /// 统计日序号（热力图的最右一天）。
  final int today;

  /// 日序号 → 复习次数（热力图）。
  final Map<int, int> countsByDay;

  /// 全库未来 [kSrsHomeForecastDays] 天逐日到期（第 0 天含已逾期）。
  final List<int> forecast;

  /// 牌组 id（卡片直接所在的牌组，不含子牌组）→ 今天的复习次数。
  final Map<String, int> doneTodayByDeck;

  /// 原始统计数据：详情面板按牌组取子集用；测试直接构造时可为 null。
  final SrsStatsData? _data;

  final Map<String, SrsHomeDeckDetail> _details = <String, SrsHomeDeckDetail>{};

  /// 估算平均用时所看的天数。
  static const int recentDays = 14;

  /// 剩余 [remaining] 张大约要几分钟；没有用时数据时返回 null（界面不显示）。
  int? minutesFor(int remaining) {
    if (remaining <= 0 || averageMsPerCard <= 0) return null;
    final int minutes = (remaining * averageMsPerCard / 60000).ceil();
    return minutes < 1 ? 1 : minutes;
  }

  /// 今天的完成度（0..1）：已复习 ÷（已复习 + 剩余）。两者都是 0 时视为完成。
  double progressWith(int remaining) =>
      srsTodayProgress(done: doneToday, remaining: remaining) ?? 1;

  /// [deckIds]（一个牌组连同全部子牌组）今天一共复习了几次。
  int doneTodayIn(Set<String> deckIds) {
    int sum = 0;
    for (final String id in deckIds) {
      sum += doneTodayByDeck[id] ?? 0;
    }
    return sum;
  }

  /// [deckIds]（一个牌组连同全部子牌组）的详情。按 [cacheKey]（通常是牌组 id）记住：
  /// 同一份快照里切回已看过的牌组不再重算。没有原始数据时返回 null。
  SrsHomeDeckDetail? detailFor(String cacheKey, Set<String> deckIds) {
    final SrsStatsData? data = _data;
    if (data == null) return null;
    return _details[cacheKey] ??= srsHomeDeckDetailOf(data, deckIds);
  }
}

/// 今天的完成度：已复习 ÷（已复习 + 剩余）；两者都是 0（今天这里没事做）时为 null。
///
/// 复习次数与剩余张数口径不同（同一张卡学两次算两次），与统计页「今天」一致；首页的
/// 今日计划条与每个牌组行的细进度条都用这个口径。
double? srsTodayProgress({required int done, required int remaining}) {
  final int total = done + remaining;
  if (total <= 0) return null;
  return done / total;
}

/// 到期预测折成首页的逐日柱：已逾期的卡今天就该复习，并进第 0 天（统计页把逾期单列一根，
/// 首页小图不单列）。
List<int> srsHomeForecastOf(SrsFutureDue due) => <int>[
  for (int i = 0; i < due.perDay.length; i++)
    i == 0 ? due.perDay[0] + due.overdue : due.perDay[i],
];

/// 一个牌组（[deckIds] = 它与全部子牌组）的详情：取这些牌组里的卡做统计子集。
SrsHomeDeckDetail srsHomeDeckDetailOf(SrsStatsData data, Set<String> deckIds) {
  final SrsStatsData sub = data.subset(<String>{
    for (final SrsStatCard c in data.cards)
      if (deckIds.contains(c.deckId)) c.id,
  });
  final int first = sub.today - kSrsHomeRetentionDays + 1;
  final SrsCardCounts counts = sub.cardCounts();
  return SrsHomeDeckDetail(
    newCards: counts.newCards,
    matureCards: counts.mature,
    forecast: srsHomeForecastOf(sub.futureDue(kSrsHomeForecastDays)),
    retention: sub.retentionBetween(first, sub.today).rate,
    reviewsRecent: sub.reviewTotalsBetween(first, sub.today).count,
    desiredRetention: sub.desiredRetention(),
  );
}

/// 从统计数据里取首页要的数（纯函数，测试直接喂 [SrsStatsData]）。
SrsHomeStats srsHomeStatsOf(SrsStatsData data) {
  final int today = data.today;
  final SrsReviewTotals recent = data.reviewTotalsBetween(
    today - SrsHomeStats.recentDays + 1,
    today,
  );
  final SrsStreak streak = data.streak();
  final Map<String, String> deckOfCard = <String, String>{
    for (final SrsStatCard c in data.cards) c.id: c.deckId,
  };
  final Map<String, int> doneByDeck = <String, int>{};
  for (final SrsStatReview r in data.reviewsBetween(today, today)) {
    final String? deck = deckOfCard[r.cardId];
    if (deck == null) continue;
    doneByDeck[deck] = (doneByDeck[deck] ?? 0) + 1;
  }
  return SrsHomeStats(
    doneToday: data.todayStats().count,
    averageMsPerCard: recent.averageMsPerCard,
    streak: streak.current,
    longestStreak: streak.longest,
    today: today,
    countsByDay: data.countsByDay(),
    forecast: srsHomeForecastOf(data.futureDue(kSrsHomeForecastDays)),
    doneTodayByDeck: doneByDeck,
    data: data,
  );
}

/// 首页统计：随 [srsRevisionProvider] 重读（复习 / 编辑回来时 [bumpSrsRevision]）。
///
/// 顺带备好日期本地化数据：首页图表的星期 / 日期标签按当前语言格式化。
final FutureProvider<SrsHomeStats?> srsHomeStatsProvider =
    FutureProvider<SrsHomeStats?>((Ref ref) async {
      ref.watch(srsRevisionProvider);
      final SrsDbStore? store = await ref.watch(srsStoreProvider.future);
      if (store == null) return null;
      final SrsStatsBundle bundle = await loadSrsStats(store);
      await initializeDateFormatting();
      return srsHomeStatsOf(bundle.data);
    });
