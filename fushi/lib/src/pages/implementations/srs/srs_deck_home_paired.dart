part of 'srs_deck_list_page.dart';

// 复习首页「已配对设备」分区（用户 2026-11-07 拍板方案 A；取代同步菜单里「复习已配对设备的卡组」那两层页面）：
//
// - 本机牌组树下面，每台声明了远程复习能力的已配对主机一组：组头是设备名、连接状态与三色计数，点组头展开 /
//   收起；展开后是这台主机的牌组树，用的就是本机牌组树的行组件 [_DeckRow]（缩进、折叠箭头、徽章、播放按钮），
//   不再是按深度缩进的平铺列表；
// - 卡组不下载：组里的行跑在 [SrsRemoteCollectionScope] 里，点行 / 播放 / 自定义学习 / 浏览 / 牌组设置压出的
//   都是本机同一套页面，读写主机的库（见 srs_remote_review_page.dart）；
// - 主机的数字只在它自己那组里显示，不并进本机的「今日计划」（用户同日拍板不要「另有 N 张在别的设备」那行）；
// - 收起 / 展开子牌组只是本机界面状态：远程库不转发 setDeckCollapsed（改主机的牌组结构留给主机自己）；
// - 主机列表、会话与牌组摘要由 [_srsPairedHostsProvider] 在 app 级持有：再进复习页先画上次的结果（组头标明
//   更新时间 / 刷新中），后台用已有会话重读牌组，不重新探测、不重新握手；加载失败只记错误，不清掉上次的牌组。
//   缓存的只是界面要画的牌组摘要（主机的库仍在主机上，翻页 / 作答都实时打到主机）。
// - 缓存的是「网络探测」的结果，不是「本机配置门控」：每次进页面都先按本机互联配置（总开关、服务端模式、
//   启用且有凭据的已配对条目，只读本地库）对账——配置里没有了的主机移除并作废会话，凭据变了的当新主机，
//   新出现的只对它探能力 + 握手；配置没变的主机才复用会话。请求层只按 hostId + 凭据挑地址，不看总开关与
//   服务端模式，所以这道门只能在这里。

/// 一台已配对主机在首页上的状态。
class _PairedHost {
  _PairedHost(this.target);

  /// 最近一次对账时本机配置里的这台主机（显示名可能随配置更新；hostId 与凭据不变，变了就是另一个 [_PairedHost]）。
  InterconnectHostTarget target;

  /// [next] 是否还是这台主机的同一份配对：同 hostId、同凭据（请求层按这两项挑地址，会话据此仍然有效）。
  bool sameAs(InterconnectHostTarget next) =>
      next.hostId == target.hostId && next.peer.token == target.peer.token;

  /// 连上后的会话（本次运行内复用，不每次进页面都握手）；出错后为 null（下次加载重新握手）。
  SrsRemoteSession? session;

  /// 上次读到的主机牌组（先序），界面用的摘要缓存；还没读到过为 null。加载失败不清它。
  List<SrsDeckSummary>? decks;

  /// [decks] 读到的时刻。
  DateTime? updatedAt;

  /// 最近一次加载失败的提示（下次加载开始时清掉）。
  String? error;
  bool loading = false;
  bool expanded = false;

  /// 本机点过的收起 / 展开（不写回主机）；没点过的按主机牌组自身的 collapsed。
  final Map<String, bool> collapsed = <String, bool>{};

  bool isCollapsed(SrsDeckSummary d) =>
      collapsed[d.deck.id] ?? d.deck.collapsed;
}

/// 首页「已配对设备」的 app 级状态：跟着根容器活，复习页关掉再开不重新探测 / 握手。
final Provider<_SrsPairedHosts> _srsPairedHostsProvider =
    Provider<_SrsPairedHosts>((Ref ref) {
      final _SrsPairedHosts hosts = _SrsPairedHosts(
        connector: ref.read(srsRemoteHostConnectorProvider),
      );
      ref.onDispose(hosts.dispose);
      return hosts;
    });

/// 已配对主机列表与各自的会话 / 牌组摘要缓存。
class _SrsPairedHosts extends ChangeNotifier {
  _SrsPairedHosts({required this.connector});

  final SrsRemoteHostConnector connector;

  List<_PairedHost> hosts = const <_PairedHost>[];
  bool _disposed = false;

  /// 正在跑的一轮对账（同一时刻只跑一轮：页面重进 / 点刷新撞上时等同一轮）。
  Future<void>? _syncing;

  /// 跑完之后还要不要补一轮全量重探（对账进行中点了「立即同步」）。
  bool _reprobeQueued = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 进复习首页时调：先按本机配置对账（关了互联 / 切成服务端就清空，取消配对或停用的移除），配置没变的主机
  /// 复用会话、只在后台重读牌组（界面先画缓存）；配置里新出现的（或上次没应答的）主机才探能力并握手。
  Future<void> refresh() => _run(reprobeKnown: false);

  /// 全量重探（「立即同步」）：对账后连已在列表里的主机也重新探能力（已有的保留会话、牌组缓存与展开状态），
  /// 再并行读各自的牌组。
  Future<void> probe() {
    if (_syncing != null) {
      _reprobeQueued = true;
      return _syncing!;
    }
    return _run(reprobeKnown: true);
  }

  Future<void> _run({required bool reprobeKnown}) {
    final Future<void>? running = _syncing;
    if (running != null) return running;
    final Future<void> run = _sync(reprobeKnown: reprobeKnown).whenComplete(() {
      _syncing = null;
      _notify();
      if (_reprobeQueued && !_disposed) {
        _reprobeQueued = false;
        srsRunLogged('SrsPairedHosts.probe', probe);
      }
    });
    _syncing = run;
    return run;
  }

  Future<void> _sync({required bool reprobeKnown}) async {
    final List<InterconnectHostTarget> configured = await connector
        .configured();
    if (_disposed) return;

    // 第一步（纯本地）：配置里没有了 / 凭据变了的主机立刻移除并作废会话，配置门控关闭时清空。
    final Map<String, _PairedHost> old = <String, _PairedHost>{
      for (final _PairedHost h in hosts) h.target.hostId: h,
    };
    final Map<String, _PairedHost> kept = <String, _PairedHost>{};
    for (final InterconnectHostTarget c in configured) {
      final _PairedHost? prev = old[c.hostId];
      if (prev != null && prev.sameAs(c)) {
        prev.target = c;
        kept[c.hostId] = old.remove(c.hostId)!;
      }
    }
    for (final _PairedHost gone in old.values) {
      gone.session?.client.cancelPending();
    }
    hosts = <_PairedHost>[
      for (final InterconnectHostTarget c in configured) ?kept[c.hostId],
    ];
    _notify();

    // 第二步（走网络）：只探需要探的——新出现的 / 凭据变了的 / 上次没应答的；全量重探时连已有的一起。
    // 已有的主机同时用已有会话重读牌组，不等探测。
    final List<InterconnectHostTarget> candidates = <InterconnectHostTarget>[
      for (final InterconnectHostTarget c in configured)
        if (reprobeKnown || !kept.containsKey(c.hostId)) c,
    ];
    final Future<List<InterconnectHostTarget>> probing = connector.supporting(
      candidates,
    );
    final List<Future<void>> loads = <Future<void>>[
      if (!reprobeKnown)
        for (final _PairedHost h in kept.values) load(h),
    ];
    final Set<String> supported = <String>{
      for (final InterconnectHostTarget t in await probing) t.hostId,
    };
    if (_disposed) {
      await Future.wait(loads);
      return;
    }

    // 合并：探测期间本轮外没人改 [hosts]（同一时刻只跑一轮），按配置顺序排。
    final List<_PairedHost> added = <_PairedHost>[];
    final List<_PairedHost> next = <_PairedHost>[];
    for (final InterconnectHostTarget c in configured) {
      final _PairedHost? prev = kept[c.hostId];
      if (prev != null) {
        if (!reprobeKnown || supported.contains(c.hostId)) {
          next.add(prev);
        } else {
          prev.session?.client.cancelPending();
        }
      } else if (supported.contains(c.hostId)) {
        final _PairedHost h = _PairedHost(c);
        added.add(h);
        next.add(h);
      }
    }
    hosts = next;
    _notify();
    await Future.wait(<Future<void>>[
      ...loads,
      for (final _PairedHost h in reprobeKnown ? next : added) load(h),
    ]);
  }

  /// 重读 [h] 的牌组（还没连上时先握手）。任何失败都落成组头上可重试的错误态：会话作废（下次重新握手），
  /// 上次的牌组缓存保留。连接层 / 主机报的错按机读码出文案；其余异常（主机回包不合契约导致的类型错误等）
  /// 记进错误日志，组头出通用的加载失败。
  Future<void> load(_PairedHost h) async {
    if (h.loading || _disposed) return;
    h
      ..loading = true
      ..error = null;
    _notify();
    try {
      final List<SrsDeckSummary> decks = await _readDecks(h);
      h
        ..decks = decks
        ..updatedAt = DateTime.now();
    } on InterconnectHostError catch (e) {
      _fail(h, srsRemoteReviewErrorText(e));
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsPairedHosts.load', e, stack);
      _fail(h, t.srs_home_paired_error_load);
    } finally {
      h.loading = false;
      _notify();
    }
  }

  void _fail(_PairedHost h, String error) {
    h.session?.client.cancelPending();
    h
      ..error = error
      ..session = null;
  }

  /// 用已有会话读牌组；没有会话、或主机回「已换配置」（这个会话绑定的 profile 作废）时握手开新会话再读。
  Future<List<SrsDeckSummary>> _readDecks(_PairedHost h) async {
    final SrsRemoteSession? reused = h.session;
    if (reused != null) {
      try {
        return await reused.store.deckSummaries();
      } on InterconnectHostError catch (e) {
        if (e.message != SrsRemoteStoreError.profileChanged) rethrow;
        reused.client.cancelPending();
        h.session = null;
      }
    }
    final SrsRemoteSession session = await connector.open(h.target);
    h.session = session;
    return session.store.deckSummaries();
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

/// 一台主机牌组摘要的合计：顶层牌组行之和（顶层已含子牌组，与本机首页同一口径，见 [SrsDeckListData]）。
class _PairedDeckTotals {
  const _PairedDeckTotals({
    required this.cards,
    required this.newCount,
    required this.learnCount,
    required this.reviewCount,
    required this.rwkvPending,
  });

  factory _PairedDeckTotals.of(List<SrsDeckSummary> decks) {
    int cards = 0, newCount = 0, learnCount = 0, reviewCount = 0;
    bool rwkvPending = false;
    for (final SrsDeckSummary d in decks) {
      if (d.depth != 0) continue;
      cards += d.totalCards;
      newCount += d.newCount;
      learnCount += d.learnCount;
      reviewCount += d.reviewCount;
      rwkvPending = rwkvPending || d.rwkvPending;
    }
    return _PairedDeckTotals(
      cards: cards,
      newCount: newCount,
      learnCount: learnCount,
      reviewCount: reviewCount,
      rwkvPending: rwkvPending,
    );
  }

  final int cards;
  final int newCount;
  final int learnCount;
  final int reviewCount;
  final bool rwkvPending;
}

/// 组头副标题里「更新于 …」的时刻：今天只写钟点，更早的带上日期。
String _srsPairedUpdatedText(BuildContext context, DateTime at) {
  final String clock = TimeOfDay.fromDateTime(at).format(context);
  final DateTime now = DateTime.now();
  final bool today =
      at.year == now.year && at.month == now.month && at.day == now.day;
  final String when = today
      ? clock
      : '${MaterialLocalizations.of(context).formatShortMonthDay(at)} $clock';
  return t.srs_home_paired_updated(time: when);
}

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

  /// 副标题：没有缓存时「连接中 / 错误」；有缓存时「N 张 · 更新于 … · 刷新中 / 错误」。
  String _status(
    BuildContext context,
    _PairedDeckTotals? totals,
    String? error,
  ) {
    final DateTime? at = host.updatedAt;
    if (totals == null || at == null) {
      return host.loading ? t.srs_home_paired_connecting : error ?? '';
    }
    return <String>[
      t.srs_home_deck_cards(n: totals.cards),
      _srsPairedUpdatedText(context, at),
      if (host.loading) t.srs_home_paired_refreshing,
      ?error,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SrsDeckSummary>? decks = host.decks;
    final _PairedDeckTotals? totals = decks == null
        ? null
        : _PairedDeckTotals.of(decks);
    final String? error = host.error;
    final String hostId = host.target.hostId;
    final String status = _status(context, totals, error);
    final WidgetRef? scoped = ref;
    // 展开要有会话（牌组行压出的页面读写主机的库）；只有缓存、会话作废时组头仍画上次的数字，点了重试。
    final bool canExpand = totals != null && host.session != null;
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
                if (totals != null)
                  SrsCountTriple(
                    dense: true,
                    tight: true,
                    newCount: totals.newCount,
                    learnCount: totals.learnCount,
                    reviewCount: totals.reviewCount,
                    reviewPending: totals.rwkvPending,
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
