part of '../srs_deck_list_page.dart';

// 复习首页的 Apple（Cupertino，iOS 27 / macOS 27）布局——2026-11-24 用户拍板方案 A，效果图
// `fushi/build/srs_cupertino_design/index.html`。[_SrsDeckListPageState.build] 先按设计
// 系统分派（[isGlassDesign]），Apple 走这里，M3E 原样不动。
//
// 业务状态与动作只有一份：本扩展直接调 [_SrsDeckListPageState] 的方法（_addNote /
// _openBrowse / _openImport / _syncNow / _openReview / _onDeckAction / _placeDeck …）
// 与它的选中 / 焦点状态（_selectedId / _focusId / _paired），不另存镜像。牌组树的
// 折叠、拖放、键盘 / 手柄、删除进度与 M3E 是同一个 [_DeckList] / [_DeckRow]（只换
// 外观，`apple: true`）。
//
// 版式：
// - 页头（[FushiStaticMasthead]）：大标题 + 平铺「有冲突时的同步冲突（红点）· ＋ 添加
//   笔记 · 🔍 浏览 · ⋯」，⋯ 是分三节的菜单（牌组：新建 / 导入；同步：立即同步 / 同步
//   冲突 / 同步与历史；数据：导出 .apkg / 笔记类型）。宽屏（≥ [_kSrsHomeWideMin]）页头
//   右侧是「开始复习」主按钮（多个顶层牌组有活时旁边一颗 ⌄ 选从哪个开始）；窄屏主按钮在
//   今日卡底部。
// - 宽屏：一条滚动——横幅、三张摘要卡（今日 · 选中牌组 · 连续天数，放不下排 2 + 1）、
//   「牌组」分组标题 + 分组牌组树、已配对设备。
// - 窄屏根层：横幅、今日卡、连续天数卡（16 周）、全库预测 / RWKV 卡、牌组分组、已配对
//   设备；点行进牌组详情页（牌组卡 + 子牌组分组），页头返回键回上一层。

/// 宽屏三张摘要卡里「连续天数」热力图的周数；手机 16 周（拍板点 5）。
const int _kAppleSrsHeatmapWeeksWide = 26;
const int _kAppleSrsHeatmapWeeksNarrow = 16;

/// 三张摘要卡并排所需的最小列宽（不够就 2 + 1）。
const double _kAppleSrsCardMinWidth = 300;

extension _AppleSrsHome on _SrsDeckListPageState {
  Widget _buildAppleHome(
    BuildContext context,
    AsyncValue<SrsDeckListData?> data,
    int conflicts,
  ) {
    final SrsDeckListData? list = data.valueOrNull;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= _kSrsHomeWideMin;
        final SrsDeckSummary? focus = wide ? null : _deckById(list, _focusId);
        final bool nested = focus != null;
        final String title = focus?.deck.name ?? t.nav_srs;
        return SectionPopScope(
          intercepting: nested,
          onIntercept: () => _back(list),
          child: FushiPageScaffold(
            title: title,
            header: _appleMasthead(
              context,
              conflicts,
              list,
              title: title,
              focus: focus,
              wide: wide,
            ),
            body: Builder(
              builder: (BuildContext context) => AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                switchInCurve: FushiMotion.enter,
                switchOutCurve: FushiMotion.exit,
                child: KeyedSubtree(
                  key: ValueKey<String>(
                    data.isLoading && !data.hasValue
                        ? 'loading'
                        : data.hasError
                        ? 'error'
                        : 'list',
                  ),
                  child: ListenableBuilder(
                    listenable: Listenable.merge(<Listenable>[
                      ref.watch(srsImportControllerProvider),
                      ref.watch(srsDeckDeleteControllerProvider),
                    ]),
                    builder: (BuildContext context, Widget? _) =>
                        _appleBody(context, data, wide: wide, focus: focus),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 页头平铺动作（拍板点 2）：有冲突时「同步冲突」带红点提到栏上（优先级最高，最后才收），
  /// ＋ 添加笔记、🔍 浏览，最后是恒在的分节「⋯」。iOS 档最多平铺 3 颗由收纳判据
  /// （[fushiHeaderMinCollapsed]）负责。
  List<Widget> _appleBarActions(int conflicts) => <Widget>[
    if (conflicts > 0)
      FushiIconButton(
        key: const ValueKey<String>('srs_conflicts'),
        icon: FushiIcons.syncProblem,
        tooltip: t.srs_conflicts_title_count(n: conflicts),
        badge: true,
        overflowPriority: 10,
        onTap: () => srsRunLogged('SrsDeckList.conflicts', _openConflicts),
      ),
    FushiIconButton(
      key: const ValueKey<String>('srs_add_note'),
      icon: FushiIcons.add,
      tooltip: t.srs_note_add,
      overflowPriority: 5,
      onTap: () => srsRunLogged('SrsDeckList.addNote', _addNote),
    ),
    FushiIconButton(
      key: const ValueKey<String>('srs_browse'),
      icon: FushiIcons.search,
      tooltip: t.srs_browse_title,
      overflowPriority: 4,
      onTap: () => srsRunLogged('SrsDeckList.browse', _openBrowse),
    ),
    FushiHeaderMoreButton(
      buttonKey: const ValueKey<String>('srs_home_more'),
      keepEntriesInMenu: true,
      entries: _appleMoreEntries(conflicts),
    ),
  ];

  /// 「⋯」三节：牌组 / 同步 / 数据。
  List<FushiHeaderMoreEntry> _appleMoreEntries(int conflicts) {
    final String decks = t.srs_home_decks_header;
    final String sync = t.srs_home_menu_sync;
    final String data = t.srs_home_menu_data;
    return <FushiHeaderMoreEntry>[
      FushiHeaderMoreEntry(
        key: const ValueKey<String>('srs_new_deck'),
        icon: FushiIcons.libraryAdd,
        label: t.srs_deck_new,
        section: decks,
        onSelected: () => srsRunLogged('SrsDeckList.newDeck', _createDeck),
      ),
      FushiHeaderMoreEntry(
        key: const ValueKey<String>('srs_import'),
        icon: FushiIcons.importFile,
        label: t.srs_import,
        section: decks,
        onSelected: () => srsRunLogged('SrsDeckList.import', _openImport),
      ),
      FushiHeaderMoreEntry(
        key: const ValueKey<String>('srs_sync_now'),
        icon: FushiIcons.sync,
        label: t.srs_sync_now,
        section: sync,
        onSelected: () => srsRunLogged('SrsDeckList.syncNow', _syncNow),
      ),
      FushiHeaderMoreEntry(
        key: const ValueKey<String>('srs_conflicts_menu'),
        icon: conflicts > 0 ? FushiIcons.syncProblem : FushiIcons.cloudSync,
        label: conflicts > 0
            ? t.srs_conflicts_title_count(n: conflicts)
            : t.srs_conflicts_title,
        section: sync,
        onSelected: () => srsRunLogged('SrsDeckList.conflicts', _openConflicts),
      ),
      FushiHeaderMoreEntry(
        key: const ValueKey<String>('srs_timeline'),
        icon: FushiIcons.history,
        label: t.srs_timeline_title,
        section: sync,
        onSelected: () => srsRunLogged(
          'SrsDeckList.history',
          () => _push<void>((_) => const SrsHistoryPage()),
        ),
      ),
      FushiHeaderMoreEntry(
        key: const ValueKey<String>('srs_export_apkg'),
        icon: FushiIcons.upload,
        label: t.srs_export_apkg,
        section: data,
        onSelected: () => srsRunLogged(
          'SrsDeckList.export',
          () => openSrsExport(context, ref),
        ),
      ),
      FushiHeaderMoreEntry(
        key: const ValueKey<String>('srs_note_types'),
        icon: FushiIcons.ankiCard,
        label: t.srs_note_types_title,
        section: data,
        onSelected: () => srsRunLogged('SrsDeckList.noteTypes', _openNoteTypes),
      ),
    ];
  }

  Widget _appleMasthead(
    BuildContext context,
    int conflicts,
    SrsDeckListData? list, {
    required String title,
    required SrsDeckSummary? focus,
    required bool wide,
  }) {
    final NavigatorState? navigator = Navigator.maybeOf(context);
    final bool canPop = ModalRoute.of(context)?.isFirst == false;
    final String backLabel = MaterialLocalizations.of(
      context,
    ).backButtonTooltip;
    final SrsDeckSummary? nested = focus;
    final SrsDeckSummary? go = nested != null || !wide
        ? null
        : list?.firstRootWithWork;
    final List<SrsDeckSummary> roots = <SrsDeckSummary>[
      if (list != null)
        for (final SrsDeckSummary d in list.decks)
          if (d.parentId == null && _srsDeckHasWork(d)) d,
    ];
    Widget? trailing;
    if (go != null) {
      final Widget cta = FushiMastheadCtaButton(
        buttonKey: const ValueKey<String>('srs-masthead-start'),
        icon: FushiIcons.play,
        label: t.srs_home_start,
        onPressed: () =>
            srsRunLogged('SrsDeckList.review', () => _openReview(go)),
      );
      trailing = roots.length <= 1
          ? cta
          : Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: <Widget>[
                cta,
                Builder(
                  builder: (BuildContext anchor) => FushiIconButton(
                    key: const ValueKey<String>('srs-masthead-start-pick'),
                    icon: FushiIcons.expandMore,
                    tooltip: t.srs_home_start_pick,
                    onTap: () => unawaited(_pickStartDeck(anchor, roots)),
                  ),
                ),
              ],
            );
    }
    return FushiStaticMasthead(
      key: const ValueKey<String>('srs_home_masthead'),
      title: title,
      leading: nested != null
          ? FushiIconButton(
              key: const ValueKey<String>('srs_home_back'),
              icon: FushiIcons.back,
              tooltip: backLabel,
              onTap: () => _back(list),
            )
          : canPop && navigator != null
          ? FushiIconButton(
              icon: FushiIcons.back,
              tooltip: backLabel,
              onTap: () => unawaited(navigator.maybePop()),
            )
          : null,
      actions: _appleBarActions(conflicts),
      trailing: trailing,
    );
  }

  /// 「开始复习 ⌄」：选从哪个有活的顶层牌组开始（Apple 菜单，牌组图标 + 名字 + 剩余张数）。
  Future<void> _pickStartDeck(
    BuildContext anchor,
    List<SrsDeckSummary> roots,
  ) async {
    final RenderBox? box = anchor.findRenderObject() as RenderBox?;
    final RenderBox? overlay =
        Navigator.of(anchor).overlay?.context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return;
    final Rect rect =
        box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final SrsDeckSummary? picked = await showFushiMenu<SrsDeckSummary>(
      context: anchor,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      semanticLabel: t.srs_home_start_pick,
      items: <PopupMenuEntry<SrsDeckSummary>>[
        for (final SrsDeckSummary d in roots)
          FushiPopupMenuItem<SrsDeckSummary>(
            key: ValueKey<String>('srs-masthead-start-${d.deck.id}'),
            value: d,
            icon: FushiIcons.play,
            label: '${d.deck.name} · ${_srsDeckToday(d)}',
          ),
      ],
    );
    if (picked == null || !mounted) return;
    srsRunLogged('SrsDeckList.review', () => _openReview(picked));
  }

  Widget _appleBody(
    BuildContext context,
    AsyncValue<SrsDeckListData?> data, {
    required bool wide,
    required SrsDeckSummary? focus,
  }) {
    if (data.hasError && !data.hasValue) {
      return SrsLoadErrorView(
        error: data.error,
        retryKey: const ValueKey<String>('srs-load-retry'),
        onRetry: () => ref.invalidate(srsStoreProvider),
      );
    }
    final SrsDeckListData? list = data.valueOrNull;
    if (list == null && data.hasValue) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            key: const ValueKey<String>('srs-deck-list-unavailable'),
            icon: FushiIcons.error,
            tone: FushiPlaceholderTone.error,
            message: t.srs_engine_unavailable,
            action: fushiAppleBorderedButton(
              context,
              prominent: false,
              onPressed: () => ref.invalidate(srsStoreProvider),
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(
                t.retry,
                key: const ValueKey<String>('srs-load-retry'),
              ),
            ),
          ),
        ),
      );
    }
    if (list == null) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final SrsDeckDeleteController deleter = ref.read(
      srsDeckDeleteControllerProvider,
    );
    deleter.pruneDeleted(<String>[
      for (final SrsDeckSummary d in list.decks) d.deck.id,
    ]);
    return _AppleSrsHomeView(
      data: list,
      paired: _hasPaired ? _paired : null,
      wide: wide,
      focus: focus,
      selectedId: _selectedId ?? _focusId,
      stats: ref.watch(srsHomeStatsProvider).valueOrNull,
      deleting: deleter.deleting,
      banners: <Widget>[
        SrsScrubErrorNotice(gapBelow: _appleSrsBlockGap(context)),
        ..._appleSrsDeckBanners(
          context,
          data: list,
          showImportTasks: ref
              .read(srsImportControllerProvider)
              .tasks
              .isNotEmpty,
          lapisPending:
              ref.watch(srsLegacyLapisPendingProvider).valueOrNull ?? 0,
          joinProvisional:
              ref.watch(srsCollectionBindingProvider).valueOrNull?.state ==
              SrsCollectionBindingState.provisional,
          onMigrateLapis: () => srsRunLogged(
            'SrsDeckList.lapisMigration',
            () => openSrsLegacyLapisMigrationPage(context),
          ),
          onDismissLapisReminder: () => srsRunLogged(
            'SrsDeckList.lapisReminderDismiss',
            () => dismissSrsLapisMigrationReminder(ref),
          ),
          onStarterPacks: () => srsRunLogged(
            'SrsDeckList.starterPacks',
            () => openSrsStarterPacks(context, ref),
          ),
          onAddFirst: () => srsRunLogged('SrsDeckList.addFirst', _addNote),
          legacyLimitUnitDecks:
              ref.watch(srsLimitUnitLegacyCountProvider).valueOrNull ?? 0,
          onKeepLegacyLimitCards: () => srsRunLogged(
            'SrsDeckList.limitUnitKeepCards',
            () => _settleLegacyLimitUnit(list.store, SrsLimitUnit.cards),
          ),
          onAcceptLimitAnswers: () => srsRunLogged(
            'SrsDeckList.limitUnitAcceptAnswers',
            () => _settleLegacyLimitUnit(list.store, SrsLimitUnit.reviews),
          ),
        ),
      ],
      onFocus: _setFocus,
      onSelect: _select,
      onReview: (SrsDeckSummary d) =>
          srsRunLogged('SrsDeckList.review', () => _openReview(d)),
      onAction: _onDeckAction,
      onSetCollapsed: _setCollapsed,
      onPlace: (SrsDeckSummary deck, String? parentId, String? beforeId) =>
          srsRunLogged(
            'SrsDeckList.drop',
            () => _placeDeck(deck, parentId, beforeId: beforeId),
          ),
    );
  }
}

/// Apple 复习首页的内容区（数据与回调同 M3E [_SrsHomeView]）。
class _AppleSrsHomeView extends StatelessWidget {
  const _AppleSrsHomeView({
    required this.data,
    required this.paired,
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
  final _SrsPairedHosts? paired;
  final bool wide;
  final SrsDeckSummary? focus;
  final String? selectedId;
  final SrsHomeStats? stats;
  final Map<String, ValueListenable<double?>> deleting;
  final List<Widget> banners;
  final ValueChanged<String?> onFocus;
  final ValueChanged<String> onSelect;
  final void Function(SrsDeckSummary deck) onReview;
  final void Function(SrsDeckSummary deck, _DeckAction action) onAction;
  final Future<int?> Function(SrsDeckSummary deck, bool collapsed)
  onSetCollapsed;
  final _DeckPlace onPlace;

  /// 宽屏中间卡默认显示的牌组（同 M3E：有效选中 → 第一个有活的顶层 → 第一个顶层）。
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
    apple: true,
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

  /// 牌组卡（详情统计按牌组子树由内核出一份，没到之前图表处留位）。
  Widget _deckCard(SrsDeckSummary deck) {
    final List<SrsDeckSummary> level = _siblingsOf(data.decks, deck);
    final int i = level.indexWhere(
      (SrsDeckSummary d) => d.deck.id == deck.deck.id,
    );
    return FutureBuilder<SrsHomeDeckDetail>(
      future: stats?.detailFor(
        deck.deck.id,
        srsDeckSubtreeIds(data.decks, deck.deck.id),
      ),
      builder: (BuildContext context, AsyncSnapshot<SrsHomeDeckDetail> s) =>
          _AppleSrsDeckCard(
            key: ValueKey<String>('srs-home-detail-${deck.deck.id}'),
            deck: deck,
            detail: s.data,
            today: stats?.today,
            isDefault: deck.deck.id == data.store.defaultDeckId,
            canMoveUp: i > 0,
            canMoveDown: i >= 0 && i < level.length - 1,
            onReview: onReview,
            onAction: onAction,
          ),
    );
  }

  Widget? _decksHeader() => data.decks.isEmpty
      ? null
      : _AppleSrsSectionHeader(
          key: const ValueKey<String>('srs-home-decks-header'),
          title: t.srs_home_decks_header,
          trailing: t.srs_home_deck_cards(n: data.totalCards),
        );

  List<Widget> _pairedSection() {
    final _SrsPairedHosts? p = paired;
    return <Widget>[
      if (p != null)
        _AppleSrsPairedSection(
          key: const ValueKey<String>('srs-home-paired'),
          paired: p,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final Map<String, SrsDeckSummary> byId = <String, SrsDeckSummary>{
      for (final SrsDeckSummary d in data.decks) d.deck.id: d,
    };
    final double gutter = (m.desktop ? 20 : 16) * m.scale;
    final double top = 8 * m.scale + MediaQuery.paddingOf(context).top;
    final double gap = _appleSrsBlockGap(context);
    final SrsHomeStats? s = stats;
    final Widget? decksHeader = _decksHeader();

    if (wide) {
      final SrsDeckSummary? selected = _selection(byId);
      final List<Widget> cards = <Widget>[
        if (data.totalCards > 0)
          _AppleSrsTodayCard(
            key: const ValueKey<String>('srs-home-today'),
            data: data,
            stats: s,
            showStart: false,
            onReview: onReview,
          ),
        if (selected != null)
          AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            // passthrough：按行拉齐的高度传到卡本身，新旧两层都撑满。
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              fit: StackFit.passthrough,
              alignment: AlignmentDirectional.topCenter,
              children: <Widget>[...previous, ?current],
            ),
            child: KeyedSubtree(
              key: ValueKey<String>('srs-home-detail-pane-${selected.deck.id}'),
              child: _deckCard(selected),
            ),
          ),
        if (s != null)
          _AppleSrsStreakCard(
            key: const ValueKey<String>('srs-home-heatmap'),
            stats: s,
            weeks: _kAppleSrsHeatmapWeeksWide,
          ),
      ];
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double content = math.min(
            constraints.maxWidth - gutter * 2,
            _kSrsHomeContentMaxWidth,
          );
          final double side = math.max(0, (constraints.maxWidth - content) / 2);
          return _tree(
            rootId: null,
            selectedId: selected?.deck.id,
            header: <Widget>[
              ...banners,
              if (cards.isNotEmpty)
                // 三张摘要卡按行拉齐（与首页仪表盘同一个纯布局件；放不下三列排 2 + 1）。
                FushiEntranceScope(
                  child: HomePosterRows(
                    key: const ValueKey<String>('srs-home-band'),
                    gap: gap,
                    minColumnWidth: _kAppleSrsCardMinWidth,
                    children: <Widget>[
                      for (int i = 0; i < cards.length; i++)
                        FushiStaggeredEntrance(index: i, child: cards[i]),
                    ],
                  ),
                ),
              ?decksHeader,
            ],
            footer: <Widget>[..._pairedSection()],
            padding: EdgeInsets.fromLTRB(
              side,
              top,
              side,
              srsHomeListBottomPadding(context),
            ),
            onOpen: (SrsDeckSummary d) => onSelect(d.deck.id),
          );
        },
      );
    }

    final EdgeInsets padding = EdgeInsets.fromLTRB(
      gutter,
      top,
      gutter,
      srsHomeListBottomPadding(context),
    );
    final SrsDeckSummary? focused = focus;
    final Widget body;
    if (focused == null) {
      body = _tree(
        rootId: null,
        header: <Widget>[
          ...banners,
          if (data.totalCards > 0)
            _AppleSrsTodayCard(
              key: const ValueKey<String>('srs-home-today'),
              data: data,
              stats: s,
              showStart: true,
              onReview: onReview,
            ),
          ?decksHeader,
        ],
        footer: <Widget>[
          ..._pairedSection(),
          if (s != null) ...<Widget>[
            _AppleSrsStreakCard(
              key: const ValueKey<String>('srs-home-heatmap'),
              stats: s,
              weeks: _kAppleSrsHeatmapWeeksNarrow,
            ),
            ..._appleSrsHomeDueCards(s, data),
          ],
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
          _deckCard(focused),
          if (hasChildren)
            _AppleSrsSectionHeader(
              key: const ValueKey<String>('srs-home-subdecks-header'),
              title: t.srs_home_subdecks_header,
            ),
        ],
        footer: const <Widget>[],
        padding: padding,
        onOpen: (SrsDeckSummary d) => onFocus(d.deck.id),
      );
    }
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
