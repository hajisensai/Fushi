/// 复习（SRS）统计的数据面：把复习日志与卡片缓存归一成统计用的扁平记录，再由
/// 纯函数聚合出统计中心「复习」分区的每一块（对齐 Anki 2.1.50+ 统计页）。
///
/// - 只读 SRS 自己的数据（有效复习投影 `srs_stat_reviews` / `srs_cards_cache` / 笔记），按
///   profile；不碰学习统计域的 `study_segments`（那是阅读 / 观看 / 游戏的时长事实表）。统计
///   中心总览要的复习时长由 `loadStatFacts(includeReviews:)` 读同一张投影表合并（BUG-3771）。
/// - 「今天」与日序号一律走 SRS 的 [SrsDayContext]（翻日时刻 + UTC 偏移，与复习页、
///   牌组计数同一口径），不走统计页的 dateKey。
/// - 复习 = 有效的评分日志（被 undo 撤销的、被判与原生日志等价的导入日志都不算，
///   与 [SrsCardHistory.effectiveRatings] 同一判据）。
/// - 「按小时」用日志自己记下的 UTC 偏移（旅行不改历史复习落在几点，#2062）。
///
/// 装载见 `srs_stats_loader.dart`；这里不碰数据库，单测直接构造输入。
library;

import 'dart:math' as math;

import 'package:fushi_srs/fushi_srs.dart';

const int _dayMs = 24 * 60 * 60 * 1000;
const int _hourMs = 60 * 60 * 1000;

/// 成熟卡的间隔门槛（天，与 Anki 一致）。
const int kSrsMatureIntervalDays = 21;

/// 易忘卡（leech）门槛：遗忘次数（与 Anki 默认 leech 阈值一致）。
const int kSrsLeechLapses = 8;

/// 一次复习属于哪一类（统计口径，对齐 Anki revlog 的 Learn / Young / Mature /
/// Relearn / Filtered，另把「新卡的第一次评分」从学习里拆出来）。
enum SrsStatReviewKind { newCard, learn, young, mature, relearn, filtered }

/// 一次有效复习（评分 1..4）。
class SrsStatReview {
  const SrsStatReview({
    required this.cardId,
    required this.at,
    required this.day,
    required this.hour,
    required this.rating,
    required this.kind,
    this.durationMs = 0,
    this.early = false,
  });

  final String cardId;

  /// 复习时刻（毫秒）。
  final int at;

  /// SRS 日序号（[SrsDayContext.dayIndexOf]）。
  final int day;

  /// 本地小时 0..23（按日志自己的 UTC 偏移）。
  final int hour;

  /// 1 = 重来，2 = 困难，3 = 良好，4 = 简单。
  final int rating;
  final SrsStatReviewKind kind;
  final int durationMs;

  /// 提前复习：复习卡在到期日之前就被复习了。
  final bool early;

  bool get correct => rating > 1;
}

/// 卡片当前所处状态（卡片计数饼图的分类之一；暂停 / 搁置另算，见 [SrsStatCard]）。
enum SrsStatCardState { newCard, learning, relearning, young, mature }

/// 一张卡的统计视图（当前状态，来自卡片缓存 = 最后一条有效日志的结果）。
class SrsStatCard {
  const SrsStatCard({
    required this.id,
    required this.noteId,
    required this.deckId,
    required this.state,
    this.suspended = false,
    this.buried = false,
    this.fushiScheduled = true,
    this.intervalDays = 0,
    this.dueDay,
    this.dueAt,
    this.stability,
    this.difficulty,
    this.retrievability,
    this.lapses = 0,
    this.reps = 0,
    this.addedDay = 0,
    this.label = '',
    this.desiredRetention = 0.8,
    this.byRecall = false,
  });

  final String id;
  final String noteId;
  final String deckId;
  final SrsStatCardState state;
  final bool suspended;

  /// 今天被搁置（buriedUntilDay > 今天）。
  final bool buried;

  /// 由 Fushi 排程（移交给 Anki 的卡不进未来到期 / 负担）。
  final bool fushiScheduled;
  final int intervalDays;
  final int? dueDay;
  final int? dueAt;

  /// FSRS 稳定性（天）。
  final double? stability;

  /// FSRS 难度（1..10）。
  final double? difficulty;

  /// 此刻的可提取度（0..1）；没有记忆状态或排程内核不可用时为 null。
  final double? retrievability;
  final int lapses;
  final int reps;

  /// 加入日（笔记创建时刻的 SRS 日序号）。
  final int addedDay;

  /// 列表显示用的第一个字段（去 HTML）。
  final String label;

  /// 所在牌组的目标保留率。
  final double desiredRetention;

  /// 复习卡按 RWKV-Instant 排队（所在牌组是 RWKV 且 RWKV 可用）：此刻回忆率降到目标时出现，
  /// 存下的到期日不代表什么时候复习——未来到期 / 逾期 / 负担不计它（[SrsFutureDue.byRecall]），
  /// [retrievability] 是 RWKV 的。
  final bool byRecall;

  bool get isReview =>
      state == SrsStatCardState.young || state == SrsStatCardState.mature;
}

/// 一次成熟状态变化（成熟卡增长曲线用）：+1 = 这天变成熟，−1 = 这天掉出成熟。
class SrsStatMaturityEvent {
  const SrsStatMaturityEvent({
    required this.cardId,
    required this.day,
    required this.delta,
  });

  final String cardId;
  final int day;
  final int delta;
}

/// 统计中心「复习」分区的时间范围（与 Anki 统计页同一组）。
enum SrsStatsRange { month, threeMonths, year, all }

/// 某段日子的一个桶（逐日 / 逐周 / 逐月），[firstDay]..[lastDay] 都含。
class SrsDayBucket {
  const SrsDayBucket(this.firstDay, this.lastDay);

  final int firstDay;
  final int lastDay;

  int get days => lastDay - firstDay + 1;
  bool contains(int day) => day >= firstDay && day <= lastDay;

  @override
  bool operator ==(Object other) =>
      other is SrsDayBucket &&
      other.firstDay == firstDay &&
      other.lastDay == lastDay;

  @override
  int get hashCode => Object.hash(firstDay, lastDay);

  @override
  String toString() => 'Bucket($firstDay..$lastDay)';
}

/// 桶的粒度。
enum SrsBucketUnit { day, week, month }

/// [firstDay]..[lastDay] 切桶：≤ 92 天逐日，≤ 400 天逐周（从末日往回数整 7 天，
/// 最新一周恒完整），更长按自然月。
(SrsBucketUnit, List<SrsDayBucket>) srsStatsBuckets(int firstDay, int lastDay) {
  if (lastDay < firstDay) return (SrsBucketUnit.day, const <SrsDayBucket>[]);
  final int span = lastDay - firstDay + 1;
  if (span <= 92) {
    return (
      SrsBucketUnit.day,
      <SrsDayBucket>[
        for (int d = firstDay; d <= lastDay; d++) SrsDayBucket(d, d),
      ],
    );
  }
  if (span <= 400) {
    final List<SrsDayBucket> out = <SrsDayBucket>[];
    for (int end = lastDay; end >= firstDay; end -= 7) {
      out.add(SrsDayBucket(math.max(firstDay, end - 6), end));
    }
    return (SrsBucketUnit.week, out.reversed.toList());
  }
  final List<SrsDayBucket> out = <SrsDayBucket>[];
  final DateTime first = srsDayToDate(firstDay);
  int y = first.year;
  int m = first.month;
  while (true) {
    final int start = math.max(firstDay, srsDateToDay(y, m, 1));
    if (start > lastDay) break;
    final int nextStart = m == 12
        ? srsDateToDay(y + 1, 1, 1)
        : srsDateToDay(y, m + 1, 1);
    out.add(SrsDayBucket(start, math.min(lastDay, nextStart - 1)));
    m++;
    if (m == 13) {
      m = 1;
      y++;
    }
  }
  return (SrsBucketUnit.month, out);
}

/// 今日概览。
class SrsTodayStats {
  const SrsTodayStats({
    required this.count,
    required this.durationMs,
    required this.ratings,
    required this.byKind,
    required this.early,
    required this.matureCorrect,
    required this.matureTotal,
  });

  final int count;
  final int durationMs;

  /// 下标 0..3 = 评分 1..4 的次数。
  final List<int> ratings;
  final Map<SrsStatReviewKind, int> byKind;

  /// 提前复习次数。
  final int early;
  final int matureCorrect;
  final int matureTotal;

  int get correct => count - ratings[0];
  double? get correctRate => count == 0 ? null : correct / count;
  int kind(SrsStatReviewKind k) => byKind[k] ?? 0;
}

/// 未来到期预测。
class SrsFutureDue {
  const SrsFutureDue({
    required this.overdue,
    required this.perDay,
    required this.youngPerDay,
    required this.daily,
    required this.dailyLoad,
    this.byRecall = 0,
  });

  /// 不计在内的复习卡：按 RWKV-Instant 排队（[SrsStatCard.byRecall]），没有有意义的到期日。
  final int byRecall;

  /// 逾期（到期日早于今天）的复习卡数。
  final int overdue;

  /// 下标 0 = 今天、1 = 明天…的到期数（今天含学习中的卡）。
  final List<int> perDay;

  /// [perDay] 中年轻卡与学习卡的部分（其余为成熟卡）。
  final List<int> youngPerDay;

  /// 是否逐日（false 时 [perDay] 仍是逐日，只是 UI 自行分桶）。
  final bool daily;

  /// 每日平均负担（Anki「Daily load」：Σ 1 / 间隔，复习卡 + 学习卡按 1）。
  final double dailyLoad;

  int get total => perDay.fold<int>(0, (int a, int b) => a + b);
  int get dueTomorrow => perDay.length > 1 ? perDay[1] : 0;
  int get dueToday => perDay.isEmpty ? 0 : perDay[0];

  /// 范围内日均（不含逾期）。
  double get averagePerDay => perDay.isEmpty ? 0 : total / perDay.length;
}

/// 打卡（连续学习天数）。
class SrsStreak {
  const SrsStreak({required this.current, required this.longest});

  /// 截至今天（今天还没复习则截至昨天）的连续天数。
  final int current;
  final int longest;
}

/// 复习量 / 用时的一个桶。
class SrsReviewBucket {
  SrsReviewBucket(this.bucket);

  final SrsDayBucket bucket;
  final Map<SrsStatReviewKind, int> counts = <SrsStatReviewKind, int>{};
  final Map<SrsStatReviewKind, int> durations = <SrsStatReviewKind, int>{};

  int get totalCount => counts.values.fold<int>(0, (int a, int b) => a + b);
  int get totalMs => durations.values.fold<int>(0, (int a, int b) => a + b);
}

/// 一段范围内的复习合计（复习量卡片的摘要行）。
class SrsReviewTotals {
  const SrsReviewTotals({
    required this.count,
    required this.durationMs,
    required this.daysStudied,
    required this.days,
  });

  final int count;
  final int durationMs;
  final int daysStudied;

  /// 范围天数。
  final int days;

  double get averagePerDay => days == 0 ? 0 : count / days;
  double get averagePerStudiedDay => daysStudied == 0 ? 0 : count / daysStudied;
  double get averageMsPerCard => count == 0 ? 0 : durationMs / count;
}

/// 卡片计数（饼图）。暂停优先于搁置，二者都优先于学习状态（与 Anki 相同）。
class SrsCardCounts {
  const SrsCardCounts({
    required this.newCards,
    required this.learning,
    required this.relearning,
    required this.young,
    required this.mature,
    required this.suspended,
    required this.buried,
  });

  final int newCards;
  final int learning;
  final int relearning;
  final int young;
  final int mature;
  final int suspended;
  final int buried;

  int get total =>
      newCards + learning + relearning + young + mature + suspended + buried;
}

/// 直方图的一格：[lo] ≤ 值 < [hi]（末格含 [hi] 以上全部，见 [SrsHistogram.openEnded]）。
class SrsHistogramBin {
  const SrsHistogramBin(this.lo, this.hi, this.count);

  final double lo;
  final double hi;
  final int count;
}

/// 直方图（间隔 / 稳定性 / 难度 / 可提取度）。
class SrsHistogram {
  const SrsHistogram({
    required this.bins,
    required this.total,
    required this.mean,
    required this.median,
    this.openEnded = false,
    this.sum = 0,
  });

  static const SrsHistogram empty = SrsHistogram(
    bins: <SrsHistogramBin>[],
    total: 0,
    mean: null,
    median: null,
  );

  final List<SrsHistogramBin> bins;
  final int total;
  final double? mean;
  final double? median;

  /// 末格是「≥ 下沿」（长尾截断在 95 分位）。
  final bool openEnded;

  /// 值的总和（可提取度：Anki「估计掌握量」= Σ R）。
  final double sum;
}

/// 按小时（0..23）的复习数与答对数。
class SrsHourly {
  const SrsHourly({required this.counts, required this.correct});

  final List<int> counts;
  final List<int> correct;

  double? rateAt(int hour) =>
      counts[hour] == 0 ? null : correct[hour] / counts[hour];
}

/// 评分按钮分布的一组（学习中 / 年轻 / 成熟）。
class SrsButtonGroup {
  const SrsButtonGroup(this.ratings);

  /// 下标 0..3 = 评分 1..4。
  final List<int> ratings;

  int get total => ratings.fold<int>(0, (int a, int b) => a + b);
  int get correct => total - ratings[0];
  double? get correctRate => total == 0 ? null : correct / total;
}

/// 评分按钮分布。
class SrsButtons {
  const SrsButtons({
    required this.learning,
    required this.young,
    required this.mature,
  });

  final SrsButtonGroup learning;
  final SrsButtonGroup young;
  final SrsButtonGroup mature;
}

/// 真实保留率（复习卡的一次复习答对 = 记住了）。
class SrsRetention {
  const SrsRetention({
    required this.youngCorrect,
    required this.youngTotal,
    required this.matureCorrect,
    required this.matureTotal,
  });

  final int youngCorrect;
  final int youngTotal;
  final int matureCorrect;
  final int matureTotal;

  int get correct => youngCorrect + matureCorrect;
  int get total => youngTotal + matureTotal;
  double? get youngRate => youngTotal == 0 ? null : youngCorrect / youngTotal;
  double? get matureRate =>
      matureTotal == 0 ? null : matureCorrect / matureTotal;
  double? get rate => total == 0 ? null : correct / total;
}

/// 制卡来源的一组（同种类同标题）。
class SrsSourceShare {
  const SrsSourceShare({
    required this.kind,
    required this.title,
    required this.notes,
  });

  /// [SrsSourceKind] 之一；没有出处的笔记为空串。
  final String kind;

  /// 出处标题（书名 / 视频名…）；没有时为空串。
  final String title;
  final int notes;
}

/// 统计用的整份数据（某 profile、某一时刻）。
class SrsStatsData {
  SrsStatsData({
    required this.day,
    required this.nowMs,
    required List<SrsStatReview> reviews,
    required this.cards,
    this.maturityEvents = const <SrsStatMaturityEvent>[],
    this.sources = const <String, SrsSourceRef?>{},
    this.retrievabilityAvailable = true,
  }) : reviews = List<SrsStatReview>.of(reviews)
         ..sort((SrsStatReview a, SrsStatReview b) => a.at.compareTo(b.at)),
       today = day.dayIndexOf(nowMs);

  final SrsDayContext day;
  final int nowMs;
  final int today;

  /// 有效复习，按时刻升序。
  final List<SrsStatReview> reviews;

  /// 可见卡片（不含隐藏）。
  final List<SrsStatCard> cards;
  final List<SrsStatMaturityEvent> maturityEvents;

  /// noteId → 出处。
  final Map<String, SrsSourceRef?> sources;

  /// 可提取度能不能算（排程内核可用）。
  final bool retrievabilityAvailable;

  /// 只保留这些卡（牌组 / 搜索筛选）。复习与成熟事件按卡跟随。
  SrsStatsData subset(Set<String> cardIds) => SrsStatsData(
    day: day,
    nowMs: nowMs,
    reviews: <SrsStatReview>[
      for (final SrsStatReview r in reviews)
        if (cardIds.contains(r.cardId)) r,
    ],
    cards: <SrsStatCard>[
      for (final SrsStatCard c in cards)
        if (cardIds.contains(c.id)) c,
    ],
    maturityEvents: <SrsStatMaturityEvent>[
      for (final SrsStatMaturityEvent e in maturityEvents)
        if (cardIds.contains(e.cardId)) e,
    ],
    sources: sources,
    retrievabilityAvailable: retrievabilityAvailable,
  );

  bool get isEmpty => reviews.isEmpty && cards.isEmpty;

  /// 有数据的最早一天（复习或加卡）；都没有时为今天。
  int get earliestDay {
    int d = today;
    if (reviews.isNotEmpty) d = math.min(d, reviews.first.day);
    for (final SrsStatCard c in cards) {
      if (c.addedDay < d) d = c.addedDay;
    }
    return d;
  }

  /// 范围的第一天（末天恒为今天）。
  int firstDayOf(SrsStatsRange range) => switch (range) {
    SrsStatsRange.month => today - 29,
    SrsStatsRange.threeMonths => today - 89,
    SrsStatsRange.year => today - 364,
    SrsStatsRange.all => math.min(today, earliestDay),
  };

  Iterable<SrsStatReview> reviewsBetween(int firstDay, int lastDay) =>
      reviews.where((SrsStatReview r) => r.day >= firstDay && r.day <= lastDay);

  // ------------------------------------------------------------- 今日

  SrsTodayStats todayStats() {
    final List<int> ratings = <int>[0, 0, 0, 0];
    final Map<SrsStatReviewKind, int> byKind = <SrsStatReviewKind, int>{};
    int count = 0, ms = 0, early = 0, matureOk = 0, matureAll = 0;
    for (final SrsStatReview r in reviewsBetween(today, today)) {
      count++;
      ms += r.durationMs;
      ratings[r.rating - 1]++;
      byKind[r.kind] = (byKind[r.kind] ?? 0) + 1;
      if (r.early) early++;
      if (r.kind == SrsStatReviewKind.mature) {
        matureAll++;
        if (r.correct) matureOk++;
      }
    }
    return SrsTodayStats(
      count: count,
      durationMs: ms,
      ratings: ratings,
      byKind: byKind,
      early: early,
      matureCorrect: matureOk,
      matureTotal: matureAll,
    );
  }

  // ------------------------------------------------------------- 未来到期

  /// 往后 [days] 天（含今天）的到期预测。只算 Fushi 排程、未暂停的卡；搁置的卡
  /// 照常按到期日计（明天它就回来了）。
  SrsFutureDue futureDue(int days) {
    final int n = math.max(1, days);
    final List<int> perDay = List<int>.filled(n, 0);
    final List<int> young = List<int>.filled(n, 0);
    int overdue = 0;
    int byRecall = 0;
    double load = 0;
    for (final SrsStatCard c in cards) {
      if (!c.fushiScheduled || c.suspended) continue;
      if (c.byRecall && c.isReview) {
        byRecall++;
        continue;
      }
      int? offset;
      bool isYoung = true;
      switch (c.state) {
        case SrsStatCardState.newCard:
          continue;
        case SrsStatCardState.learning:
        case SrsStatCardState.relearning:
          load += 1;
          final int at = c.dueAt ?? nowMs;
          offset = math.max(0, day.dayIndexOf(at) - today);
        case SrsStatCardState.young:
        case SrsStatCardState.mature:
          load += 1 / math.max(1, c.intervalDays);
          isYoung = c.state == SrsStatCardState.young;
          offset = (c.dueDay ?? today) - today;
      }
      if (offset < 0) {
        overdue++;
        continue;
      }
      if (offset >= n) continue;
      perDay[offset]++;
      if (isYoung) young[offset]++;
    }
    return SrsFutureDue(
      overdue: overdue,
      perDay: perDay,
      youngPerDay: young,
      daily: true,
      dailyLoad: load,
      byRecall: byRecall,
    );
  }

  /// 「全部」范围下未来到期看多远：最晚到期日（夹在 30..3650 天）。
  int furthestDueOffset() {
    int far = 30;
    for (final SrsStatCard c in cards) {
      if (!c.fushiScheduled || c.suspended || !c.isReview || c.byRecall) {
        continue;
      }
      final int off = (c.dueDay ?? today) - today + 1;
      if (off > far) far = off;
    }
    return math.min(far, 3650);
  }

  // ------------------------------------------------------------- 日历与打卡

  /// 日序号 → 复习数。
  Map<int, int> countsByDay() {
    final Map<int, int> out = <int, int>{};
    for (final SrsStatReview r in reviews) {
      out[r.day] = (out[r.day] ?? 0) + 1;
    }
    return out;
  }

  SrsStreak streak() {
    final Set<int> days = <int>{for (final SrsStatReview r in reviews) r.day};
    int current = 0;
    int d = days.contains(today) ? today : today - 1;
    while (days.contains(d)) {
      current++;
      d--;
    }
    int longest = 0, run = 0;
    int? prev;
    for (final int x in days.toList()..sort()) {
      run = (prev != null && x == prev + 1) ? run + 1 : 1;
      if (run > longest) longest = run;
      prev = x;
    }
    return SrsStreak(current: current, longest: longest);
  }

  // ------------------------------------------------------------- 复习量 / 用时

  (SrsBucketUnit, List<SrsReviewBucket>) reviewBuckets(SrsStatsRange range) {
    final (SrsBucketUnit unit, List<SrsDayBucket> spans) = srsStatsBuckets(
      firstDayOf(range),
      today,
    );
    final List<SrsReviewBucket> out = <SrsReviewBucket>[
      for (final SrsDayBucket b in spans) SrsReviewBucket(b),
    ];
    if (out.isEmpty) return (unit, out);
    int i = 0;
    for (final SrsStatReview r in reviewsBetween(
      out.first.bucket.firstDay,
      today,
    )) {
      while (i < out.length && r.day > out[i].bucket.lastDay) {
        i++;
      }
      if (i >= out.length) break;
      final SrsReviewBucket b = out[i];
      b.counts[r.kind] = (b.counts[r.kind] ?? 0) + 1;
      b.durations[r.kind] = (b.durations[r.kind] ?? 0) + r.durationMs;
    }
    return (unit, out);
  }

  SrsReviewTotals reviewTotals(SrsStatsRange range) =>
      reviewTotalsBetween(firstDayOf(range), today);

  SrsReviewTotals reviewTotalsBetween(int firstDay, int lastDay) {
    int count = 0, ms = 0;
    final Set<int> studied = <int>{};
    for (final SrsStatReview r in reviewsBetween(firstDay, lastDay)) {
      count++;
      ms += r.durationMs;
      studied.add(r.day);
    }
    return SrsReviewTotals(
      count: count,
      durationMs: ms,
      daysStudied: studied.length,
      days: math.max(0, lastDay - firstDay + 1),
    );
  }

  // ------------------------------------------------------------- 卡片状态

  SrsCardCounts cardCounts() {
    int n = 0, l = 0, rl = 0, y = 0, m = 0, s = 0, b = 0;
    for (final SrsStatCard c in cards) {
      if (c.suspended) {
        s++;
      } else if (c.buried) {
        b++;
      } else {
        switch (c.state) {
          case SrsStatCardState.newCard:
            n++;
          case SrsStatCardState.learning:
            l++;
          case SrsStatCardState.relearning:
            rl++;
          case SrsStatCardState.young:
            y++;
          case SrsStatCardState.mature:
            m++;
        }
      }
    }
    return SrsCardCounts(
      newCards: n,
      learning: l,
      relearning: rl,
      young: y,
      mature: m,
      suspended: s,
      buried: b,
    );
  }

  // ------------------------------------------------------------- 分布

  /// 复习卡的当前间隔（天）。
  SrsHistogram intervalHistogram() => srsDaysHistogram(<double>[
    for (final SrsStatCard c in cards)
      if (c.isReview) c.intervalDays.toDouble(),
  ]);

  /// 稳定性（天）。
  SrsHistogram stabilityHistogram() => srsDaysHistogram(<double>[
    for (final SrsStatCard c in cards)
      if (c.state != SrsStatCardState.newCard && c.stability != null)
        c.stability!,
  ]);

  /// 难度（换算成 0..1：D 1..10 → (D − 1) / 9，与 Anki 显示的百分比一致）。
  SrsHistogram difficultyHistogram() => srsUnitHistogram(<double>[
    for (final SrsStatCard c in cards)
      if (c.state != SrsStatCardState.newCard && c.difficulty != null)
        ((c.difficulty! - 1) / 9).clamp(0.0, 1.0),
  ], bins: 10);

  /// 可提取度（0..1）。
  SrsHistogram retrievabilityHistogram() => srsUnitHistogram(<double>[
    for (final SrsStatCard c in cards)
      if (c.state != SrsStatCardState.newCard && c.retrievability != null)
        c.retrievability!.clamp(0.0, 1.0),
  ], bins: 20);

  // ------------------------------------------------------------- 按小时 / 按钮

  SrsHourly hourly(SrsStatsRange range) {
    final List<int> counts = List<int>.filled(24, 0);
    final List<int> correct = List<int>.filled(24, 0);
    for (final SrsStatReview r in reviewsBetween(firstDayOf(range), today)) {
      counts[r.hour]++;
      if (r.correct) correct[r.hour]++;
    }
    return SrsHourly(counts: counts, correct: correct);
  }

  SrsButtons buttons(SrsStatsRange range) {
    final List<int> learning = <int>[0, 0, 0, 0];
    final List<int> young = <int>[0, 0, 0, 0];
    final List<int> mature = <int>[0, 0, 0, 0];
    for (final SrsStatReview r in reviewsBetween(firstDayOf(range), today)) {
      switch (r.kind) {
        case SrsStatReviewKind.newCard:
        case SrsStatReviewKind.learn:
        case SrsStatReviewKind.relearn:
          learning[r.rating - 1]++;
        case SrsStatReviewKind.young:
          young[r.rating - 1]++;
        case SrsStatReviewKind.mature:
          mature[r.rating - 1]++;
        case SrsStatReviewKind.filtered:
          break;
      }
    }
    return SrsButtons(
      learning: SrsButtonGroup(learning),
      young: SrsButtonGroup(young),
      mature: SrsButtonGroup(mature),
    );
  }

  // ------------------------------------------------------------- 保留率

  /// [firstDay]..[lastDay] 内复习卡的真实保留率（学习 / 重学 / 筛选复习不算）。
  SrsRetention retentionBetween(int firstDay, int lastDay) {
    int yOk = 0, yAll = 0, mOk = 0, mAll = 0;
    for (final SrsStatReview r in reviewsBetween(firstDay, lastDay)) {
      if (r.kind == SrsStatReviewKind.young) {
        yAll++;
        if (r.correct) yOk++;
      } else if (r.kind == SrsStatReviewKind.mature) {
        mAll++;
        if (r.correct) mOk++;
      }
    }
    return SrsRetention(
      youngCorrect: yOk,
      youngTotal: yAll,
      matureCorrect: mOk,
      matureTotal: mAll,
    );
  }

  /// 复习卡目标保留率的平均（期望保留率；按卡平均，没有复习卡时取全部卡）。
  double? desiredRetention() {
    final Iterable<SrsStatCard> base = cards.any((SrsStatCard c) => c.isReview)
        ? cards.where((SrsStatCard c) => c.isReview)
        : cards;
    if (base.isEmpty) return null;
    double sum = 0;
    int n = 0;
    for (final SrsStatCard c in base) {
      sum += c.desiredRetention;
      n++;
    }
    return sum / n;
  }

  /// 每个桶末尾的成熟卡数（成熟卡增长曲线）。
  List<int> matureCountsAt(List<SrsDayBucket> buckets) {
    if (buckets.isEmpty) return const <int>[];
    final List<SrsStatMaturityEvent> events =
        List<SrsStatMaturityEvent>.of(maturityEvents)..sort(
          (SrsStatMaturityEvent a, SrsStatMaturityEvent b) =>
              a.day.compareTo(b.day),
        );
    final List<int> out = <int>[];
    int running = 0;
    int i = 0;
    for (final SrsDayBucket b in buckets) {
      while (i < events.length && events[i].day <= b.lastDay) {
        running += events[i].delta;
        i++;
      }
      out.add(math.max(0, running));
    }
    return out;
  }

  // ------------------------------------------------------------- 添加 / 易忘 / 来源

  /// 每个桶里新加的卡数。
  List<int> addedCounts(List<SrsDayBucket> buckets) {
    final List<int> out = List<int>.filled(buckets.length, 0);
    if (buckets.isEmpty) return out;
    for (final SrsStatCard c in cards) {
      for (int i = 0; i < buckets.length; i++) {
        if (buckets[i].contains(c.addedDay)) {
          out[i]++;
          break;
        }
      }
    }
    return out;
  }

  /// 范围内复习卡被遗忘（复习时按了「重来」）的次数。
  int lapsesBetween(int firstDay, int lastDay) => reviewsBetween(
    firstDay,
    lastDay,
  ).where((SrsStatReview r) => r.rating == 1 && _isReviewKind(r.kind)).length;

  /// 易忘卡：遗忘次数 ≥ [threshold]，按遗忘次数倒序。
  List<SrsStatCard> leeches({int threshold = kSrsLeechLapses}) =>
      <SrsStatCard>[
        for (final SrsStatCard c in cards)
          if (c.lapses >= threshold) c,
      ]..sort((SrsStatCard a, SrsStatCard b) {
        final int byLapses = b.lapses.compareTo(a.lapses);
        return byLapses != 0 ? byLapses : a.id.compareTo(b.id);
      });

  /// 遗忘次数最多的卡（不论门槛，最多 [limit] 张，遗忘 0 次的不列）。
  List<SrsStatCard> mostLapsed({int limit = 10}) {
    final List<SrsStatCard> all =
        <SrsStatCard>[
          for (final SrsStatCard c in cards)
            if (c.lapses > 0) c,
        ]..sort((SrsStatCard a, SrsStatCard b) {
          final int byLapses = b.lapses.compareTo(a.lapses);
          return byLapses != 0 ? byLapses : a.id.compareTo(b.id);
        });
    return all.take(limit).toList();
  }

  /// 制卡来源（按笔记计）：同种类同标题归一组，按笔记数倒序。
  List<SrsSourceShare> sourceShares() {
    final Map<(String, String), int> counts = <(String, String), int>{};
    final Set<String> seen = <String>{};
    for (final SrsStatCard c in cards) {
      if (!seen.add(c.noteId)) continue;
      final SrsSourceRef? s = sources[c.noteId];
      final (String, String) key = (s?.kind ?? '', s?.title?.trim() ?? '');
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final List<SrsSourceShare> out =
        <SrsSourceShare>[
          for (final MapEntry<(String, String), int> e in counts.entries)
            SrsSourceShare(kind: e.key.$1, title: e.key.$2, notes: e.value),
        ]..sort((SrsSourceShare a, SrsSourceShare b) {
          final int byCount = b.notes.compareTo(a.notes);
          if (byCount != 0) return byCount;
          final int byKind = a.kind.compareTo(b.kind);
          return byKind != 0 ? byKind : a.title.compareTo(b.title);
        });
    return out;
  }
}

bool _isReviewKind(SrsStatReviewKind k) =>
    k == SrsStatReviewKind.young || k == SrsStatReviewKind.mature;

double? _median(List<double> sorted) {
  if (sorted.isEmpty) return null;
  final int mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// 以「天」为单位的直方图：长尾截在 95 分位（末格「≥」），格宽取 1 / 2 / 5 ×
/// 10ⁿ 天里让格数 ≤ 24 的最小者。
SrsHistogram srsDaysHistogram(List<double> values) {
  if (values.isEmpty) return SrsHistogram.empty;
  final List<double> sorted = List<double>.of(values)..sort();
  final double sum = sorted.fold<double>(0, (double a, double b) => a + b);
  final double p95 = sorted[((sorted.length - 1) * 0.95).floor()];
  final double maxV = sorted.last;
  final double top = math.max(1, p95.ceilToDouble());
  double width = 1;
  outer:
  for (double pow10 = 1; ; pow10 *= 10) {
    for (final double m in const <double>[1, 2, 5]) {
      width = pow10 * m;
      if (top / width <= 24) break outer;
    }
  }
  final bool openEnded = maxV >= top + width;
  final int binCount = openEnded
      ? (top / width).ceil() + 1
      : (math.max(top, maxV) / width).floor() + 1;
  final List<int> counts = List<int>.filled(binCount, 0);
  for (final double v in sorted) {
    final int i = math.min(binCount - 1, (v / width).floor());
    counts[i]++;
  }
  return SrsHistogram(
    bins: <SrsHistogramBin>[
      for (int i = 0; i < binCount; i++)
        SrsHistogramBin(i * width, (i + 1) * width, counts[i]),
    ],
    total: sorted.length,
    mean: sum / sorted.length,
    median: _median(sorted),
    openEnded: openEnded,
    sum: sum,
  );
}

/// 0..1 的直方图（[bins] 等宽格，1.0 落进末格）。
SrsHistogram srsUnitHistogram(List<double> values, {required int bins}) {
  if (values.isEmpty) return SrsHistogram.empty;
  final List<double> sorted = List<double>.of(values)..sort();
  final List<int> counts = List<int>.filled(bins, 0);
  double sum = 0;
  for (final double v in sorted) {
    sum += v;
    counts[math.min(bins - 1, (v * bins).floor())]++;
  }
  return SrsHistogram(
    bins: <SrsHistogramBin>[
      for (int i = 0; i < bins; i++)
        SrsHistogramBin(i / bins, (i + 1) / bins, counts[i]),
    ],
    total: sorted.length,
    mean: sum / sorted.length,
    median: _median(sorted),
    sum: sum,
  );
}

/// 一条有效日志在统计里的投影（与日界无关的那部分；落在 srs.db 的 `srs_stat_reviews`，一条日志一行，
/// 由 Rust `history::stats_from_json` 在缓存刷新时产出，见 `SrsDbStore._refreshStatProjection`）。
///
/// 日序号、小时、「提前复习」都依赖读方的日界口径，读时由 [srsStatsFromProjection] 算；
/// 这里只留原始时刻、写入时的 UTC 偏移和「上一条有效结果的到期日」。分类 [kind] 依赖前序
/// 有效状态，只能在按整张卡的有效历史重放时定，所以在投影里存死。
class SrsStatProjection {
  const SrsStatProjection({
    required this.logId,
    required this.cardId,
    required this.occurredAt,
    this.utcOffsetMin = 0,
    this.rating,
    this.kind = SrsStatReviewKind.newCard,
    this.durationMs = 0,
    this.prevDueDay,
    this.maturityDelta = 0,
  });

  final String logId;

  /// 归属卡（卡自己可见就是它自己；不可见（或已无缓存行）的前身卡归继承它历史的可见卡，见 `SrsStatReviews`）。
  final String cardId;
  final int occurredAt;
  final int utcOffsetMin;

  /// 1..4；null = 不是统计复习，只是成熟状态变化（[maturityDelta] ≠ 0）。
  final int? rating;
  final SrsStatReviewKind kind;
  final int durationMs;

  /// 按到期日排的复习卡复习：上一条有效结果的到期日（> 当天 = 提前复习）；其余 null。
  final int? prevDueDay;

  /// +1 = 这条之后变成熟，−1 = 掉出成熟，0 = 不变。
  final int maturityDelta;

  bool get isReview => rating != null;
}

/// 投影 → 统计复习记录 + 成熟变化，日序号 / 小时 / 提前复习按 [day] 的口径算。
({List<SrsStatReview> reviews, List<SrsStatMaturityEvent> maturity})
srsStatsFromProjection(
  Iterable<SrsStatProjection> projection,
  SrsDayContext day,
) {
  final List<SrsStatReview> reviews = <SrsStatReview>[];
  final List<SrsStatMaturityEvent> maturity = <SrsStatMaturityEvent>[];
  for (final SrsStatProjection p in projection) {
    final int dayIndex = day.dayIndexOf(p.occurredAt);
    final int? rating = p.rating;
    if (rating != null) {
      final int offsetMs = p.utcOffsetMin * 60000;
      reviews.add(
        SrsStatReview(
          cardId: p.cardId,
          at: p.occurredAt,
          day: dayIndex,
          hour: ((p.occurredAt + offsetMs) % _dayMs) ~/ _hourMs,
          rating: rating,
          kind: p.kind,
          durationMs: p.durationMs,
          early: p.prevDueDay != null && p.prevDueDay! > dayIndex,
        ),
      );
    }
    if (p.maturityDelta != 0) {
      maturity.add(
        SrsStatMaturityEvent(
          cardId: p.cardId,
          day: dayIndex,
          delta: p.maturityDelta,
        ),
      );
    }
  }
  return (reviews: reviews, maturity: maturity);
}

/// 卡片当前状态 → 统计分类（[queue] 是缓存里的队列名）。
SrsStatCardState srsStatCardStateOf(String queue, int intervalDays) =>
    switch (SrsQueue.parse(queue)) {
      SrsQueue.newCard => SrsStatCardState.newCard,
      SrsQueue.learning => SrsStatCardState.learning,
      SrsQueue.relearning => SrsStatCardState.relearning,
      SrsQueue.review =>
        intervalDays >= kSrsMatureIntervalDays
            ? SrsStatCardState.mature
            : SrsStatCardState.young,
    };
