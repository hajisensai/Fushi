part of '../srs_deck_list_page.dart';

// Apple（Cupertino）复习首页的摘要卡（方案 A：今日 / 选中牌组 / 连续天数三张卡 +
// 全库预测 / RWKV 此刻）。卡面一律 inset grouped 的 secondaryGroupedBackground 实色面，
// 背景中性（牌组色只在小图标上，拍板点 8）；数字 SF Rounded（[appleSrsRounded]）；
// 图表是 Swift Charts 式（[AppleSrsBarChart] / [AppleSrsRing] / [AppleSrsHeatmap]）。
// key 与 M3E 同名（srs-home-today / srs-home-detail-<id> / srs-home-heatmap …），测试与
// 焦点驱动两套共用。

/// 卡片标题（iOS 17 / macOS 13 semibold）。
TextStyle _appleSrsHeadline(BuildContext context) {
  final FushiAppleMetrics m = FushiAppleMetrics.of(context);
  return m
      .titleStyle(context)
      .copyWith(
        fontSize: (m.desktop ? 13 : 17) * m.scale,
        fontWeight: FontWeight.w600,
      );
}

/// 大号圆体数字（Activity / Fitness 摘要卡式）。
TextStyle _appleSrsFigure(BuildContext context, double iosSize) {
  final FushiAppleMetrics m = FushiAppleMetrics.of(context);
  return appleSrsRounded(
    context,
    m
        .titleStyle(context)
        .copyWith(
          fontSize: (m.desktop ? iosSize * 0.82 : iosSize) * m.scale,
          fontWeight: FontWeight.w700,
          height: 1.05,
        ),
  );
}

/// 摘要卡：分组面 + 内边距 + 标题行（彩色单色图标 + 标题）。
class _AppleSrsCard extends StatelessWidget {
  const _AppleSrsCard({
    required this.child,
    this.title,
    this.icon,
    this.iconColor,
  });

  final Widget child;
  final String? title;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double s = m.scale;
    final String? heading = title;
    final IconData? glyph = icon;
    // 卡本身不可点（按钮在卡里）：不随悬停抬升（效果图「只有整卡可点的才抬升」）。
    return Builder(
      builder: (BuildContext context) => FushiAppleGroupSurface(
        child: Padding(
          padding: EdgeInsets.all((m.desktop ? 14 : 16) * s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: (m.desktop ? 10 : 12) * s,
            children: <Widget>[
              if (heading != null)
                Row(
                  spacing: 6 * s,
                  children: <Widget>[
                    if (glyph != null)
                      FushiIcon(
                        glyph,
                        size: (m.desktop ? 15 : 18) * s,
                        color: iconColor ?? appleColorsOf(context).accent,
                      ),
                    Expanded(
                      child: Text(
                        heading,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _appleSrsHeadline(context),
                      ),
                    ),
                  ],
                ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// 图例 / 计数里的一个色点 + 文案。
class _AppleSrsLegendDot extends StatelessWidget {
  const _AppleSrsLegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6 * m.scale,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: SizedBox.square(dimension: 8 * m.scale),
        ),
        Flexible(child: Text(label, style: m.footnoteStyle(context))),
      ],
    );
  }
}

/// 「今日」卡（拍板点 9 / 11）：今天还剩的张数（大号圆体）+ 单环完成度 + 三色图例 +
/// 约几分钟 / 已完成 / 连续天数 + 近 7 天复习柱（虚线日均）；[showStart] 时（iOS 窄屏，
/// 页头没有主按钮）卡底是整宽 prominent「开始复习」。
class _AppleSrsTodayCard extends StatelessWidget {
  const _AppleSrsTodayCard({
    super.key,
    required this.data,
    required this.stats,
    required this.showStart,
    required this.onReview,
  });

  final SrsDeckListData data;
  final SrsHomeStats? stats;
  final bool showStart;
  final void Function(SrsDeckSummary deck) onReview;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final AppleSrsSystemColors system = AppleSrsSystemColors.of(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double s = m.scale;
    final int remaining = data.todayNew + data.todayLearn + data.todayReview;
    final bool pending = data.rwkvPending;
    final bool allDone = remaining == 0 && !pending;
    final SrsHomeStats? st = stats;
    final int? minutes = st?.minutesFor(remaining);
    final double progress =
        st?.progressWith(remaining) ?? (allDone ? 1.0 : 0.0);
    final SrsDeckSummary? go = data.firstRootWithWork;
    final int rootsWithWork = data.decks
        .where((SrsDeckSummary d) => d.parentId == null && _srsDeckHasWork(d))
        .length;
    final List<String> facts = <String>[
      if (minutes != null && !allDone) t.srs_home_minutes(n: minutes),
      if (st != null && st.doneToday > 0)
        t.srs_home_done_count(n: st.doneToday),
      if (st != null && st.streak > 0) t.srs_home_streak(n: st.streak),
      if (!showStart && go != null && rootsWithWork > 1)
        t.srs_home_start_from(name: go.deck.name),
    ];
    final Widget figure = remaining > 0
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            spacing: 4 * s,
            children: <Widget>[
              Text(
                '$remaining',
                key: const ValueKey<String>('srs-home-today-remaining'),
                style: _appleSrsFigure(context, 40),
              ),
              Flexible(
                child: Text(
                  t.widget_settings_unit_cards,
                  style: m.subtitleStyle(context),
                ),
              ),
            ],
          )
        : Row(
            spacing: 8 * s,
            children: <Widget>[
              if (allDone)
                FushiIcon(FushiIcons.check, size: 24 * s, color: system.green),
              Flexible(
                child: Text(
                  allDone ? t.srs_home_all_done : t.srs_home_meta_pending,
                  key: const ValueKey<String>('srs-home-today-title'),
                  style: _appleSrsFigure(context, 22),
                ),
              ),
            ],
          );
    final Widget legend = Wrap(
      spacing: 12 * s,
      runSpacing: 4 * s,
      children: <Widget>[
        _AppleSrsLegendDot(
          color: system.green,
          label: pending && data.todayReview == 0
              ? t.srs_home_meta_pending
              : t.srs_home_meta_due(n: data.todayReview),
        ),
        _AppleSrsLegendDot(
          color: system.red,
          label: t.srs_home_meta_learning(n: data.todayLearn),
        ),
        _AppleSrsLegendDot(
          color: system.blue,
          label: t.srs_home_meta_new(n: data.todayNew),
        ),
      ],
    );
    final double ring = (m.desktop ? 72 : 84) * s;
    final Widget summary = Row(
      spacing: 16 * s,
      children: <Widget>[
        Semantics(
          label: '${t.stat_today} ${_srsPercent(progress)}',
          excludeSemantics: true,
          child: AppleSrsRing(
            key: const ValueKey<String>('srs-home-today-ring'),
            value: progress,
            color: apple.accent,
            size: ring,
            stroke: ring * 0.14,
            child: Text(
              _srsPercent(progress),
              style: appleSrsRounded(
                context,
                m
                    .footnoteStyle(context)
                    .copyWith(color: apple.label, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 6 * s,
            children: <Widget>[
              figure,
              if (facts.isNotEmpty)
                Text(facts.join(' · '), style: m.footnoteStyle(context)),
              if (!allDone) legend,
            ],
          ),
        ),
      ],
    );
    final Widget? recent = st == null ? null : _recent(context, st);
    final Widget? start = showStart && go != null
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: 6 * s,
            children: <Widget>[
              FushiPressScale(
                child: KeyedSubtree(
                  key: const ValueKey<String>('srs-home-start'),
                  child: fushiAppleBorderedButton(
                    context,
                    prominent: true,
                    size: FushiButtonSize.m,
                    onPressed: () => onReview(go),
                    icon: const FushiIcon(FushiIcons.play),
                    label: Text(t.srs_home_start),
                  ),
                ),
              ),
              if (rootsWithWork > 1)
                Text(
                  t.srs_home_start_from(name: go.deck.name),
                  textAlign: TextAlign.center,
                  style: m.footnoteStyle(context),
                ),
            ],
          )
        : null;
    return _AppleSrsCard(
      title: t.stat_today,
      icon: FushiIcons.calendar,
      iconColor: system.red,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 14 * s,
        children: <Widget>[summary, ?recent, ?start],
      ),
    );
  }

  /// 近 7 天复习柱：今天实色、其余淡；虚线是日均。
  Widget _recent(BuildContext context, SrsHomeStats st) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final List<int> days = st.recentCounts();
    if (days.isEmpty) return const SizedBox.shrink();
    final int last = days.length - 1;
    final int sum = days.fold(0, (int a, int b) => a + b);
    final double average = sum / days.length;
    return Column(
      key: const ValueKey<String>('srs-home-today-recent'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 6 * m.scale,
      children: <Widget>[
        Text(
          '${t.srs_stats_period_week} · ${t.srs_stats_reviews_count(n: sum)}',
          style: m.footnoteStyle(context),
        ),
        AppleSrsBarChart(
          height: 84 * m.scale,
          color: AppleSrsSystemColors.of(context).blue,
          highlightLast: true,
          average: average,
          averageLabel: '${t.srs_stats_avg_per_day} ${average.round()}',
          semanticLabel:
              '${t.srs_stats_period_week} ${t.srs_stats_reviews_count(n: sum)}',
          bars: <AppleSrsBar>[
            for (int i = 0; i < days.length; i++)
              AppleSrsBar(
                value: days[i],
                label: i == last
                    ? t.stat_today
                    : _srsHomeDate(st.today - last + i, DateFormat.E),
                title:
                    '${_srsHomeDate(st.today - last + i, DateFormat.MMMd)} · '
                    '${t.srs_stats_reviews_count(n: days[i])}',
              ),
          ],
        ),
      ],
    );
  }
}

/// 选中牌组卡（宽屏三卡的中间一张；手机详情页的首卡）：Reminders 式图标 + 名字 +
/// 张数构成、保持率、RWKV 此刻或未来 7 天到期，底部「复习此牌组」(prominent) +
/// 「浏览卡片」(bordered) + ⋯（牌组菜单，与行菜单同项同序）。
class _AppleSrsDeckCard extends StatelessWidget {
  const _AppleSrsDeckCard({
    super.key,
    required this.deck,
    required this.detail,
    required this.today,
    required this.isDefault,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onReview,
    required this.onAction,
  });

  final SrsDeckSummary deck;
  final SrsHomeDeckDetail? detail;
  final int? today;
  final bool isDefault;
  final bool canMoveUp;
  final bool canMoveDown;
  final void Function(SrsDeckSummary deck) onReview;
  final void Function(SrsDeckSummary deck, _DeckAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final AppleSrsSystemColors system = AppleSrsSystemColors.of(context);
    final double s = m.scale;
    final SrsHomeDeckDetail? d = detail;
    final bool work = _srsDeckHasWork(deck);
    final Widget header = Row(
      spacing: 12 * s,
      children: <Widget>[
        _AppleDeckIcon(deck: deck, size: (m.desktop ? 30 : 38) * s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiTooltip(
                message: deck.fullName,
                child: Text(
                  deck.deck.name,
                  key: ValueKey<String>('srs-home-detail-name-${deck.deck.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: _appleSrsHeadline(context),
                ),
              ),
              Text(_srsDeckMeta(deck), style: m.footnoteStyle(context)),
              Text(
                d == null
                    ? t.srs_home_deck_cards(n: deck.totalCards)
                    : t.srs_home_deck_card_counts(
                        n: deck.totalCards,
                        fresh: d.newCards,
                        mature: d.matureCards,
                      ),
                style: m.footnoteStyle(context),
              ),
            ],
          ),
        ),
      ],
    );
    final double? retention = d?.retention;
    final double? target = d?.desiredRetention;
    final Widget retentionBlock = Column(
      key: const ValueKey<String>('srs-home-detail-retention'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 2 * s,
      children: <Widget>[
        Text(t.srs_home_retention_title, style: m.footnoteStyle(context)),
        if (d == null)
          SizedBox(height: 28 * s)
        else if (retention == null)
          Text(t.srs_home_retention_none, style: m.subtitleStyle(context))
        else ...<Widget>[
          Text(
            _srsPercent(retention),
            style: _appleSrsFigure(context, 28).copyWith(color: system.green),
          ),
          Text(
            t.srs_home_retention_detail(
              target: target == null ? '—' : _srsPercent(target),
              n: d.reviewsRecent,
            ),
            style: m.footnoteStyle(context),
          ),
        ],
      ],
    );
    final SrsRwkvNow? now = d?.rwkvNow;
    final int? day = today;
    final List<int> forecast = d?.forecast ?? const <int>[];
    final bool showForecast =
        d != null && d.showsForecast && day != null && forecast.isNotEmpty;
    final Widget actions = Row(
      spacing: 8 * s,
      children: <Widget>[
        Flexible(
          child: FushiPressScale(
            child: KeyedSubtree(
              key: const ValueKey<String>('srs-home-detail-review'),
              child: fushiAppleBorderedButton(
                context,
                prominent: true,
                onPressed: work ? () => onReview(deck) : null,
                icon: const FushiIcon(FushiIcons.play),
                label: Text(t.srs_home_review_deck, maxLines: 1),
              ),
            ),
          ),
        ),
        Flexible(
          child: FushiPressScale(
            child: KeyedSubtree(
              key: const ValueKey<String>('srs-home-detail-browse'),
              child: fushiAppleBorderedButton(
                context,
                prominent: false,
                onPressed: () => onAction(deck, _DeckAction.browse),
                label: Text(t.srs_home_browse_cards, maxLines: 1),
              ),
            ),
          ),
        ),
        Builder(
          builder: (BuildContext anchor) => FushiIconButton(
            key: const ValueKey<String>('srs-home-detail-options'),
            icon: FushiIcons.more,
            tooltip: t.srs_home_deck_options,
            onTap: () => unawaited(
              _showDeckMenu(
                anchor,
                deck: deck,
                isDefault: isDefault,
                canMoveUp: canMoveUp,
                canMoveDown: canMoveDown,
                onAction: onAction,
              ),
            ),
          ),
        ),
      ],
    );
    return _AppleSrsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 14 * s,
        children: <Widget>[
          header,
          retentionBlock,
          if (now != null)
            KeyedSubtree(
              key: const ValueKey<String>('srs-home-detail-rwkv'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: 6 * s,
                children: <Widget>[
                  Text(
                    t.srs_stats_rwkv_now_title,
                    style: m.footnoteStyle(context),
                  ),
                  _AppleSrsRwkvView(
                    now: now,
                    target: d?.desiredRetention,
                    queued: srsHomeRwkvQueued(
                      reviewCount: deck.reviewCount,
                      hasDueDateCards: d?.hasDueDateCards ?? true,
                      rwkvPending: deck.rwkvPending,
                    ),
                  ),
                ],
              ),
            ),
          if (showForecast)
            _AppleSrsForecastChart(forecast: forecast, today: day),
          actions,
        ],
      ),
    );
  }
}

/// 未来 7 天到期柱（标题行写「明天 N」）。
class _AppleSrsForecastChart extends StatelessWidget {
  const _AppleSrsForecastChart({required this.forecast, required this.today});

  final List<int> forecast;
  final int today;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 6 * m.scale,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.srs_home_forecast_title,
                style: m.footnoteStyle(context),
              ),
            ),
            if (forecast.length > 1)
              Text(
                t.srs_home_forecast_tomorrow(n: forecast[1]),
                style: m.footnoteStyle(context),
              ),
          ],
        ),
        AppleSrsBarChart(
          height: 84 * m.scale,
          color: AppleSrsSystemColors.of(context).green,
          semanticLabel: t.srs_home_forecast_title,
          bars: <AppleSrsBar>[
            for (int i = 0; i < forecast.length; i++)
              AppleSrsBar(
                value: forecast[i],
                label: _srsForecastLabel(today, i),
                title:
                    '${_srsForecastTitle(today, i)} · '
                    '${t.srs_home_deck_cards(n: forecast[i])}',
              ),
          ],
        ),
      ],
    );
  }
}

/// 「RWKV 此刻」（拍板点 4）：三档计数（低于目标 red / 接近 orange / 远高于 green）、
/// 「现在停下…」恒显示、今天队列的对账说明收进 ⓘ（点开 / 收起），回想概率直方图
/// 带「目标 90%」竖虚线。
class _AppleSrsRwkvView extends StatefulWidget {
  const _AppleSrsRwkvView({
    required this.now,
    required this.target,
    required this.queued,
  });

  final SrsRwkvNow now;
  final double? target;
  final int? queued;

  @override
  State<_AppleSrsRwkvView> createState() => _AppleSrsRwkvViewState();
}

class _AppleSrsRwkvViewState extends State<_AppleSrsRwkvView> {
  bool _queueOpen = false;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final AppleSrsSystemColors system = AppleSrsSystemColors.of(context);
    final double s = m.scale;
    final SrsRwkvNow now = widget.now;
    final double? goal = widget.target;
    final int? queue = widget.queued;
    final bool hasQueueNote = queue != null && queue != now.due;
    final TextStyle figure = _appleSrsFigure(context, 20);

    Widget count(String key, Color color, int n, String label) => Semantics(
      key: ValueKey<String>('srs-home-rwkv-$key'),
      label: '$label $n',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('$n', style: figure.copyWith(color: color)),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: m.footnoteStyle(context),
          ),
        ],
      ),
    );

    final List<int>? ahead = now.ahead;
    final List<SrsBarDatum> bars = srsHomeRecallBars(now.recallBins, goal);
    final List<Color> zones = <Color>[system.red, system.orange, system.green];
    final int n = now.recallBins.length;
    final int start = n - bars.length;
    final int labelEvery = math.max(1, (bars.length / 5).ceil());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 8 * s,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12 * s,
          children: <Widget>[
            Expanded(
              child: count(
                'below',
                system.red,
                now.due,
                t.srs_stats_rwkv_now_below_target,
              ),
            ),
            Expanded(
              child: count(
                'near',
                system.orange,
                now.near,
                t.srs_stats_rwkv_now_near,
              ),
            ),
            Expanded(
              child: count(
                'safe',
                system.green,
                now.safe,
                t.srs_home_rwkv_safe,
              ),
            ),
            if (hasQueueNote)
              FushiIconButton(
                key: const ValueKey<String>('srs-home-rwkv-queue-info'),
                icon: FushiIcons.info,
                tooltip: t.srs_home_rwkv_queue_info,
                selected: _queueOpen,
                onTap: () => setState(() => _queueOpen = !_queueOpen),
              ),
          ],
        ),
        if (hasQueueNote)
          FushiTreeReveal(
            visible: _queueOpen,
            child: Text(
              t.srs_home_rwkv_queue_note(n: queue),
              key: const ValueKey<String>('srs-home-rwkv-queue-note'),
              style: m.footnoteStyle(context),
            ),
          ),
        if (ahead != null && ahead.length >= SrsRwkvHorizon.values.length)
          Text(
            t.srs_home_rwkv_ahead(
              h1: ahead[SrsRwkvHorizon.oneHour.index],
              h3: ahead[SrsRwkvHorizon.threeHours.index],
              day: ahead[SrsRwkvHorizon.dayEnd.index],
            ),
            key: const ValueKey<String>('srs-home-rwkv-ahead'),
            style: m.footnoteStyle(context),
          ),
        if (bars.isNotEmpty) ...<Widget>[
          Text(t.srs_home_rwkv_recall_chart, style: m.footnoteStyle(context)),
          AppleSrsBarChart(
            key: const ValueKey<String>('srs-home-rwkv-recall-chart'),
            height: 96 * s,
            color: system.green,
            barWidthFactor: 0.8,
            edgeLabels: true,
            semanticLabel: t.srs_home_rwkv_recall_chart,
            ruleAt: goal == null || bars.isEmpty
                ? null
                : ((goal * n) - start) / bars.length,
            ruleLabel: goal == null
                ? null
                : t.srs_home_rwkv_target(p: _srsPercent(goal)),
            bars: <AppleSrsBar>[
              for (int i = 0; i < bars.length; i++)
                AppleSrsBar(
                  value: bars[i].values.fold<int>(0, (int a, int b) => a + b),
                  color:
                      zones[math.max(
                        0,
                        bars[i].values.indexWhere((int v) => v > 0),
                      )],
                  label: i % labelEvery == 0 ? bars[i].label : null,
                  title:
                      '${bars[i].title} · '
                      '${t.srs_home_deck_cards(n: bars[i].values.fold<int>(0, (int a, int b) => a + b))}',
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 「连续天数」卡（拍板点 5）：连续天数大号圆体 + 最长纪录、日历热力图（手机 16 周、
/// 宽屏 26 周）、[totals] 时底部三格累计（学习天数 / 复习次数 / 学习日均）。
class _AppleSrsStreakCard extends StatelessWidget {
  const _AppleSrsStreakCard({
    super.key,
    required this.stats,
    required this.weeks,
  });

  final SrsHomeStats stats;
  final int weeks;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final AppleSrsSystemColors system = AppleSrsSystemColors.of(context);
    final double s = m.scale;
    final NumberFormat number = NumberFormat.decimalPattern(
      LocaleSettings.currentLocale.languageTag,
    );
    final int studied = stats.studiedDays;
    final int total = stats.totalReviews;
    final List<(String, String)> items = <(String, String)>[
      (t.srs_stats_calendar_days_studied, t.srs_stats_days(n: studied)),
      (t.srs_stats_reviews_title, number.format(total)),
      (
        t.srs_stats_avg_studied_day,
        studied == 0 ? '—' : number.format((total / studied).round()),
      ),
    ];
    return _AppleSrsCard(
      title: t.stat_streak,
      icon: FushiIcons.streak,
      iconColor: system.orange,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 12 * s,
        children: <Widget>[
          Semantics(
            label: t.srs_home_streak_longest(
              n: stats.streak,
              m: stats.longestStreak,
            ),
            excludeSemantics: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              spacing: 4 * s,
              children: <Widget>[
                Text('${stats.streak}', style: _appleSrsFigure(context, 40)),
                Text(
                  t.widget_label_streak_days,
                  style: m.subtitleStyle(context),
                ),
                const Spacer(),
                Flexible(
                  flex: 4,
                  child: Text(
                    '${t.srs_stats_streak_longest} · ${stats.longestStreak} '
                    '${t.widget_label_streak_days}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: m.footnoteStyle(context),
                  ),
                ),
              ],
            ),
          ),
          AppleSrsHeatmap(
            key: const ValueKey<String>('srs-home-heatmap-grid'),
            countsByDay: stats.countsByDay,
            today: stats.today,
            weeks: weeks,
            maxCell: 14 * s,
            dateOf: srsDayToDate,
            dayLabel: (int day) => _srsHomeDate(day, DateFormat.MMMd),
            monthLabel: (int day) => _srsHomeDate(day, DateFormat.MMM),
            countLabel: (int n) => t.srs_stats_reviews_count(n: n),
            lessLabel: t.srs_home_heatmap_less,
            moreLabel: t.srs_home_heatmap_more,
          ),
          Row(
            key: const ValueKey<String>('srs-home-heatmap-totals'),
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12 * s,
            children: <Widget>[
              for (final (String label, String text) in items)
                Expanded(
                  child: Semantics(
                    label: '$label $text',
                    excludeSemantics: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(text, style: _appleSrsFigure(context, 17)),
                        Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: m.footnoteStyle(context),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 全库「未来 7 天」卡（手机根层）。
class _AppleSrsForecastCard extends StatelessWidget {
  const _AppleSrsForecastCard({super.key, required this.stats});

  final SrsHomeStats stats;

  @override
  Widget build(BuildContext context) => _AppleSrsCard(
    title: t.srs_home_forecast_title,
    icon: FushiIcons.trendingUp,
    iconColor: AppleSrsSystemColors.of(context).green,
    child: _AppleSrsForecastChart(forecast: stats.forecast, today: stats.today),
  );
}

/// 全库「RWKV 此刻」卡。
class _AppleSrsRwkvNowCard extends StatelessWidget {
  const _AppleSrsRwkvNowCard({
    super.key,
    required this.stats,
    required this.now,
    required this.queued,
  });

  final SrsHomeStats stats;
  final SrsRwkvNow now;
  final int? queued;

  @override
  Widget build(BuildContext context) => _AppleSrsCard(
    title: t.srs_stats_rwkv_now_title,
    icon: FushiIcons.speed,
    iconColor: AppleSrsSystemColors.of(context).orange,
    child: _AppleSrsRwkvView(
      now: now,
      target: stats.desiredRetention,
      queued: queued,
    ),
  );
}

/// [_srsHomeDueCards] 的 Apple 版（同条件、同 key）。
List<Widget> _appleSrsHomeDueCards(SrsHomeStats stats, SrsDeckListData data) =>
    <Widget>[
      if (stats.showsForecast)
        _AppleSrsForecastCard(
          key: const ValueKey<String>('srs-home-forecast'),
          stats: stats,
        ),
      if (stats.rwkvNow case final SrsRwkvNow now)
        _AppleSrsRwkvNowCard(
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

/// 分组标题（iOS：20 号粗体 label，像「提醒事项」「我的列表」；macOS：13 号 semibold
/// secondaryLabel），右侧附注张数。
class _AppleSrsSectionHeader extends StatelessWidget {
  const _AppleSrsSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.action,
  });

  /// 标题行末尾的动作钮（已配对设备分区的「刷新」）。
  final Widget? action;

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final double s = m.scale;
    final String? more = trailing;
    final TextStyle style = m.desktop
        ? m
              .footnoteStyle(context)
              .copyWith(fontWeight: FontWeight.w600, fontSize: 13 * s)
        : m
              .titleStyle(context)
              .copyWith(fontSize: 22, fontWeight: FontWeight.w700);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        m.desktop ? 4 * s : 4,
        8 * s,
        m.desktop ? 4 * s : 4,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Expanded(child: Text(title, style: style)),
          if (more != null)
            Text(
              more,
              style: m
                  .footnoteStyle(context)
                  .copyWith(color: apple.secondaryLabel),
            ),
          ?action,
        ],
      ),
    );
  }
}
