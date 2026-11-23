part of 'home_dashboard_page.dart';

/// 首页小组件网格（spec 2026-11-15）每一格的内容。
///
/// 格子尺寸由网格给定（[HomeWidgetGrid] 紧约束），尺寸是连续可调的（每种组件一段
/// 范围），所以内容一律按格子的**实际宽高**（LayoutBuilder）排版，不按尺寸档
/// switch：格子越大放得越多（更多条目 / 封面行、更高的柱条、更多行文字），任何
/// 允许的尺寸都不溢出、不留大片空白。外框一律走 [HomeWidgetFrame]（海报色块 /
/// 分区卡两套外观），只有色块外观下有条目的「继续」直接画封面色块（与库页同一套
/// [FushiCoverBlock]）。数据全部来自本页已有的快照（继续条目、统计行、追踪快照），
/// 不新增查询。
extension _HomeWidgetCells on _HomeDashboardPageState {
  /// [item] 这一格的内容。
  Widget _buildWidgetCell({
    required FushiDesignTokens tokens,
    required AppModel appModel,
    required List<_ContinueEntry> entries,
    required List<MediaItem> books,
    required HomeWidgetItem item,
  }) {
    final bool poster = _posterPanels;
    return switch (item.kind) {
      HomeWidgetKind.continueHero => _continueHeroCell(
        tokens,
        appModel,
        entries,
        poster,
      ),
      HomeWidgetKind.continueReading ||
      HomeWidgetKind.continueWatching ||
      HomeWidgetKind.continuePlaying =>
        _continueKindCell(tokens, appModel, item.kind, <_ContinueEntry>[
          for (final _ContinueEntry e in entries)
            if (homeWidgetContinueKindOf(
                  isBook: e.isBook,
                  isAudiobook: e.isAudiobook,
                  isVideo: e.isVideo,
                  isGame: e.isGame,
                ) ==
                item.kind)
              e,
        ], poster),
      HomeWidgetKind.today => _todayCell(tokens, poster),
      HomeWidgetKind.week => _weekCell(poster),
      HomeWidgetKind.srsReview => HomeSrsPanel(
        key: const ValueKey<String>('home-srs-card'),
        onOpenDecks: () => _goToTab(HomeTab.srs),
        onStartReview: _startSrsReview,
        poster: poster,
      ),
      HomeWidgetKind.recentlyAdded => _recentCell(
        tokens,
        appModel,
        books,
        poster,
      ),
      HomeWidgetKind.tracking => _trackingCell(appModel, books, poster),
      HomeWidgetKind.aiAgent => HomeAiAgentPanel(
        key: const ValueKey<String>('home-ai-agent-card'),
        poster: poster,
      ),
      HomeWidgetKind.panorama => HomePanoramaPanel(
        key: const ValueKey<String>('home-panorama-card'),
        onOpen: _openPanoramaWork,
        poster: poster,
      ),
      HomeWidgetKind.languageGoals => _languageGoalsCell(tokens, item, poster),
    };
  }

  // ── 继续 ────────────────────────────────────────────────────────────────

  /// 「继续」主角：半栏（宽 < [kHomeWidgetWideWidth]）走 [_continueHeroNarrow]；
  /// 否则 [_continueHeroFull]。
  Widget _continueHeroCell(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
    bool poster,
  ) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) =>
        entries.isNotEmpty && !homeWidgetIsWide(c.maxWidth)
        ? _continueHeroNarrow(tokens, appModel, entries, poster)
        : _continueHeroFull(tokens, appModel, entries, poster),
  );

  /// 半栏（1 列宽）的「继续」主角：主卡 / 封面行在 1 列宽里排不开，改成条目小行
  /// 一列（小封面 + 两行标题，高度够再挂进度），放得下几条放几条，最近一条在最上。
  Widget _continueHeroNarrow(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
    bool poster,
  ) => HomeWidgetFrame(
    key: const ValueKey<String>('home-continue-card'),
    title: t.home_continue,
    icon: FushiIcons.playCircle,
    hueKey: HomeWidgetKind.continueHero.id,
    poster: poster,
    dense: false,
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => _widgetMiniList(
        tokens: tokens,
        appModel: appModel,
        key: const ValueKey<String>('home-continue-list'),
        keyPrefix: 'home-continue-item',
        entries: entries,
        area: box.biggest,
        subtitleOf: (_ContinueEntry e) => e.badgeLabel ?? _continueMetaLine(e),
      ),
    ),
  );

  /// 「继续」主角（够宽时）：最近一条放大；格子够大再挂其余条目——横向够宽（宽 ≥ 460 且
  /// 宽高比 ≥ 1.5）挂在主卡旁，否则高度够时挂在主卡下（[_continueSplitFor]）。
  /// 其余条目那一段按实际大小排：只放得下一行时横滑（全部条目可达），放得下多行时
  /// 铺成多行多列（格子越大条目越多）。没有条目时是首载骨架 / 空库引导。
  Widget _continueHeroFull(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
    bool poster,
  ) {
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
              // 首页拼贴（BUG-4903）：视频一律竖版海报摆法，没有海报时剧照裁成
              // 竖版，不整张铺成横版背景（小块里看起来像没封面）。
              portraitOnly: true,
            );
            final _ContinueSplit split = _continueSplitFor(
              c.biggest,
              entries.length,
              minSide: _kContinueBlockSideMin,
            );
            if (split == _ContinueSplit.none) return hero(c.maxHeight);
            return _heroWithSide(
              area: c.biggest,
              sideways: split == _ContinueSplit.side,
              hero: hero,
              side: (Size area) =>
                  _continueBlockSide(tokens, appModel, entries, area),
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
              child: FushiContinueOrientedEntry(
                entry: _continueMainEntry(tokens, appModel, entries.first),
                builder: (FushiContinueEntry main) {
                  final Widget spotlight = FushiContinueSpotlight(
                    main: main,
                    heroCoverHeight: cover,
                    soloCoverHeight: cover,
                    // 整块由网格错峰进场。
                    staggerEntrance: false,
                  );
                  if (!main.still) return spotlight;
                  // 剧照主卡（16:9）按格子高定宽：共享组件按宽定高（窄档封顶
                  // 300），在定高的格子里会把底部的片名 / 进度叠层裁掉。
                  return Align(
                    alignment: AlignmentDirectional.topStart,
                    child: SizedBox(width: height * 16 / 9, child: spotlight),
                  );
                },
              ),
            );
          }

          final _ContinueSplit split = _continueSplitFor(
            c.biggest,
            entries.length,
            minSide: _kContinueMiniSideMin,
          );
          if (split == _ContinueSplit.none) return hero(c.maxHeight);
          final bool sideways = split == _ContinueSplit.side;
          return _heroWithSide(
            area: c.biggest,
            sideways: sideways,
            hero: hero,
            side: (Size area) =>
                _continueCardSide(tokens, appModel, entries, area, sideways),
          );
        },
      ),
    );
  }

  /// 主卡 + 其余条目两段的分割：[sideways] 时左右（主卡占约 55%），否则上下（主卡占
  /// 约 60%）。[hero] 拿到主卡那段的高度，[side] 拿到其余条目那段的尺寸。
  Widget _heroWithSide({
    required Size area,
    required bool sideways,
    required Widget Function(double height) hero,
    required Widget Function(Size area) side,
  }) {
    const double gap = kFushiCoverBlockSpacing;
    if (sideways) {
      final double heroWidth = (area.width - gap) * _kContinueHeroShare;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(width: heroWidth, child: hero(area.height)),
          const SizedBox(width: gap),
          Expanded(
            child: side(Size(area.width - heroWidth - gap, area.height)),
          ),
        ],
      );
    }
    final double heroHeight = (area.height - gap) * _kContinueHeroStackShare;
    final double sideHeight = area.height - heroHeight - gap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(height: heroHeight, child: hero(heroHeight)),
        const SizedBox(height: gap),
        Expanded(child: side(Size(area.width, sideHeight))),
      ],
    );
  }

  /// 色块外观「继续」其余条目：放得下一行半高块时横滑（全部可达），放得下多行时
  /// 铺成多行多列（格子越大块越多）。
  Widget _continueBlockSide(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
    Size area,
  ) {
    const double gap = kFushiCoverBlockSpacing;
    final int rows = math.max(
      1,
      ((area.height + gap) / (_kContinueBlockRowMin + gap)).floor(),
    );
    if (rows == 1) {
      return _continueBlockRow(tokens, appModel, entries, area.height);
    }
    final double rowHeight = (area.height - gap * (rows - 1)) / rows;
    final int cols = math.max(
      1,
      ((area.width + gap) / (rowHeight * 1.6 + gap)).floor(),
    );
    final double width = (area.width - gap * (cols - 1)) / cols;
    final int count = math.min(entries.length - 1, rows * cols);
    return Wrap(
      key: const ValueKey<String>('home-continue-grid'),
      spacing: gap,
      runSpacing: gap,
      children: <Widget>[
        for (int i = 0; i < count; i++)
          SizedBox(
            width: width,
            height: rowHeight,
            child: _continueBlock(
              tokens,
              appModel,
              entries[i + 1],
              i + 1,
              homeCoverBlockSizeFor(rowHeight),
              portraitOnly: true,
            ),
          ),
      ],
    );
  }

  /// 分区卡外观「继续」其余条目：
  /// - 主卡旁（[sideways]）不太高时：库页同款封面卡横滑，与主卡等高；
  /// - 主卡下只放得下一行时：条目小行横滑（手机 2×3 只剩约 80 高，封面卡放不下）；
  /// - 放得下多行时（更高 / 主卡旁很高）：条目小行铺成多行多列，格子越大条目越多。
  Widget _continueCardSide(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
    Size area,
    bool sideways,
  ) {
    if (sideways && area.height < _kContinueCoverRowMax) {
      return _continueCoverRow(tokens, appModel, entries, area.height);
    }
    final List<_ContinueEntry> rest = entries.sublist(1);
    final int rows = _miniListRows(area.height);
    if (rows == 1) {
      return _continueMiniRow(tokens, appModel, entries, area.height);
    }
    return _widgetMiniList(
      tokens: tokens,
      appModel: appModel,
      key: const ValueKey<String>('home-continue-list'),
      keyPrefix: 'home-continue-item',
      indexOffset: 1,
      entries: rest,
      area: area,
      subtitleOf: (_ContinueEntry e) => e.badgeLabel ?? _continueMetaLine(e),
    );
  }

  /// 色块外观「继续」其余条目只放得下一行时：半高封面色块横滑（全部条目可达）。
  Widget _continueBlockRow(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
    double height,
  ) {
    final double tileWidth = height * 1.9;
    // 视口给半高色块的投影留余量（[FushiShadowBleedViewport]），不把阴影裁成直角框。
    return FushiShadowBleedViewport(
      bleed: kFushiCoverBlockHalfBleed,
      builder: (BuildContext _, EdgeInsets padding) => SectionSwipeCascade(
        child: HorizontalDragScrollable(
          child: ListView.separated(
            key: const ValueKey<String>('home-continue-row'),
            scrollDirection: Axis.horizontal,
            physics: desktopAwareScrollPhysics(),
            padding: padding,
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
                homeCoverBlockSizeFor(height),
                portraitOnly: true,
              ),
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
    // 与共享封面行（FushiContinueSpotlight._sideRow）同一套悬停余量：卡 × 放大倍数
    // + 上下材质上抬 = 行高，悬停放大 / 上抬不被横滚视口截平。
    const double scale = kFushiHoverLiftScale;
    const double rise = kShelfMaterialHoverRise * scale;
    final double coverHeight = math.max(
      48,
      (height - 2 * rise) / scale - metaHeight,
    );
    final List<FushiContinueEntry> side = <FushiContinueEntry>[
      for (int i = 1; i < entries.length; i++)
        _continueSideEntry(tokens, appModel, entries[i], i),
    ];
    final double widest =
        coverHeight *
        side.fold<double>(
          0,
          (double m, FushiContinueEntry e) => math.max(m, e.layoutAspectRatio),
        );
    return SectionSwipeCascade(
      child: HorizontalDragScrollable(
        child: ListView.separated(
          key: const ValueKey<String>('home-continue-row'),
          scrollDirection: Axis.horizontal,
          physics: desktopAwareScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: widest * (scale - 1) / 2,
            vertical: math.max(0, (height - coverHeight - metaHeight) / 2),
          ),
          itemCount: side.length,
          separatorBuilder: (BuildContext _, int _) =>
              SizedBox(width: tokens.spacing.gap),
          itemBuilder: (BuildContext _, int i) => FushiContinueOrientedEntry(
            entry: side[i],
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

  /// 主卡下面的其余条目只放得下一行时（如手机 2×3）：条目小行横滑，每块约八成
  /// 格宽（露出下一块提示能滑），行高 = 那段的高度。
  Widget _continueMiniRow(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
    double height,
  ) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      final double width = math.min(260, c.maxWidth * 0.8);
      return SectionSwipeCascade(
        child: HorizontalDragScrollable(
          child: ListView.separated(
            key: const ValueKey<String>('home-continue-row'),
            scrollDirection: Axis.horizontal,
            physics: desktopAwareScrollPhysics(),
            itemCount: entries.length - 1,
            separatorBuilder: (BuildContext _, int _) =>
                SizedBox(width: tokens.spacing.gap),
            itemBuilder: (BuildContext _, int i) {
              final _ContinueEntry e = entries[i + 1];
              return SizedBox(
                width: width,
                child: _widgetMiniTile(
                  tokens: tokens,
                  appModel: appModel,
                  key: ValueKey<String>('home-continue-item/${i + 1}'),
                  entry: e,
                  height: height,
                  subtitle: e.badgeLabel ?? _continueMetaLine(e),
                ),
              );
            },
          ),
        ),
      );
    },
  );

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

  /// 「继续阅读 / 观看 / 游玩」：同一份继续条目按类型筛出来，按格子实际大小放
  /// 条目小行——放得下几行几列放几行几列（[_widgetMiniList]）。矮格（窄网格一行
  /// 高）只放最近一条，不画小标题行，组件名改作条目的眉标。
  Widget _continueKindCell(
    FushiDesignTokens tokens,
    AppModel appModel,
    HomeWidgetKind kind,
    List<_ContinueEntry> list,
    bool poster,
  ) {
    final String title = homeWidgetLabel(kind);
    String subtitleOf(_ContinueEntry e) => e.badgeLabel ?? _continueMetaLine(e);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool dense = homeWidgetIsDense(c.maxHeight);
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
                  builder: (BuildContext context, BoxConstraints box) {
                    final bool single =
                        _miniListRows(box.maxHeight) == 1 &&
                        _miniListColumns(box.maxWidth) == 1;
                    if (single) {
                      return _widgetMiniTile(
                        tokens: tokens,
                        appModel: appModel,
                        key: ValueKey<String>('home-${kind.id}-item/0'),
                        entry: list.first,
                        height: box.maxHeight,
                        subtitle: subtitleOf(list.first),
                        eyebrow: headerless ? title : null,
                      );
                    }
                    return _widgetMiniList(
                      tokens: tokens,
                      appModel: appModel,
                      keyPrefix: 'home-${kind.id}-item',
                      entries: list,
                      area: box.biggest,
                      subtitleOf: subtitleOf,
                    );
                  },
                ),
        );
      },
    );
  }

  /// [height] 高的区域里放几行条目小行（行高至少 [_kMiniRowMin]）。
  int _miniListRows(double height) =>
      math.max(1, ((height + _kMiniGap) / (_kMiniRowMin + _kMiniGap)).floor());

  /// [width] 宽的区域里放几列条目小行（每列至少 [_kMiniTileMinWidth]）。
  int _miniListColumns(double width) => math.max(
    1,
    ((width + _kMiniGap) / (_kMiniTileMinWidth + _kMiniGap)).floor(),
  );

  /// 条目小行铺满 [area]：行数按高度、列数按宽度算（[_miniListRows] /
  /// [_miniListColumns]），行高在 [_kMiniRowMin]…[_kMiniRowMax] 之间撑满，放得下
  /// 几条放几条——格子越大条目越多。[indexOffset] 是条目 key 的起始序号。
  Widget _widgetMiniList({
    required FushiDesignTokens tokens,
    required AppModel appModel,
    required String keyPrefix,
    required List<_ContinueEntry> entries,
    required Size area,
    required String Function(_ContinueEntry entry) subtitleOf,
    int indexOffset = 0,
    Key? key,
  }) {
    final int rows = _miniListRows(area.height);
    final int columns = _miniListColumns(area.width);
    final double rowHeight = math.min(
      _kMiniRowMax,
      (area.height - _kMiniGap * (rows - 1)) / rows,
    );
    final List<_ContinueEntry> shown = entries.take(rows * columns).toList();
    final double width = (area.width - _kMiniGap * (columns - 1)) / columns;
    return Wrap(
      key: key,
      spacing: _kMiniGap,
      runSpacing: _kMiniGap,
      children: <Widget>[
        for (int i = 0; i < shown.length; i++)
          SizedBox(
            width: width,
            child: _widgetMiniTile(
              tokens: tokens,
              appModel: appModel,
              key: ValueKey<String>('$keyPrefix/${i + indexOffset}'),
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
                      child: LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints box) {
                          final TextStyle titleStyle = tokens.type.listTitle
                              .copyWith(color: fg);
                          final TextStyle metaStyle = tokens.type.metadata
                              .copyWith(color: muted);
                          final TextStyle browStyle = context
                              .fushiType
                              .labelSmall
                              .copyWith(
                                color: muted,
                                fontWeight: FontWeight.w600,
                              );
                          // 按可用高度挑放哪几行（标题优先），整行放得下才放，
                          // 不出半行字；半栏窄格（文字区 < 120）标题放两行。
                          final _MiniTileLines lines = _miniTileLines(
                            height: box.maxHeight,
                            narrow: box.maxWidth < _kMiniNarrowTextWidth,
                            titleLine: _lineHeight(context, titleStyle),
                            metaLine: _lineHeight(context, metaStyle),
                            browLine: _lineHeight(context, browStyle),
                            hasSubtitle: subtitle.isNotEmpty,
                            hasEyebrow: brow != null,
                          );
                          return _fitCenter(
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                if (brow != null && lines.eyebrow)
                                  Text(
                                    brow,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: browStyle,
                                  ),
                                Text(
                                  title,
                                  maxLines: lines.title,
                                  overflow: TextOverflow.ellipsis,
                                  style: titleStyle,
                                ),
                                if (lines.subtitle)
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: metaStyle,
                                  ),
                              ],
                            ),
                          );
                        },
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

  /// 「今日」：按格子实际大小排——
  /// - 主体：窄格是今日字数大字（不矮时再挂时长 / 目标进度一行）；宽格在分区卡外观
  ///   沿用原学习头部行（[HomeStudyHeader]），色块外观是目标环 + 大字 + 一行；
  /// - 内容区够宽（≥ [_kTodayBarsSideWidth]）时结束侧再挂近 7 天柱条，不够宽但够高
  ///   （≥ [_kTodayBarsBelowHeight]）时柱条挂在主体下面——格子变大不留空。
  /// 整块点按改目标（与原目标行同一个 key `home-goal-row`）。
  Widget _todayCell(FushiDesignTokens tokens, bool poster) {
    // 没有目标 / 只有一条全部语言的每日字数目标 = 原「今日」外观（点按开目标面板）；
    // 其余 → 目标翻页，点按进「目标」设置子页。
    final bool classic = _todayClassic;
    final WidgetGoalsInput goalsInput = _studyGoalsInput();
    // 总览版式列出全部目标（主目标 / 左右滑范围只管聚焦版式）。
    final bool overview =
        !classic &&
        ref.read(appProvider).homeTodayLayout == StudyGoalTodayLayout.overview;
    final List<StudyGoalProgress> goals = !_initialLoadDone || classic
        ? const <StudyGoalProgress>[]
        : overview
        ? _studyGoalProgress(goalsInput)
        : _todayGoals(goalsInput);
    // 柱条跟着翻页当前那条目标走（滑动写当前页偏好 → 重建到这里）。
    final StudyGoalProgress? shown = goals.isEmpty
        ? null
        : goals[_todayGoalIndex(goals)];
    void editGoal() =>
        unawaited(classic ? _editGoal() : _openStudyGoalsSettings());
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool dense = homeWidgetIsDense(c.maxHeight);
        final bool wide = homeWidgetIsWide(c.maxWidth);
        final Widget main;
        if (!_initialLoadDone) {
          main = const HomeWidgetOverflowClip(child: HomeGoalSkeleton());
        } else if (overview) {
          main = _todayOverview(tokens, goals, goalsInput);
        } else if (!classic) {
          main = _todayGoalsPager(tokens, goals, goalsInput, dense: dense);
        } else if (wide && !poster) {
          main = _fitCenter(_buildStudyHeader(tokens));
        } else {
          main = _todayFigure(tokens, wide: wide, dense: dense);
        }
        return HomeWidgetFrame(
          key: const ValueKey<String>('home-study-card'),
          // 总览里混了每周 / 每月目标时不叫「今日目标」（与系统小组件同一规则）。
          title: !overview
              ? t.stat_today
              : goals.every(
                  (StudyGoalProgress g) =>
                      g.goal.period == StudyGoalPeriod.daily,
                )
              ? t.home_today_goals_title
              : t.home_language_goals_mixed_title,
          icon: FushiIcons.barChart,
          hueKey: HomeWidgetKind.today.id,
          poster: poster,
          dense: dense,
          // 宽的矮格：头部行自己就写着今日时长与目标，不再占一行小标题。
          showHeader: !(dense && wide),
          onTap: editGoal,
          tapKey: const ValueKey<String>('home-goal-row'),
          child: !_initialLoadDone || overview
              ? main
              : LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    Widget bars(double height) => Builder(
                      builder: (BuildContext context) {
                        // 周 / 月目标：本周生效日柱条 + 每天份额（设计 B）。
                        if (shown != null && shown.splitsPeriod) {
                          return KeyedSubtree(
                            key: const ValueKey<String>('home-today-week'),
                            child: _buildGoalDayStrip(
                              shown,
                              goalsInput,
                              height: height,
                            ),
                          );
                        }
                        final FushiCoverBlockColors? colors =
                            HomeWidgetStyle.maybeOf(context)?.colors;
                        return KeyedSubtree(
                          key: const ValueKey<String>('home-today-week'),
                          child: colors != null
                              ? _buildPosterWeekBars(
                                  colors,
                                  height: height,
                                  key: const ValueKey<String>(
                                    'home-today-week-bars',
                                  ),
                                  goal: shown,
                                  input: goalsInput,
                                )
                              : _buildWeekBars(
                                  height: height,
                                  goal: shown,
                                  input: goalsInput,
                                ),
                        );
                      },
                    );
                    if (box.maxWidth >= _kTodayBarsSideWidth) {
                      // 细柱（设计稿 11-20 #12「宁可把柱状图变小」）：柱状图只占卡宽
                      // 约 20%、最多 7 根 12px 细柱的宽，省出的宽度给左边的大字与
                      // 副行，卡片尺寸不变。
                      final double barsWidth = math.min(
                        box.maxWidth * _kTodayBarsWidthShare,
                        _kTodayBarsMaxWidth,
                      );
                      return Row(
                        children: <Widget>[
                          Expanded(child: main),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: barsWidth,
                            child: HomeWidgetOverflowClip(
                              child: bars(math.max(16, box.maxHeight)),
                            ),
                          ),
                        ],
                      );
                    }
                    if (box.maxHeight >= _kTodayBarsBelowHeight) {
                      final double mainHeight = math.min(
                        classic
                            ? _kTodayMainMaxHeight
                            : _kTodayGoalsMainMaxHeight,
                        box.maxHeight * 0.5,
                      );
                      const double gap = 8;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          SizedBox(height: mainHeight, child: main),
                          const SizedBox(height: gap),
                          Expanded(
                            child: HomeWidgetOverflowClip(
                              child: bars(
                                math.max(16, box.maxHeight - mainHeight - gap),
                              ),
                            ),
                          ),
                        ],
                      );
                    }
                    return main;
                  },
                ),
        );
      },
    );
  }

  /// 「今日」格追踪了非字数目标时：每个目标一页（从主目标那页开始），页上是环 +
  /// 大字 + 「已完成 / 目标」；格子够高时下面再列其余目标的进度行。滑到哪页就把它
  /// 记成主目标。
  Widget _todayGoalsPager(
    FushiDesignTokens tokens,
    List<StudyGoalProgress> goals,
    WidgetGoalsInput input, {
    required bool dense,
  }) {
    final AppModel appModel = ref.read(appProvider);
    return Builder(
      builder: (BuildContext context) {
        final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
        final Color strong =
            style?.colors?.onContainer ?? tokens.surfaces.onSurface;
        return HomeTodayGoalPager(
          key: const ValueKey<String>('home-today-goal-pager'),
          count: goals.length,
          page: _todayGoalIndex(goals),
          dotColor: strong,
          dotLabel: (int i) => t.home_today_goal_page(
            goal: studyGoalSemanticsLabel(
              goals[i],
              studyGoalProgressLabel(goals[i], input),
            ),
          ),
          // 滑动只记「停在哪页」，不改主目标：页集合（含周 / 月主目标）不随手势变。
          onPageChanged: (int i) {
            final String id = goals[i].goal.id;
            if (id != appModel.homeTodayPageGoal) {
              unawaited(appModel.setHomeTodayPageGoal(id));
            }
          },
          pageBuilder: (BuildContext context, int i) => _todayGoalPage(
            tokens,
            goals[i],
            <StudyGoalProgress>[
              for (final StudyGoalProgress g in goals)
                if (g.goal.id != goals[i].goal.id) g,
            ],
            input,
            dense: dense,
          ),
        );
      },
    );
  }

  /// 「今日」目标翻页的一页（聚焦版式）：[goal] 是大环 + 「数值 / 目标」大字，上面
  /// 一行「语言 · 度量 · 周期」，下面一行状态（「还差 400」「已完成」「+4.8K」
  /// 「休息日」）；[others] 在格子够高时列成小行（与总览同一种行）。
  Widget _todayGoalPage(
    FushiDesignTokens tokens,
    StudyGoalProgress goal,
    List<StudyGoalProgress> others,
    WidgetGoalsInput input, {
    required bool dense,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
        final FushiCoverBlockColors? colors = style?.colors;
        final Color muted = style?.muted ?? tokens.surfaces.onVariant;
        final Color strong = colors?.onContainer ?? tokens.surfaces.onSurface;
        final TextStyle caption = tokens.type.metadata.copyWith(color: muted);
        final double ringSize = dense
            ? 40
            : box.maxHeight >= 96
            ? 64
            : 52;
        final StudyGoalCompactText text = studyGoalCompactText(
          goal,
          unitChoice: input.unitChoice,
        );
        final String title = _todayGoalTitle(text, showLanguage: true);
        // 周 / 月目标（设计 A）：大字 = 今天「12 / 20 今天」，小字 = 周期一行
        // 「本周 99 / 100 · 还剩 3 天」；今天没有份额（休息日 / 周期已达成）时大字
        // 回到周期数值，小字写「休息日 · 落后 40」/「本周已完成」。
        final bool split = goal.splitsPeriod;
        final bool hasShare = split && goal.todayShare > 0;
        final bool reached = split
            ? goal.todayState.reached
            : goal.state.reached;
        final String figureValue = hasShare ? text.todayValue : text.value;
        final String figureUnit = hasShare
            ? '/ ${text.todayShare} ${t.study_goal_today_word}'
            : '/ ${text.target}';
        // 小格（矮于 96）放不下柱条：小字换成进度差（设计 C）「落后 11.3K · 还剩 3 天」。
        final String statusLine = !split
            ? text.status
            : !hasShare
            ? text.todayLine
            : dense
            ? text.pace
            : box.maxHeight < 96
            ? '${text.pace} · ${text.daysLeft}'
            : text.periodLine;
        // 窄格（1 列宽）只留环 + 大字：整块等比缩小后小字读不清。
        final bool lines = !dense && box.maxWidth >= _kTodayGoalLabelMinWidth;
        // 矮格（一行高）只留环 + 大字；周 / 月目标在够宽时仍带一行进度差（设计 C：
        // 大字已是「12 / 20 今天」，小字「按计划」）。
        final bool paceOnly =
            !lines && split && box.maxWidth >= _kTodayGoalLabelMinWidth;
        final Widget head = Semantics(
          key: ValueKey<String>('home-today-goal-${goal.goal.id}'),
          container: true,
          label: studyGoalSemanticsLabel(
            goal,
            studyGoalProgressLabel(goal, input),
          ),
          excludeSemantics: true,
          child: Row(
            children: <Widget>[
              // 双环只在放得下柱条的高格里画；矮格整块会被等比缩小，两圈分不清。
              _studyGoalRingFor(
                context,
                goal,
                size: box.maxHeight < 96 ? math.min(ringSize, 40) : ringSize,
                dual: true,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (lines)
                      Text(
                        title,
                        key: const ValueKey<String>('home-today-goal-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: caption.copyWith(fontWeight: FontWeight.w600),
                      ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: HomeWidgetFigure(
                        value: figureValue,
                        unit: figureUnit,
                        large: !dense,
                      ),
                    ),
                    if (lines || paceOnly)
                      Text(
                        statusLine,
                        key: const ValueKey<String>('home-today-goal-status'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: caption.copyWith(
                          color: reached ? strong : muted,
                          fontWeight: reached ? FontWeight.w700 : null,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
        // 主目标下面放得下几行其余目标就列几行（其余目标是小行）。
        final int rows = dense
            ? 0
            : math.min(
                others.length,
                ((box.maxHeight - _kTodayGoalHeadHeight) / _kTodayGoalRowHeight)
                    .floor(),
              );
        // 只有主目标：整块等比缩到格子里（矮格不裁掉大字 / 环）。
        if (rows <= 0) {
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: SizedBox(width: box.maxWidth, child: head),
          );
        }
        final bool showLanguage =
            studyGoalsSharedLanguage(<StudyGoalProgress>[goal, ...others]) ==
            null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            head,
            const SizedBox(height: 6),
            for (final StudyGoalProgress g in others.take(rows))
              SizedBox(
                height: _kTodayGoalRowHeight,
                child: _todayGoalRow(
                  tokens,
                  g,
                  input,
                  keyPrefix: 'home-today-goal-row',
                  showLanguage: showLanguage,
                  bar: false,
                ),
              ),
          ],
        );
      },
    );
  }

  /// 一条目标的标题：「中文 · Reading」「日本語 · Characters · Week」（每日目标不写
  /// 周期；[showLanguage] 为 false 或不分语言的度量不写语言）。
  String _todayGoalTitle(
    StudyGoalCompactText text, {
    required bool showLanguage,
  }) {
    final String language = showLanguage ? text.language : '';
    return language.isEmpty ? text.caption : '$language · ${text.caption}';
  }

  /// 目标环（[StudyGoalRing]，带完成状态）：分区卡外观用目标语言的颜色，色块外观用
  /// 色块的强调色 / 前景色。首页各格共用。
  Widget _studyGoalRingFor(
    BuildContext context,
    StudyGoalProgress? goal, {
    required double size,
    bool showPercent = true,
    String? language,
    bool dual = false,
  }) {
    final FushiCoverBlockColors? colors = HomeWidgetStyle.maybeOf(
      context,
    )?.colors;
    final StudyGoalColors goalColors = studyGoalColorsOf(
      context,
      language: goal?.goal.language ?? language,
      metric: goal?.goal.metric,
    );
    final Color color = colors?.accent ?? goalColors.ring;
    final Color track =
        colors?.onContainer.withValues(alpha: 0.18) ?? goalColors.track;
    final Color? label = colors?.onContainer;
    if (goal == null) {
      return StudyGoalRing(
        fraction: 0,
        color: color,
        track: track,
        size: size,
        showPercent: false,
        labelColor: label,
      );
    }
    if (dual && goal.splitsPeriod && size < _kDualRingMinSize) {
      // 小环里两圈分不清：只画今天这一圈（周期数值在旁边的文字里）。
      return StudyGoalRing(
        key: const ValueKey<String>('home-today-goal-today-ring'),
        fraction: goal.todayFraction,
        color: color,
        track: track,
        size: size,
        showPercent: showPercent,
        labelColor: label,
        state: goal.todayState,
      );
    }
    if (dual && goal.splitsPeriod) {
      return StudyGoalDualRing(
        key: const ValueKey<String>('home-today-goal-dual-ring'),
        progress: goal,
        color: color,
        track: track,
        size: size,
        labelColor: label,
      );
    }
    return StudyGoalRing.progress(
      goal,
      color: color,
      track: track,
      size: size,
      showPercent: showPercent,
      labelColor: label,
    );
  }

  /// 「今日」格的一行目标（总览版式的行、聚焦版式主目标下面的小行）：起始侧语言色点 +
  /// 标题（[_todayGoalTitle]），结束侧「数值 / 目标」（达成时前面一个对勾、超出时
  /// 再带「+4.8K」，休息日写「休息日」）；[bar] 时下面一条进度条。
  Widget _todayGoalRow(
    FushiDesignTokens tokens,
    StudyGoalProgress g,
    WidgetGoalsInput input, {
    required String keyPrefix,
    required bool showLanguage,
    required bool bar,
  }) {
    return Builder(
      builder: (BuildContext context) {
        final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
        final FushiCoverBlockColors? colors = style?.colors;
        final Color muted = style?.muted ?? tokens.surfaces.onVariant;
        final Color strong = colors?.onContainer ?? tokens.surfaces.onSurface;
        final StudyGoalColors goalColors = studyGoalColorsOf(
          context,
          language: g.goal.language,
          metric: g.goal.metric,
        );
        final Color accent = colors?.accent ?? goalColors.ring;
        final Color track =
            colors?.onContainer.withValues(alpha: 0.18) ?? goalColors.track;
        final StudyGoalCompactText text = studyGoalCompactText(
          g,
          unitChoice: input.unitChoice,
        );
        // 周 / 月目标（设计 C）：行尾写今天「12 / 20 今天 · 按计划」（休息日 / 周期
        // 已达成换成状态），进度条仍是整个周期。
        final bool split = g.splitsPeriod;
        final StudyGoalState state = split ? g.todayState : g.state;
        final bool rest = state == StudyGoalState.restDay;
        final String value = split
            ? text.todayLine
            : switch (state) {
                StudyGoalState.restDay => text.status,
                StudyGoalState.exceeded =>
                  '${text.value} / ${text.target} · ${text.status}',
                _ => '${text.value} / ${text.target}',
              };
        final TextStyle caption = tokens.type.metadata.copyWith(
          color: rest ? muted : strong,
        );
        final Widget line = Row(
          children: <Widget>[
            SizedBox.square(
              dimension: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: rest ? accent.withValues(alpha: 0.45) : accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _todayGoalTitle(text, showLanguage: showLanguage),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: caption.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            if (state.reached) ...<Widget>[
              FushiIcon(FushiIcons.check, size: 14, color: accent),
              const SizedBox(width: 2),
            ],
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: caption.copyWith(
                  fontWeight: state.reached ? FontWeight.w700 : null,
                ),
              ),
            ),
          ],
        );
        return Semantics(
          key: ValueKey<String>('$keyPrefix-${g.goal.id}'),
          container: true,
          label: studyGoalSemanticsLabel(g, studyGoalProgressLabel(g, input)),
          excludeSemantics: true,
          child: !bar
              ? line
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    line,
                    const SizedBox(height: 5),
                    StudyGoalProgressBar(
                      progress: g,
                      color: accent,
                      track: track,
                    ),
                  ],
                ),
        );
      },
    );
  }

  /// 「今日」格的总览版式（设置 › 目标 › 「今日」格 › 版式 = 总览）：全部目标一条一行
  /// （[_todayGoalRow]，带进度条），按目标列表的顺序；格子矮时行去掉进度条，仍放
  /// 不下就只列前几条 + 末行「还有 N 个」（不悄悄少画）。
  Widget _todayOverview(
    FushiDesignTokens tokens,
    List<StudyGoalProgress> goals,
    WidgetGoalsInput input,
  ) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
        final Color muted = style?.muted ?? tokens.surfaces.onVariant;
        final double height = box.maxHeight;
        // 至少两行（或仅有的一行）带进度条、连同「还有 N 个」放得下才带条；否则
        // 去掉进度条多列几行（只剩一行 + 「还有 7 个」读不出全貌）。
        final bool bar =
            height >=
            _kTodayOverviewRowHeight * math.min(goals.length, 2) +
                (goals.length > 2 ? _kTodayOverviewMoreHeight : 0);
        final double rowHeight = bar
            ? _kTodayOverviewRowHeight
            : _kTodayGoalRowHeight;
        int shown = goals.length;
        if (goals.length * rowHeight > height) {
          shown = math.max(
            1,
            ((height - _kTodayOverviewMoreHeight) / rowHeight).floor(),
          );
        }
        final int more = goals.length - shown;
        final bool showLanguage = studyGoalsSharedLanguage(goals) == null;
        return ClipRect(
          child: Column(
            key: const ValueKey<String>('home-today-overview'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < shown; i++)
                SizedBox(
                  height: rowHeight,
                  child: FushiStaggeredEntrance(
                    index: i,
                    child: _todayGoalRow(
                      tokens,
                      goals[i],
                      input,
                      keyPrefix: 'home-today-overview-row',
                      showLanguage: showLanguage,
                      bar: bar,
                    ),
                  ),
                ),
              if (more > 0)
                SizedBox(
                  height: _kTodayOverviewMoreHeight,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      t.widget_label_goals_more(n: more),
                      key: const ValueKey<String>('home-today-overview-more'),
                      maxLines: 1,
                      style: tokens.type.metadata.copyWith(
                        color: muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 「今日」的大字版：今日字数；不矮时下面一行是目标进度（没设目标时是时长）；
  /// [wide]（色块外观的宽格）时起始侧再挂目标环。
  Widget _todayFigure(
    FushiDesignTokens tokens, {
    required bool wide,
    required bool dense,
  }) {
    final AppModel appModel = ref.read(appProvider);
    // 经典外观只在「没有目标 / 一条全部语言的每日字数目标」时出现（[_todayClassic]），
    // 分子就是今日学习字数（全部语言）。
    final StudyGoal? classicGoal = _classicCharsGoal;
    final int goal = classicGoal?.target ?? 0;
    final StudyGoalUnit unit = classicGoal == null
        ? StudyGoalUnit.chars
        : studyGoalUnitOf(classicGoal, appModel.readingGoalTextUnit);
    final String todayKey = _statWindow.todayKey;
    final int todayChars = studyGoalCharsForDay(_dailyRows, todayKey);
    final int goalChars = todayChars;
    int todayMs = 0;
    for (final StatFact f in _dailyRows) {
      if (f.dateKey == todayKey) todayMs += f.ms;
    }
    final bool hasGoal = goal > 0;
    final String todayTime = formatStatTime(todayMs);
    // 副行只写目标（设计稿 11-20 #12）：大字已经是今日字数，副行再写一遍
    // 「800 / 1000 字」只会把时长挤成省略号；读到多少由起始侧的目标环给。经典外观
    // 只承载一条每日字数目标（周 / 月目标走目标翻页），所以只有「目标 N」一种写法。
    final String? goalLine = !hasGoal
        ? null
        : t.home_today_goal_target(goal: formatStatCharsAxis(goal));
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
            unit: statGoalUnitLabel(unit),
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
              // 宽格有目标时目标进度与今日时长同一行：时长不让位，目标文字放不下才省略。
              if (goalLine != null && wide)
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        goalLine,
                        key: const ValueKey<String>('home-today-goal-line'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: caption,
                      ),
                    ),
                    Text(' · ', maxLines: 1, style: caption),
                    time,
                  ],
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
                // 达成后环心是对勾（与目标环 [StudyGoalRing] 同一完成状态）。
                center: hasGoal
                    ? (goalChars >= goal
                          ? FushiIcon(
                              FushiIcons.check,
                              size: dense ? 18 : 24,
                              color: colors.accent,
                            )
                          : null)
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

  /// 「近 7 天」学习字数柱条（今天在最后），柱高 = 格子内容区的实际高度（格子越高
  /// 柱越高），点块进统计中心。
  Widget _weekCell(bool poster) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) => HomeWidgetFrame(
      key: const ValueKey<String>('home-week-card'),
      title: t.stat_week_past,
      icon: FushiIcons.barChart,
      hueKey: HomeWidgetKind.week.id,
      poster: poster,
      dense: homeWidgetIsDense(c.maxHeight),
      onTap: _openStatisticsCenter,
      tapKey: const ValueKey<String>('home-week-open'),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final FushiCoverBlockColors? colors = HomeWidgetStyle.maybeOf(
            context,
          )?.colors;
          final double height = math.max(16, box.maxHeight);
          return HomeWidgetOverflowClip(
            child: colors != null
                ? _buildPosterWeekBars(colors, height: height)
                : _buildWeekBars(height: height),
          );
        },
      ),
    ),
  );

  // ── 语言目标 ────────────────────────────────────────────────────────────

  /// 「语言目标」格（设计 A，mockup 第三屏）：[item] 那种语言（null = 全部语言）的
  /// 目标环（[studyGoalRingSlots]：每个周期至多一条时固定日 / 周 / 月三格，空周期是
  /// 空环 +「—」；某周期有几条时一条目标一个环、最多三个、环下写度量短名），底下一行
  /// 是「今日 6.2k / 10k」（第一条目标）。一行高、或矮到环不足
  /// [_kLanguageGoalsMinRing] 时换成紧凑样子：每条目标一个小环 + 数值 / 目标 + 度量，并排放不下才分页。整块是这种语言的颜色（色块外观的底色、分区卡外观的环色，
  /// [studyGoalHue]），标题「日本語 目标」。没有这种语言的目标时是「为 X 添加目标」，
  /// 点按开目标面板并预填该语言；有目标时点按进「目标」设置子页。
  ///
  /// 用户在编辑态挑了目标（[HomeWidgetItem.goals]）时只画挑的那几条、照挑的顺序
  /// （[studyGoalPickedRingSlots]）；挑的目标语言都相同时标题是那种语言，否则是「目标」。
  /// 挑的记录都删了就回到自动。
  Widget _languageGoalsCell(
    FushiDesignTokens tokens,
    HomeWidgetItem item,
    bool poster,
  ) {
    final WidgetGoalsInput input = _studyGoalsInput();
    final List<StudyGoalProgress> all = _initialLoadDone
        ? _studyGoalProgress(input)
        : const <StudyGoalProgress>[];
    final List<StudyGoalProgress> picked = studyGoalPickedProgress(
      all,
      item.goals,
    );
    final ({String? language})? shared = picked.isEmpty
        ? (language: item.language)
        : studyGoalsSharedLanguage(picked);
    final String? language = shared == null ? item.language : shared.language;
    final String languageLabel = studyGoalLanguageLabel(language);
    final List<StudyGoalProgress> mine = picked.isNotEmpty
        ? picked
        : <StudyGoalProgress>[
            for (final StudyGoalProgress p in all)
              if (studyGoalSameLanguage(p.goal.language, item.language)) p,
          ];
    final bool empty = _initialLoadDone && mine.isEmpty;
    final String slotKey = item.language ?? 'all';
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool dense = homeWidgetIsDense(c.maxHeight);
        final Widget child;
        if (!_initialLoadDone) {
          child = const HomeWidgetOverflowClip(child: HomeGoalSkeleton());
        } else if (empty) {
          child = _fitCenter(
            Builder(
              builder: (BuildContext context) {
                final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
                final Color muted = style?.muted ?? tokens.surfaces.onVariant;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FushiIcon(FushiIcons.add, size: 16, color: muted),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        t.home_language_goals_empty(
                          language: studyGoalLanguageLabel(item.language),
                        ),
                        key: const ValueKey<String>(
                          'home-language-goals-empty',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.type.metadata.copyWith(color: muted),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        } else {
          child = _languageGoalsRings(
            tokens,
            mine,
            input,
            language: language,
            dense: dense,
            oneRow: item.size.rows <= 1,
            picked: picked.isNotEmpty,
            slotKey: slotKey,
          );
        }
        return HomeWidgetFrame(
          key: ValueKey<String>('home-language-goals-card/$slotKey'),
          title: shared == null
              ? t.home_language_goals_mixed_title
              : t.home_language_goals_title(language: languageLabel),
          icon: FushiIcons.language,
          hueKey: item.slot,
          hue: studyGoalHue(language),
          poster: poster,
          dense: dense,
          onTap: () => unawaited(
            empty ? _addLanguageGoal(item.language) : _openStudyGoalsSettings(),
          ),
          tapKey: ValueKey<String>('home-language-goals-open/$slotKey'),
          child: child,
        );
      },
    );
  }

  /// 「语言目标」格的环 + 底行（mockup `.rings3` + `.mini`）；环位见
  /// [studyGoalRingSlots]。一行高（[oneRow]）或环小于 [_kLanguageGoalsMinRing] 时是
  /// 紧凑样子（[_languageGoalsCompact]）；用户挑了几条目标（[picked]）时紧凑样子是
  /// 一组可滑的页（与「今日」格同一个 [HomeTodayGoalPager]），一条目标一页。
  Widget _languageGoalsRings(
    FushiDesignTokens tokens,
    List<StudyGoalProgress> goals,
    WidgetGoalsInput input, {
    required String? language,
    required bool dense,
    required bool oneRow,
    required bool picked,
    required String slotKey,
  }) {
    final List<StudyGoalRingSlot> slots = _languageGoalsSlots(
      picked
          ? studyGoalPickedRingSlots(goals, input)
          : studyGoalRingSlots(goals, input),
      input,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
        final FushiCoverBlockColors? colors = style?.colors;
        final Color muted = style?.muted ?? tokens.surfaces.onVariant;
        final Color strong = colors?.onContainer ?? tokens.surfaces.onSurface;
        final TextStyle caption = tokens.type.metadata.copyWith(color: muted);
        // 环色跟各自目标的语言（挑的目标可以混语言），带完成状态（[StudyGoalRing]）；
        // 环够大时环心写百分数。
        Widget ring(StudyGoalProgress? g, double size) => _studyGoalRingFor(
          context,
          g,
          size: size,
          showPercent: size >= 44,
          language: language,
          // 周 / 月目标：一行高的小环画今天的份额（与旁边「x / y 今天」同一个数）；
          // 两行起的大环照旧是周期进度（环下另写今天一行）。
          dual: size < _kDualRingMinSize,
        );

        // 环的大小随格子：等分的宽与（扣掉环下标签、底行后的）高里取小的。
        const double labelExtent = 18;
        const double lineExtent = 22;
        final double byWidth =
            (box.maxWidth - 8.0 * (slots.length + 1)) / slots.length;
        final double byHeight =
            box.maxHeight - labelExtent - (dense ? 0 : lineExtent);
        final double fitted = math.min(byWidth, byHeight);
        // 一行高的格子（用户 2026-11 拍板）或环放不下 → 紧凑样子；两行起照旧三环。
        if (oneRow || fitted < _kLanguageGoalsMinRing) {
          // 一行高：挑了几条就并排几条（环 + 已完成 / 目标 + 度量），放不下时分页
          // 可滑（与「今日」格同一个 [HomeTodayGoalPager]）；自动挑的按日 → 周 → 月
          // 取该语言的目标（与两行起的环位同一上限）。
          final List<StudyGoalProgress> shown = picked
              ? goals
              : studyGoalProgressByPeriod(
                  goals,
                ).take(kStudyGoalRingSlots).toList();
          final bool showLanguage = studyGoalsSharedLanguage(shown) == null;
          final int perPage = math.max(
            1,
            (box.maxWidth / _kLanguageGoalsCompactMinWidth).floor(),
          );
          Widget row(List<StudyGoalProgress> part, BoxConstraints rowBox) =>
              _languageGoalsCompact(
                context,
                part,
                input,
                ring: ring,
                box: rowBox,
                showLanguage: showLanguage,
              );
          if (shown.length <= perPage) return row(shown, box);
          final int pages = (shown.length / perPage).ceil();
          final int page = (_languageGoalsPage[slotKey] ?? 0).clamp(
            0,
            pages - 1,
          );
          List<StudyGoalProgress> part(int i) =>
              shown.skip(i * perPage).take(perPage).toList();
          return HomeTodayGoalPager(
            key: ValueKey<String>('home-language-goals-pager/$slotKey'),
            count: pages,
            page: page,
            dotColor: strong,
            dotLabel: (int i) => t.home_today_goal_page(
              goal: <String>[
                for (final StudyGoalProgress g in part(i))
                  studyGoalProgressLabel(g, input),
              ].join(', '),
            ),
            onPageChanged: (int i) => _languageGoalsPage[slotKey] = i,
            pageBuilder: (BuildContext context, int i) => LayoutBuilder(
              builder: (BuildContext context, BoxConstraints pageBox) =>
                  row(part(i), pageBox),
            ),
          );
        }
        final double ringSize = math.min(fitted, 64);

        Widget slotView(StudyGoalRingSlot slot) {
          final StudyGoalProgress? g = slot.progress;
          final bool done = g?.state.reached ?? false;
          return Semantics(
            key: ValueKey<String>('home-language-goals-ring-${slot.key}'),
            container: true,
            label: g == null
                ? '${studyGoalPeriodShortLabel(StudyGoalPeriod.fromWire(slot.key))} · —'
                : studyGoalSemanticsLabel(g, studyGoalProgressLabel(g, input)),
            excludeSemantics: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Opacity(
                  opacity: g == null ? 0.45 : 1,
                  child: ring(g, ringSize),
                ),
                const SizedBox(height: 3),
                Text(
                  slot.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: caption.copyWith(
                    color: done ? strong : muted,
                    fontWeight: done ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
                // 每个环自己的「已完成 / 目标」（旧版只有一条底行写第一条目标，摆在别的环
                // 下面容易看成那个环的数）。
                if (g != null && !dense)
                  Text(
                    _studyGoalPairText(g),
                    key: ValueKey<String>(
                      'home-language-goals-pair-${slot.key}',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: caption.copyWith(
                      color: strong,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                // 周 / 月目标：今天的份额（「12 / 20 今天」/「休息日」/「本周已完成」）。
                if (g != null && !dense && g.splitsPeriod)
                  Text(
                    studyGoalTodayText(g).short,
                    key: ValueKey<String>(
                      'home-language-goals-today-${slot.key}',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: caption,
                  ),
              ],
            ),
          );
        }

        return FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: box.maxWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: <Widget>[
                    for (final StudyGoalRingSlot slot in slots)
                      Flexible(child: slotView(slot)),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 「数值 / 目标」紧凑写法（[studyGoalCompactPair]，与系统小组件、设置行同一个
  /// 格式化：「3.7K / 10K」「24m / 30m」）。
  String _studyGoalPairText(StudyGoalProgress g) {
    final ({String value, String target}) pair = studyGoalCompactPair(
      g.value,
      g.target,
      isTime: g.id.isTime,
    );
    return '${pair.value} / ${pair.target}';
  }

  /// 环位标签补度量名：固定「日 / 周 / 月」三环（每个周期至多一条目标）时环下只写
  /// 周期，三条目标度量不同（中文：每日字数 + 每周观看）时认不出哪个环是什么——
  /// 这时写成「字数 · 日」「观看 · 周」。度量都相同、或一条目标一环（标签本来就是
  /// 度量）时原样。
  List<StudyGoalRingSlot> _languageGoalsSlots(
    List<StudyGoalRingSlot> slots,
    WidgetGoalsInput input,
  ) {
    final List<StudyGoalProgress> present = <StudyGoalProgress>[
      for (final StudyGoalRingSlot slot in slots) ?slot.progress,
    ];
    final bool byPeriod = slots.every(
      (StudyGoalRingSlot slot) =>
          StudyGoalPeriod.values.any((StudyGoalPeriod p) => p.wire == slot.key),
    );
    final bool mixedMetrics =
        present.map((StudyGoalProgress g) => g.goal.metric).toSet().length > 1;
    if (!byPeriod || !mixedMetrics) return slots;
    return <StudyGoalRingSlot>[
      for (final StudyGoalRingSlot slot in slots)
        slot.progress == null
            ? slot
            : StudyGoalRingSlot(
                key: slot.key,
                caption:
                    '${studyGoalMetricShortLabel(slot.progress!.goal.metric, unit: input.unitOf(slot.progress!.goal))}'
                    ' · ${studyGoalPeriodAbbrLabel(slot.progress!.goal.period)}',
                progress: slot.progress,
              ),
    ];
  }

  /// 「语言目标」格矮的时候（一行高）：[goals] 并排，每条是起始侧一个环 + 「已完成 /
  /// 目标」+ 度量（「Watching · Today」「Chars / wk」；语言不全相同时 [showLanguage]
  /// 带语言名）。用户 2026-11 反馈：只有环和「0 分钟」看不出是哪个目标、离目标多远。
  Widget _languageGoalsCompact(
    BuildContext context,
    List<StudyGoalProgress> goals,
    WidgetGoalsInput input, {
    required Widget Function(StudyGoalProgress? goal, double size) ring,
    required BoxConstraints box,
    required bool showLanguage,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
    final Color muted = style?.muted ?? tokens.surfaces.onVariant;
    final double ringSize = box.maxHeight.clamp(22.0, 40.0);
    Widget entry(StudyGoalProgress goal) {
      final ({String value, String? unit}) figure = studyGoalFigure(
        goal,
        input,
      );
      final StudyGoal labelled = showLanguage
          ? goal.goal
          : goal.goal.copyWith(language: () => null);
      final String metric = studyGoalShortLabel(
        labelled,
        unitChoice: input.unitChoice,
      );
      // 周 / 月目标（设计 C）：大字是今天「12 / 20」，小字「度量 · 今天 · 按计划」；
      // 今天没有份额（休息日 / 周期已达成）时大字回到周期数值、小字写状态。
      final StudyGoalTodayText? today = goal.splitsPeriod
          ? studyGoalTodayText(goal)
          : null;
      final bool todayFigure = today != null && goal.todayShare > 0;
      return Semantics(
        key: ValueKey<String>('home-language-goals-compact/${goal.goal.id}'),
        container: true,
        label: studyGoalSemanticsLabel(
          goal,
          studyGoalProgressLabel(goal, input),
        ),
        excludeSemantics: true,
        child: Row(
          children: <Widget>[
            ring(goal, ringSize),
            const SizedBox(width: 10),
            Expanded(
              // 数值缩放着放得下；度量那行保持可读字号，放不下就省略。格子矮于两行字时
              // 整块等比缩小（不溢出）。
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints text) =>
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: SizedBox(
                        width: text.maxWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerStart,
                              child: HomeWidgetFigure(
                                value: todayFigure
                                    ? '${today.value} / ${today.share}'
                                    : _studyGoalPairText(goal),
                                // 周 / 月目标的今天份额：单位处写「今天」（「1.2K / 7K
                                // 今天」），小字只剩度量与进度。
                                unit: todayFigure
                                    ? t.study_goal_today_word
                                    : goal.id.isTime
                                    ? null
                                    : figure.unit,
                              ),
                            ),
                            Text(
                              today != null
                                  ? todayFigure
                                        ? '$metric · ${today.pace}'
                                        : '$metric · ${today.short}'
                                  : goal.restDay && !goal.state.reached
                                  ? '$metric · ${t.study_goal_status_rest_day}'
                                  : goal.goal.period == StudyGoalPeriod.daily
                                  ? '$metric · ${t.stat_today}'
                                  : metric,
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
              ),
            ),
          ],
        ),
      );
    }

    return KeyedSubtree(
      key: const ValueKey<String>('home-language-goals-compact'),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < goals.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: entry(goals[i])),
          ],
        ],
      ),
    );
  }

  // ── 最近添加 / 追踪 ──────────────────────────────────────────────────────

  /// 「最近添加」（用户 2026-11-17 重设计）：按格子实际大小选样式——
  /// - 色块外观、够宽放色块（每块宽 ≥ [_kRecentBlockMinWidth]、高 ≥
  ///   [_kContinueBlockRowMin]）：与「继续」卡同一套封面色块铺成几行几列；够大
  ///   （≥ 2 列 × 3 行）时最新一项放大成占满起始侧一整列的主色块；
  /// - 否则（1 列宽的窄格 / 分区卡外观）：条目小行（[_widgetMiniList]）。
  /// 同一合集已在数据层合成一项（扇形 + 卷数）；「继续」里已有的去重。有内容时外框
  /// 不画「最近添加」大水印（会压在条目文字后面）。
  Widget _recentCell(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<MediaItem> books,
    bool poster,
  ) {
    final List<_ContinueEntry> list = _initialLoadDone
        ? _recentlyAddedEntries(appModel, books)
        : const <_ContinueEntry>[];
    final DateTime now = DateTime.now();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 色块模式下外框不画底（[HomeWidgetFrame.bare]）、四周不留内边距：内容区
        // = 整格减去小标题行。
        final Size blockArea = Size(
          c.maxWidth,
          math.max(
            0,
            c.maxHeight - kHomeWidgetHeaderHeight - kHomeWidgetHeaderGap,
          ),
        );
        final _RecentBlockGrid? blocks = poster && list.isNotEmpty
            ? _recentBlockGridFor(blockArea, list.length)
            : null;
        return HomeWidgetFrame(
          key: const ValueKey<String>('home-recent-card'),
          title: t.home_recently_added,
          icon: FushiIcons.schedule,
          hueKey: HomeWidgetKind.recentlyAdded.id,
          poster: poster,
          dense: false,
          bare: blocks != null,
          child: list.isEmpty
              ? _widgetEmptyLine(
                  tokens,
                  _initialLoadDone ? t.home_widget_recent_empty : '',
                )
              : blocks != null
              ? _recentBlocks(tokens, appModel, list, blocks, blockArea, now)
              : LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) =>
                      _widgetMiniList(
                        tokens: tokens,
                        appModel: appModel,
                        key: const ValueKey<String>('home-recent-list'),
                        keyPrefix: 'home-recent-item',
                        entries: list,
                        area: box.biggest,
                        subtitleOf: (_ContinueEntry e) =>
                            _recentSubtitle(e, now),
                      ),
                ),
        );
      },
    );
  }

  /// 按 [grid] 把色块铺满 [area]：有主色块时它占起始侧一整列（全高、宽约四成），
  /// 其余在剩下的区域里几行几列；放不下的条目不画（不缩字号）。
  Widget _recentBlocks(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> list,
    _RecentBlockGrid grid,
    Size area,
    DateTime now,
  ) {
    const double gap = kFushiCoverBlockSpacing;
    Widget tiles(Size box, int cols, int rows, int offset) {
      final double w = (box.width - gap * (cols - 1)) / cols;
      final double h = (box.height - gap * (rows - 1)) / rows;
      final int count = math.min(list.length - offset, cols * rows);
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: <Widget>[
          for (int i = 0; i < count; i++)
            SizedBox(
              width: w,
              height: h,
              child: FushiStaggeredEntrance(
                index: i + offset,
                child: _recentBlock(
                  tokens,
                  appModel,
                  list[i + offset],
                  i + offset,
                  homeCoverBlockSizeFor(h),
                  now,
                ),
              ),
            ),
        ],
      );
    }

    if (!grid.featured) {
      return KeyedSubtree(
        key: const ValueKey<String>('home-recent-blocks'),
        child: tiles(area, grid.cols, grid.rows, 0),
      );
    }
    final double leadWidth = (area.width - gap) * _kRecentLeadShare;
    final double restWidth = area.width - leadWidth - gap;
    final int restCols = math.max(
      1,
      ((restWidth + gap) / (_kRecentBlockMinWidth + gap)).floor(),
    );
    return Row(
      key: const ValueKey<String>('home-recent-blocks'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: leadWidth,
          child: FushiStaggeredEntrance(
            index: 0,
            child: _recentBlock(
              tokens,
              appModel,
              list.first,
              0,
              homeCoverBlockSizeFor(area.height, allowHero: true),
              now,
            ),
          ),
        ),
        const SizedBox(width: gap),
        SizedBox(
          width: restWidth,
          child: tiles(Size(restWidth, area.height), restCols, grid.rows, 1),
        ),
      ],
    );
  }

  /// 媒体追踪同步状态（模块门控在可用性判据里）。色块外观且格子够宽够高（宽格、
  /// 高 ≥ [_trackingPosterMinHeight]）时画拼贴追踪块（[HomeTrackingPoster]，设计
  /// 稿 H6：按状态取色、待关联数大字兼水印、待关联条目封面扇形叠放、「处理 ›」）；
  /// 其余（半栏 / 矮格 / 分区卡外观）按格子实际大小排版在 [HomeTrackingPanel] 里。
  Widget _trackingCell(AppModel appModel, List<MediaItem> books, bool poster) {
    final HomeTrackingSummary summary = HomeTrackingSummary.of(_tracking);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        if (poster &&
            homeWidgetIsWide(c.maxWidth) &&
            c.maxHeight >=
                _trackingPosterMinHeight(MediaQuery.textScalerOf(context))) {
          return KeyedSubtree(
            key: const ValueKey<String>('home-tracking-card'),
            child: HomeTrackingPoster(
              summary: summary,
              covers: _trackingUnlinkedCovers(appModel, books),
              onOpen: () => _openTrackingPage(summary),
              height: c.maxHeight,
            ),
          );
        }
        return HomeTrackingPanel(
          key: const ValueKey<String>('home-tracking-card'),
          summary: summary,
          onOpen: () => _openTrackingPage(summary),
          poster: poster,
        );
      },
    );
  }
}

// ── 按实际尺寸排版的阈值（逻辑像素） ──────────────────────────────────────

/// 「继续」主卡在左右分割里占的宽度比例 / 上下分割里占的高度比例。
const double _kContinueHeroShare = 0.55;
const double _kContinueHeroStackShare = 0.6;

/// 「继续」上下分割时主卡至少多高（再矮就只放主卡）。
const double _kContinueHeroMinHeight = 100;

/// 「继续」左右分割的最小格宽与最小宽高比（其余条目那段至少约 200 宽）。
const double _kContinueSideMinWidth = 460;
const double _kContinueSideMinAspect = 1.5;

/// 「继续」上下分割时其余条目那段的最小高度：色块外观（半高色块）/ 分区卡外观
/// （条目小行）。
const double _kContinueBlockSideMin = 96;
const double _kContinueMiniSideMin = 64;

/// 色块外观其余条目铺多行时每行至少多高。
const double _kContinueBlockRowMin = 96;

/// 首页色块按格子**实际高度**取尺寸档（BUG-5252）。首页小组件的格子高度连续可调
/// （「最近添加」/「继续」其余条目的一格约 96～210 高、主色块可到 300+），而
/// [FushiCoverBlockSize] 是按库页固定高度定的档：半高卡 125、规整块 184 / 204、
/// 拼贴首块 250 / 264，[FushiCoverBlock] 的 logo 槽高 / 字号 / 内边距按档取（半高
/// 40、规整 52 / 64、首块 66 / 84）。首页从前不论格子多高一律给半高档 / 规整档：
/// 半高档那时还不画 logo，系列卡在首页只剩文字 + 大字水印；300+ 高的主色块只有
/// 64 高的 logo 槽，logo 缩在角落。
///
/// - 不矮于库页半高卡（[_kHomeBlockRegularMinHeight]）→ 规整档（与库页系列卡同
///   一套 logo 槽 / 排版）；更矮的格子才是半高档；
/// - [allowHero]（「最近添加」主色块）且不矮于窄窗拼贴首块
///   （[kFushiCoverBlockHeroHeightCompact]）→ 首块档（与库页拼贴首块同一档 logo）。
///   「继续」其余条目不升首块档：首块档会加状态 chip 与「继续」主按钮。
FushiCoverBlockSize homeCoverBlockSizeFor(
  double height, {
  bool allowHero = false,
}) {
  if (allowHero && height >= kFushiCoverBlockHeroHeightCompact) {
    return FushiCoverBlockSize.hero;
  }
  if (height >= _kHomeBlockRegularMinHeight) return FushiCoverBlockSize.regular;
  return FushiCoverBlockSize.half;
}

/// 库页半高卡的高度（拼贴首块旁两张叠放：(264 − 间距) / 2 = 125）。首页格子不比
/// 它矮时按规整档排（规整档窄窗内容：标题槽 52 + chip 行 + 上下内边距 32 ≈ 115，
/// 放得下）。
const double _kHomeBlockRegularMinHeight =
    (kFushiCoverBlockHeroHeight - kFushiCoverBlockSpacing) / 2;

/// 「最近添加」一块色块的最小宽度：再窄标题只剩几个字，退回条目小行。
const double _kRecentBlockMinWidth = 220;

/// 「最近添加」主色块占的宽度比例。
const double _kRecentLeadShare = 0.4;

/// 「最近添加」色块的排法（[_recentBlockGridFor]）。
@immutable
class _RecentBlockGrid {
  const _RecentBlockGrid({
    required this.cols,
    required this.rows,
    required this.featured,
  });

  final int cols;
  final int rows;

  /// 最新一项放大成占满起始侧一整列的主色块。
  final bool featured;
}

/// [area] 里「最近添加」色块怎么排；放不下一块够宽的色块时为 null（退回条目
/// 小行）。[count] 是条目数（够 3 项才有主色块）。
_RecentBlockGrid? _recentBlockGridFor(Size area, int count) {
  const double gap = kFushiCoverBlockSpacing;
  final int cols = ((area.width + gap) / (_kRecentBlockMinWidth + gap)).floor();
  final int rows = ((area.height + gap) / (_kContinueBlockRowMin + gap))
      .floor();
  if (cols < 1 || rows < 1) return null;
  return _RecentBlockGrid(
    cols: cols,
    rows: rows,
    featured: cols >= 2 && rows >= 3 && count >= 3,
  );
}

/// 分区卡外观主卡旁的封面卡横滑行最高多高；更高就改铺条目小行（封面放大没有意义，
/// 多列条目更有用）。
const double _kContinueCoverRowMax = 300;

/// 拼贴追踪块（[HomeTrackingPoster]）至少要多高才不溢出（纯函数）：上下内边距
/// 32 + 标题行（12 号）+ 大字（34 号）+ chip 行 26 + 余量 8，字号随系统缩放。
/// 宽网格 2×1（约 104…140）在默认字号的常见桌面宽下放得下，窄网格一行高放不下。
double _trackingPosterMinHeight(TextScaler scaler) =>
    32 + scaler.scale(12) * 1.25 + scaler.scale(34) + 26 + 8;

/// 条目小行：行高范围、每列最小宽、间距。
const double _kMiniRowMin = 52;
const double _kMiniRowMax = 72;
const double _kMiniTileMinWidth = 220;
const double _kMiniGap = 8;

/// 「今日」内容区够宽时柱条挂在结束侧、够高时挂在下面；挂在下面时主体最多占多高。
const double _kTodayBarsSideWidth = 380;
const double _kTodayBarsBelowHeight = 130;
const double _kTodayMainMaxHeight = 72;

/// 「今日」目标翻页：主体要多高（柱条挂下面时）、主目标头部约占多高、其余目标每行多高。
const double _kTodayGoalsMainMaxHeight = 140;
const double _kTodayGoalHeadHeight = 82;
const double _kTodayGoalRowHeight = 20;

/// 「今日」目标翻页的一页窄于它时不写「标签 · 进度」小字行。
const double _kTodayGoalLabelMinWidth = 150;

/// 「今日」格总览版式：带进度条的一行高、末行「还有 N 个」的高。
const double _kTodayOverviewRowHeight = 32;
const double _kTodayOverviewMoreHeight = 18;

/// 「语言目标」格的环小于它（一行高的格子）就换紧凑样子：一个环 + 数值。
const double _kLanguageGoalsMinRing = 32;

/// 周 / 月目标的双环（里圈今天、外圈周期）至少这么大才画两圈；更小只画今天一圈。
const double _kDualRingMinSize = 48;

/// 一行高「语言目标」格里并排的一条目标至少要这么宽（环 + 「800 / 1K 字」+ 度量）。
const double _kLanguageGoalsCompactMinWidth = 170;

/// 「今日」结束侧近 7 天柱条占内容宽的比例，与上限（7 根 12px 细柱 + 6 道 5px 间隔）。
const double _kTodayBarsWidthShare = 0.2;
const double _kTodayBarsMaxWidth = 7 * 12 + 6 * 5;

/// 「继续」主角怎么分：只放主卡 / 其余条目挂在主卡旁 / 挂在主卡下。
enum _ContinueSplit { none, side, below }

/// [area] 大小的「继续」主角格子怎么分（[count] 条条目；[minSide] = 上下分割时
/// 其余条目那段的最小高度）。纯函数。
_ContinueSplit _continueSplitFor(
  Size area,
  int count, {
  required double minSide,
}) {
  if (count < 2) return _ContinueSplit.none;
  if (area.width >= _kContinueSideMinWidth &&
      area.width / math.max(1, area.height) >= _kContinueSideMinAspect) {
    return _ContinueSplit.side;
  }
  const double gap = kFushiCoverBlockSpacing;
  final double hero = (area.height - gap) * _kContinueHeroStackShare;
  final double side = area.height - gap - hero;
  if (hero >= _kContinueHeroMinHeight && side >= minSide) {
    return _ContinueSplit.below;
  }
  return _ContinueSplit.none;
}

/// 条目小行文字区里文字区宽于它才放单行标题；更窄（半栏 1 列）时标题放两行。
const double _kMiniNarrowTextWidth = 120;

/// 条目小行的文字区放哪几行：标题行数、放不放副行 / 眉标。
typedef _MiniTileLines = ({int title, bool subtitle, bool eyebrow});

/// 按 [height] 挑条目小行放哪几行（纯函数）：先放一行标题；[narrow] 时再放第二行
/// 标题；剩下的高度够一整行才放副行（进度），再够才放眉标——放不下的整行不放，
/// 不会裁出半行字。
_MiniTileLines _miniTileLines({
  required double height,
  required bool narrow,
  required double titleLine,
  required double metaLine,
  required double browLine,
  required bool hasSubtitle,
  required bool hasEyebrow,
}) {
  double left = height - titleLine;
  int title = 1;
  if (narrow && left >= titleLine) {
    title = 2;
    left -= titleLine;
  }
  final bool subtitle = hasSubtitle && left >= metaLine;
  if (subtitle) left -= metaLine;
  final bool eyebrow = hasEyebrow && left >= browLine;
  return (title: title, subtitle: subtitle, eyebrow: eyebrow);
}

/// [style] 一行字的实际高度（含系统字号缩放）。
double _lineHeight(BuildContext context, TextStyle style) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: 'Ag漢', style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final double h = painter.height;
  painter.dispose();
  return h;
}
