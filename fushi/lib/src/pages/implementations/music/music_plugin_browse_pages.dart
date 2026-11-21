part of 'music_plugin_pages.dart';

// 插件原生浏览（能力 `browse`，docs/specs/2026-10-28-music-plugins.md §4 / §5）：
// - 可点标签（[MusicPluginTagChips]）：作品行显示前几个，专辑详情显示全部；点了进带这个条件的列表；
// - 带条件的作品列表（[MusicPluginBrowseListPage]）：顶部是当前条件（可移除 / 追加）、开关、
//   单选筛选与排序，按插件的 hasMore 续载，下一批失败保留已有结果并给重试；列表页留在路由栈里，
//   从作品详情返回时条件、排序与滚动位置原样都在；
// - 分类目录（[MusicPluginCatalogPage]）：标签 / 声优 / 社团……用户打开时才分页取；
// - 音源推荐页顶部的浏览入口（[MusicPluginBrowseBar]）：全部作品 + 各分类目录。

/// 筛选项定义缓存：按插件 id + 版本记（插件更新后换键重取）。只缓存取到的值、不缓存在途
/// Future（取失败下次重取；Future 绑定创建它的 zone，跨 zone 复用会卡住等待方）。
final Map<String, MusicPluginBrowseSchema> _browseSchemaCache =
    <String, MusicPluginBrowseSchema>{};

Future<MusicPluginBrowseSchema> _browseSchemaOf(
  AppModel app,
  MusicPluginManifest manifest,
) async {
  final String key = '${manifest.id}@${manifest.version}';
  final MusicPluginBrowseSchema? cached = _browseSchemaCache[key];
  if (cached != null) return cached;
  final MusicPluginBrowseSchema schema = await app.musicPluginManager
      .source(manifest.id)
      .browseSchema();
  return _browseSchemaCache[key] = schema;
}

/// 打开带 [query] 条件的作品列表。[title] 缺省按条件生成。
Future<void> openMusicPluginBrowseList(
  BuildContext context, {
  required MusicPluginManifest manifest,
  required MusicPluginBrowseQuery query,
  String? title,
}) => _push(
  context,
  MusicPluginBrowseListPage(
    manifest: manifest,
    initialQuery: query,
    title: title,
  ),
);

/// 点一个标签 / 声优 / 社团：进只带这一个条件的作品列表。
Future<void> openMusicPluginTag(
  BuildContext context,
  MusicPluginManifest manifest,
  MusicPluginTag tag,
) => openMusicPluginBrowseList(
  context,
  manifest: manifest,
  query: MusicPluginBrowseQuery(filters: <MusicPluginTag>[tag]),
);

/// 分页列表底部：加载中转圈，下一批失败时一行「重试」（已有结果保留）。
Widget? _browseFooter(
  BuildContext context, {
  required bool loading,
  required bool hasMore,
  required Object? error,
  required VoidCallback onRetry,
  required String keyPrefix,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  if (error != null && !loading) {
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.gap),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Flexible(
            child: Text(
              '${t.music_plugin_browse_load_more_failed}：'
              '${musicPluginErrorText(error)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.bodySmall,
            ),
          ),
          FushiPressScale(
            child: FushiOutlinedButton.icon(
              key: ValueKey<String>('$keyPrefix-retry'),
              onPressed: onRetry,
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(t.retry),
            ),
          ),
        ],
      ),
    );
  }
  if (loading || hasMore) {
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.gap),
      child: const FushiLinearProgressIndicator(),
    );
  }
  return null;
}

/// 滚到离底部不远、或首屏内容不够一屏时取下一批（下一批失败后不自动重试，等用户点重试）。
bool _nearEnd(Notification n) {
  final ScrollMetrics? m = switch (n) {
    ScrollNotification(:final ScrollMetrics metrics) => metrics,
    ScrollMetricsNotification(:final ScrollMetrics metrics) => metrics,
    _ => null,
  };
  return m != null && m.axis == Axis.vertical && m.extentAfter < 600;
}

/// 一组可点标签。插件声明了 `browse` 时每个标签可点（进带这个条件的列表），否则只是文字。
/// [maxCollapsed] 非空时先只显示这么多个；[expandable] 时末尾给「全部 N 个标签」/「收起」。
class MusicPluginTagChips extends StatefulWidget {
  const MusicPluginTagChips({
    super.key,
    required this.manifest,
    required this.tags,
    this.maxCollapsed,
    this.expandable = true,
  });

  final MusicPluginManifest manifest;
  final List<MusicPluginTag> tags;
  final int? maxCollapsed;
  final bool expandable;

  @override
  State<MusicPluginTagChips> createState() => _MusicPluginTagChipsState();
}

class _MusicPluginTagChipsState extends State<MusicPluginTagChips> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<MusicPluginTag> tags = widget.tags;
    final int? max = widget.maxCollapsed;
    final bool collapsible = max != null && tags.length > max;
    final List<MusicPluginTag> shown = collapsible && !_expanded
        ? tags.take(max).toList()
        : tags;
    final bool linkable = widget.manifest.can(MusicPluginCapability.browse);
    return FushiAnimatedSize(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      alignment: AlignmentDirectional.topStart,
      child: Wrap(
        spacing: tokens.spacing.gap / 2,
        runSpacing: tokens.spacing.gap / 2,
        children: <Widget>[
          for (final MusicPluginTag tag in shown)
            linkable
                ? FushiPressScale(
                    child: FushiInputChip(
                      key: ValueKey<String>(
                        'music-plugin-tag-${tag.facet}-${tag.id}',
                      ),
                      dense: true,
                      label: Text(tag.name),
                      onPressed: () => unawaited(
                        openMusicPluginTag(context, widget.manifest, tag),
                      ),
                    ),
                  )
                : FushiChip(
                    key: ValueKey<String>(
                      'music-plugin-tag-${tag.facet}-${tag.id}',
                    ),
                    label: Text(tag.name),
                  ),
          if (collapsible && widget.expandable)
            FushiPressScale(
              child: FushiActionChipControl(
                key: const ValueKey<String>('music-plugin-tags-toggle'),
                avatar: FushiIcon(
                  _expanded ? FushiIcons.expandLess : FushiIcons.expandMore,
                ),
                label: Text(
                  _expanded
                      ? t.music_plugin_description_less
                      : t.music_plugin_tags_show_all(count: tags.length),
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ),
        ],
      ),
    );
  }
}

/// 带条件的作品列表：条件栏（当前条件可移除 / 追加、开关、单选、排序）+ 续载列表。
class MusicPluginBrowseListPage extends ConsumerStatefulWidget {
  const MusicPluginBrowseListPage({
    super.key,
    required this.manifest,
    this.initialQuery = const MusicPluginBrowseQuery(),
    this.title,
  });

  final MusicPluginManifest manifest;
  final MusicPluginBrowseQuery initialQuery;

  /// 页名（推荐段的「查看全部」给段名）；null 按条件生成。
  final String? title;

  @override
  ConsumerState<MusicPluginBrowseListPage> createState() =>
      _MusicPluginBrowseListPageState();
}

class _MusicPluginBrowseListPageState
    extends ConsumerState<MusicPluginBrowseListPage> {
  static const int _pageSize = 30;

  late MusicPluginBrowseQuery _query = widget.initialQuery;
  MusicPluginBrowseSchema _schema = const MusicPluginBrowseSchema();
  final List<Object> _items = <Object>[];
  MusicPluginHomeKind _kind = MusicPluginHomeKind.albums;
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  Object? _error;

  /// 条件代次：改条件后，在途的旧请求结果丢弃。
  int _generation = 0;

  /// 每次改条件换一个滚动身份：新条件的结果从顶部开始（返回详情时同一条件的位置不动）。
  int _queryRevision = 0;

  MusicPluginSource get _source =>
      ref.read(appProvider).musicPluginManager.source(widget.manifest.id);

  @override
  void initState() {
    super.initState();
    unawaited(_loadSchema());
    unawaited(_loadMore());
  }

  Future<void> _loadSchema() async {
    try {
      final MusicPluginBrowseSchema s = await _browseSchemaOf(
        ref.read(appProvider),
        widget.manifest,
      );
      if (mounted) setState(() => _schema = s);
    } on Object {
      // 筛选项取不到只是少了条件控件，列表照常（列表自己的错误另行显示）。
    }
  }

  void _apply(MusicPluginBrowseQuery q) {
    _generation++;
    setState(() {
      _query = q;
      _queryRevision++;
      _items.clear();
      _page = 0;
      _hasMore = false;
      _error = null;
      _loading = false;
    });
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    final int gen = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MusicPluginBrowseResult r = await _source.browseList(
        _query,
        page: _page,
        pageSize: _pageSize,
      );
      if (!mounted || gen != _generation) return;
      setState(() {
        if (_page == 0) _kind = r.kind;
        // 续页的种类与首页不同（插件 bug）时丢掉这一批，不混排。
        if (r.kind == _kind) _items.addAll(r.items);
        _page++;
        _hasMore = r.hasMore;
      });
    } on Object catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e);
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  void _maybeLoadMore(Notification n) {
    if (_hasMore && !_loading && _error == null && _nearEnd(n)) {
      unawaited(_loadMore());
    }
  }

  Future<void> _addFilter(MusicPluginBrowseOption facet) async {
    final MusicPluginTag? tag = await Navigator.of(context)
        .push<MusicPluginTag>(
          adaptivePageRoute<MusicPluginTag>(
            context: context,
            builder: (_) => MusicPluginCatalogPage(
              manifest: widget.manifest,
              facet: facet,
              pick: true,
            ),
          ),
        );
    if (tag != null && mounted) _apply(_query.withFilter(tag));
  }

  String get _title {
    final String? given = widget.title;
    if (given != null) return given;
    if (_query.filters.isEmpty) return t.music_plugin_browse_all_works;
    return _query.filters.map((MusicPluginTag f) => f.name).join(' · ');
  }

  MusicViewKind get _viewKind => switch (_kind) {
    MusicPluginHomeKind.tracks => MusicViewKind.tracks,
    MusicPluginHomeKind.playlists => MusicViewKind.playlists,
    MusicPluginHomeKind.albums => MusicViewKind.albums,
  };

  /// 菜单触发器（单选 / 排序）：外层菜单接管点击，按钮自身 onPressed 为 null。
  Widget _menuTrigger(IconData icon, String label) => FushiOutlinedButton.icon(
    onPressed: null,
    style: kFushiMenuTriggerButtonStyle,
    icon: FushiIcon(icon, size: 18),
    label: Text(label),
  );

  Widget _conditions(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicPluginBrowseSchema schema = _schema;
    String chipLabel(MusicPluginTag f) => switch (schema.facetLabel(f.facet)) {
      final String facet => '$facet：${f.name}',
      null => f.name,
    };
    final List<Widget> chips = <Widget>[
      for (final MusicPluginTag f in _query.filters)
        FushiPressScale(
          child: FushiInputChip(
            key: ValueKey<String>(
              'music-plugin-browse-filter-${f.facet}-${f.id}',
            ),
            label: Text(chipLabel(f)),
            onDeleted: () => _apply(_query.withoutFilter(f)),
            deleteButtonTooltipMessage: t.music_plugin_browse_remove_filter(
              name: f.name,
            ),
          ),
        ),
      if (schema.facets.isNotEmpty)
        FushiOverflowMenu<String>(
          key: const ValueKey<String>('music-plugin-browse-add-filter'),
          tooltip: t.music_plugin_browse_add_filter,
          onSelected: (String id) {
            final MusicPluginBrowseOption facet = schema.facets.firstWhere(
              (MusicPluginBrowseOption f) => f.id == id,
            );
            unawaited(_addFilter(facet));
          },
          items: <PopupMenuEntry<String>>[
            for (final MusicPluginBrowseOption f in schema.facets)
              FushiPopupMenuItem<String>(value: f.id, label: f.label),
          ],
          child: _menuTrigger(FushiIcons.add, t.music_plugin_browse_add_filter),
        ),
      for (final MusicPluginBrowseOption o in schema.toggles)
        FushiPressScale(
          child: FushiFilterChip(
            key: ValueKey<String>('music-plugin-browse-toggle-${o.id}'),
            label: Text(o.label),
            selected: _query.toggles.contains(o.id),
            onSelected: (bool on) => _apply(_query.withToggle(o.id, on: on)),
          ),
        ),
      for (final MusicPluginBrowseChoice c in schema.choices)
        FushiOverflowMenu<String>(
          key: ValueKey<String>('music-plugin-browse-choice-${c.id}'),
          tooltip: c.label,
          // 「不限」用空串作值（选项 id 都是非空串）。
          onSelected: (String v) =>
              _apply(_query.withChoice(c.id, v.isEmpty ? null : v)),
          items: <PopupMenuEntry<String>>[
            FushiPopupMenuItem<String>(
              value: '',
              label: t.music_plugin_browse_any,
              selected: !_query.choices.containsKey(c.id),
            ),
            for (final MusicPluginBrowseOption v in c.values)
              FushiPopupMenuItem<String>(
                value: v.id,
                label: v.label,
                selected: _query.choices[c.id] == v.id,
              ),
          ],
          child: _menuTrigger(
            FushiIcons.filterList,
            '${c.label}：${c.values.where((MusicPluginBrowseOption v) => v.id == _query.choices[c.id]).firstOrNull?.label ?? t.music_plugin_browse_any}',
          ),
        ),
      if (schema.sorts.isNotEmpty)
        FushiOverflowMenu<String>(
          key: const ValueKey<String>('music-plugin-browse-sort'),
          tooltip: t.sort_by,
          onSelected: (String id) => _apply(_query.withSort(id)),
          items: <PopupMenuEntry<String>>[
            for (final MusicPluginBrowseOption s in schema.sorts)
              FushiPopupMenuItem<String>(
                value: s.id,
                label: s.label,
                selected: _query.sort == s.id,
              ),
          ],
          child: _menuTrigger(
            FushiIcons.sort,
            schema.sorts
                    .where((MusicPluginBrowseOption s) => s.id == _query.sort)
                    .firstOrNull
                    ?.label ??
                t.sort_by,
          ),
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: tokens.spacing.gap / 2,
      runSpacing: tokens.spacing.gap / 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: chips,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MusicViewStyleStore.instance,
    builder: (BuildContext context, Widget? _) => _buildPage(context),
  );

  Widget _buildPage(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicViewKind viewKind = _viewKind;
    // 缺省单列行：作品行带作品编号 / 字幕状态与可点标签（色块只露第一个标签），
    // 按标签发现同类是这一页的主要用途。
    final MusicViewStyle style = musicViewStyleOf(
      context,
      viewKind,
      MusicViewStyle.list,
    );
    final bool masthead = shellRedesignActive(context);
    final Widget header = _conditions(context);
    final Widget results;
    if (_error != null && _items.isEmpty) {
      results = musicBrowseErrorView(
        context,
        musicPluginErrorText(_error!),
        () => unawaited(_loadMore()),
      );
    } else if (_items.isEmpty && (_loading || _page == 0)) {
      results = const FushiLoadingView();
    } else if (_items.isEmpty) {
      results = Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.searchOff,
          message: t.music_plugin_browse_empty,
        ),
      );
    } else {
      final bool covers = _kind != MusicPluginHomeKind.tracks;
      results = NotificationListener<Notification>(
        onNotification: (Notification n) {
          _maybeLoadMore(n);
          return false;
        },
        child: MusicStyledCollection(
          scrollKey: ValueKey<String>(
            'music-plugin-browse-${widget.manifest.id}-$_queryRevision',
          ),
          style: style,
          itemCount: _items.length,
          padding: withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.section,
            ),
          ),
          gridMaterial: covers ? ShelfCoverMaterial.glossyAlbum : null,
          gridDelegate: covers ? musicAlbumGridDelegate : null,
          gridCardBuilder: covers
              ? (BuildContext context, int i) =>
                    _PluginGridCard(manifest: widget.manifest, item: _items[i])
              : null,
          rowBuilder: (BuildContext context, int i) =>
              musicPluginItemTile(context, ref, widget.manifest, _items, i),
          blockBuilder:
              (BuildContext context, int i, FushiCoverBlockSize size) =>
                  musicPluginItemBlock(
                    context,
                    ref,
                    widget.manifest,
                    _items,
                    i,
                    size,
                  ),
          footer: _browseFooter(
            context,
            loading: _loading,
            hasMore: _hasMore,
            error: _error,
            onRetry: () => unawaited(_loadMore()),
            keyPrefix: 'music-plugin-browse',
          ),
        ),
      );
    }
    return musicBrowseScaffold(
      context,
      title: _title,
      actions: <FushiToolbarItem>[
        if (musicViewStyleSwitchable(context))
          musicViewStyleToggle(viewKind, style),
      ],
      mastheadBottom: masthead ? header : null,
      body: (BuildContext context) => Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!masthead)
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.page,
                    vertical: tokens.spacing.gap,
                  ),
                  child: header,
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: fushiMotionDuration(context, FushiMotion.medium),
                  child: KeyedSubtree(
                    key: ValueKey<int>(_queryRevision),
                    child: results,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一个分类目录（标签 / 声优 / 社团……）：可按名字过滤、分页续载。[pick] 时点一项把它
/// 作为条件交回上一页（列表页的「添加条件」），否则进带这个条件的作品列表。
class MusicPluginCatalogPage extends ConsumerStatefulWidget {
  const MusicPluginCatalogPage({
    super.key,
    required this.manifest,
    required this.facet,
    this.pick = false,
  });

  final MusicPluginManifest manifest;
  final MusicPluginBrowseOption facet;
  final bool pick;

  @override
  ConsumerState<MusicPluginCatalogPage> createState() =>
      _MusicPluginCatalogPageState();
}

class _MusicPluginCatalogPageState
    extends ConsumerState<MusicPluginCatalogPage> {
  static const int _pageSize = 60;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _filter = '';
  final List<MusicPluginCatalogEntry> _items = <MusicPluginCatalogEntry>[];
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMore());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _restart(String filter) {
    _generation++;
    setState(() {
      _filter = filter;
      _items.clear();
      _page = 0;
      _hasMore = false;
      _error = null;
      _loading = false;
    });
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    final int gen = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MusicPluginPage<MusicPluginCatalogEntry> p = await ref
          .read(appProvider)
          .musicPluginManager
          .source(widget.manifest.id)
          .browseCatalog(
            widget.facet.id,
            query: _filter,
            page: _page,
            pageSize: _pageSize,
          );
      if (!mounted || gen != _generation) return;
      setState(() {
        final Set<String> have = <String>{
          for (final MusicPluginCatalogEntry e in _items) e.tag.id,
        };
        _items.addAll(
          p.items.where((MusicPluginCatalogEntry e) => have.add(e.tag.id)),
        );
        _page++;
        _hasMore = p.hasMore;
      });
    } on Object catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e);
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  void _open(MusicPluginTag tag) {
    if (widget.pick) {
      Navigator.of(context).pop(tag);
      return;
    }
    unawaited(openMusicPluginTag(context, widget.manifest, tag));
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool masthead = shellRedesignActive(context);
    final Widget search = FushiSearchField(
      key: const ValueKey<String>('music-plugin-catalog-search'),
      controller: _controller,
      focusNode: _focus,
      hintText: t.music_plugin_browse_catalog_hint,
      onChanged: (String v) {
        // 清空即回到完整目录；有字时等回车再搜（目录可能很大，不逐字请求）。
        if (v.trim().isEmpty && _filter.isNotEmpty) _restart('');
      },
      onSubmitted: (String v) {
        if (v.trim() != _filter) _restart(v.trim());
      },
    );
    final Widget body;
    if (_error != null && _items.isEmpty) {
      body = musicBrowseErrorView(
        context,
        musicPluginErrorText(_error!),
        () => unawaited(_loadMore()),
      );
    } else if (_items.isEmpty && (_loading || _page == 0)) {
      body = const FushiLoadingView();
    } else if (_items.isEmpty) {
      body = Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.searchOff,
          message: t.music_server_search_empty,
        ),
      );
    } else {
      final Widget? footer = _browseFooter(
        context,
        loading: _loading,
        hasMore: _hasMore,
        error: _error,
        onRetry: () => unawaited(_loadMore()),
        keyPrefix: 'music-plugin-catalog',
      );
      body = NotificationListener<Notification>(
        onNotification: (Notification n) {
          if (_hasMore && !_loading && _error == null && _nearEnd(n)) {
            unawaited(_loadMore());
          }
          return false;
        },
        child: FushiEntranceScope(
          child: ListView.builder(
            key: ValueKey<String>(
              'music-plugin-catalog-${widget.facet.id}-$_filter',
            ),
            padding: withBottomSafeInset(
              context,
              EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.gap,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
            ),
            itemCount: _items.length + (footer == null ? 0 : 1),
            itemBuilder: fushiStaggeredItemBuilder((
              BuildContext context,
              int i,
            ) {
              if (i >= _items.length) return footer!;
              final MusicPluginCatalogEntry e = _items[i];
              return FushiPressScale(
                child: FushiGroupedListItem(
                  key: ValueKey<String>(
                    'music-plugin-catalog-entry-${e.tag.id}',
                  ),
                  index: i,
                  count: _items.length,
                  onTap: () => _open(e.tag),
                  child: FushiListItem(
                    leading: const FushiIcon(FushiIcons.tag),
                    title: Text(
                      e.tag.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: e.count == null
                        ? null
                        : Text(
                            t.music_plugin_browse_catalog_count(
                              count: e.count!,
                            ),
                          ),
                    trailing: FushiIcon(
                      widget.pick ? FushiIcons.add : FushiIcons.chevronRight,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      );
    }
    return musicBrowseScaffold(
      context,
      title: widget.facet.label,
      mastheadBottom: masthead ? search : null,
      body: (BuildContext context) => Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!masthead)
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.page,
                    vertical: tokens.spacing.gap,
                  ),
                  child: search,
                ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

/// 音源推荐页顶部的浏览入口（插件声明了 `browse` 才出现）：「全部作品」+ 各分类目录。
/// 筛选项取不到时只留「全部作品」。
class MusicPluginBrowseBar extends ConsumerStatefulWidget {
  const MusicPluginBrowseBar({super.key, required this.manifest});

  final MusicPluginManifest manifest;

  @override
  ConsumerState<MusicPluginBrowseBar> createState() =>
      _MusicPluginBrowseBarState();
}

class _MusicPluginBrowseBarState extends ConsumerState<MusicPluginBrowseBar> {
  late final Future<MusicPluginBrowseSchema> _schema = _browseSchemaOf(
    ref.read(appProvider),
    widget.manifest,
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FutureBuilder<MusicPluginBrowseSchema>(
      future: _schema,
      builder: (BuildContext context, AsyncSnapshot<MusicPluginBrowseSchema> s) {
        final List<MusicPluginBrowseOption> facets =
            s.data?.facets ?? const <MusicPluginBrowseOption>[];
        return Padding(
          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
          child: FushiAnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            alignment: AlignmentDirectional.topStart,
            child: Wrap(
              spacing: tokens.spacing.gap / 2,
              runSpacing: tokens.spacing.gap / 2,
              children: <Widget>[
                FushiPressScale(
                  child: FushiActionChipControl(
                    key: ValueKey<String>(
                      'music-plugin-browse-all-${widget.manifest.id}',
                    ),
                    avatar: const FushiIcon(FushiIcons.gridView),
                    label: Text(t.music_plugin_browse_all_works),
                    onPressed: () => unawaited(
                      openMusicPluginBrowseList(
                        context,
                        manifest: widget.manifest,
                        query: const MusicPluginBrowseQuery(),
                      ),
                    ),
                  ),
                ),
                for (final MusicPluginBrowseOption f in facets)
                  FushiPressScale(
                    child: FushiActionChipControl(
                      key: ValueKey<String>(
                        'music-plugin-browse-facet-${widget.manifest.id}-${f.id}',
                      ),
                      avatar: const FushiIcon(FushiIcons.tag),
                      label: Text(f.label),
                      onPressed: () => unawaited(
                        _push(
                          context,
                          MusicPluginCatalogPage(
                            manifest: widget.manifest,
                            facet: f,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
