import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:fushi/src/pages/implementations/srs_stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_dashboard.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 统计中心的「复习」分区（内置复习模块 SRS 的统计，对齐 Anki 2.1.50+ 统计页）。
///
/// 只在复习模块开着时出现（统计中心按 `srsModuleEnabledProvider` 决定要不要这个
/// tab）；数据只读 SRS 自己的表（[loadSrsStats]：复习日志 + 卡片缓存 + 笔记，按当前
/// profile），「今天」与日序号走 SRS 的翻日口径（[SrsDayContext]），不走学习统计域的
/// dateKey / [StatRange]——两者是不同的事实：这里是复习事件，那里是阅读 / 观看时长。
///
/// 排布（自上而下 = 手机单列的阅读顺序；宽屏按宽度断点分两 / 三列，见
/// [kSrsStatsTwoColumnMinWidth]）：筛选（时间范围 / 牌组 / Anki 搜索）→ 今日
/// （四张关键数字 + 分类与评分）→ 未来到期 → 复习日历 → 复习量 / 用时 → 卡片状态 →
/// 保留率（真实 vs 期望 + 成熟卡增长）→ 记忆分布（间隔 / 稳定性 / 难度 / 可提取度）
/// → 按小时 → 评分按钮 → 新增卡片 → 易忘卡 → 制卡来源。
class SrsStatisticsTab extends ConsumerStatefulWidget {
  const SrsStatisticsTab({super.key});

  @override
  ConsumerState<SrsStatisticsTab> createState() => _SrsStatisticsTabState();
}

/// 两列的最小内容宽度（手机横屏 / 平板竖屏起）。
const double kSrsStatsTwoColumnMinWidth = 760;

/// 三列的最小内容宽度（桌面 / 平板横屏）。
const double kSrsStatsThreeColumnMinWidth = 1240;

/// 记忆分布的四个视图。
enum _MemoryView { interval, stability, difficulty, retrievability }

class _SrsStatisticsTabState extends ConsumerState<SrsStatisticsTab> {
  SrsStatsBundle? _bundle;
  SrsStatsData? _data;
  bool _loading = true;
  bool _unavailable = false;
  bool _failed = false;
  bool _dateSymbolsReady = false;

  /// 正在装载（装载期间又来的刷新信号只记一笔，装完再跑一次，不并发重跑整份统计）。
  bool _inFlight = false;
  bool _again = false;

  /// 上次装载用的库（换 profile / 重开库时整份重读）。
  SrsDbStore? _loadedStore;

  SrsStatsRange _range = SrsStatsRange.month;
  String _deckId = '';
  bool _futureCumulative = false;
  bool _futureBacklog = true;
  bool _reviewsTime = false;
  _MemoryView _memory = _MemoryView.interval;

  @override
  void initState() {
    super.initState();
    unawaited(
      initializeDateFormatting().then((_) {
        if (mounted) setState(() => _dateSymbolsReady = true);
      }),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  /// [srsRevisionProvider] 的一跳：只有会改变统计结果的事件落了库（[SrsDbStore.statsFingerprint] 变了）才重读。
  /// 以前任何写（牌组收起 / 展开、同步空轮、媒体、去重跳过的制卡…）都整份重跑统计。
  Future<void> _onRevision() async {
    if (await _needsReload()) await _load();
  }

  Future<bool> _needsReload() async {
    final SrsStatsBundle? b = _bundle;
    final SrsDbStore? loaded = _loadedStore;
    if (b == null || loaded == null) return true;
    final SrsDbStore? store = await ref.read(srsStoreProvider.future);
    if (!identical(store, loaded)) return true;
    return store!.statsFingerprint != b.fingerprint;
  }

  Future<void> _load() async {
    if (_inFlight) {
      _again = true;
      return;
    }
    _inFlight = true;
    try {
      do {
        _again = false;
        await _loadOnce();
      } while (_again && mounted);
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _loadOnce() async {
    SrsDbStore? store;
    try {
      store = await ref.read(srsStoreProvider.future);
      if (store == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _unavailable = true;
          });
        }
        return;
      }
      final SrsStatsBundle bundle = await loadSrsStats(store);
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _loadedStore = store;
        _loading = false;
        _unavailable = false;
        _failed = false;
        if (_deckId.isNotEmpty && bundle.index.tree[_deckId] == null) {
          _deckId = '';
        }
        _applyFilter();
      });
    } catch (error, stack) {
      ErrorLogService.instance.log('SrsStatisticsTab.load', error, stack);
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  /// 牌组子树 → 统计数据的子集。
  void _applyFilter() {
    final SrsStatsBundle? b = _bundle;
    if (b == null) return;
    _data = _deckId.isEmpty
        ? b.data
        : b.data.subset(b.index.cardIdsInDeck(_deckId));
  }

  // ------------------------------------------------------------- 格式

  String get _locale => LocaleSettings.currentLocale.languageTag;

  String _fmt(int day, DateFormat Function(String locale) pattern, String fb) {
    final DateTime d = srsDayToDate(day);
    if (!_dateSymbolsReady) return fb;
    try {
      return pattern(_locale).format(d);
    } on ArgumentError {
      return pattern('en').format(d);
    }
  }

  String _md(int day) {
    final DateTime d = srsDayToDate(day);
    return _fmt(day, DateFormat.Md, '${d.month}/${d.day}');
  }

  String _ymd(int day) {
    final DateTime d = srsDayToDate(day);
    return _fmt(day, DateFormat.yMd, '${d.year}/${d.month}/${d.day}');
  }

  String _month(int day) {
    final DateTime d = srsDayToDate(day);
    return _fmt(day, DateFormat.MMM, '${d.month}');
  }

  String _yearMonth(int day) {
    final DateTime d = srsDayToDate(day);
    return _fmt(day, DateFormat.yMMM, '${d.year}/${d.month}');
  }

  String _bucketLabel(SrsBucketUnit unit, SrsDayBucket b) => switch (unit) {
    SrsBucketUnit.day || SrsBucketUnit.week => _md(b.firstDay),
    SrsBucketUnit.month => _month(b.firstDay),
  };

  String _bucketTitle(SrsBucketUnit unit, SrsDayBucket b) => switch (unit) {
    SrsBucketUnit.day => _ymd(b.firstDay),
    SrsBucketUnit.week => '${_ymd(b.firstDay)} – ${_md(b.lastDay)}',
    SrsBucketUnit.month => _yearMonth(b.firstDay),
  };

  static String _percent(double? v) =>
      v == null ? kStatEmptyValue : '${(v * 100).toStringAsFixed(1)}%';

  static String _duration(int ms) => ms < 60000
      ? t.srs_stats_seconds(n: (ms / 1000).round())
      : formatStatTime(ms);

  static String _decimal(double v) =>
      v >= 100 ? v.round().toString() : v.toStringAsFixed(1);

  String _kindLabel(SrsStatReviewKind k) => switch (k) {
    SrsStatReviewKind.newCard => t.srs_stats_kind_new,
    SrsStatReviewKind.learn => t.srs_stats_kind_learn,
    SrsStatReviewKind.young => t.srs_stats_kind_young,
    SrsStatReviewKind.mature => t.srs_stats_kind_mature,
    SrsStatReviewKind.relearn => t.srs_stats_kind_relearn,
    SrsStatReviewKind.filtered => t.srs_stats_kind_filtered,
  };

  Color _kindColor(SrsStatColors c, SrsStatReviewKind k) => switch (k) {
    SrsStatReviewKind.newCard => c.newCard,
    SrsStatReviewKind.learn => c.learn,
    SrsStatReviewKind.young => c.young,
    SrsStatReviewKind.mature => c.mature,
    SrsStatReviewKind.relearn => c.relearn,
    SrsStatReviewKind.filtered => c.filtered,
  };

  /// 堆叠顺序（自下而上，与 Anki 相同：成熟 → 年轻 → 重学 → 学习 → 新卡 → 筛选）。
  static const List<SrsStatReviewKind> _stackOrder = <SrsStatReviewKind>[
    SrsStatReviewKind.mature,
    SrsStatReviewKind.young,
    SrsStatReviewKind.relearn,
    SrsStatReviewKind.learn,
    SrsStatReviewKind.newCard,
    SrsStatReviewKind.filtered,
  ];

  String _rangeLabel(SrsStatsRange r) => switch (r) {
    SrsStatsRange.month => t.srs_stats_range_month,
    SrsStatsRange.threeMonths => t.srs_stats_range_three_months,
    SrsStatsRange.year => t.srs_stats_range_year,
    SrsStatsRange.all => t.stat_all_time,
  };

  List<String> get _ratingLabels => <String>[
    t.srs_rating_again,
    t.srs_rating_hard,
    t.srs_rating_good,
    t.srs_rating_easy,
  ];

  // ------------------------------------------------------------- 页面

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      srsRevisionProvider,
      (int? a, int b) => unawaited(_onRevision()),
    );
    ref.listen<AsyncValue<SrsDbStore?>>(srsStoreProvider, (
      AsyncValue<SrsDbStore?>? a,
      AsyncValue<SrsDbStore?> b,
    ) {
      if (b.hasValue) unawaited(_load());
    });
    return buildEmbeddedStatTab(context, _buildBody(context));
  }

  Widget _buildBody(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    if (_unavailable || _failed) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(tokens.spacing.card),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  _failed ? t.error_load_failed : t.srs_stats_unavailable,
                  textAlign: TextAlign.center,
                  style: tokens.type.metadata,
                ),
                if (_failed) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  FushiTextButton.icon(
                    key: const ValueKey<String>('srs-stats-retry'),
                    onPressed: () {
                      setState(() {
                        _loading = true;
                        _failed = false;
                      });
                      unawaited(_load());
                    },
                    icon: const FushiIcon(FushiIcons.refresh),
                    label: Text(t.retry),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    final SrsStatsData data = _data!;
    final SrsStatColors colors = SrsStatColors.of(context);
    final bool empty = data.isEmpty;
    final List<_Section> sections = empty
        ? <_Section>[]
        : <_Section>[
            if (data.rwkvNow case final SrsRwkvNow now)
              _Section(_rwkvNowSection(now), 1.6),
            if (data.hasDueDateCards || data.rwkvNow == null)
              _Section(_futureSection(data, colors), 3.2),
            _Section(_calendarSection(data), 2.6),
            _Section(_reviewsSection(data, colors), 3.6),
            _Section(_cardCountSection(data, colors), 3),
            _Section(_retentionSection(data, colors), 4),
            _Section(_memorySection(data, colors), 3.2),
            _Section(_addedSection(data, colors), 2.6),
            _Section(_sourceSection(data, colors), 2.6),
          ];
    return FushiEntranceScope(
      replayKey: Object.hash(_range, _deckId),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final int columns = box.maxWidth >= kSrsStatsThreeColumnMinWidth
              ? 3
              : box.maxWidth >= kSrsStatsTwoColumnMinWidth
              ? 2
              : 1;
          int order = 0;
          Widget entrance(Widget child) =>
              FushiStaggeredEntrance(index: order++, child: child);
          final List<Widget> slivers = <Widget>[
            SliverToBoxAdapter(
              child: SizedBox(height: MediaQuery.paddingOf(context).top),
            ),
            SliverToBoxAdapter(child: entrance(_filters(context))),
            if (empty)
              SliverToBoxAdapter(
                child: entrance(StatDashboardEmpty(message: t.srs_stats_empty)),
              )
            else ...<Widget>[
              SliverToBoxAdapter(child: entrance(_todayHero(data))),
              SliverToBoxAdapter(child: entrance(_todayDetail(data, colors))),
              SliverToBoxAdapter(
                child: _SrsColumns(
                  key: ValueKey<String>('srs-stats-columns-$columns'),
                  columns: columns,
                  sections: sections,
                  firstOrder: order,
                ),
              ),
            ],
            buildStatTailSliver(context),
          ];
          return CustomScrollView(
            key: const ValueKey<String>('srs-stats-scroll'),
            slivers: slivers,
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------- 筛选

  Widget _filters(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsStatsBundle bundle = _bundle!;
    final List<(String, String)> decks = <(String, String)>[
      ('', t.srs_stats_deck_all),
      ...bundle.index.decks,
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.card,
        tokens.spacing.card,
        0,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double fieldWidth = math.min(box.maxWidth, 360);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.min(box.maxWidth, 440),
                    ),
                    child: FushiSegmentedButton<SrsStatsRange>(
                      key: const ValueKey<String>('srs-stats-range'),
                      segments: <ButtonSegment<SrsStatsRange>>[
                        for (final SrsStatsRange r in SrsStatsRange.values)
                          ButtonSegment<SrsStatsRange>(
                            value: r,
                            label: Text(
                              _rangeLabel(r),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      selected: <SrsStatsRange>{_range},
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
                          EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                      onSelectionChanged: (Set<SrsStatsRange> s) {
                        if (s.isNotEmpty) setState(() => _range = s.first);
                      },
                    ),
                  ),
                  if (decks.length > 2)
                    SizedBox(
                      width: fieldWidth,
                      child: FushiDropdown<String>(
                        key: ValueKey<String>(
                          'srs-stats-deck-${decks.length}-$_deckId',
                        ),
                        options: <String>[
                          for (final (String, String) d in decks) d.$1,
                        ],
                        initialOption: _deckId,
                        generateLabel: (String id) => decks
                            .firstWhere(
                              ((String, String) d) => d.$1 == id,
                              orElse: () => (id, id),
                            )
                            .$2,
                        onChanged: (String? id) => setState(() {
                          _deckId = id ?? '';
                          _applyFilter();
                        }),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------- 今日

  Widget _todayHero(SrsStatsData data) {
    final SrsTodayStats s = data.todayStats();
    final SrsStreak streak = data.streak();
    return StatHero(
      key: const ValueKey<String>('srs-stats-today'),
      tiles: <Widget>[
        StatKpiTile(
          icon: FushiIcons.ankiCard,
          label: t.srs_stats_today_reviews,
          value: '${s.count}',
          caption: t.stat_today,
        ),
        StatKpiTile(
          icon: FushiIcons.timer,
          label: t.srs_stats_today_time,
          value: _duration(s.durationMs),
          caption: s.count == 0
              ? null
              : '${t.srs_stats_avg_answer_time} '
                    '${t.srs_stats_seconds(n: (s.durationMs / s.count / 1000).toStringAsFixed(1))}',
        ),
        StatKpiTile(
          icon: FushiIcons.success,
          label: t.srs_stats_today_correct,
          value: _percent(s.correctRate),
          caption: s.count == 0 ? null : '${s.correct} / ${s.count}',
        ),
        StatKpiTile(
          icon: FushiIcons.streak,
          label: t.srs_stats_streak_current,
          value: t.srs_stats_days(n: streak.current),
          caption:
              '${t.srs_stats_streak_longest} '
              '${t.srs_stats_days(n: streak.longest)}',
        ),
      ],
    );
  }

  Widget _todayDetail(SrsStatsData data, SrsStatColors colors) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SrsTodayStats s = data.todayStats();
    final TextStyle meta = tokens.type.metadata.copyWith(
      color: scheme.onSurfaceVariant,
    );
    Widget chip(String label, int n, Color? color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.surfaces.overlay,
        borderRadius: BorderRadius.all(tokens.radii.chipCorner),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (color != null) ...<Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.all(Radius.circular(2)),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(label, style: meta),
          const SizedBox(width: 6),
          Text(
            '$n',
            style: tokens.type.metadata.tabular.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    final int review =
        s.kind(SrsStatReviewKind.young) + s.kind(SrsStatReviewKind.mature);
    return StatSectionCard(
      key: const ValueKey<String>('srs-stats-today-detail'),
      title: t.stat_today,
      icon: FushiIcons.calendar,
      subtitle: s.count == 0 ? t.srs_stats_today_none : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              chip(
                t.srs_stats_kind_new,
                s.kind(SrsStatReviewKind.newCard),
                colors.newCard,
              ),
              chip(
                t.srs_stats_kind_learn,
                s.kind(SrsStatReviewKind.learn),
                colors.learn,
              ),
              chip(t.srs_stats_kind_review, review, colors.mature),
              chip(
                t.srs_stats_kind_relearn,
                s.kind(SrsStatReviewKind.relearn),
                colors.relearn,
              ),
              chip(
                t.srs_stats_kind_filtered,
                s.kind(SrsStatReviewKind.filtered),
                colors.filtered,
              ),
              chip(t.srs_stats_kind_early, s.early, null),
            ],
          ),
          SizedBox(height: tokens.spacing.card),
          SrsStackedMeter(values: s.ratings, colors: colors.ratings),
          SizedBox(height: tokens.spacing.gap),
          _ratingBreakdownLine(s.ratings, colors),
          if (s.matureTotal > 0) ...<Widget>[
            SizedBox(height: tokens.spacing.gap / 2),
            Text(
              t.srs_stats_today_mature_correct(
                correct: s.matureCorrect,
                total: s.matureTotal,
                percent: _percent(s.matureCorrect / s.matureTotal),
              ),
              style: meta,
            ),
          ],
        ],
      ),
    );
  }

  /// 「重来 3（12%）· 困难 …」一行：评分名 + 次数 + 占比，色块只作辅助。
  Widget _ratingBreakdownLine(List<int> ratings, SrsStatColors colors) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int total = ratings.fold<int>(0, (int a, int b) => a + b);
    return Wrap(
      spacing: tokens.spacing.card,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        for (int i = 0; i < 4; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: colors.ratings[i],
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${_ratingLabels[i]} ${ratings[i]}'
                '${total == 0 ? '' : ' (${(ratings[i] * 100 / total).round()}%)'}',
                style: tokens.type.metadata.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
      ],
    );
  }

  // ------------------------------------------------------------- 未来到期

  int _futureDays(SrsStatsData data) => switch (_range) {
    SrsStatsRange.month => 31,
    SrsStatsRange.threeMonths => 91,
    SrsStatsRange.year => 366,
    SrsStatsRange.all => data.furthestDueOffset(),
  };

  /// RWKV 牌组：此刻该复习 / 接近目标线的张数与过去 30 天日均（都是测量，RWKV 不预测到期日）。
  Widget _rwkvNowSection(SrsRwkvNow now) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return StatSectionCard(
      key: const ValueKey<String>('srs-stats-rwkv-now'),
      title: t.srs_stats_rwkv_now_title,
      icon: FushiIcons.trendingUp,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _statLine(<(String, String)>[
            (t.srs_stats_rwkv_now_due, '${now.due}'),
            (t.srs_stats_rwkv_now_near, '${now.near}'),
            (t.srs_stats_rwkv_now_avg, _decimal(now.dailyAverage)),
          ]),
          SizedBox(height: tokens.spacing.gap),
          Text(t.srs_stats_rwkv_now_hint, style: context.fushiType.bodySmall),
        ],
      ),
    );
  }

  Widget _futureSection(SrsStatsData data, SrsStatColors colors) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsFutureDue f = data.futureDue(_futureDays(data));
    final (SrsBucketUnit unit, List<SrsDayBucket> spans) = srsStatsBuckets(
      data.today,
      data.today + f.perDay.length - 1,
    );
    String label(SrsDayBucket b) {
      final int off = b.firstDay - data.today;
      if (unit == SrsBucketUnit.day) return off == 0 ? '0' : '+$off';
      return _bucketLabel(unit, b);
    }

    String title(SrsDayBucket b) {
      final int off = b.firstDay - data.today;
      if (unit == SrsBucketUnit.day) {
        final String when = switch (off) {
          0 => t.stat_today,
          1 => t.srs_stats_tomorrow,
          _ => t.srs_stats_in_days(n: off),
        };
        return '$when · ${_md(b.firstDay)}';
      }
      return _bucketTitle(unit, b);
    }

    final List<SrsBarDatum> bars = <SrsBarDatum>[
      if (_futureBacklog && f.overdue > 0)
        SrsBarDatum(
          label: '<0',
          title: t.srs_stats_future_overdue,
          values: <int>[0, f.overdue],
        ),
      for (final SrsDayBucket b in spans)
        () {
          int young = 0, all = 0;
          for (int d = b.firstDay; d <= b.lastDay; d++) {
            all += f.perDay[d - data.today];
            young += f.youngPerDay[d - data.today];
          }
          return SrsBarDatum(
            label: label(b),
            title: title(b),
            values: <int>[all - young, young],
          );
        }(),
    ];
    final List<SrsChartSeries> series = <SrsChartSeries>[
      SrsChartSeries(t.srs_stats_kind_mature, colors.mature),
      SrsChartSeries(
        '${t.srs_stats_kind_young} / ${t.srs_stats_kind_learn}',
        colors.young,
      ),
    ];
    int running = 0;
    final List<int> cumulative = <int>[
      for (final SrsBarDatum b in bars) running += b.total,
    ];
    return StatSectionCard(
      key: const ValueKey<String>('srs-stats-future'),
      title: t.srs_stats_future_title,
      icon: FushiIcons.trendingUp,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 视图切换放卡身第一行（不挤卡头：窄屏下标题 + 两段按钮放不下）。
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _toggle(
              key: 'srs-stats-future-view',
              options: <String>[
                t.srs_stats_view_daily,
                t.srs_stats_view_cumulative,
              ],
              selected: _futureCumulative ? 1 : 0,
              onChanged: (int i) => setState(() => _futureCumulative = i == 1),
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          _statLine(<(String, String)>[
            (t.srs_stats_future_tomorrow, '${f.dueTomorrow}'),
            (t.srs_stats_avg_per_day, _decimal(f.averagePerDay)),
            (t.srs_stats_future_load, _decimal(f.dailyLoad)),
            (t.srs_stats_future_overdue, '${f.overdue}'),
          ]),
          if (f.byRecall > 0) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.srs_stats_future_due_by_recall(n: f.byRecall),
              key: const ValueKey<String>('srs-stats-future-by-recall'),
              style: context.fushiType.bodySmall,
            ),
          ],
          SizedBox(height: tokens.spacing.card),
          if (_futureCumulative)
            SrsLineChart(
              values: cumulative,
              labels: <String>[for (final SrsBarDatum b in bars) b.label],
              titles: <String>[for (final SrsBarDatum b in bars) b.title],
              color: colors.mature,
              valueText: (int v) => t.srs_stats_cards_total(n: v),
            )
          else ...<Widget>[
            SrsBarChart(
              bars: bars,
              series: series,
              scaleOf: statCountAxisScale,
              valueText: (int v) => '$v',
            ),
            SizedBox(height: tokens.spacing.gap),
            SrsChartLegend(series: series),
          ],
          SizedBox(height: tokens.spacing.gap / 2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiFilterChip(
              key: const ValueKey<String>('srs-stats-future-backlog'),
              label: Text(t.srs_stats_future_backlog),
              selected: _futureBacklog,
              onSelected: (bool v) => setState(() => _futureBacklog = v),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 日历

  Widget _calendarSection(SrsStatsData data) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsStreak streak = data.streak();
    final int first = data.firstDayOf(_range);
    final SrsReviewTotals tot = data.reviewTotalsBetween(first, data.today);
    return StatSectionCard(
      key: const ValueKey<String>('srs-stats-calendar'),
      title: t.srs_stats_calendar_title,
      icon: FushiIcons.calendar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SrsCalendarHeatmap(
            countsByDay: data.countsByDay(),
            today: data.today,
            dayLabel: _ymd,
            monthLabel: _month,
          ),
          SizedBox(height: tokens.spacing.gap),
          _statLine(<(String, String)>[
            (
              t.srs_stats_calendar_days_studied,
              t.srs_stats_calendar_days_value(
                studied: tot.daysStudied,
                days: tot.days,
                percent: _percent(
                  tot.days == 0 ? null : tot.daysStudied / tot.days,
                ),
              ),
            ),
            (t.srs_stats_streak_current, t.srs_stats_days(n: streak.current)),
            (t.srs_stats_streak_longest, t.srs_stats_days(n: streak.longest)),
          ]),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 复习量 / 用时

  Widget _reviewsSection(SrsStatsData data, SrsStatColors colors) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final (SrsBucketUnit unit, List<SrsReviewBucket> buckets) = data
        .reviewBuckets(_range);
    final SrsReviewTotals tot = data.reviewTotals(_range);
    final List<SrsChartSeries> series = <SrsChartSeries>[
      for (final SrsStatReviewKind k in _stackOrder)
        SrsChartSeries(_kindLabel(k), _kindColor(colors, k)),
    ];
    final List<SrsBarDatum> bars = <SrsBarDatum>[
      for (final SrsReviewBucket b in buckets)
        SrsBarDatum(
          label: _bucketLabel(unit, b.bucket),
          title: _bucketTitle(unit, b.bucket),
          values: <int>[
            for (final SrsStatReviewKind k in _stackOrder)
              _reviewsTime ? (b.durations[k] ?? 0) : (b.counts[k] ?? 0),
          ],
        ),
    ];
    final List<(String, String)> summary = _reviewsTime
        ? <(String, String)>[
            (t.srs_stats_total, _duration(tot.durationMs)),
            (
              t.srs_stats_avg_per_day,
              _duration(tot.days == 0 ? 0 : tot.durationMs ~/ tot.days),
            ),
            (
              t.srs_stats_avg_answer_time,
              t.srs_stats_seconds(
                n: (tot.averageMsPerCard / 1000).toStringAsFixed(1),
              ),
            ),
          ]
        : <(String, String)>[
            (t.srs_stats_total, '${tot.count}'),
            (t.srs_stats_avg_per_day, _decimal(tot.averagePerDay)),
            (t.srs_stats_avg_studied_day, _decimal(tot.averagePerStudiedDay)),
          ];
    return StatSectionCard(
      key: const ValueKey<String>('srs-stats-reviews'),
      title: _reviewsTime ? t.srs_stats_view_time : t.srs_stats_reviews_title,
      icon: FushiIcons.barChart,
      subtitle: _rangeLabel(_range),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 视图切换放卡身第一行（不挤卡头：窄屏下标题 + 两段按钮放不下）。
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _toggle(
              key: 'srs-stats-reviews-view',
              options: <String>[t.srs_stats_view_count, t.srs_stats_view_time],
              selected: _reviewsTime ? 1 : 0,
              onChanged: (int i) => setState(() => _reviewsTime = i == 1),
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          _statLine(summary),
          SizedBox(height: tokens.spacing.card),
          SrsBarChart(
            bars: bars,
            series: series,
            scaleOf: _reviewsTime ? statDurationAxisScale : statCountAxisScale,
            valueText: _reviewsTime ? _duration : (int v) => '$v',
          ),
          SizedBox(height: tokens.spacing.gap),
          SrsChartLegend(series: series),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 卡片状态

  Widget _cardCountSection(SrsStatsData data, SrsStatColors colors) {
    final SrsCardCounts c = data.cardCounts();
    return StatSectionCard(
      key: const ValueKey<String>('srs-stats-card-counts'),
      title: t.srs_stats_cards_title,
      icon: FushiIcons.dataUsage,
      child: SrsDonutChart(
        centerLabel: t.srs_stats_cards_total(n: c.total),
        segments: <SrsDonutSegment>[
          SrsDonutSegment(t.srs_stats_kind_new, c.newCards, colors.newCard),
          SrsDonutSegment(t.srs_stats_kind_learn, c.learning, colors.learn),
          SrsDonutSegment(
            t.srs_stats_kind_relearn,
            c.relearning,
            colors.relearn,
          ),
          SrsDonutSegment(t.srs_stats_kind_young, c.young, colors.young),
          SrsDonutSegment(t.srs_stats_kind_mature, c.mature, colors.mature),
          SrsDonutSegment(
            t.srs_stats_kind_suspended,
            c.suspended,
            colors.suspended,
          ),
          SrsDonutSegment(t.srs_stats_kind_buried, c.buried, colors.buried),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 保留率

  Widget _retentionSection(SrsStatsData data, SrsStatColors colors) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int today = data.today;
    final List<(String, SrsRetention)> rows = <(String, SrsRetention)>[
      (t.stat_today, data.retentionBetween(today, today)),
      (
        t.srs_stats_period_yesterday,
        data.retentionBetween(today - 1, today - 1),
      ),
      (t.srs_stats_period_week, data.retentionBetween(today - 6, today)),
      (t.srs_stats_period_month, data.retentionBetween(today - 29, today)),
      (t.srs_stats_period_year, data.retentionBetween(today - 364, today)),
      (t.stat_all_time, data.retentionBetween(data.earliestDay, today)),
    ];
    final double? desired = data.desiredRetention();
    final TextStyle head = tokens.type.metadata.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    final TextStyle cell = tokens.type.metadata.tabular.copyWith(
      color: scheme.onSurface,
    );
    Widget num(double? v, int n) => Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Text(
        n == 0 ? kStatEmptyValue : _percent(v),
        style: cell.copyWith(
          color: n == 0 ? scheme.onSurfaceVariant : scheme.onSurface,
        ),
      ),
    );
    final (_, List<SrsReviewBucket> buckets) = data.reviewBuckets(_range);
    final (SrsBucketUnit unit, _) = srsStatsBuckets(
      data.firstDayOf(_range),
      today,
    );
    final List<SrsDayBucket> spans = <SrsDayBucket>[
      for (final SrsReviewBucket b in buckets) b.bucket,
    ];
    final List<int> mature = data.matureCountsAt(spans);
    return StatSectionCard(
      key: const ValueKey<String>('srs-stats-retention'),
      title: t.srs_stats_retention_title,
      icon: FushiIcons.verified,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _statLine(<(String, String)>[
            (
              t.srs_stats_retention_true,
              _percent(
                data.retentionBetween(data.firstDayOf(_range), today).rate,
              ),
            ),
            (t.srs_stats_retention_desired, _percent(desired)),
          ]),
          SizedBox(height: tokens.spacing.gap),
          Table(
            key: const ValueKey<String>('srs-stats-retention-table'),
            columnWidths: const <int, TableColumnWidth>{
              0: FlexColumnWidth(1.6),
              1: FlexColumnWidth(),
              2: FlexColumnWidth(),
              3: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: <TableRow>[
              TableRow(
                children: <Widget>[
                  const SizedBox.shrink(),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(t.srs_stats_kind_young, style: head),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(t.srs_stats_kind_mature, style: head),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(t.srs_stats_total, style: head),
                  ),
                ],
              ),
              for (final (String, SrsRetention) r in rows)
                TableRow(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Text(
                        r.$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.type.metadata.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    num(r.$2.youngRate, r.$2.youngTotal),
                    num(r.$2.matureRate, r.$2.matureTotal),
                    num(r.$2.rate, r.$2.total),
                  ],
                ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap),
          Text(
            t.srs_stats_retention_hint,
            style: tokens.type.metadata.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: tokens.spacing.card),
          Text(
            t.srs_stats_mature_growth,
            style: tokens.type.metadata.copyWith(
              color: statSectionTitleStyle(context).color,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          SrsLineChart(
            key: const ValueKey<String>('srs-stats-mature-growth'),
            height: 140,
            values: mature,
            labels: <String>[
              for (final SrsDayBucket b in spans) _bucketLabel(unit, b),
            ],
            titles: <String>[
              for (final SrsDayBucket b in spans) _bucketTitle(unit, b),
            ],
            color: colors.mature,
            valueText: (int v) => t.srs_stats_cards_total(n: v),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 记忆分布

  Widget _memorySection(SrsStatsData data, SrsStatColors colors) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool days =
        _memory == _MemoryView.interval || _memory == _MemoryView.stability;
    final SrsHistogram h = switch (_memory) {
      _MemoryView.interval => data.intervalHistogram(),
      _MemoryView.stability => data.stabilityHistogram(),
      _MemoryView.difficulty => data.difficultyHistogram(),
      _MemoryView.retrievability => data.retrievabilityHistogram(),
    };
    String valueOf(double v) =>
        days ? t.srs_stats_days(n: _decimal(v)) : '${(v * 100).round()}%';
    String binLabel(SrsHistogramBin b) => days
        ? (b.lo == b.lo.roundToDouble() ? '${b.lo.round()}' : _decimal(b.lo))
        : '${(b.lo * 100).round()}';
    String binTitle(int i, SrsHistogramBin b) {
      if (h.openEnded && i == h.bins.length - 1) return '≥ ${valueOf(b.lo)}';
      if (days && b.hi - b.lo == 1) return valueOf(b.lo);
      return days
          ? '${_decimal(b.lo)} – ${valueOf(b.hi)}'
          : '${(b.lo * 100).round()} – ${(b.hi * 100).round()}%';
    }

    final List<(String, String)> summary = <(String, String)>[
      (t.srs_stats_mean, h.mean == null ? kStatEmptyValue : valueOf(h.mean!)),
      (
        t.srs_stats_median,
        h.median == null ? kStatEmptyValue : valueOf(h.median!),
      ),
      if (_memory == _MemoryView.retrievability && h.total > 0)
        (t.srs_stats_knowledge, t.srs_stats_cards_total(n: h.sum.round())),
    ];
    final bool unavailable =
        _memory == _MemoryView.retrievability && !data.retrievabilityAvailable;
    return StatSectionCard(
      key: const ValueKey<String>('srs-stats-memory'),
      title: t.srs_stats_memory_title,
      icon: FushiIcons.modelTraining,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSegmentedButton<_MemoryView>(
            key: const ValueKey<String>('srs-stats-memory-view'),
            segments: <ButtonSegment<_MemoryView>>[
              for (final (_MemoryView v, String label)
                  in <(_MemoryView, String)>[
                    (_MemoryView.interval, t.srs_stats_memory_interval),
                    (_MemoryView.stability, t.srs_stats_memory_stability),
                    (_MemoryView.difficulty, t.srs_stats_memory_difficulty),
                    (
                      _MemoryView.retrievability,
                      t.srs_stats_memory_retrievability,
                    ),
                  ])
                ButtonSegment<_MemoryView>(
                  value: v,
                  label: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            selected: <_MemoryView>{_memory},
            showSelectedIcon: false,
            style: const ButtonStyle(
              padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
                EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
            onSelectionChanged: (Set<_MemoryView> s) {
              if (s.isNotEmpty) setState(() => _memory = s.first);
            },
          ),
          SizedBox(height: tokens.spacing.card),
          if (unavailable || h.total == 0)
            Padding(
              padding: EdgeInsets.symmetric(vertical: tokens.spacing.card),
              child: Text(
                unavailable
                    ? t.srs_stats_retrievability_unavailable
                    : t.srs_stats_memory_empty,
                textAlign: TextAlign.center,
                style: tokens.type.metadata.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else ...<Widget>[
            _statLine(summary),
            SizedBox(height: tokens.spacing.card),
            SrsBarChart(
              bars: <SrsBarDatum>[
                for (int i = 0; i < h.bins.length; i++)
                  SrsBarDatum(
                    label: binLabel(h.bins[i]),
                    title: binTitle(i, h.bins[i]),
                    values: <int>[h.bins[i].count],
                  ),
              ],
              series: <SrsChartSeries>[
                SrsChartSeries(t.srs_stats_cards_title, colors.accent),
              ],
              scaleOf: statCountAxisScale,
              valueText: (int v) => t.srs_stats_cards_total(n: v),
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 添加 / 来源

  Widget _addedSection(SrsStatsData data, SrsStatColors colors) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final (SrsBucketUnit unit, List<SrsDayBucket> spans) = srsStatsBuckets(
      data.firstDayOf(_range),
      data.today,
    );
    final List<int> added = data.addedCounts(spans);
    final int total = added.fold<int>(0, (int a, int b) => a + b);
    final int days = math.max(1, data.today - data.firstDayOf(_range) + 1);
    return StatSectionCard(
      key: const ValueKey<String>('srs-stats-added'),
      title: t.srs_stats_added_title,
      icon: FushiIcons.addCircle,
      subtitle: _rangeLabel(_range),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _statLine(<(String, String)>[
            (t.srs_stats_total, t.srs_stats_cards_total(n: total)),
            (t.srs_stats_avg_per_day, _decimal(total / days)),
          ]),
          SizedBox(height: tokens.spacing.card),
          SrsBarChart(
            height: 140,
            bars: <SrsBarDatum>[
              for (int i = 0; i < spans.length; i++)
                SrsBarDatum(
                  label: _bucketLabel(unit, spans[i]),
                  title: _bucketTitle(unit, spans[i]),
                  values: <int>[added[i]],
                ),
            ],
            series: <SrsChartSeries>[
              SrsChartSeries(t.srs_stats_added_title, colors.newCard),
            ],
            scaleOf: statCountAxisScale,
            valueText: (int v) => t.srs_stats_cards_total(n: v),
          ),
        ],
      ),
    );
  }

  String _sourceKindLabel(String kind) => switch (kind) {
    SrsSourceKind.book => t.srs_stats_source_book,
    SrsSourceKind.manga => t.srs_stats_source_manga,
    SrsSourceKind.video => t.srs_stats_source_video,
    SrsSourceKind.audiobook => t.srs_stats_source_audiobook,
    SrsSourceKind.onlineNovel => t.srs_stats_source_online_novel,
    SrsSourceKind.onlineVideo => t.srs_stats_source_online_video,
    SrsSourceKind.game => t.srs_stats_source_game,
    SrsSourceKind.music => t.srs_stats_source_music,
    SrsSourceKind.web => t.srs_stats_source_web,
    SrsSourceKind.manual => t.srs_stats_source_manual,
    SrsSourceKind.anki => t.srs_stats_source_anki,
    '' => t.srs_stats_source_none,
    _ => t.srs_stats_source_other,
  };

  IconData _sourceKindIcon(String kind) => switch (kind) {
    SrsSourceKind.book || SrsSourceKind.onlineNovel => FushiIcons.books,
    SrsSourceKind.manga => FushiIcons.manga,
    SrsSourceKind.video || SrsSourceKind.onlineVideo => FushiIcons.video,
    SrsSourceKind.audiobook => FushiIcons.audiobook,
    SrsSourceKind.game => FushiIcons.games,
    SrsSourceKind.music => FushiIcons.music,
    SrsSourceKind.web => FushiIcons.globe,
    SrsSourceKind.anki => FushiIcons.ankiCard,
    _ => FushiIcons.edit,
  };

  Widget _sourceSection(SrsStatsData data, SrsStatColors colors) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<SrsSourceShare> all = data.sourceShares();
    const int shown = 8;
    final List<SrsSourceShare> rows = all.take(shown).toList();
    final int rest = all
        .skip(shown)
        .fold<int>(0, (int a, SrsSourceShare s) => a + s.notes);
    final int total = all.fold<int>(
      0,
      (int a, SrsSourceShare s) => a + s.notes,
    );
    final int max = rows.isEmpty ? 1 : math.max(rows.first.notes, rest);
    Widget row(IconData icon, String title, String? kind, int n) => Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              FushiIcon(icon, size: 18, color: scheme.onSurfaceVariant),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: title,
                        style: TextStyle(color: scheme.onSurface),
                      ),
                      if (kind != null)
                        TextSpan(
                          text: '  $kind',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ),
              Text(
                '$n · ${total == 0 ? '0' : (n * 100 / total).round()}%',
                style: tokens.type.metadata.tabular.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.all(tokens.radii.chipCorner),
            child: FushiLinearProgressIndicator(
              value: n / max,
              minHeight: 6,
              color: colors.accent,
              backgroundColor: colors.empty,
            ),
          ),
        ],
      ),
    );
    return StatSectionCard(
      key: const ValueKey<String>('srs-stats-sources'),
      title: t.srs_stats_sources_title,
      icon: FushiIcons.link,
      subtitle: t.srs_stats_cards_total(n: total),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final SrsSourceShare s in rows)
            row(
              _sourceKindIcon(s.kind),
              s.title.isNotEmpty ? s.title : _sourceKindLabel(s.kind),
              s.title.isNotEmpty ? _sourceKindLabel(s.kind) : null,
              s.notes,
            ),
          if (rest > 0)
            row(FushiIcons.moreHoriz, t.srs_stats_source_other, null, rest),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 小件

  /// 卡头行尾的两段切换（每日 / 累计、次数 / 用时）。
  Widget _toggle({
    required String key,
    required List<String> options,
    required int selected,
    required ValueChanged<int> onChanged,
  }) => FushiSegmentedButton<int>(
    key: ValueKey<String>(key),
    segments: <ButtonSegment<int>>[
      for (int i = 0; i < options.length; i++)
        ButtonSegment<int>(
          value: i,
          label: Text(options[i], maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
    ],
    selected: <int>{selected},
    showSelectedIcon: false,
    style: const ButtonStyle(
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 8),
      ),
    ),
    onSelectionChanged: (Set<int> s) {
      if (s.isNotEmpty) onChanged(s.first);
    },
  );

  /// 关键数字一行（标签在上、数字在下，窄屏自动换行）。
  Widget _statLine(List<(String, String)> items) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: tokens.spacing.card + tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        for (final (String label, String value) in items)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: tokens.type.metadata.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (value.isNotEmpty)
                Text(
                  value,
                  style: context.fushiType.titleMedium.tabular.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// 一个区块与它的估计高度权重（多列时贪心分配到最矮的一列，保持阅读顺序）。
class _Section {
  const _Section(this.child, this.weight);

  final Widget child;
  final double weight;
}

/// 多列排布：按宽度断点给 1 / 2 / 3 列；每个区块按顺序放进当前最矮的一列
/// （权重估计高度），单列时就是原顺序。
class _SrsColumns extends StatelessWidget {
  const _SrsColumns({
    required this.columns,
    required this.sections,
    required this.firstOrder,
    super.key,
  });

  final int columns;
  final List<_Section> sections;
  final int firstOrder;

  @override
  Widget build(BuildContext context) {
    final List<List<int>> slots = srsStatsColumnSlots(<double>[
      for (final _Section s in sections) s.weight,
    ], columns);
    Widget cell(int i) =>
        FushiStaggeredEntrance(index: firstOrder + i, child: sections[i].child);
    if (columns == 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[for (int i = 0; i < sections.length; i++) cell(i)],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final List<int> col in slots)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[for (final int i in col) cell(i)],
            ),
          ),
      ],
    );
  }
}

/// 纯函数：把按顺序的区块（权重 = 估计高度）分到 [columns] 列——每块放进当前
/// 累计最矮的一列（并列取最左），列内保持原顺序。
List<List<int>> srsStatsColumnSlots(List<double> weights, int columns) {
  final int n = math.max(1, columns);
  final List<List<int>> out = <List<int>>[for (int i = 0; i < n; i++) <int>[]];
  final List<double> heights = List<double>.filled(n, 0);
  for (int i = 0; i < weights.length; i++) {
    int best = 0;
    for (int c = 1; c < n; c++) {
      if (heights[c] < heights[best] - 1e-9) best = c;
    }
    out[best].add(i);
    heights[best] += weights[i];
  }
  return out;
}
