part of 'srs_deck_list_page.dart';

// 复习首页「已配对设备」分区（用户 2026-11-07 拍板方案 A；取代同步菜单里「复习已配对设备的卡组」那两层页面）：
//
// - 本机牌组树下面，每台声明了远程复习能力的已配对主机一组：组头是设备名、连接状态与三色计数，点组头展开 /
//   收起；展开后是这台主机的牌组树，用的就是本机牌组树的行组件 [_DeckRow]（缩进、折叠箭头、徽章、播放按钮），
//   不再是按深度缩进的平铺列表；
// - 卡组不下载：组里的行跑在 [SrsRemoteCollectionScope] 里，点行 / 播放 / 自定义学习 / 浏览 / 牌组设置压出的
//   都是本机同一套页面，读写主机的库（见 srs_remote_review_page.dart）；
// - 主机的数字只在它自己那组里显示，不并进本机的「今日计划」（用户同日拍板不要「另有 N 张在别的设备」那行）；
// - 收起 / 展开子牌组只是本机界面状态：远程库不转发 setDeckCollapsed（改主机的牌组结构留给主机自己）。

/// 一台已配对主机在首页上的状态。
class _PairedHost {
  _PairedHost(this.target);

  final InterconnectHostTarget target;

  /// 连上后的会话；连不上 / 出错后为 null（下次加载重新握手）。
  SrsRemoteSession? session;

  /// 主机上的牌组（先序）；还没读到为 null。
  List<SrsDeckSummary>? decks;

  /// 最近一次加载失败的提示。
  String? error;
  bool loading = false;
  bool expanded = false;

  /// 本机点过的收起 / 展开（不写回主机）；没点过的按主机牌组自身的 collapsed。
  final Map<String, bool> collapsed = <String, bool>{};

  bool isCollapsed(SrsDeckSummary d) =>
      collapsed[d.deck.id] ?? d.deck.collapsed;
}

/// 已配对主机列表与各自的连接 / 牌组。由牌组页持有，不放进懒建的列表项：分区滚出屏幕再滚回来不重连。
class _SrsPairedHosts extends ChangeNotifier {
  _SrsPairedHosts({required this.connector});

  final SrsRemoteHostConnector connector;

  List<_PairedHost> hosts = const <_PairedHost>[];
  bool _disposed = false;
  int _probeSeq = 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 重新找一遍主机（已有的保留连接与展开状态），再并行读各自的牌组。
  Future<void> probe() async {
    final int seq = ++_probeSeq;
    final List<InterconnectHostTarget> targets = await connector.probe();
    if (_disposed || seq != _probeSeq) return;
    final Map<String, _PairedHost> old = <String, _PairedHost>{
      for (final _PairedHost h in hosts) h.target.hostId: h,
    };
    hosts = <_PairedHost>[
      for (final InterconnectHostTarget t in targets)
        old.remove(t.hostId) ?? _PairedHost(t),
    ];
    for (final _PairedHost gone in old.values) {
      gone.session?.client.cancelPending();
    }
    _notify();
    await Future.wait(<Future<void>>[
      for (final _PairedHost h in hosts) load(h),
    ]);
  }

  /// 连上 [h]（还没连时）并重读它的牌组。连接层 / 主机报的错显示在组头，其余异常照常抛给调用方留痕。
  Future<void> load(_PairedHost h) async {
    if (h.loading || _disposed) return;
    h
      ..loading = true
      ..error = null;
    _notify();
    try {
      final SrsRemoteSession session = h.session ??= await connector.open(
        h.target,
      );
      final List<SrsDeckSummary> decks = await session.store.deckSummaries();
      if (_disposed) return;
      h.decks = decks;
    } on InterconnectHostError catch (e) {
      h
        ..error = srsRemoteReviewErrorText(e)
        ..session = null
        ..decks = null;
    } finally {
      h.loading = false;
      _notify();
    }
  }

  void toggleExpanded(_PairedHost h) {
    h.expanded = !h.expanded;
    _notify();
  }

  void setCollapsed(_PairedHost h, SrsDeckSummary deck, bool collapsed) {
    if (h.isCollapsed(deck) == collapsed) return;
    h.collapsed[deck.deck.id] = collapsed;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final _PairedHost h in hosts) {
      h.session?.client.cancelPending();
    }
    super.dispose();
  }
}

/// 首页的「已配对设备」分区：小标题 + 每台主机一组。没有可用主机时页面不放它（见 [_SrsHomeView]）。
class _SrsPairedDevicesSection extends StatelessWidget {
  const _SrsPairedDevicesSection({super.key, required this.paired});

  final _SrsPairedHosts paired;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ListenableBuilder(
      listenable: paired,
      builder: (BuildContext context, Widget? _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap * 1.5,
        children: <Widget>[
          _SrsHomeSectionHeader(title: t.srs_home_paired_header),
          for (final _PairedHost h in paired.hosts)
            _SrsPairedDeviceGroup(
              key: ValueKey<String>('srs-paired-${h.target.hostId}'),
              host: h,
              paired: paired,
            ),
        ],
      ),
    );
  }
}

/// 一台主机：组头 + （展开时）它的牌组树。连上后整组跑在 [SrsRemoteCollectionScope] 里，从组里压出的页面
/// 经 [srsPushPage] 带上同一个作用域，读写主机的库。
class _SrsPairedDeviceGroup extends StatelessWidget {
  const _SrsPairedDeviceGroup({
    super.key,
    required this.host,
    required this.paired,
  });

  final _PairedHost host;
  final _SrsPairedHosts paired;

  @override
  Widget build(BuildContext context) {
    final SrsRemoteSession? session = host.session;
    if (session == null) return _group(context, null);
    // 按会话换作用域：重连后是新的远程库，子作用域的 overrideWith 不随重建更新。
    return SrsRemoteCollectionScope(
      key: ObjectKey(session),
      store: session.store,
      media: session.media,
      child: Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? _) =>
            _group(context, ref),
      ),
    );
  }

  /// [ref] 是主机作用域里的 ref；还没连上时为 null（只有组头）。
  Widget _group(BuildContext context, WidgetRef? ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SrsDeckSummary> decks = host.decks ?? const <SrsDeckSummary>[];
    final bool open = host.expanded && ref != null && host.decks != null;
    final Map<String, SrsDeckSummary> byId = <String, SrsDeckSummary>{
      for (final SrsDeckSummary d in decks) d.deck.id: d,
    };
    final List<bool> visible = <bool>[
      for (final SrsDeckSummary d in decks)
        open &&
            !_srsDeckHiddenByCollapse(
              d,
              byId,
              rootId: null,
              collapsed: host.isCollapsed,
            ),
    ];
    final int visibleRows = visible.where((bool v) => v).length;
    final bool empty = open && decks.isEmpty;
    // 组头是分段卡的第 0 段，可见的牌组行（或「没有牌组」）接在后面。
    final int count = 1 + visibleRows + (empty ? 1 : 0);
    final Set<String> parents = <String>{
      for (final SrsDeckSummary d in decks)
        if (d.parentId != null) d.parentId!,
    };
    final Map<String, int> rootIndex = _srsDeckRootIndex(decks);
    final String hostId = host.target.hostId;

    final List<Widget> rows = <Widget>[];
    if (ref != null) {
      final _PairedDeckActions actions = _PairedDeckActions(
        context: context,
        ref: ref,
        host: host,
        paired: paired,
      );
      int shown = 0;
      for (int i = 0; i < decks.length; i++) {
        final SrsDeckSummary d = decks[i];
        final int index = 1 + (visible[i] ? shown++ : shown);
        final int? rootAt = rootIndex[d.deck.id];
        rows.add(
          FushiTreeReveal(
            key: ValueKey<String>('srs-paired-deck-$hostId-${d.deck.id}'),
            visible: visible[i],
            child: _DeckRow(
              deck: d,
              depth: d.depth,
              badge: rootAt == null ? null : _srsDeckBadgeShape(rootAt),
              doneToday: null,
              selected: false,
              deleting: null,
              index: index,
              count: count,
              isDefault: false,
              hasTree: parents.isNotEmpty,
              hasChildren: parents.contains(d.deck.id),
              collapsed: host.isCollapsed(d),
              onSetCollapsed: (bool c) => paired.setCollapsed(host, d, c),
              onOpen: actions.review,
              onReview: actions.review,
              onAction: actions.run,
              canMoveUp: false,
              canMoveDown: false,
              remote: true,
            ),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SrsPairedDeviceHeader(
          host: host,
          paired: paired,
          count: count,
          ref: ref,
        ),
        ...rows,
        FushiTreeReveal(
          key: ValueKey<String>('srs-paired-empty-$hostId'),
          visible: empty,
          child: FushiGroupedListItem(
            index: 1,
            count: count,
            child: FushiListItem(
              density: srsListDensityOf(context),
              title: Text(t.srs_remote_review_decks_empty),
            ),
          ),
        ),
        FushiTreeReveal(
          key: ValueKey<String>('srs-paired-hint-$hostId'),
          visible: open && decks.isNotEmpty,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.rowHorizontal,
              tokens.spacing.gap,
              tokens.spacing.rowHorizontal,
              0,
            ),
            child: Text(
              t.srs_remote_review_hint,
              style: context.fushiType.bodySmall.copyWith(
                color: isGlassDesign(context)
                    ? appleColorsOf(context).secondaryLabel
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _PairedHostAction { addNote, browse, refresh }

/// 组头：设备图标、名字、状态（连接中 / 出错 / N 张）、三色计数、菜单与展开箭头。点组头展开 / 收起；出错时
/// 点组头重试。
class _SrsPairedDeviceHeader extends StatelessWidget {
  const _SrsPairedDeviceHeader({
    required this.host,
    required this.paired,
    required this.count,
    required this.ref,
  });

  final _PairedHost host;
  final _SrsPairedHosts paired;
  final int count;

  /// 主机作用域里的 ref；还没连上时为 null（没有菜单）。
  final WidgetRef? ref;

  void _retry() => srsRunLogged('SrsPairedHosts.load', () => paired.load(host));

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SrsDeckSummary>? decks = host.decks;
    final SrsRemoteSession? session = host.session;
    final SrsDeckListData? data = decks == null || session == null
        ? null
        : SrsDeckListData(store: session.store, decks: decks);
    final String? error = host.error;
    final String hostId = host.target.hostId;
    final String status = host.loading
        ? t.srs_home_paired_connecting
        : error ?? t.srs_home_deck_cards(n: data?.totalCards ?? 0);
    final WidgetRef? scoped = ref;
    final bool canExpand = data != null;
    return FushiPressScale(
      child: FushiGroupedListItem(
        key: ValueKey<String>('srs-paired-header-$hostId'),
        index: 0,
        count: count,
        onTap: error != null
            ? _retry
            : canExpand
            ? () => paired.toggleExpanded(host)
            : null,
        child: Semantics(
          expanded: canExpand ? host.expanded : null,
          child: FushiListItem(
            density: srsListDensityOf(context),
            leading: const FushiListLeadingIcon(FushiIcons.devices),
            title: Text(host.target.displayName),
            subtitle: Text(status),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: tokens.spacing.gap / 2,
              children: <Widget>[
                if (data != null && !host.loading)
                  SrsCountTriple(
                    dense: true,
                    tight: true,
                    newCount: data.todayNew,
                    learnCount: data.todayLearn,
                    reviewCount: data.todayReview,
                    reviewPending: data.rwkvPending,
                  ),
                if (error != null)
                  FushiIconButton(
                    key: ValueKey<String>('srs-paired-retry-$hostId'),
                    icon: FushiIcons.refresh,
                    tooltip: t.retry,
                    onTap: _retry,
                  ),
                if (scoped != null)
                  FushiPopupMenuButton<_PairedHostAction>(
                    key: ValueKey<String>('srs-paired-menu-$hostId'),
                    tooltip: t.srs_deck_menu,
                    icon: const FushiIcon(FushiIcons.more),
                    onSelected: (_PairedHostAction a) => _PairedDeckActions(
                      context: context,
                      ref: scoped,
                      host: host,
                      paired: paired,
                    ).runHost(a),
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<_PairedHostAction>>[
                          PopupMenuItem<_PairedHostAction>(
                            value: _PairedHostAction.addNote,
                            child: Text(t.srs_note_add),
                          ),
                          PopupMenuItem<_PairedHostAction>(
                            value: _PairedHostAction.browse,
                            child: Text(t.srs_browse_title),
                          ),
                          PopupMenuItem<_PairedHostAction>(
                            value: _PairedHostAction.refresh,
                            child: Text(t.refresh),
                          ),
                        ],
                  ),
                if (canExpand)
                  FushiTreeChevron(
                    expanded: host.expanded,
                    child: const FushiIcon(FushiIcons.chevronRight),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 主机牌组上的动作：都在主机作用域里压页（[context] / [ref] 取自 [SrsRemoteCollectionScope] 之下），
/// 回来时重读这台主机的计数。
class _PairedDeckActions {
  const _PairedDeckActions({
    required this.context,
    required this.ref,
    required this.host,
    required this.paired,
  });

  final BuildContext context;
  final WidgetRef ref;
  final _PairedHost host;
  final _SrsPairedHosts paired;

  Future<void> _push(WidgetBuilder builder) async {
    await srsPushPage<void>(context, builder);
    await paired.load(host);
  }

  Future<void> _review(SrsDeckSummary deck, [SrsCustomStudy? custom]) => _push(
    (_) => SrsReviewPage(
      deckId: deck.deck.id,
      deckName: deck.fullName,
      custom: custom,
    ),
  );

  Future<void> _browse({String? query}) => _push(
    (_) => SrsBrowsePage(
      initialQuery: query,
      onChangeNoteType: showSrsChangeNoteTypeFlow,
      onMigrateToFushiCard: srsMigrateNotesToFushiCard,
    ),
  );

  void review(SrsDeckSummary deck) =>
      srsRunLogged('SrsPairedHosts.review', () => _review(deck));

  /// 牌组行菜单（远程只有这三项，见 [_deckMenuItems]）。
  void run(SrsDeckSummary deck, _DeckAction action) {
    switch (action) {
      case _DeckAction.customStudy:
        srsRunLogged(
          'SrsPairedHosts.customStudy',
          () => srsRunCustomStudy(
            context,
            ref,
            deck,
            openReview: (SrsCustomStudy? custom) => _review(deck, custom),
          ),
        );
      case _DeckAction.browse:
        srsRunLogged(
          'SrsPairedHosts.browseDeck',
          () => _browse(query: srsDeckQuery(deck.fullName)),
        );
      case _DeckAction.settings:
        srsRunLogged(
          'SrsPairedHosts.settings',
          () => _push((_) => SrsDeckSettingsPage(deckId: deck.deck.id)),
        );
      case _DeckAction.addChild ||
          _DeckAction.rename ||
          _DeckAction.move ||
          _DeckAction.moveUp ||
          _DeckAction.moveDown ||
          _DeckAction.fillWordAudio ||
          _DeckAction.delete:
        // 远程菜单不出这些项（改主机的牌组结构 / 批量补词音留给主机自己）。
        break;
    }
  }

  void runHost(_PairedHostAction action) {
    switch (action) {
      case _PairedHostAction.addNote:
        srsRunLogged(
          'SrsPairedHosts.addNote',
          () => _push((_) => const SrsNoteEditorPage()),
        );
      case _PairedHostAction.browse:
        srsRunLogged('SrsPairedHosts.browse', _browse);
      case _PairedHostAction.refresh:
        srsRunLogged('SrsPairedHosts.load', () => paired.load(host));
    }
  }
}
