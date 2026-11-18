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
              FushiCoverBlockSize.half,
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
              portraitOnly: true,
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
    void editGoal() => unawaited(_editGoal());
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool dense = homeWidgetIsDense(c.maxHeight);
        final bool wide = homeWidgetIsWide(c.maxWidth);
        final Widget main;
        if (!_initialLoadDone) {
          main = const HomeWidgetOverflowClip(child: HomeGoalSkeleton());
        } else if (wide && !poster) {
          main = _fitCenter(_buildStudyHeader(tokens));
        } else {
          main = _todayFigure(tokens, wide: wide, dense: dense);
        }
        return HomeWidgetFrame(
          key: const ValueKey<String>('home-study-card'),
          title: t.stat_today,
          icon: FushiIcons.barChart,
          hueKey: HomeWidgetKind.today.id,
          poster: poster,
          dense: dense,
          // 宽的矮格：头部行自己就写着今日时长与目标，不再占一行小标题。
          showHeader: !(dense && wide),
          onTap: editGoal,
          tapKey: const ValueKey<String>('home-goal-row'),
          child: !_initialLoadDone
              ? main
              : LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    Widget bars(double height) => Builder(
                      builder: (BuildContext context) {
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
                                )
                              : _buildWeekBars(height: height),
                        );
                      },
                    );
                    if (box.maxWidth >= _kTodayBarsSideWidth) {
                      return Row(
                        children: <Widget>[
                          Expanded(flex: 11, child: main),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 9,
                            child: HomeWidgetOverflowClip(
                              child: bars(math.max(16, box.maxHeight)),
                            ),
                          ),
                        ],
                      );
                    }
                    if (box.maxHeight >= _kTodayBarsBelowHeight) {
                      final double mainHeight = math.min(
                        _kTodayMainMaxHeight,
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

  /// 「今日」的大字版：今日字数；不矮时下面一行是目标进度（没设目标时是时长）；
  /// [wide]（色块外观的宽格）时起始侧再挂目标环。
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
                  FushiCoverBlockSize.half,
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
              FushiCoverBlockSize.regular,
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
