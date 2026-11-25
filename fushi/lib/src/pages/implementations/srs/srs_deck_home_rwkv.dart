part of 'srs_deck_list_page.dart';

/// 复习首页的「RWKV 此刻」：RWKV 排队的复习卡此刻低于 / 接近 / 远高于目标线的张数，停在这里的话 1 小时 /
/// 3 小时后、今天结束前会新增多少张（[SrsRwkvNow.ahead]），以及此刻回忆率的分布（[SrsRwkvNow.recallBins]）。
///
/// RWKV 不知道一张卡哪天到期，这些卡不进「未来 7 天」；纯 RWKV 的范围不画那张空图，改画这一块
/// （[srsHomeShowsForecast]）。全是统计内核（`stats_report` 的 `rwkvNow`）算好的数，这里只排版。
///
/// 第一项是「低于目标」，不叫「到期」：它是此刻回忆率的测量，和牌组列表上「N 到期」（今天的出卡队列）不是一个
/// 口径——队列还会按「每天最少复习数」从高于目标的卡里补足、按同日间隔与每日复习上限暂缓一部分（Rust
/// `study.rs` `instant_eligible` / `count_tree`）。[queued] 给了且与低于目标的张数不同时，在下面写明今天排队
/// 多少张、差在哪（应用内反馈 TcVEYa3z46，BUG-5170）。
class _SrsRwkvNowView extends StatelessWidget {
  const _SrsRwkvNowView({
    super.key,
    required this.now,
    required this.target,
    this.queued,
    this.poster,
  });

  final SrsRwkvNow now;

  /// 目标保留率（牌组设置的平均）：分布图按它分色；null = 不分色。
  final double? target;

  /// 头部「N 到期」里这些 RWKV 卡今天排队的张数（[srsHomeRwkvQueued]）；头部还数了别的卡、或 RWKV 还没
  /// 准备好时为 null，不写对账说明。
  final int? queued;

  /// 画在海报色块里时的取色（文字配色随块）；null = 普通卡片。
  final FushiCoverBlockColors? poster;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsStatColors colors = SrsStatColors.of(context);
    final FushiCoverBlockColors? block = poster;
    final TextStyle base =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final Color muted = block != null
        ? block.onContainer.withValues(alpha: 0.85)
        : isGlassDesign(context)
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final TextStyle caption = block != null
        ? FushiPosterText.caption.on(base).copyWith(color: muted)
        : context.fushiType.bodySmall.copyWith(color: muted);
    final TextStyle figure = context.fushiType.titleMediumEmphasized.copyWith(
      height: 1,
      color: block?.onContainer,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    Widget count(String key, Color dot, int n, String label) => Semantics(
      key: ValueKey<String>('srs-home-rwkv-$key'),
      label: '$label $n',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            child: const SizedBox.square(dimension: 8),
          ),
          Text('$n', style: figure),
          Text(label, style: caption),
        ],
      ),
    );

    final List<int>? ahead = now.ahead;
    final double? goal = target;
    final int? queue = queued;
    final bool chart = now.recallBins.any((int n) => n > 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        Wrap(
          spacing: tokens.spacing.gap * 1.5,
          runSpacing: tokens.spacing.gap / 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            count(
              'below',
              colors.again,
              now.due,
              t.srs_stats_rwkv_now_below_target,
            ),
            count('near', colors.hard, now.near, t.srs_stats_rwkv_now_near),
            count('safe', colors.good, now.safe, t.srs_home_rwkv_safe),
          ],
        ),
        if (queue != null && queue != now.due)
          Text(
            t.srs_home_rwkv_queue_note(n: queue),
            key: const ValueKey<String>('srs-home-rwkv-queue-note'),
            style: caption,
          ),
        if (ahead != null && ahead.length >= SrsRwkvHorizon.values.length)
          Text(
            t.srs_home_rwkv_ahead(
              h1: ahead[SrsRwkvHorizon.oneHour.index],
              h3: ahead[SrsRwkvHorizon.threeHours.index],
              day: ahead[SrsRwkvHorizon.dayEnd.index],
            ),
            key: const ValueKey<String>('srs-home-rwkv-ahead'),
            style: caption,
          ),
        if (chart) ...<Widget>[
          Row(
            spacing: tokens.spacing.gap,
            children: <Widget>[
              Expanded(
                child: Text(
                  t.srs_home_rwkv_recall_chart,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: caption,
                ),
              ),
              if (goal != null)
                Text(
                  t.srs_home_rwkv_target(p: _srsPercent(goal)),
                  maxLines: 1,
                  style: caption,
                ),
            ],
          ),
          _SrsRecallChart(bins: now.recallBins, target: goal),
        ],
      ],
    );
  }
}

/// 此刻回忆率直方图：每格一个区间（内核给 20 格、每格 5%），从最低有卡的那格（最多再往左补到目标线所在格的
/// 前一格，让目标线两侧都看得见）画到 100%。按目标线分三色：低于目标 / 接近目标（高出不到
/// [SrsRwkvNow.nearMargin]）/ 远高于目标，与上方三个计数同色同序。各牌组目标不同时按平均目标分色，只是示意。
class _SrsRecallChart extends StatelessWidget {
  const _SrsRecallChart({required this.bins, required this.target});

  static const double height = 96;

  final List<int> bins;
  final double? target;

  @override
  Widget build(BuildContext context) {
    final SrsStatColors colors = SrsStatColors.of(context);
    final List<SrsBarDatum> bars = srsHomeRecallBars(bins, target);
    if (bars.isEmpty) return const SizedBox.shrink();
    return SrsBarChart(
      key: const ValueKey<String>('srs-home-rwkv-recall-chart'),
      height: height,
      showTotalInTooltip: false,
      bars: bars,
      series: <SrsChartSeries>[
        SrsChartSeries(t.srs_stats_rwkv_now_below_target, colors.again),
        SrsChartSeries(t.srs_stats_rwkv_now_near, colors.hard),
        SrsChartSeries(t.srs_home_rwkv_safe, colors.good),
      ],
      scaleOf: statCountAxisScale,
      valueText: (int v) => '$v',
    );
  }
}

/// 头部「N 到期」（[SrsDeckSummary.reviewCount] / [SrsDeckListData.todayReview]）里有多少是「RWKV 此刻」这些卡
/// 今天排队的张数，给面板写对账说明用。头部只在范围里没有按到期日排队的卡（[hasDueDateCards] 为 false：
/// 没有 FSRS 复习卡、学习中的卡）时才全是 RWKV 卡；RWKV 还没准备好（[rwkvPending]）时头部的数不全。这两种
/// 情况返回 null，不写说明，免得拿不同范围的数硬对。
@visibleForTesting
int? srsHomeRwkvQueued({
  required int reviewCount,
  required bool hasDueDateCards,
  required bool rwkvPending,
}) => hasDueDateCards || rwkvPending ? null : reviewCount;

/// [_SrsRecallChart] 的柱：每格三个值（低于目标 / 接近 / 远高于，只有所属那一段非零）。没有卡时为空。
@visibleForTesting
List<SrsBarDatum> srsHomeRecallBars(List<int> bins, double? target) {
  final int n = bins.length;
  final int first = bins.indexWhere((int c) => c > 0);
  if (n == 0 || first < 0) return const <SrsBarDatum>[];
  final int start = target == null
      ? first
      : math.min(first, math.max(0, (target * n).floor() - 1));
  int zoneOf(int i) {
    if (target == null) return 2;
    final double lower = i / n;
    if (lower + 1e-9 < target) return 0;
    if (lower + 1e-9 < target + SrsRwkvNow.nearMargin) return 1;
    return 2;
  }

  String pct(int i) => '${(i * 100 / n).round()}%';
  return <SrsBarDatum>[
    for (int i = start; i < n; i++)
      SrsBarDatum(
        label: pct(i),
        title: '${pct(i)}–${pct(i + 1)}',
        values: <int>[for (int z = 0; z < 3; z++) zoneOf(i) == z ? bins[i] : 0],
      ),
  ];
}

/// 全库的「RWKV 此刻」卡（与「未来 7 天」并列的统计卡；只在库里有 RWKV 排队的复习卡时出现）。
class _SrsRwkvNowCard extends StatelessWidget {
  const _SrsRwkvNowCard({
    super.key,
    required this.stats,
    required this.now,
    this.queued,
  });

  final SrsHomeStats stats;
  final SrsRwkvNow now;

  /// 全库头部「N 到期」里这些卡今天排队的张数（[srsHomeRwkvQueued]）。
  final int? queued;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (shellRedesignActive(context)) {
      final FushiCoverBlockColors colors = fushiPosterColors(
        context,
        fushiPosterHue('srs-home-rwkv-now'),
      );
      return FushiPosterBlock(
        watermark: '',
        colors: colors,
        hoverEnabled: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: <Widget>[
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiPosterChip(
                colors: colors,
                icon: FushiIcons.trendingUp,
                label: t.srs_stats_rwkv_now_title,
              ),
            ),
            _SrsRwkvNowView(
              now: now,
              target: stats.desiredRetention,
              queued: queued,
              poster: colors,
            ),
          ],
        ),
      );
    }
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => FushiCard(
        pressScale: false,
        stateLayer: false,
        padding: EdgeInsets.all(tokens.spacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Text(
              t.srs_stats_rwkv_now_title,
              style: context.fushiType.titleSmallEmphasized,
            ),
            _SrsRwkvNowView(
              now: now,
              target: stats.desiredRetention,
              queued: queued,
            ),
          ],
        ),
      ),
    );
  }
}

/// 首页统计卡里热力图之后的那几张：按到期日排队的卡有预测时画「未来 7 天」，有 RWKV 排队的复习卡时画
/// 「RWKV 此刻」；纯 RWKV 的库只有后者（到期日预测对它们恒为空，[srsHomeShowsForecast]）。[data] 是全库牌组
/// 计数，给「RWKV 此刻」和头部「N 到期」对账（[srsHomeRwkvQueued]）。
List<Widget> _srsHomeDueCards(SrsHomeStats stats, SrsDeckListData data) =>
    <Widget>[
      if (stats.showsForecast)
        _SrsForecastCard(
          key: const ValueKey<String>('srs-home-forecast'),
          stats: stats,
        ),
      if (stats.rwkvNow case final SrsRwkvNow now)
        _SrsRwkvNowCard(
          key: const ValueKey<String>('srs-home-rwkv-now'),
          stats: stats,
          now: now,
          queued: srsHomeRwkvQueued(
            reviewCount: data.todayReview,
            hasDueDateCards: stats.hasDueDateCards,
            rwkvPending: data.rwkvPending,
          ),
        ),
    ];
