/// 复习（SRS）统计的结果类型：统计中心「复习」分区、复习首页、桌面小组件、操作目录 `srs/stats` 读到的每一块
/// （对齐 Anki 2.1.50+ 统计页）。
///
/// 数据与聚合都在 Rust 内核（native/fushi_fsrs/src/store/stats.rs，命令 `stats_report`）：内核读有效复习投影
/// `srs_stat_reviews` 与卡片缓存，按请求的日界（[SrsDayContext]：翻日时刻随 profile、时区用本机偏移）与范围 / 牌组
/// 算好交回；这里只把交回的 JSON 解成界面用的类型，不再逐行聚合。装载见 `srs_stats_loader.dart`。
library;

import 'package:fushi_srs/fushi_srs.dart';

/// 一次复习属于哪一类（统计口径，对齐 Anki revlog 的 Learn / Young / Mature / Relearn / Filtered，另把「新卡的第一次
/// 评分」从学习里拆出来）。下标与内核 `srs_stat_reviews.kind` 相同。
enum SrsStatReviewKind { newCard, learn, young, mature, relearn, filtered }

/// 统计中心「复习」分区的时间范围（与 Anki 统计页同一组；`name` 即内核请求的 `range`）。
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

/// 桶的粒度：≤ 92 天逐日，≤ 400 天逐周（最新一周恒完整），更长按自然月（内核切桶）。
enum SrsBucketUnit { day, week, month }

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

/// RWKV 牌组的复习卡此刻的情况（[SrsStatsReport.rwkvNow]）：全是测量，不是预测。RWKV 不知道一张卡哪天到期
/// （每答一题模型状态都在变），所以这些卡不进 [SrsFutureDue]。
class SrsRwkvNow {
  const SrsRwkvNow({
    required this.total,
    required this.due,
    required this.near,
    required this.dailyAverage,
  });

  /// 按 R 排队的复习卡（未暂停、归 Fushi 排程）。
  final int total;

  /// 此刻 R ≤ 所在牌组目标保留率：现在就会出（与出卡同一口径）。
  final int due;

  /// R 高出目标保留率不到 [nearMargin]：接下来最先出的卡。
  final int near;

  /// 过去 30 天（含今天）这些卡每天实际复习的张数。
  final double dailyAverage;

  static const double nearMargin = 0.05;
}

/// 未来到期预测。
class SrsFutureDue {
  const SrsFutureDue({
    required this.overdue,
    required this.perDay,
    required this.youngPerDay,
    required this.dailyLoad,
    this.byRecall = 0,
    this.unit = SrsBucketUnit.day,
    this.buckets = const <SrsFutureBucket>[],
  });

  /// 不计在内的复习卡：按 RWKV-Instant 排队，没有有意义的到期日。
  final int byRecall;

  /// 逾期（到期日早于今天）的复习卡数。
  final int overdue;

  /// 下标 0 = 今天、1 = 明天…的到期数（今天含学习中的卡）。
  final List<int> perDay;

  /// [perDay] 中年轻卡与学习卡的部分（其余为成熟卡）。
  final List<int> youngPerDay;

  /// 每日平均负担（Anki「Daily load」：Σ 1 / 间隔，复习卡 + 学习卡按 1）。
  final double dailyLoad;

  /// [perDay] 按看的天数切好的桶（图表用）。
  final SrsBucketUnit unit;
  final List<SrsFutureBucket> buckets;

  int get total => perDay.fold<int>(0, (int a, int b) => a + b);
  int get dueTomorrow => perDay.length > 1 ? perDay[1] : 0;
  int get dueToday => perDay.isEmpty ? 0 : perDay[0];

  /// 范围内日均（不含逾期）。
  double get averagePerDay => perDay.isEmpty ? 0 : total / perDay.length;
}

/// 未来到期的一个桶：[all] 张，其中 [young] 张是年轻卡与学习卡。
class SrsFutureBucket {
  const SrsFutureBucket(this.bucket, this.all, this.young);

  final SrsDayBucket bucket;
  final int all;
  final int young;
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
  const SrsReviewBucket(this.bucket, this.counts, this.durations);

  final SrsDayBucket bucket;
  final Map<SrsStatReviewKind, int> counts;
  final Map<SrsStatReviewKind, int> durations;

  int get totalCount => counts.values.fold<int>(0, (int a, int b) => a + b);
  int get totalMs => durations.values.fold<int>(0, (int a, int b) => a + b);
}

/// 一段日子内的复习合计。
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

/// 一个时间窗（[SrsStatsWindow.since]）的保留率与复习合计。
class SrsStatsWindowResult {
  const SrsStatsWindowResult(this.retention, this.totals);

  final SrsRetention retention;
  final SrsReviewTotals totals;
}

/// 请求的一个时间窗：今天往前第 [from] 天（null = 有数据的最早一天）到往前第 [to] 天，两端都含。
class SrsStatsWindow {
  const SrsStatsWindow(this.from, [this.to = 0]);

  /// 有数据的最早一天到今天。
  const SrsStatsWindow.all() : from = null, to = 0;

  /// 最近 [days] 天（含今天）。
  const SrsStatsWindow.last(int days) : from = days - 1, to = 0;

  final int? from;
  final int to;

  List<Object?> toJson() => <Object?>[from, to];
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

/// 一个范围 + 一个牌组子集的全部统计（内核 `stats_report` 的结果）。
class SrsStatsReport {
  SrsStatsReport._({
    required this.range,
    required this.today,
    required this.nowMs,
    required this.isEmpty,
    required this.earliestDay,
    required this.firstDay,
    required this.retrievabilityAvailable,
    required this.todayStats,
    required this.streak,
    required this.countsByDay,
    required this.future,
    required this.furthestDueOffset,
    required this.rwkvNow,
    required this.hasDueDateCards,
    required this.reviewUnit,
    required this.reviewBuckets,
    required this.matureCounts,
    required this.addedCounts,
    required this.cardCounts,
    required this.intervalHistogram,
    required this.stabilityHistogram,
    required this.difficultyHistogram,
    required this.retrievabilityHistogram,
    required this.hourly,
    required this.buttons,
    required this.windows,
    required this.desiredRetention,
    required this.sources,
    required this.todayByDeck,
    required this.learningDueAts,
    required this.reviewsNextDay,
  });

  /// 解内核交回的 JSON。
  factory SrsStatsReport.fromJson(
    Map<String, Object?> j, {
    required SrsStatsRange range,
    required int nowMs,
  }) {
    List<int> ints(Object? v) => <int>[
      for (final Object? x in v! as List) x! as int,
    ];
    double? dbl(Object? v) => (v as num?)?.toDouble();
    Map<SrsStatReviewKind, int> kinds(Object? v) {
      final List<int> xs = ints(v);
      return <SrsStatReviewKind, int>{
        for (int i = 0; i < xs.length; i++)
          if (xs[i] != 0) SrsStatReviewKind.values[i]: xs[i],
      };
    }

    SrsBucketUnit unit(Object? v) => SrsBucketUnit.values.byName(v! as String);
    SrsHistogram hist(Object? v) {
      final Map<String, Object?> h = (v! as Map).cast<String, Object?>();
      return SrsHistogram(
        bins: <SrsHistogramBin>[
          for (final List<Object?> b
              in (h['bins']! as List).cast<List<Object?>>())
            SrsHistogramBin(dbl(b[0])!, dbl(b[1])!, b[2]! as int),
        ],
        total: h['total']! as int,
        mean: dbl(h['mean']),
        median: dbl(h['median']),
        openEnded: h['openEnded']! as bool,
        sum: dbl(h['sum'])!,
      );
    }

    final List<Object?> today = j['todayStats']! as List;
    final List<int> streak = ints(j['streak']);
    final Map<String, Object?> future = (j['future']! as Map)
        .cast<String, Object?>();
    final Object? rwkv = j['rwkvNow'];
    final Map<String, Object?> reviews = (j['reviews']! as Map)
        .cast<String, Object?>();
    final List<int> cc = ints(j['cardCounts']);
    final Map<String, Object?> hists = (j['hist']! as Map)
        .cast<String, Object?>();
    final List<Object?> hourly = j['hourly']! as List;
    final List<Object?> buttons = j['buttons']! as List;
    return SrsStatsReport._(
      range: range,
      today: j['today']! as int,
      nowMs: nowMs,
      isEmpty: j['empty']! as bool,
      earliestDay: j['earliestDay']! as int,
      firstDay: j['firstDay']! as int,
      retrievabilityAvailable: j['retrievabilityAvailable']! as bool,
      todayStats: SrsTodayStats(
        count: today[0]! as int,
        durationMs: today[1]! as int,
        ratings: ints(today[2]),
        byKind: kinds(today[3]),
        early: today[4]! as int,
        matureCorrect: today[5]! as int,
        matureTotal: today[6]! as int,
      ),
      streak: SrsStreak(current: streak[0], longest: streak[1]),
      countsByDay: <int, int>{
        for (final List<Object?> e
            in (j['countsByDay']! as List).cast<List<Object?>>())
          e[0]! as int: e[1]! as int,
      },
      future: SrsFutureDue(
        overdue: future['overdue']! as int,
        byRecall: future['byRecall']! as int,
        dailyLoad: dbl(future['load'])!,
        perDay: ints(future['perDay']),
        youngPerDay: ints(future['youngPerDay']),
        unit: unit(future['unit']),
        buckets: <SrsFutureBucket>[
          for (final List<Object?> b
              in (future['buckets']! as List).cast<List<Object?>>())
            SrsFutureBucket(
              SrsDayBucket(b[0]! as int, b[1]! as int),
              b[2]! as int,
              b[3]! as int,
            ),
        ],
      ),
      furthestDueOffset: j['furthestDue']! as int,
      rwkvNow: rwkv is List
          ? SrsRwkvNow(
              total: rwkv[0]! as int,
              due: rwkv[1]! as int,
              near: rwkv[2]! as int,
              dailyAverage: dbl(rwkv[3])!,
            )
          : null,
      hasDueDateCards: j['hasDueDateCards']! as bool,
      reviewUnit: unit(reviews['unit']),
      reviewBuckets: <SrsReviewBucket>[
        for (final List<Object?> b
            in (reviews['buckets']! as List).cast<List<Object?>>())
          SrsReviewBucket(
            SrsDayBucket(b[0]! as int, b[1]! as int),
            kinds(b[2]),
            kinds(b[3]),
          ),
      ],
      matureCounts: ints(j['matureAt']),
      addedCounts: ints(j['added']),
      cardCounts: SrsCardCounts(
        newCards: cc[0],
        learning: cc[1],
        relearning: cc[2],
        young: cc[3],
        mature: cc[4],
        suspended: cc[5],
        buried: cc[6],
      ),
      intervalHistogram: hist(hists['interval']),
      stabilityHistogram: hist(hists['stability']),
      difficultyHistogram: hist(hists['difficulty']),
      retrievabilityHistogram: hist(hists['retrievability']),
      hourly: SrsHourly(counts: ints(hourly[0]), correct: ints(hourly[1])),
      buttons: SrsButtons(
        learning: SrsButtonGroup(ints(buttons[0])),
        young: SrsButtonGroup(ints(buttons[1])),
        mature: SrsButtonGroup(ints(buttons[2])),
      ),
      windows: <String, SrsStatsWindowResult>{
        for (final MapEntry<String, Object?> e
            in ((j['windows'] as Map?) ?? const <String, Object?>{})
                .cast<String, Object?>()
                .entries)
          e.key: () {
            final List<int> w = ints(e.value);
            return SrsStatsWindowResult(
              SrsRetention(
                youngCorrect: w[0],
                youngTotal: w[1],
                matureCorrect: w[2],
                matureTotal: w[3],
              ),
              SrsReviewTotals(
                count: w[4],
                durationMs: w[5],
                daysStudied: w[6],
                days: w[7],
              ),
            );
          }(),
      },
      desiredRetention: dbl(j['desiredRetention']),
      sources: <SrsSourceShare>[
        for (final List<Object?> s
            in (j['sources']! as List).cast<List<Object?>>())
          SrsSourceShare(
            kind: s[0]! as String,
            title: s[1]! as String,
            notes: s[2]! as int,
          ),
      ],
      todayByDeck: (j['todayByDeck']! as Map).cast<String, int>(),
      learningDueAts: ints(j['learningDueAts']),
      reviewsNextDay: j['reviewsNextDay']! as int,
    );
  }

  /// 请求的范围（[firstDay]..[today]）。
  final SrsStatsRange range;

  /// 今天的 SRS 日序号（[SrsDayContext.dayIndexOf]）。
  final int today;
  final int nowMs;

  /// 这个子集里既没有卡也没有复习。
  final bool isEmpty;

  /// 有数据的最早一天（复习或加卡）；都没有时为今天。
  final int earliestDay;

  /// 范围的第一天（末天恒为今天）。
  final int firstDay;

  /// 可提取度能不能算（排程内核可用）。
  final bool retrievabilityAvailable;

  final SrsTodayStats todayStats;
  final SrsStreak streak;

  /// 日序号 → 复习数（全部日子，不限范围）。
  final Map<int, int> countsByDay;

  /// 往后若干天（含今天）的到期预测：只算 Fushi 排程、未暂停的卡；搁置的卡照常按到期日计。
  final SrsFutureDue future;

  /// 「全部」范围下未来到期看多远：最晚到期日（夹在 30..3650 天）。
  final int furthestDueOffset;

  /// RWKV 牌组复习卡此刻的情况；子集里没有按 R 排队的复习卡时为 null。
  final SrsRwkvNow? rwkvNow;

  /// 有没有按到期日排队、会进 [future] 的卡（学习中的卡、FSRS 牌组的复习卡）。
  final bool hasDueDateCards;

  /// 范围内的复习量 / 用时桶。
  final SrsBucketUnit reviewUnit;
  final List<SrsReviewBucket> reviewBuckets;

  /// 每个 [reviewBuckets] 桶末尾的成熟卡数（成熟卡增长曲线）。
  final List<int> matureCounts;

  /// 每个 [reviewBuckets] 桶里新加的卡数。
  final List<int> addedCounts;

  final SrsCardCounts cardCounts;

  /// 复习卡的当前间隔（天）。
  final SrsHistogram intervalHistogram;

  /// 稳定性（天）。
  final SrsHistogram stabilityHistogram;

  /// 难度（换算成 0..1：D 1..10 → (D − 1) / 9，与 Anki 显示的百分比一致）。
  final SrsHistogram difficultyHistogram;

  /// 可提取度（0..1）。
  final SrsHistogram retrievabilityHistogram;

  /// 范围内按小时 / 评分按钮。
  final SrsHourly hourly;
  final SrsButtons buttons;

  /// 请求的时间窗（名字 → 结果）。
  final Map<String, SrsStatsWindowResult> windows;

  /// 复习卡目标保留率的平均（期望保留率；按卡平均，没有复习卡时取全部卡）。
  final double? desiredRetention;

  /// 制卡来源（按笔记计）：同种类同标题归一组，按笔记数倒序。
  final List<SrsSourceShare> sources;

  /// 卡片直接所在的牌组 → 今天的复习次数（首页牌组行）。
  final Map<String, int> todayByDeck;

  /// 学习 / 重学卡（Fushi 排程、没暂停、今天没搁置）此刻之后的精确到期时刻（桌面小组件）。
  final List<int> learningDueAts;

  /// 明天到期、按到期日排队的复习卡数（同上口径，桌面小组件）。
  final int reviewsNextDay;

  /// 范围内的复习合计（[SrsStatsLoad] 恒请求的 `range` 窗）。
  SrsReviewTotals get rangeTotals => windows[kSrsStatsRangeWindow]!.totals;

  /// 范围内的真实保留率（同上）。
  SrsRetention get rangeRetention => windows[kSrsStatsRangeWindow]!.retention;
}

/// 每次请求都带上的时间窗名：范围的第一天到今天。
const String kSrsStatsRangeWindow = 'range';

/// 统计页「未来到期」看几天（含今天）；null = 最晚到期日（「全部」）。
int? srsStatsFutureDays(SrsStatsRange range) => switch (range) {
  SrsStatsRange.month => 31,
  SrsStatsRange.threeMonths => 91,
  SrsStatsRange.year => 366,
  SrsStatsRange.all => null,
};

/// 范围的第一天往前数几天（「全部」= null，由内核取有数据的最早一天）。
int? srsStatsRangeBack(SrsStatsRange range) => switch (range) {
  SrsStatsRange.month => 29,
  SrsStatsRange.threeMonths => 89,
  SrsStatsRange.year => 364,
  SrsStatsRange.all => null,
};
