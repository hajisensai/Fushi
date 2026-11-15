part of 'home_dashboard_page.dart';

/// 首页小组件网格（spec 2026-11-15）每一格的内容。
///
/// 格子尺寸由网格给定（[HomeWidgetGrid] 紧约束），每种组件按自己的尺寸档排版：
/// 外框一律走 [HomeWidgetFrame]（海报色块 / 分区卡两套外观），只有色块外观下有
/// 条目的「继续」直接画封面色块（与库页同一套 [FushiCoverBlock]）。数据全部来自
/// 本页已有的快照（继续条目、统计行、追踪快照），不新增查询。
extension _HomeWidgetCells on _HomeDashboardPageState {
  /// [item] 这一格的内容；[dense] = 窄网格一行高的格子。
  Widget _buildWidgetCell({
    required FushiDesignTokens tokens,
    required AppModel appModel,
    required List<_ContinueEntry> entries,
    required List<MediaItem> books,
    required HomeWidgetItem item,
    required bool dense,
  }) {
    final bool poster = _posterPanels;
    final HomeWidgetSize size = item.size;
    return switch (item.kind) {
      HomeWidgetKind.continueHero => _continueHeroCell(
        tokens,
        appModel,
        entries,
        size,
        poster,
      ),
      HomeWidgetKind.continueReading ||
      HomeWidgetKind.continueWatching ||
      HomeWidgetKind.continuePlaying => _continueKindCell(
        tokens,
        appModel,
        item.kind,
        <_ContinueEntry>[
          for (final _ContinueEntry e in entries)
            if (homeWidgetContinueKindOf(
                  isBook: e.isBook,
                  isAudiobook: e.isAudiobook,
                  isVideo: e.isVideo,
                  isGame: e.isGame,
                ) ==
                item.kind)
              e,
        ],
        size,
        poster,
        dense,
      ),
      HomeWidgetKind.today => _todayCell(tokens, size, poster, dense),
      HomeWidgetKind.week => _weekCell(poster, dense),
      HomeWidgetKind.srsReview => HomeSrsPanel(
        key: const ValueKey<String>('home-srs-card'),
        onOpenDecks: () => _goToTab(HomeTab.srs),
        onStartReview: _startSrsReview,
        size: size,
        poster: poster,
        dense: dense,
      ),
      HomeWidgetKind.recentlyAdded => _recentCell(
        tokens,
        appModel,
        books,
        size,
        poster,
      ),
      HomeWidgetKind.tracking => _trackingCell(poster, dense),
      HomeWidgetKind.aiAgent => HomeAiAgentPanel(
        key: const ValueKey<String>('home-ai-agent-card'),
        size: size,
        poster: poster,
        dense: dense,
      ),
      HomeWidgetKind.panorama => HomePanoramaPanel(
        key: const ValueKey<String>('home-panorama-card'),
        onOpen: _openPanoramaWork,
        size: size,
        poster: poster,
      ),
    };
  }

  // ── 继续 ────────────────────────────────────────────────────────────────

  /// 「继续」主角：2×2 只有主卡；2×3（主卡在上、其余条目横滑在下）与 4×2（主卡在
  /// 起始侧、横滑在旁边）再挂其余条目。没有条目时是首载骨架 / 空库引导。
  Widget _continueHeroCell(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
    HomeWidgetSize size,
    bool poster,
  ) {
    final bool sideways = size.cols >= 4;
    final bool withSide = entries.length > 1 && (sideways || size.rows >= 3);
    if (entries.isEmpty) {
      return HomeWidgetFrame(
        key: const ValueKey<String>('home-continue-card'),
        title: t.home_continue,
        icon: FushiIcons.playCircle,
        hueKey: HomeWidgetKind.continueHero.id,
        poster: poster,
        dense: false,
        child: HomeWidgetOverflowClip(
          child: _initialLoadDone
              ? _continueEmptyState(appModel)
              : HomeContinueRowSkeleton(
                  coverHeight: _HomeDashboardPageState._kContinueCoverHeight,
                ),
        ),
      );
    }
    if (poster) {
      // 色块外观：主条目是拼贴首块（带状态 chip 与「继续」按钮外观），其余是半高块。
      return KeyedSubtree(
        key: const ValueKey<String>('home-continue-blocks'),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            Widget hero(double _) => _continueBlock(
              tokens,
              appModel,
              entries.first,
              0,
              FushiCoverBlockSize.hero,
            );
            if (!withSide) return hero(c.maxHeight);
            return _heroWithSide(
              area: c.biggest,
              sideways: sideways,
              hero: hero,
              side: (double height) =>
                  _continueBlockRow(tokens, appModel, entries, height),
            );
          },
        ),
      );
    }
    final double gap = tokens.spacing.gap;
    return HomeWidgetFrame(
      key: const ValueKey<String>('home-continue-card'),
      title: t.home_continue,
      icon: FushiIcons.playCircle,
      hueKey: HomeWidgetKind.continueHero.id,
      poster: false,
      dense: false,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          Widget hero(double height) {
            final double cover = math.max(60, height - gap * 3);
            return HomeWidgetOverflowClip(
              child: FushiContinueSpotlight(
                main: _continueMainEntry(tokens, appModel, entries.first),
                heroCoverHeight: cover,
                soloCoverHeight: cover,
                // 整块由网格错峰进场。
                staggerEntrance: false,
              ),
            );
          }

          if (!withSide) return hero(c.maxHeight);
          return _heroWithSide(
            area: c.biggest,
            sideways: sideways,
            hero: hero,
            side: (double height) =>
                _continueCoverRow(tokens, appModel, entries, height),
          );
        },
      ),
    );
  }

  /// 主卡 + 其余条目两段的分割：[sideways] 时左右（主卡占约 55%），否则上下（主卡占
  /// 约 60%）。[hero] / [side] 拿到各自那段的高度。
  Widget _heroWithSide({
    required Size area,
    required bool sideways,
    required Widget Function(double height) hero,
    required Widget Function(double height) side,
  }) {
    const double gap = kFushiCoverBlockSpacing;
    if (sideways) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(width: (area.width - gap) * 0.55, child: hero(area.height)),
          const SizedBox(width: gap),
          Expanded(child: side(area.height)),
        ],
      );
    }
    final double heroHeight = (area.height - gap) * 0.6;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(height: heroHeight, child: hero(heroHeight)),
        const SizedBox(height: gap),
        Expanded(child: side(area.height - heroHeight - gap)),
      ],
    );
  }

  /// 色块外观「继续」其余条目：一行半高封面色块横滑。
  Widget _continueBlockRow(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
    double height,
  ) {
    final double tileWidth = height * 1.9;
    return SectionSwipeCascade(
      child: HorizontalDragScrollable(
        child: ListView.separated(
          key: const ValueKey<String>('home-continue-row'),
          scrollDirection: Axis.horizontal,
          physics: desktopAwareScrollPhysics(),
          itemCount: entries.length - 1,
          separatorBuilder: (BuildContext _, int _) =>
              const SizedBox(width: kFushiCoverBlockSpacing),
          itemBuilder: (BuildContext _, int i) => SizedBox(
            width: tileWidth,
            child: _continueBlock(
              tokens,
              appModel,
              entries[i + 1],
              i + 1,
              FushiCoverBlockSize.half,
            ),
          ),
        ),
      ),
    );
  }

  /// 分区卡外观「继续」其余条目：库页同款封面卡（封面 + 标题 + 进度）横滑。
  Widget _continueCoverRow(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
    double height,
  ) {
    const FushiContinueSideMeta meta = FushiContinueSideMeta.full;
    final double metaHeight = meta.heightFor(context);
    final double coverHeight = math.max(48, height - metaHeight);
    return SectionSwipeCascade(
      child: HorizontalDragScrollable(
        child: ListView.separated(
          key: const ValueKey<String>('home-continue-row'),
          scrollDirection: Axis.horizontal,
          physics: desktopAwareScrollPhysics(),
          itemCount: entries.length - 1,
          separatorBuilder: (BuildContext _, int _) =>
              SizedBox(width: tokens.spacing.gap),
          itemBuilder: (BuildContext _, int i) => FushiContinueOrientedEntry(
            entry: _continueSideEntry(tokens, appModel, entries[i + 1], i + 1),
            builder: (FushiContinueEntry e) => FushiContinueSideTile(
              entry: e,
              coverHeight: coverHeight,
              meta: meta,
              metaHeight: metaHeight,
            ),
          ),
        ),
      ),
    );
  }

  /// 空库引导：一句说明 + 去书架 / 去媒体库（首页不会是一片空白）。
  Widget _continueEmptyState(AppModel appModel) {
    final ModuleVisibility visibility = appModel.moduleVisibility;
    return HomeEmptyState(
      icon: FushiIcons.playCircle,
      message: t.home_continue_empty,
      actions: <Widget>[
        for (final HomeTab tab in const <HomeTab>[HomeTab.books, HomeTab.video])
          if (isHomeTabVisible(tab, visibility))
            FushiFilledButton.tonalIcon(
              key: ValueKey<String>('home-empty-go-${tab.name}'),
              onPressed: () => _goToTab(tab),
              icon: FushiIcon(homeNavItemFor(tab).icon),
              label: Text(homeNavItemFor(tab).label),
            ),
      ],
    );
  }

  /// 「继续阅读 / 观看 / 游玩」：同一份继续条目按类型筛出来。1 行高 = 最近一条；
  /// 2 行高 = 能放几行放几行。窄网格一行高的格子不画小标题行，组件名改作条目的眉标。
  Widget _continueKindCell(
    FushiDesignTokens tokens,
    AppModel appModel,
    HomeWidgetKind kind,
    List<_ContinueEntry> list,
    HomeWidgetSize size,
    bool poster,
    bool dense,
  ) {
    final String title = homeWidgetLabel(kind);
    final bool headerless = dense && list.isNotEmpty;
    return HomeWidgetFrame(
      key: ValueKey<String>('home-${kind.id}-card'),
      title: title,
      icon: switch (kind) {
        HomeWidgetKind.continueWatching => FushiIcons.play,
        HomeWidgetKind.continuePlaying => FushiIcons.games,
        _ => FushiIcons.books,
      },
      hueKey: kind.id,
      poster: poster,
      dense: dense,
      showHeader: !headerless,
      child: list.isEmpty
          ? _widgetEmptyLine(
              tokens,
              _initialLoadDone ? t.home_continue_empty : '',
            )
          : LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                String subtitleOf(_ContinueEntry e) =>
                    e.badgeLabel ?? _continueMetaLine(e);
                if (size.rows == 1) {
                  return _widgetMiniTile(
                    tokens: tokens,
                    appModel: appModel,
                    key: ValueKey<String>('home-${kind.id}-item/0'),
                    entry: list.first,
                    height: c.maxHeight,
                    subtitle: subtitleOf(list.first),
                    eyebrow: headerless ? title : null,
                  );
                }
                return _widgetMiniList(
                  tokens: tokens,
                  appModel: appModel,
                  keyPrefix: 'home-${kind.id}-item',
                  entries: list,
                  area: c.biggest,
                  columns: 1,
                  subtitleOf: subtitleOf,
                );
              },
            ),
    );
  }

  /// 一列 / 两列的条目小行（「继续阅读」等 2 行高的格子、「最近添加」）：行高固定，
  /// 放得下几行放几行。
  Widget _widgetMiniList({
    required FushiDesignTokens tokens,
    required AppModel appModel,
    required String keyPrefix,
    required List<_ContinueEntry> entries,
    required Size area,
    required int columns,
    required String Function(_ContinueEntry entry) subtitleOf,
    Key? key,
  }) {
    const double rowHeight = 56;
    const double gap = 8;
    final int rows = math.max(
      1,
      ((area.height + gap) / (rowHeight + gap)).floor(),
    );
    final List<_ContinueEntry> shown = entries.take(rows * columns).toList();
    final double width = (area.width - gap * (columns - 1)) / columns;
    return Wrap(
      key: key,
      spacing: gap,
      runSpacing: gap,
      children: <Widget>[
        for (int i = 0; i < shown.length; i++)
          SizedBox(
            width: width,
            child: _widgetMiniTile(
              tokens: tokens,
              appModel: appModel,
              key: ValueKey<String>('$keyPrefix/$i'),
              entry: shown[i],
              height: rowHeight,
              subtitle: subtitleOf(shown[i]),
            ),
          ),
      ],
    );
  }

  /// 条目小行：小封面 +（眉标）标题 + 副行，点按续开 / 打开。文字配色跟外框走。
  Widget _widgetMiniTile({
    required FushiDesignTokens tokens,
    required AppModel appModel,
    required Key key,
    required _ContinueEntry entry,
    required double height,
    required String subtitle,
    String? eyebrow,
  }) {
    final ShelfCoverMaterial material = _continueMaterial(entry);
    final String title = _continueDisplayTitle(entry);
    final Widget cover = _continueCover(tokens, appModel, entry);
    void open() => unawaited(_openContinueEntry(appModel, entry));
    return Builder(
      builder: (BuildContext context) {
        final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
        final Color fg = style?.foreground ?? tokens.surfaces.onSurface;
        final Color muted = style?.muted ?? tokens.surfaces.onVariant;
        final String? brow = eyebrow;
        return FushiPressScale(
          child: Semantics(
            container: true,
            button: true,
            label: <String>[
              title,
              if (subtitle.isNotEmpty) subtitle,
            ].join(' · '),
            onTap: open,
            excludeSemantics: true,
            child: InkWell(
              key: key,
              onTap: open,
              borderRadius: FushiBorderRadius.card,
              child: SizedBox(
                height: height,
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: height * homeContinuePortraitAspect(material),
                      height: height,
                      child: ShelfCoverMaterialScope(
                        material: material,
                        child: ShelfCoverFrame(
                          density: ShelfCoverDensity.compact,
                          child: cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _fitCenter(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (brow != null)
                              Text(
                                brow,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tokens.type.metadata.copyWith(
                                  color: muted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.type.listTitle.copyWith(color: fg),
                            ),
                            if (subtitle.isNotEmpty)
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tokens.type.metadata.copyWith(
                                  color: muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 组件里没东西时的一行说明（格子保留，只收内容）。
  Widget _widgetEmptyLine(FushiDesignTokens tokens, String text) => Builder(
    builder: (BuildContext context) {
      final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: tokens.type.metadata.copyWith(
            color: style?.muted ?? tokens.surfaces.onVariant,
          ),
        ),
      );
    },
  );

  /// 自然高度的内容在格子里竖向居中，放不下的部分裁掉（不抛溢出）。
  Widget _fitCenter(Widget child) => ClipRect(
    child: OverflowBox(
      alignment: AlignmentDirectional.centerStart,
      minHeight: 0,
      maxHeight: double.infinity,
      child: child,
    ),
  );

  // ── 今日 / 近 7 天 ──────────────────────────────────────────────────────

  /// 「今日」：1×1 = 今日字数大字（格子不矮时再挂时长 / 目标进度一行）；2×1 = 分区
  /// 卡外观沿用原学习头部行（[HomeStudyHeader]），色块外观是目标环 + 大字 + 一行。
  /// 整块点按改目标（与原目标行同一个 key `home-goal-row`）。
  Widget _todayCell(
    FushiDesignTokens tokens,
    HomeWidgetSize size,
    bool poster,
    bool dense,
  ) {
    void editGoal() => unawaited(_editGoal());
    final bool wide = size.cols >= 2;
    final Widget child;
    if (!_initialLoadDone) {
      child = const HomeWidgetOverflowClip(child: HomeGoalSkeleton());
    } else if (wide && !poster) {
      child = _fitCenter(_buildStudyHeader(tokens));
    } else {
      child = _todayFigure(tokens, wide: wide, dense: dense);
    }
    return HomeWidgetFrame(
      key: const ValueKey<String>('home-study-card'),
      title: t.stat_today,
      icon: FushiIcons.barChart,
      hueKey: HomeWidgetKind.today.id,
      poster: poster,
      dense: dense,
      // 2×1 窄格子：头部行自己就写着今日时长与目标，不再占一行小标题。
      showHeader: !(dense && wide),
      onTap: editGoal,
      tapKey: const ValueKey<String>('home-goal-row'),
      child: child,
    );
  }

  /// 「今日」的大字版：今日字数；不矮时下面一行是目标进度（没设目标时是时长）；
  /// [wide]（色块外观 2×1）时起始侧再挂目标环。
  Widget _todayFigure(
    FushiDesignTokens tokens, {
    required bool wide,
    required bool dense,
  }) {
    final AppModel appModel = ref.read(appProvider);
    final StudyGoalPeriod period = appModel.readingGoalPeriod;
    final int goal = appModel.readingGoalActiveChars;
    final StatWindow w = _statWindow;
    final String todayKey = w.todayKey;
    final int todayChars = studyGoalCharsForDay(_dailyRows, todayKey);
    final int goalChars = switch (period) {
      StudyGoalPeriod.daily => todayChars,
      StudyGoalPeriod.weekly => studyGoalCharsForWeek(_dailyRows, w),
    };
    int todayMs = 0;
    for (final StatFact f in _dailyRows) {
      if (f.dateKey == todayKey) todayMs += f.ms;
    }
    final bool hasGoal = goal > 0;
    final String todayTime = formatStatTime(todayMs);
    final String? goalLine = !hasGoal
        ? null
        : switch (period) {
            StudyGoalPeriod.daily => t.stat_goal_progress(
              read: goalChars,
              goal: goal,
            ),
            StudyGoalPeriod.weekly => t.stat_goal_progress_weekly(
              read: goalChars,
              goal: goal,
            ),
          };
    return Builder(
      builder: (BuildContext context) {
        final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
        final Color muted = style?.muted ?? tokens.surfaces.onVariant;
        final TextStyle caption = tokens.type.metadata.copyWith(color: muted);
        final Widget figure = Semantics(
          label: formatStatChars(todayChars),
          excludeSemantics: true,
          child: HomeWidgetFigure(
            value: formatStatCharsAxis(todayChars),
            unit: t.stat_goal_unit_chars,
            large: !dense,
          ),
        );
        final Widget time = Semantics(
          key: const ValueKey<String>('home-today-time'),
          container: true,
          label: '${t.stat_today} · $todayTime',
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIcon(FushiIcons.schedule, size: 13, color: muted),
              const SizedBox(width: 4),
              Text(todayTime, maxLines: 1, style: caption),
            ],
          ),
        );
        final Widget column = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            figure,
            if (!dense) ...<Widget>[
              const SizedBox(height: 4),
              if (goalLine != null && wide)
                Text(
                  goalLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: caption,
                )
              else
                time,
            ],
          ],
        );
        final FushiCoverBlockColors? colors = style?.colors;
        if (!wide || colors == null) return _fitCenter(column);
        return Row(
          children: <Widget>[
            ExcludeSemantics(
              child: FushiPosterRing(
                value: hasGoal ? (goalChars / goal).clamp(0.0, 1.0) : null,
                colors: colors,
                size: dense ? 40 : 52,
                center: hasGoal
                    ? null
                    : FushiIcon(
                        FushiIcons.flag,
                        size: 18,
                        color: colors.onContainer,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: _fitCenter(column)),
          ],
        );
      },
    );
  }

  /// 「近 7 天」学习字数柱条（今天在最后），点块进统计中心。
  Widget _weekCell(bool poster, bool dense) => HomeWidgetFrame(
    key: const ValueKey<String>('home-week-card'),
    title: t.stat_week_past,
    icon: FushiIcons.barChart,
    hueKey: HomeWidgetKind.week.id,
    poster: poster,
    dense: dense,
    onTap: _openStatisticsCenter,
    tapKey: const ValueKey<String>('home-week-open'),
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final FushiCoverBlockColors? colors = HomeWidgetStyle.maybeOf(
          context,
        )?.colors;
        final double height = math.max(16, c.maxHeight);
        return HomeWidgetOverflowClip(
          child: colors != null
              ? _buildPosterWeekBars(colors, height: height)
              : _buildWeekBars(height: height),
        );
      },
    ),
  );

  // ── 最近添加 / 追踪 ──────────────────────────────────────────────────────

  /// 「最近添加」：2×2 一列、4×2 两列条目小行（最多 [_kRecentLimit] 条，「继续」里
  /// 已有的去重）。
  Widget _recentCell(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<MediaItem> books,
    HomeWidgetSize size,
    bool poster,
  ) {
    final List<_ContinueEntry> list = _initialLoadDone
        ? _recentlyAddedEntries(appModel, books)
        : const <_ContinueEntry>[];
    final DateTime now = DateTime.now();
    return HomeWidgetFrame(
      key: const ValueKey<String>('home-recent-card'),
      title: t.home_recently_added,
      icon: FushiIcons.schedule,
      hueKey: HomeWidgetKind.recentlyAdded.id,
      poster: poster,
      dense: false,
      child: list.isEmpty
          ? _widgetEmptyLine(
              tokens,
              _initialLoadDone ? t.home_widget_recent_empty : '',
            )
          : LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) =>
                  _widgetMiniList(
                    tokens: tokens,
                    appModel: appModel,
                    key: const ValueKey<String>('home-recent-list'),
                    keyPrefix: 'home-recent-item',
                    entries: list,
                    area: c.biggest,
                    columns: size.cols >= 4 ? 2 : 1,
                    subtitleOf: (_ContinueEntry e) => _recentSubtitle(e, now),
                  ),
            ),
    );
  }

  /// 媒体追踪同步状态（模块门控在可用性判据里）。
  Widget _trackingCell(bool poster, bool dense) {
    final HomeTrackingSummary summary = HomeTrackingSummary.of(_tracking);
    return HomeTrackingPanel(
      key: const ValueKey<String>('home-tracking-card'),
      summary: summary,
      onOpen: () => _openTrackingPage(summary),
      poster: poster,
      dense: dense,
    );
  }
}
