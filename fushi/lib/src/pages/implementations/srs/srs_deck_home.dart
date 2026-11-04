part of 'srs_deck_list_page.dart';

// 复习首页（方案 D「今日计划清单 + 详情双栏」+ 方案 E 的热力图 / 未来 7 天，所有者 2026-11-04 拍板）：
//
// - 顶部「今日计划」条：今天还剩几张、估算时长 / 已完成 / 连续天数、三色分段进度条与图例、「开始复习」；
// - 下面是牌组树（[_DeckList]：缩进、折叠、拖放改父级 / 排序、行菜单、删除进度都在这棵树里，树一直可拖，
//   没有单独的整理模式）；树下是复习热力图与未来 7 天到期两张卡；
// - 宽屏（内容宽 ≥ [_kSrsHomeWideMin]）双栏：右栏是选中牌组的详情（点行 = 选中，点行尾播放 = 复习）；
// - 手机：点行进该牌组的详情页（同右栏内容 + 它的子牌组），返回键 / 顶栏返回回上一层；播放按钮直接复习。

/// 内容区宽于此值：今日计划 + 牌组树在左、选中牌组详情在右。
const double _kSrsHomeWideMin = 840;

/// 宽屏内容限宽（居中），超宽屏不把两栏拉满。
const double _kSrsHomeContentMaxWidth = 1680;

/// 内容宽于此值改三栏：热力图 / 未来 7 天单独成第三栏，不再压在牌组树下面。
const double _kSrsHomeThreeColumnMin = 1320;

/// 手机上热力图与未来 7 天两张小卡并排的最小内容宽度（更窄时上下排）。
const double _kSrsHomeStatsSideBySideMin = 360;

/// 顶层牌组徽章的 M3E 形状：按牌组在顶层里的位置轮流取，相邻行不撞形。
final List<RoundedPolygon> _kSrsDeckBadgeShapes = <RoundedPolygon>[
  MaterialShapes.cookie9Sided,
  MaterialShapes.flower,
  MaterialShapes.softBurst,
  MaterialShapes.gem,
  MaterialShapes.clover4Leaf,
  MaterialShapes.sunny,
  MaterialShapes.pentagon,
  MaterialShapes.cookie6Sided,
];

RoundedPolygon _srsDeckBadgeShape(int rootIndex) =>
    _kSrsDeckBadgeShapes[rootIndex % _kSrsDeckBadgeShapes.length];

/// 牌组今天还剩的张数（三种计数之和；父牌组的计数已含子牌组）。
int _srsDeckToday(SrsDeckSummary d) =>
    d.newCount + d.learnCount + d.reviewCount;

/// 牌组今天还有没有活（有剩余，或到期数在等 RWKV）。
bool _srsDeckHasWork(SrsDeckSummary d) => _srsDeckToday(d) > 0 || d.rwkvPending;

/// 「18 待复习 · 2 学习中 · 4 新词」；RWKV 未就绪时到期一项写「准备中」；全零写「今天已完成」。
String _srsDeckMeta(SrsDeckSummary d) {
  final List<String> parts = <String>[
    if (d.reviewCount > 0) t.srs_home_meta_due(n: d.reviewCount),
    if (d.rwkvPending) t.srs_home_meta_pending,
    if (d.learnCount > 0) t.srs_home_meta_learning(n: d.learnCount),
    if (d.newCount > 0) t.srs_home_meta_new(n: d.newCount),
  ];
  return parts.isEmpty ? t.srs_home_deck_done : parts.join(' · ');
}

/// 牌组名首字（徽章里画）。
String _srsDeckInitial(SrsDeckSummary d) =>
    d.deck.name.characters.isEmpty ? '?' : d.deck.name.characters.first;

/// 顶层牌组在顶层里的序号（徽章形状轮换用）。
int _srsRootIndexOf(List<SrsDeckSummary> decks, SrsDeckSummary root) {
  int i = 0;
  for (final SrsDeckSummary d in decks) {
    if (d.parentId != null) continue;
    if (identical(d, root) || d.deck.id == root.deck.id) return i;
    i++;
  }
  return 0;
}

/// [deck] 所在的顶层牌组（详情面板的徽章跟着它的顶层祖先取形状）。
SrsDeckSummary _srsRootOf(
  SrsDeckSummary deck,
  Map<String, SrsDeckSummary> byId,
) {
  SrsDeckSummary d = deck;
  int guard = 0;
  while (d.parentId != null && guard++ < 64) {
    final SrsDeckSummary? parent = byId[d.parentId];
    if (parent == null) break;
    d = parent;
  }
  return d;
}

/// 日期格式化：按当前语言，没有该语言的日期数据时退回英文（[srsHomeStatsProvider] 已备好数据）。
String _srsHomeDate(int day, DateFormat Function(String locale) pattern) {
  final DateTime d = srsDayToDate(day);
  try {
    return pattern(LocaleSettings.currentLocale.languageTag).format(d);
  } on ArgumentError {
    return pattern('en').format(d);
  }
}

/// 预测图横轴：今天写「今天」，其余写星期几。
String _srsForecastLabel(int today, int offset) =>
    offset == 0 ? t.stat_today : _srsHomeDate(today + offset, DateFormat.E);

/// 预测图气泡标题：「明天 · 11/5」。
String _srsForecastTitle(int today, int offset) {
  final String when = switch (offset) {
    0 => t.stat_today,
    1 => t.srs_stats_tomorrow,
    _ => t.srs_stats_in_days(n: offset),
  };
  return '$when · ${_srsHomeDate(today + offset, DateFormat.Md)}';
}

String _srsPercent(double v) => '${(v * 100).round()}%';

/// AnimatedSwitcher 的布局：新旧两层顶端对齐叠放（默认居中，高度不同的面板切换时会上下跳）。
Widget _srsTopStackLayout(Widget? current, List<Widget> previous) => Stack(
  alignment: AlignmentDirectional.topCenter,
  children: <Widget>[...previous, ?current],
);

/// 复习首页：根层（今日计划 + 牌组树 + 热力图 / 预测），宽屏右栏是选中牌组详情；手机上 [focus]
/// 非 null 时是该牌组的详情页。
class _SrsHomeView extends StatelessWidget {
  const _SrsHomeView({
    required this.data,
    required this.wide,
    required this.focus,
    required this.selectedId,
    required this.stats,
    required this.deleting,
    required this.banners,
    required this.onFocus,
    required this.onSelect,
    required this.onReview,
    required this.onAction,
    required this.onSetCollapsed,
    required this.onPlace,
  });

  final SrsDeckListData data;

  /// 双栏排法（[_kSrsHomeWideMin]）。
  final bool wide;

  /// 手机：当前打开的牌组详情页；null = 根层。宽屏恒为 null。
  final SrsDeckSummary? focus;

  /// 宽屏：用户选中的牌组 id（失效或 null 时选第一个有活的顶层牌组）。
  final String? selectedId;
  final SrsHomeStats? stats;
  final Map<String, ValueListenable<double?>> deleting;

  /// 同步 / 导入 / 迁移提醒 / 空库等横幅（只在根层显示）。
  final List<Widget> banners;
  final ValueChanged<String?> onFocus;
  final ValueChanged<String> onSelect;
  final void Function(SrsDeckSummary deck) onReview;
  final void Function(SrsDeckSummary deck, _DeckAction action) onAction;
  final Future<int?> Function(SrsDeckSummary deck, bool collapsed)
  onSetCollapsed;
  final _DeckPlace onPlace;

  /// 宽屏右栏默认显示的牌组：有效的选中 → 第一个有活的顶层牌组 → 第一个顶层牌组。
  SrsDeckSummary? _selection(Map<String, SrsDeckSummary> byId) {
    final SrsDeckSummary? picked = selectedId == null ? null : byId[selectedId];
    if (picked != null) return picked;
    final SrsDeckSummary? work = data.firstRootWithWork;
    if (work != null) return work;
    for (final SrsDeckSummary d in data.decks) {
      if (d.parentId == null) return d;
    }
    return null;
  }

  Widget _tree({
    required String? rootId,
    required List<Widget> header,
    required List<Widget> footer,
    required EdgeInsets padding,
    required void Function(SrsDeckSummary deck) onOpen,
    String? selectedId,
  }) => _DeckList(
    key: ValueKey<String>('srs-tree-${rootId ?? '<root>'}'),
    data: data,
    rootId: rootId,
    selectedId: selectedId,
    stats: stats,
    deleting: deleting,
    header: header,
    footer: footer,
    padding: padding,
    onOpen: onOpen,
    onReview: onReview,
    onAction: onAction,
    onSetCollapsed: onSetCollapsed,
    onPlace: onPlace,
  );

  Widget _detail(SrsDeckSummary deck, Map<String, SrsDeckSummary> byId) {
    final List<SrsDeckSummary> level = _siblingsOf(data.decks, deck);
    final int i = level.indexWhere(
      (SrsDeckSummary d) => d.deck.id == deck.deck.id,
    );
    final SrsDeckSummary root = _srsRootOf(deck, byId);
    return _SrsDeckDetail(
      key: ValueKey<String>('srs-home-detail-${deck.deck.id}'),
      deck: deck,
      detail: stats?.detailFor(
        deck.deck.id,
        srsDeckSubtreeIds(data.decks, deck.deck.id),
      ),
      today: stats?.today,
      shape: _srsDeckBadgeShape(_srsRootIndexOf(data.decks, root)),
      isDefault: deck.deck.id == data.store.defaultDeckId,
      canMoveUp: i > 0,
      canMoveDown: i >= 0 && i < level.length - 1,
      onReview: onReview,
      onAction: onAction,
    );
  }

  /// 根层树上方的部分：横幅 + 今日计划 + 「牌组 · N 张」。
  List<Widget> _rootHeader({required bool horizontal}) => <Widget>[
    ...banners,
    if (data.totalCards > 0)
      _SrsTodayPlan(
        key: const ValueKey<String>('srs-home-today'),
        data: data,
        stats: stats,
        horizontal: horizontal,
        onReview: onReview,
      ),
    if (data.decks.isNotEmpty)
      _SrsHomeSectionHeader(
        key: const ValueKey<String>('srs-home-decks-header'),
        title: t.srs_home_decks_header,
        trailing: t.srs_home_deck_cards(n: data.totalCards),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Map<String, SrsDeckSummary> byId = <String, SrsDeckSummary>{
      for (final SrsDeckSummary d in data.decks) d.deck.id: d,
    };
    // 正文滚到浮动页头底下：顶部让出「状态栏 + 页头」。
    final double top = tokens.spacing.gap + MediaQuery.paddingOf(context).top;
    final SrsHomeStats? s = stats;

    if (wide) {
      final SrsDeckSummary? selected = _selection(byId);
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double content = math.min(
            constraints.maxWidth - tokens.spacing.page * 2,
            _kSrsHomeContentMaxWidth,
          );
          final double side = math.max(
            0,
            (constraints.maxWidth - content) / 2 - tokens.spacing.gap / 2,
          );
          final EdgeInsets columnPadding = withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              tokens.spacing.gap / 2,
              top,
              tokens.spacing.gap / 2,
              tokens.spacing.section,
            ),
          );
          final bool three = content >= _kSrsHomeThreeColumnMin;
          final List<Widget> statCards = <Widget>[
            if (s != null) ...<Widget>[
              _SrsHeatmapCard(
                key: const ValueKey<String>('srs-home-heatmap'),
                stats: s,
              ),
              _SrsForecastCard(
                key: const ValueKey<String>('srs-home-forecast'),
                stats: s,
              ),
            ],
          ];
          // 两栏时热力图（宽）跟在树下面，未来 7 天（窄）跟在详情下面，两栏高度大致平衡；
          // 三栏时两张统计卡自成一栏。
          Widget sideColumn(List<Widget> children) => SingleChildScrollView(
            // 侧栏各自滚动；不接主滚动控制器（主滚动归左栏的树）。
            primary: false,
            padding: columnPadding,
            child: FushiEntranceScope(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  for (int i = 0; i < children.length; i++)
                    FushiStaggeredEntrance(index: i, child: children[i]),
                ],
              ),
            ),
          );
          final Widget detail = AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            layoutBuilder: _srsTopStackLayout,
            child: selected == null
                ? const SizedBox.shrink()
                : KeyedSubtree(
                    key: ValueKey<String>(
                      'srs-home-detail-pane-${selected.deck.id}',
                    ),
                    child: _detail(selected, byId),
                  ),
          );
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: side),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                Expanded(
                  flex: three ? 10 : 11,
                  child: _tree(
                    rootId: null,
                    selectedId: selected?.deck.id,
                    header: _rootHeader(horizontal: true),
                    footer: three
                        ? const <Widget>[]
                        : <Widget>[if (statCards.isNotEmpty) statCards.first],
                    padding: columnPadding,
                    onOpen: (SrsDeckSummary d) => onSelect(d.deck.id),
                  ),
                ),
                Expanded(
                  flex: three ? 8 : 9,
                  child: sideColumn(<Widget>[
                    detail,
                    if (!three && statCards.length > 1) statCards.last,
                  ]),
                ),
                if (three) Expanded(flex: 7, child: sideColumn(statCards)),
              ],
            ),
          );
        },
      );
    }

    final EdgeInsets padding = withBottomSafeInset(
      context,
      EdgeInsets.fromLTRB(
        tokens.spacing.page,
        top,
        tokens.spacing.page,
        tokens.spacing.section,
      ),
    );
    final SrsDeckSummary? focused = focus;
    final Widget body;
    if (focused == null) {
      body = _tree(
        rootId: null,
        header: _rootHeader(horizontal: false),
        footer: <Widget>[
          if (s != null)
            _SrsHomeStatsPair(
              key: const ValueKey<String>('srs-home-stats'),
              stats: s,
            ),
        ],
        padding: padding,
        onOpen: (SrsDeckSummary d) => onFocus(d.deck.id),
      );
    } else {
      final bool hasChildren = data.decks.any(
        (SrsDeckSummary d) => d.parentId == focused.deck.id,
      );
      body = _tree(
        rootId: focused.deck.id,
        header: <Widget>[
          _SrsDeckBreadcrumb(
            key: const ValueKey<String>('srs-home-breadcrumb'),
            deck: focused,
            byId: byId,
            onFocus: onFocus,
          ),
          _detail(focused, byId),
          if (hasChildren)
            _SrsHomeSectionHeader(
              key: const ValueKey<String>('srs-home-subdecks-header'),
              title: t.srs_home_subdecks_header,
            ),
        ],
        footer: const <Widget>[],
        padding: padding,
        onOpen: (SrsDeckSummary d) => onFocus(d.deck.id),
      );
    }
    // 进 / 出详情页带淡入淡出；新旧两层的列表同时在树上，见 [_srsHomeSwitchTransition]。
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      transitionBuilder: _srsHomeSwitchTransition,
      child: KeyedSubtree(
        key: ValueKey<String>('srs-home-${focused?.deck.id ?? '<root>'}'),
        child: body,
      ),
    );
  }
}

/// 区块小标题：「牌组 · 1501 张」/「子牌组」。
class _SrsHomeSectionHeader extends StatelessWidget {
  const _SrsHomeSectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color muted = isGlassDesign(context)
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final String? more = trailing;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.gap,
        tokens.spacing.gap / 2,
        tokens.spacing.gap,
        0,
      ),
      child: Text(
        more == null ? title : '$title · $more',
        style: context.fushiType.labelLarge.copyWith(color: muted),
      ),
    );
  }
}

/// 今日计划条：「今天还剩 N 张」+「约 X 分钟 · 已完成 Y 张 · 连续 Z 天」+ 三色分段进度条 +
/// 图例 +「开始复习」。全部完成时换成完成态。
///
/// 「开始复习」复习第一个还有活的顶层牌组（与首页 dashboard 复习条同一口径，
/// [SrsDeckListData.firstRootWithWork]），多个顶层牌组有活时注明从哪个开始。
class _SrsTodayPlan extends StatelessWidget {
  const _SrsTodayPlan({
    super.key,
    required this.data,
    required this.stats,
    required this.horizontal,
    required this.onReview,
  });

  final SrsDeckListData data;
  final SrsHomeStats? stats;

  /// 宽屏：按钮在右上；手机：按钮整宽在下。
  final bool horizontal;
  final void Function(SrsDeckSummary deck) onReview;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color onCard = apple
        ? appleColorsOf(context).label
        : scheme.onPrimaryContainer;
    final ({Color fresh, Color learn, Color review}) colors = srsCountColors(
      context,
    );
    final int remaining = data.todayNew + data.todayLearn + data.todayReview;
    final bool pending = data.rwkvPending;
    final bool allDone = remaining == 0 && !pending;
    final SrsHomeStats? s = stats;
    final int? minutes = s?.minutesFor(remaining);
    final SrsDeckSummary? target = data.firstRootWithWork;
    final int rootsWithWork = data.decks
        .where((SrsDeckSummary d) => d.parentId == null && _srsDeckHasWork(d))
        .length;
    final TextStyle sub = context.fushiType.bodySmall.copyWith(
      color: onCard.withValues(alpha: 0.78),
    );

    final String title = remaining > 0
        ? t.srs_home_today_left(n: remaining)
        : pending
        ? t.srs_home_meta_pending
        : t.srs_home_all_done;
    final List<String> facts = <String>[
      if (minutes != null && !allDone) t.srs_home_minutes(n: minutes),
      if (s != null && s.doneToday > 0) t.srs_home_done_count(n: s.doneToday),
      if (s != null && s.streak > 0) t.srs_home_streak(n: s.streak),
    ];
    final Widget heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: tokens.spacing.gap / 4,
      children: <Widget>[
        Row(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            if (allDone)
              FushiIcon(
                FushiIcons.check,
                size: 28,
                color: apple ? appleColorsOf(context).accent : onCard,
              ),
            Flexible(
              child: Text(
                title,
                key: const ValueKey<String>('srs-home-today-title'),
                style: context.fushiType.headlineSmallEmphasized.copyWith(
                  color: onCard,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (facts.isNotEmpty) Text(facts.join(' · '), style: sub),
      ],
    );
    final Widget bar = _SrsTodayBar(
      done: s?.doneToday ?? (allDone ? 1 : 0),
      review: data.todayReview,
      learn: data.todayLearn,
      fresh: data.todayNew,
      doneColor: apple ? appleColorsOf(context).accent : scheme.primary,
      track: onCard.withValues(alpha: 0.14),
      colors: colors,
    );
    Widget legendItem(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: <Widget>[
        SizedBox.square(
          dimension: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        Text(label, style: sub),
      ],
    );
    final Widget legend = Wrap(
      spacing: tokens.spacing.gap * 1.5,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        legendItem(
          colors.review,
          pending && data.todayReview == 0
              ? '${t.srs_home_meta_due(n: 0)} (${t.srs_home_meta_pending})'
              : t.srs_home_meta_due(n: data.todayReview),
        ),
        legendItem(colors.learn, t.srs_home_meta_learning(n: data.todayLearn)),
        legendItem(colors.fresh, t.srs_home_meta_new(n: data.todayNew)),
      ],
    );
    final SrsDeckSummary? go = target;
    final Widget? start = go == null
        ? null
        : FushiPressScale(
            child: FushiFilledButton.icon(
              key: const ValueKey<String>('srs-home-start'),
              size: FushiButtonSize.m,
              onPressed: () => onReview(go),
              icon: const FushiIcon(FushiIcons.play),
              label: Text(t.srs_home_start),
            ),
          );
    final Widget? from = go != null && rootsWithWork > 1
        ? Text(t.srs_home_start_from(name: go.deck.name), style: sub)
        : null;

    return FushiCard(
      tone: FushiCardTone.primary,
      pressScale: false,
      stateLayer: false,
      padding: EdgeInsets.all(tokens.spacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: tokens.spacing.gap * 1.5,
        children: <Widget>[
          if (horizontal)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: tokens.spacing.gap * 1.5,
              children: <Widget>[
                Expanded(child: heading),
                if (start != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    spacing: tokens.spacing.gap / 2,
                    children: <Widget>[start, ?from],
                  ),
              ],
            )
          else
            heading,
          if (!allDone || (s?.doneToday ?? 0) > 0) bar,
          if (!allDone) legend,
          if (!horizontal && start != null) ...<Widget>[
            start,
            if (from != null) Center(child: from),
          ],
        ],
      ),
    );
  }
}

/// 今日计划条的分段进度条：今日已完成一段 + 剩余按到期 / 学习中 / 新卡三色分段，总长 = 已完成 + 剩余。
class _SrsTodayBar extends StatelessWidget {
  const _SrsTodayBar({
    required this.done,
    required this.review,
    required this.learn,
    required this.fresh,
    required this.doneColor,
    required this.track,
    required this.colors,
  });

  final int done;
  final int review;
  final int learn;
  final int fresh;
  final Color doneColor;
  final Color track;
  final ({Color fresh, Color learn, Color review}) colors;

  static const double _height = 10;
  static const double _gap = 2;

  @override
  Widget build(BuildContext context) {
    final List<(int, Color)> parts = <(int, Color)>[
      (done, doneColor),
      // 剩余三段用浅一档的同色，和「已完成」那段（实色）拉开层次。
      (review, colors.review.withValues(alpha: 0.45)),
      (learn, colors.learn.withValues(alpha: 0.45)),
      (fresh, colors.fresh.withValues(alpha: 0.45)),
    ];
    final int total = parts.fold<int>(0, (int a, (int, Color) p) => a + p.$1);
    final Duration duration = fushiMotionDuration(context, FushiMotion.long);
    return Semantics(
      label: t.srs_home_done_count(n: done),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_height / 2),
        child: SizedBox(
          height: _height,
          child: DecoratedBox(
            decoration: BoxDecoration(color: track),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                final int shown = parts
                    .where(((int, Color) p) => p.$1 > 0)
                    .length;
                // 段间距只加在「后面还有非空段」的段上，最后一段不带，免得总宽溢出。
                final int lastShown = parts.lastIndexWhere(
                  ((int, Color) p) => p.$1 > 0,
                );
                final double room = math.max(
                  0,
                  box.maxWidth - math.max(0, shown - 1) * _gap,
                );
                return Row(
                  children: <Widget>[
                    for (int i = 0; i < parts.length; i++)
                      AnimatedContainer(
                        duration: duration,
                        curve: FushiMotion.enter,
                        width: total == 0 ? 0 : room * parts[i].$1 / total,
                        margin: EdgeInsetsDirectional.only(
                          end: parts[i].$1 > 0 && i < lastShown ? _gap : 0,
                        ),
                        color: parts[i].$2,
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 牌组行的细进度条（今天的完成度，口径见 [srsTodayProgress]）。
class _SrsDeckProgress extends StatelessWidget {
  const _SrsDeckProgress({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fill = apple ? appleColorsOf(context).accent : scheme.primary;
    final Color track = apple
        ? appleColorsOf(context).tertiaryFill
        : scheme.surfaceContainerHighest;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 4,
        child: DecoratedBox(
          decoration: BoxDecoration(color: track),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: value.clamp(0, 1)),
              duration: fushiMotionDuration(context, FushiMotion.long),
              curve: FushiMotion.enter,
              builder: (BuildContext context, double f, Widget? _) =>
                  FractionallySizedBox(
                    widthFactor: f,
                    heightFactor: 1,
                    child: ColoredBox(color: fill),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 行尾的小号 tonal 播放按钮：直接复习这个牌组。
class _SrsDeckPlayButton extends StatelessWidget {
  const _SrsDeckPlayButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = apple
        ? appleColorsOf(context).accent
        : scheme.onSecondaryContainer;
    final Color fill = apple
        ? appleColorsOf(context).accent.withValues(alpha: 0.15)
        : scheme.secondaryContainer;
    return FushiPressScale(
      child: FushiIconButton(
        icon: FushiIcons.play,
        tooltip: t.srs_home_review_deck,
        backgroundColor: fill,
        enabledColor: ink,
        size: 20,
        onTap: onTap,
      ),
    );
  }
}

/// M3E 形状徽章（Apple：圆角方块）。
class _SrsDeckBadge extends StatelessWidget {
  const _SrsDeckBadge({
    required this.shape,
    required this.size,
    required this.label,
    this.done = false,
  });

  final RoundedPolygon shape;
  final double size;

  /// 徽章里的字（牌组名首字）。
  final String label;

  /// 今天这里没事做了：徽章换成弱化色。
  final bool done;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fill = apple
        ? appleColorsOf(context).accent.withValues(alpha: done ? 0.08 : 0.18)
        : (done ? scheme.surfaceContainerHighest : scheme.primaryContainer);
    final Color ink = apple
        ? appleColorsOf(context).accent
        : (done ? scheme.onSurfaceVariant : scheme.onPrimaryContainer);
    final ShapeBorder border = apple
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(size / 4))
        : MaterialShapeBorder(shape: shape);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(color: fill, shape: border),
          child: Center(
            child: Text(
              label,
              style:
                  (size >= 48
                          ? context.fushiType.titleLargeEmphasized
                          : context.fushiType.titleSmallEmphasized)
                      .copyWith(color: ink, height: 1),
            ),
          ),
        ),
      ),
    );
  }
}

/// 选中牌组的详情（宽屏右栏 / 手机详情页）：形状徽章 + 名字 + 张数统计、未来 7 天到期柱状图、
/// 保持率，按钮「复习这个牌组」「浏览卡片」「选项」。
class _SrsDeckDetail extends StatelessWidget {
  const _SrsDeckDetail({
    super.key,
    required this.deck,
    required this.detail,
    required this.today,
    required this.shape,
    required this.isDefault,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onReview,
    required this.onAction,
  });

  final SrsDeckSummary deck;

  /// 该牌组（含子牌组）的统计；统计还没读完时为 null（图表处留位）。
  final SrsHomeDeckDetail? detail;

  /// 统计日序号（预测图横轴）；统计还没读完时为 null。
  final int? today;
  final RoundedPolygon shape;
  final bool isDefault;
  final bool canMoveUp;
  final bool canMoveDown;
  final void Function(SrsDeckSummary deck) onReview;
  final void Function(SrsDeckSummary deck, _DeckAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color muted = isGlassDesign(context)
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final TextStyle small = context.fushiType.bodySmall.copyWith(color: muted);
    final SrsHomeDeckDetail? d = detail;
    final int? day = today;
    final bool work = _srsDeckHasWork(deck);
    final List<int>? forecast = d?.forecast;

    final Widget head = Row(
      spacing: tokens.spacing.gap * 1.5,
      children: <Widget>[
        _SrsDeckBadge(
          shape: shape,
          size: 52,
          label: _srsDeckInitial(deck),
          done: !work,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 2,
            children: <Widget>[
              FushiTooltip(
                message: deck.fullName,
                child: Text(
                  deck.deck.name,
                  key: ValueKey<String>('srs-home-detail-name-${deck.deck.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.fushiType.titleLargeEmphasized,
                ),
              ),
              Text(
                d == null
                    ? t.srs_home_deck_cards(n: deck.totalCards)
                    : t.srs_home_deck_card_counts(
                        n: deck.totalCards,
                        fresh: d.newCards,
                        mature: d.matureCards,
                      ),
                style: small,
              ),
              Text(_srsDeckMeta(deck), style: small),
            ],
          ),
        ),
      ],
    );

    final Widget chart = forecast == null || day == null
        ? const SizedBox(height: _SrsForecastChart.height)
        : _SrsForecastChart(values: forecast, today: day);

    final Widget actions = Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        FushiPressScale(
          child: FushiFilledButton.icon(
            key: const ValueKey<String>('srs-home-detail-review'),
            onPressed: work ? () => onReview(deck) : null,
            icon: const FushiIcon(FushiIcons.play),
            label: Text(t.srs_home_review_deck),
          ),
        ),
        FushiPressScale(
          child: FushiFilledButton.tonalIcon(
            key: const ValueKey<String>('srs-home-detail-browse'),
            onPressed: () => onAction(deck, _DeckAction.browse),
            icon: const FushiIcon(FushiIcons.search),
            label: Text(t.srs_home_browse_cards),
          ),
        ),
        Builder(
          builder: (BuildContext anchor) => FushiPressScale(
            child: FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('srs-home-detail-options'),
              onPressed: () => unawaited(
                _showDeckMenu(
                  anchor,
                  deck: deck,
                  isDefault: isDefault,
                  canMoveUp: canMoveUp,
                  canMoveDown: canMoveDown,
                  onAction: onAction,
                ),
              ),
              icon: const FushiIcon(FushiIcons.settings),
              label: Text(t.srs_home_deck_options),
            ),
          ),
        ),
      ],
    );

    final double? retention = d?.retention;
    final double? target = d?.desiredRetention;
    final Widget retentionCard = FushiCard(
      key: const ValueKey<String>('srs-home-detail-retention'),
      pressScale: false,
      stateLayer: false,
      padding: EdgeInsets.all(tokens.spacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: tokens.spacing.gap / 2,
        children: <Widget>[
          Text(t.srs_home_retention_title, style: small),
          if (d == null)
            const SizedBox(height: 32)
          else if (retention == null)
            Text(t.srs_home_retention_none, style: small)
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              spacing: tokens.spacing.gap * 1.5,
              children: <Widget>[
                Text(
                  _srsPercent(retention),
                  style: context.fushiType.headlineMediumEmphasized.copyWith(
                    height: 1,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                Flexible(
                  child: Text(
                    t.srs_home_retention_detail(
                      target: target == null ? '—' : _srsPercent(target),
                      n: d.reviewsRecent,
                    ),
                    style: small,
                  ),
                ),
              ],
            ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: tokens.spacing.gap * 1.5,
      children: <Widget>[
        FushiCard(
          pressScale: false,
          stateLayer: false,
          padding: EdgeInsets.all(tokens.spacing.page),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: tokens.spacing.gap,
            children: <Widget>[
              head,
              SizedBox(height: tokens.spacing.gap / 2),
              Text(t.srs_home_forecast_title, style: small),
              chart,
              if (forecast != null && forecast.length > 1)
                Text(
                  t.srs_home_forecast_tomorrow(n: forecast[1]),
                  style: small,
                ),
              SizedBox(height: tokens.spacing.gap / 2),
              actions,
            ],
          ),
        ),
        retentionCard,
      ],
    );
  }
}

/// 未来几天逐日到期的小柱状图（复用统计页的 [SrsBarChart]：点按 / 悬停看当天张数）。
class _SrsForecastChart extends StatelessWidget {
  const _SrsForecastChart({required this.values, required this.today});

  static const double height = 120;

  /// 第 0 天 = 今天（含已逾期）。
  final List<int> values;
  final int today;

  @override
  Widget build(BuildContext context) {
    final SrsStatColors colors = SrsStatColors.of(context);
    return SrsBarChart(
      height: height,
      showTotalInTooltip: false,
      bars: <SrsBarDatum>[
        for (int i = 0; i < values.length; i++)
          SrsBarDatum(
            label: _srsForecastLabel(today, i),
            title: _srsForecastTitle(today, i),
            values: <int>[values[i]],
          ),
      ],
      series: <SrsChartSeries>[
        SrsChartSeries(t.srs_home_forecast_title, colors.young),
      ],
      scaleOf: statCountAxisScale,
      valueText: (int v) => '$v',
    );
  }
}

/// 复习热力图卡：「连续 N 天 · 最长 M 天」+ 统计页同款日历热力图。
class _SrsHeatmapCard extends StatelessWidget {
  const _SrsHeatmapCard({super.key, required this.stats});

  final SrsHomeStats stats;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
              t.srs_home_streak_longest(
                n: stats.streak,
                m: stats.longestStreak,
              ),
              style: context.fushiType.titleSmallEmphasized,
            ),
            SrsCalendarHeatmap(
              countsByDay: stats.countsByDay,
              today: stats.today,
              dayLabel: (int day) => _srsHomeDate(day, DateFormat.yMd),
              monthLabel: (int day) => _srsHomeDate(day, DateFormat.MMM),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全库未来 7 天到期卡：柱状图 + 「明天 N 张」。
class _SrsForecastCard extends StatelessWidget {
  const _SrsForecastCard({super.key, required this.stats});

  final SrsHomeStats stats;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color muted = isGlassDesign(context)
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final List<int> forecast = stats.forecast;
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
              t.srs_home_forecast_title,
              style: context.fushiType.titleSmallEmphasized,
            ),
            if (forecast.isNotEmpty)
              _SrsForecastChart(values: forecast, today: stats.today),
            if (forecast.length > 1)
              Text(
                t.srs_home_forecast_tomorrow(n: forecast[1]),
                style: context.fushiType.bodySmall.copyWith(color: muted),
              ),
          ],
        ),
      ),
    );
  }
}

/// 手机树下的两张小卡：热力图 + 未来 7 天，够宽时并排，否则上下排。
class _SrsHomeStatsPair extends StatelessWidget {
  const _SrsHomeStatsPair({super.key, required this.stats});

  final SrsHomeStats stats;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget heat = _SrsHeatmapCard(
      key: const ValueKey<String>('srs-home-heatmap'),
      stats: stats,
    );
    final Widget forecast = _SrsForecastCard(
      key: const ValueKey<String>('srs-home-forecast'),
      stats: stats,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) =>
          box.maxWidth >= _kSrsHomeStatsSideBySideMin
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                Expanded(child: heat),
                Expanded(child: forecast),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.spacing.gap,
              children: <Widget>[heat, forecast],
            ),
    );
  }
}

/// 面包屑：全部牌组 › 祖先… › 当前。点哪一级回到哪一级（手机详情页）。
class _SrsDeckBreadcrumb extends StatelessWidget {
  const _SrsDeckBreadcrumb({
    super.key,
    required this.deck,
    required this.byId,
    required this.onFocus,
  });

  final SrsDeckSummary deck;
  final Map<String, SrsDeckSummary> byId;
  final ValueChanged<String?> onFocus;

  @override
  Widget build(BuildContext context) {
    final List<SrsDeckSummary> chain = <SrsDeckSummary>[deck];
    String? p = deck.parentId;
    int guard = 0;
    while (p != null && guard++ < 64) {
      final SrsDeckSummary? parent = byId[p];
      if (parent == null) break;
      chain.insert(0, parent);
      p = parent.parentId;
    }
    final Color muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget sep() => FushiIcon(FushiIcons.chevronRight, size: 16, color: muted);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      runSpacing: 2,
      children: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('srs-home-crumb-root'),
          onPressed: () => onFocus(null),
          child: Text(t.srs_home_all_decks),
        ),
        for (final SrsDeckSummary d in chain) ...<Widget>[
          sep(),
          if (identical(d, deck))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                d.deck.name,
                style: context.fushiType.labelLargeEmphasized,
              ),
            )
          else
            FushiTextButton(
              key: ValueKey<String>('srs-home-crumb-${d.deck.id}'),
              onPressed: () => onFocus(d.deck.id),
              child: Text(d.deck.name),
            ),
        ],
      ],
    );
  }
}

/// 牌组菜单项（牌组行、详情面板「选项」共用一份）。
List<PopupMenuEntry<_DeckAction>> _deckMenuItems({
  required bool isDefault,
  required bool canMoveUp,
  required bool canMoveDown,
}) => <PopupMenuEntry<_DeckAction>>[
  PopupMenuItem<_DeckAction>(
    value: _DeckAction.customStudy,
    child: Text(t.srs_custom_study_title),
  ),
  // 默认牌组同样可用：批量移动 / 删除错导的卡从这里进（反馈 SSfSHb5JNt）。
  PopupMenuItem<_DeckAction>(
    value: _DeckAction.browse,
    child: Text(t.srs_deck_browse_cards),
  ),
  PopupMenuItem<_DeckAction>(
    value: _DeckAction.addChild,
    child: Text(t.srs_deck_new_child),
  ),
  PopupMenuItem<_DeckAction>(
    value: _DeckAction.rename,
    child: Text(t.srs_deck_rename),
  ),
  PopupMenuItem<_DeckAction>(
    value: _DeckAction.move,
    child: Text(t.srs_deck_move),
  ),
  if (canMoveUp)
    PopupMenuItem<_DeckAction>(
      value: _DeckAction.moveUp,
      child: Text(t.srs_deck_move_up),
    ),
  if (canMoveDown)
    PopupMenuItem<_DeckAction>(
      value: _DeckAction.moveDown,
      child: Text(t.srs_deck_move_down),
    ),
  PopupMenuItem<_DeckAction>(
    value: _DeckAction.settings,
    child: Text(t.srs_deck_settings),
  ),
  PopupMenuItem<_DeckAction>(
    value: _DeckAction.fillWordAudio,
    child: Text(t.srs_word_audio_backfill_title),
  ),
  if (!isDefault)
    PopupMenuItem<_DeckAction>(
      value: _DeckAction.delete,
      child: Text(t.srs_deck_delete),
    ),
];

/// 在 [anchorContext] 的位置弹出牌组菜单，选中后交给 [onAction]。
Future<void> _showDeckMenu(
  BuildContext anchorContext, {
  required SrsDeckSummary deck,
  required bool isDefault,
  required bool canMoveUp,
  required bool canMoveDown,
  required void Function(SrsDeckSummary deck, _DeckAction action) onAction,
  Offset? at,
}) async {
  final RenderBox? box = anchorContext.findRenderObject() as RenderBox?;
  final RenderBox? overlay =
      Navigator.of(anchorContext).overlay?.context.findRenderObject()
          as RenderBox?;
  if (box == null || overlay == null || !box.hasSize) return;
  final Rect rowRect =
      box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final Offset anchor = at ?? rowRect.centerRight;
  final _DeckAction? picked = await showFushiMenu<_DeckAction>(
    context: anchorContext,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(anchor.dx, rowRect.top, 0, rowRect.height),
      Offset.zero & overlay.size,
    ),
    semanticLabel: t.srs_deck_menu,
    items: _deckMenuItems(
      isDefault: isDefault,
      canMoveUp: canMoveUp,
      canMoveDown: canMoveDown,
    ),
  );
  if (picked != null) onAction(deck, picked);
}

/// 牌组页的横幅（导入任务 / Lapis 迁移提醒 / 引擎不可用 / 空库）：首页根层树的最前面。
List<Widget> _srsDeckBanners(
  BuildContext context, {
  required SrsDeckListData data,
  required bool showImportTasks,
  required int lapisPending,
  required VoidCallback onMigrateLapis,
  required VoidCallback onDismissLapisReminder,
  required VoidCallback onStarterPacks,
  required VoidCallback onAddFirst,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return <Widget>[
    // 后台导入任务（BUG-3549）：有任务时排在最前。
    if (showImportTasks)
      const SrsImportTasksBar(key: ValueKey<String>('srs-import-tasks')),
    if (lapisPending > 0)
      FushiCard(
        key: const ValueKey<String>('srs-lapis-migration-reminder'),
        tone: FushiCardTone.primary,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Row(
              spacing: tokens.spacing.gap * 1.5,
              children: <Widget>[
                const FushiIcon(FushiIcons.swap),
                Expanded(
                  child: Text(
                    t.srs_lapis_migration_reminder_title,
                    style: context.fushiType.titleMediumEmphasized,
                  ),
                ),
              ],
            ),
            Text(t.srs_lapis_migration_entry_summary(n: lapisPending)),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                FushiPressScale(
                  child: FushiTextButton(
                    key: const ValueKey<String>(
                      'srs-lapis-migration-reminder-dismiss',
                    ),
                    onPressed: onDismissLapisReminder,
                    child: Text(t.srs_lapis_migration_reminder_dismiss),
                  ),
                ),
                FushiPressScale(
                  child: FushiFilledButton.icon(
                    key: const ValueKey<String>(
                      'srs-lapis-migration-reminder-open',
                    ),
                    onPressed: onMigrateLapis,
                    icon: const FushiIcon(FushiIcons.swap),
                    label: Text(t.srs_lapis_migration_migrate),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    if (!data.store.canSchedule)
      FushiCard(
        key: const ValueKey<String>('srs-engine-missing'),
        tone: FushiCardTone.error,
        child: Row(
          spacing: tokens.spacing.gap * 1.5,
          children: <Widget>[
            const FushiIcon(FushiIcons.warning),
            Expanded(child: Text(t.srs_engine_unavailable)),
          ],
        ),
      ),
    if (data.totalCards == 0)
      FushiCard(
        key: const ValueKey<String>('srs-empty'),
        tone: FushiCardTone.primary,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Text(
              t.srs_empty_title,
              style: context.fushiType.titleMediumEmphasized,
            ),
            Text(t.srs_empty_body),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: <Widget>[
                  FushiPressScale(
                    child: FushiFilledButton.tonalIcon(
                      key: const ValueKey<String>('srs-starter-packs'),
                      onPressed: onStarterPacks,
                      icon: const FushiIcon(FushiIcons.cloudDownload),
                      label: Text(t.srs_starter_title),
                    ),
                  ),
                  FushiPressScale(
                    child: FushiFilledButton.icon(
                      key: const ValueKey<String>('srs-add-first'),
                      onPressed: onAddFirst,
                      icon: const FushiIcon(FushiIcons.add),
                      label: Text(t.srs_empty_action),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
  ];
}

/// 手机首页根层 ↔ 牌组详情页切换的淡入淡出。
///
/// 切换时新旧两层同时在树上；Home tab 外层的 [PrimaryScrollController] 全平台继承，
/// 两层的列表会一起挂上同一个控制器（Scrollbar 断言）。退场那层改成不继承，
/// 主滚动只归入场那层。
Widget _srsHomeSwitchTransition(Widget child, Animation<double> animation) =>
    FadeTransition(
      opacity: animation,
      child: _SrsSwitchPrimaryScope(animation: animation, child: child),
    );

class _SrsSwitchPrimaryScope extends StatefulWidget {
  const _SrsSwitchPrimaryScope({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<_SrsSwitchPrimaryScope> createState() => _SrsSwitchPrimaryScopeState();
}

class _SrsSwitchPrimaryScopeState extends State<_SrsSwitchPrimaryScope> {
  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(_SrsSwitchPrimaryScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onStatus);
      widget.animation.addStatusListener(_onStatus);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    super.dispose();
  }

  void _onStatus(AnimationStatus _) => setState(() {});

  @override
  Widget build(BuildContext context) {
    final ScrollController? primary = PrimaryScrollController.maybeOf(context);
    if (primary == null) return widget.child;
    final AnimationStatus status = widget.animation.status;
    final bool leaving =
        status == AnimationStatus.reverse ||
        status == AnimationStatus.dismissed;
    return PrimaryScrollController(
      controller: primary,
      automaticallyInheritForPlatforms: leaving
          ? const <TargetPlatform>{}
          : TargetPlatform.values.toSet(),
      child: widget.child,
    );
  }
}
