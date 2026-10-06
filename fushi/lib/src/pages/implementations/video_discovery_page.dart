import 'dart:async';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart'
    as discovery;
import 'package:fushi/src/pages/implementations/airing_calendar_page.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_widgets.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeInsetSpacer,
        FushiFloatingChromeInsetPadding,
        FushiFloatingChromeOverlay,
        FushiFloatingChromeScope;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';

/// Aggregated discovery port consumed by the page. Implementations may fan a
/// request out to TMDB and AniList, but the UI receives one redacted
/// partial-success result and does not depend on provider clients directly.
abstract interface class VideoDiscoveryController {
  /// [onProgress]：部分来源先返回时的合并结果（见 `VideoDiscoveryService.load`）。
  Future<ProviderBatchResult<discovery.VideoDiscoveryPage>> load(
    discovery.VideoDiscoveryRequest request, {
    void Function(ProviderBatchResult<discovery.VideoDiscoveryPage> partial)?
        onProgress,
  });

  /// [ExternalProviderFailure.providerId] -> 用户可见来源名。
  ///
  /// BUG-2430：失败横幅原先直接印 providerId（`mal`），那是接线标识不是品牌名。解析
  /// 放在端口上，页面就不必为了一个名字去依赖 service 具体类型，也不必自己维护一张
  /// id -> 名字的映射表（那种表迟早漏掉新来源）。
  String displayNameFor(String providerId);
}

class EmptyVideoDiscoveryController implements VideoDiscoveryController {
  const EmptyVideoDiscoveryController();

  @override
  String displayNameFor(String providerId) => providerId;

  @override
  Future<ProviderBatchResult<discovery.VideoDiscoveryPage>> load(
    discovery.VideoDiscoveryRequest request, {
    void Function(ProviderBatchResult<discovery.VideoDiscoveryPage> partial)?
        onProgress,
  }) async {
    return ProviderBatchResult<discovery.VideoDiscoveryPage>.success(
      <discovery.VideoDiscoveryPage>[
        discovery.VideoDiscoveryPage(
          items: const <discovery.VideoDiscoveryItem>[],
          page: request.page,
          hasMore: false,
        ),
      ],
    );
  }
}

typedef VideoDiscoveryImageResolver = ImageProvider? Function(
    discovery.VideoDiscoveryItem item, bool landscape);

class VideoDiscoveryPage extends StatefulWidget {
  const VideoDiscoveryPage({
    required this.navigation,
    this.controller,
    this.actions = const VideoDiscoveryActions(),
    this.onOpenItem,
    this.imageResolver,
    this.embedded = false,
    super.key,
  });

  final Widget navigation;
  final VideoDiscoveryController? controller;
  final VideoDiscoveryActions actions;
  final ValueChanged<discovery.VideoDiscoveryItem>? onOpenItem;
  final VideoDiscoveryImageResolver? imageResolver;

  /// 嵌入下载中心资源页时，外层已经提供下载中心页头；隐藏本页自己的视频库
  /// 导航页头，但保留搜索、筛选、发现列表与详情动作。
  final bool embedded;

  @override
  State<VideoDiscoveryPage> createState() => _VideoDiscoveryPageState();
}

/// 首屏 Hero 轮播最多放几条热门（其余进下方「热门」横滑行）。
const int _kHeroCount = 5;

class _VideoDiscoveryPageState extends State<VideoDiscoveryPage> {
  // 与分类 chip 同一视觉高度（同处一条单行筛选行）。
  static const double _filterControlHeight = 36;
  static const int _pageSize = 30;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'video-discovery-search',
  );
  final ScrollController _scrollController = ScrollController();

  final DiscoverySearchDebouncer _debounce = DiscoverySearchDebouncer();
  int _generation = 0;
  int _page = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _totalFailure = false;

  discovery.VideoDiscoveryCategory? _category;

  /// 用户在排序菜单里显式选的排序；null = 跟随默认（见 [_sort]）。
  discovery.VideoDiscoverySort? _pickedSort;
  int _year = 0;
  String _region = '';
  String _genre = '';

  List<discovery.VideoDiscoveryItem> _popular =
      const <discovery.VideoDiscoveryItem>[];
  List<discovery.VideoDiscoveryItem> _seasonalAnime =
      const <discovery.VideoDiscoveryItem>[];
  List<discovery.VideoDiscoveryItem> _works =
      const <discovery.VideoDiscoveryItem>[];
  List<ExternalProviderFailure> _failures = const <ExternalProviderFailure>[];

  /// Hero 简介与详情页同一份数据：列表条目的简介是来源原文（动画卡片来自
  /// AniList / MAL，恒英文），详情经 [VideoDiscoveryActions.loadDetails] 按资料
  /// 语言合并（含 TMDB 交叉引用）。Hero 是发现页唯一显示简介的地方，所以对
  /// Hero 轮播的当前页与下一页预取详情、用详情的简介；详情回来前不显示简介，
  /// 免得先闪一段英文再换成中文。
  ///
  /// 作品 key → 详情简介（值为 null = 详情取回了但没有简介 / 取失败，退回列表
  /// 条目自带的简介）。
  final Map<String, String?> _heroOverviews = <String, String?>{};

  /// 详情在途的作品 key。
  final Set<String> _heroOverviewsPending = <String>{};

  VideoDiscoveryController get _controller =>
      widget.controller ?? const EmptyVideoDiscoveryController();

  bool get _searching => _searchController.text.trim().isNotEmpty;

  /// 没搜索时默认按热度浏览；一旦输入关键词，默认改按相关度——各来源按热度重排
  /// 搜索结果会把「沾边但热门」的作品顶到精确命中前面（AniList 走
  /// `POPULARITY_DESC` 而不是 `SEARCH_MATCH`，TMDB 按 popularity 重排多页结果）。
  /// 相关度只对搜索有意义，清空关键词后自动回落到热度。
  discovery.VideoDiscoverySort get _defaultSort => _searching
      ? discovery.VideoDiscoverySort.relevance
      : discovery.VideoDiscoverySort.popularity;

  discovery.VideoDiscoverySort get _sort {
    final discovery.VideoDiscoverySort? picked = _pickedSort;
    if (picked == null ||
        (picked == discovery.VideoDiscoverySort.relevance && !_searching)) {
      return _defaultSort;
    }
    return picked;
  }

  bool get _hasActiveSearchOrFilter =>
      _searching ||
      _category != null ||
      _sort != discovery.VideoDiscoverySort.popularity ||
      _year != 0 ||
      _region.isNotEmpty ||
      _genre.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _listenDetailsUpdates();
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant VideoDiscoveryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.actions.detailsUpdates,
      widget.actions.detailsUpdates,
    )) {
      _listenDetailsUpdates();
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      unawaited(_reload());
    }
  }

  StreamSubscription<void>? _detailsUpdates;

  /// 详情数据源变好（交叉索引后台就绪）时，Hero 原地重取一次：保留当前简介，
  /// 新数据到了再替换，不闪空。
  void _listenDetailsUpdates() {
    unawaited(_detailsUpdates?.cancel());
    _detailsUpdates = widget.actions.detailsUpdates?.listen((_) {
      if (!mounted || _popular.isEmpty || _hasActiveSearchOrFilter) return;
      for (final discovery.VideoDiscoveryItem item in _heroItems) {
        unawaited(_hydrateHero(item, refresh: true));
      }
    });
  }

  @override
  void dispose() {
    unawaited(_detailsUpdates?.cancel());
    _debounce.dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (discoveryShouldLoadMore(_scrollController.position)) {
      unawaited(_loadMore());
    }
  }

  void _scheduleSearch(String _) {
    // Invalidate an in-flight response as soon as the input changes. Waiting
    // until the debounce fires would let an older query briefly replace the
    // visible results while the user is already typing the next query.
    _generation += 1;
    _debounce.schedule(() => unawaited(_reload()));
  }

  void _submitSearch(String _) {
    _debounce.cancel();
    unawaited(_reload());
  }

  void _clearSearch() {
    _searchController.clear();
    _debounce.cancel();
    unawaited(_reload());
  }

  void _applyYearFilter(int year) {
    if (!mounted || _year == year) return;
    setState(() => _year = year);
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final int generation = ++_generation;
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    // 每次重载都是新的查询 / 筛选：上一次的列表不属于它，必须立刻撤下，否则
    // 「搜索结果」标题下会继续摆着旧的热门列表，直到最慢的来源返回。
    setState(() {
      _loading = true;
      _loadingMore = false;
      _totalFailure = false;
      _page = 1;
      _works = const <discovery.VideoDiscoveryItem>[];
      _popular = const <discovery.VideoDiscoveryItem>[];
      _seasonalAnime = const <discovery.VideoDiscoveryItem>[];
      _failures = const <ExternalProviderFailure>[];
      _hasMore = false;
      // 换控制器（资料语言 / key 变了）或换筛选都重取：详情按资料语言合并，
      // 留着上一轮的简介就是旧语言。重复取同一条由传输层缓存兜住。
      _heroOverviews.clear();
      _heroOverviewsPending.clear();
    });

    if (_hasActiveSearchOrFilter) {
      final ProviderBatchResult<discovery.VideoDiscoveryPage> result =
          await _safeLoad(
        _request(page: 1),
        onProgress: (ProviderBatchResult<discovery.VideoDiscoveryPage> part) {
          if (!mounted || generation != _generation) return;
          final _FlattenedDiscoveryBatch flattened = _flatten(part);
          if (flattened.items.isEmpty) return;
          setState(() => _works = flattened.items);
        },
      );
      if (!mounted || generation != _generation) return;
      final _FlattenedDiscoveryBatch flattened = _flatten(result);
      setState(() {
        _works = flattened.items;
        _popular = const <discovery.VideoDiscoveryItem>[];
        _seasonalAnime = const <discovery.VideoDiscoveryItem>[];
        _hasMore = flattened.hasMore;
        _failures = result.failures;
        _totalFailure = result.isTotalFailure;
        _loading = false;
      });
      return;
    }

    final List<ProviderBatchResult<discovery.VideoDiscoveryPage>> results =
        await Future.wait(
      <Future<ProviderBatchResult<discovery.VideoDiscoveryPage>>>[
        _safeLoad(
          _request(
            page: 1,
            feed: discovery.VideoDiscoveryFeed.trending,
            pageSize: 12,
          ),
        ),
        _safeLoad(
          _request(
            page: 1,
            category: discovery.VideoDiscoveryCategory.anime,
            feed: discovery.VideoDiscoveryFeed.airing,
            pageSize: 12,
          ),
        ),
        _safeLoad(_request(page: 1)),
      ],
    );
    if (!mounted || generation != _generation) return;
    final _FlattenedDiscoveryBatch popular = _flatten(results[0]);
    final _FlattenedDiscoveryBatch anime = _flatten(results[1]);
    final _FlattenedDiscoveryBatch works = _flatten(results[2]);
    final ProviderBatchResult<discovery.VideoDiscoveryPage> merged =
        ProviderBatchResult.merge<discovery.VideoDiscoveryPage>(results);
    setState(() {
      _popular = popular.items;
      _seasonalAnime = anime.items;
      _works = works.items;
      _hasMore = works.hasMore;
      _failures = merged.failures;
      _totalFailure = merged.isTotalFailure;
      _loading = false;
    });
    _hydrateHeroAround(0);
  }

  /// Hero 轮播的条目：热门前 [_kHeroCount] 条（搜索 / 筛选态没有 Hero）。
  List<discovery.VideoDiscoveryItem> get _heroItems => _hasActiveSearchOrFilter
      ? const <discovery.VideoDiscoveryItem>[]
      : _popular.take(_kHeroCount).toList(growable: false);

  /// 轮播停在 [page]：预取这一页与下一页的详情简介（下一页提前取，切过去时
  /// 简介已经到位，不闪空）。
  void _hydrateHeroAround(int page) {
    final List<discovery.VideoDiscoveryItem> items = _heroItems;
    if (items.isEmpty) return;
    unawaited(_hydrateHero(items[page % items.length]));
    if (items.length > 1) {
      unawaited(_hydrateHero(items[(page + 1) % items.length]));
    }
  }

  /// [refresh]：数据源变好后的重取——当前简介留着，新的到了再换。
  Future<void> _hydrateHero(
    discovery.VideoDiscoveryItem item, {
    bool refresh = false,
  }) async {
    final VideoDiscoveryDetailLoader? loader = widget.actions.loadDetails;
    final String key = item.reference.canonicalIdentityKey;
    if (loader == null) return;
    if (_heroOverviewsPending.contains(key)) return;
    if (refresh != _heroOverviews.containsKey(key)) return;
    final int generation = _generation;
    if (refresh) {
      _heroOverviewsPending.add(key);
    } else {
      setState(() => _heroOverviewsPending.add(key));
    }
    String? overview;
    bool failed = false;
    try {
      overview = (await loader(item)).item.overview;
    } on Object {
      // 详情取不到：退回列表条目自带的简介（重取失败则保留当前的）。
      failed = true;
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _heroOverviewsPending.remove(key);
      if (!(failed && refresh)) _heroOverviews[key] = overview;
    });
  }

  String? _heroSummary(discovery.VideoDiscoveryItem item) {
    if (widget.actions.loadDetails == null) return item.overview;
    final String key = item.reference.canonicalIdentityKey;
    // 还没取回（在途或尚未轮到）：先不显示，免得先闪英文原文。
    if (!_heroOverviews.containsKey(key)) return null;
    final String? detailed = _heroOverviews[key]?.trim();
    return detailed == null || detailed.isEmpty ? item.overview : detailed;
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _totalFailure) return;
    final int generation = _generation;
    final int nextPage = _page + 1;
    setState(() => _loadingMore = true);
    final ProviderBatchResult<discovery.VideoDiscoveryPage> result =
        await _safeLoad(_request(page: nextPage));
    if (!mounted || generation != _generation) return;
    final _FlattenedDiscoveryBatch flattened = _flatten(result);
    setState(() {
      _page = nextPage;
      _works = _deduplicate(<discovery.VideoDiscoveryItem>[
        ..._works,
        ...flattened.items,
      ]);
      _hasMore = flattened.hasMore;
      _failures = deduplicateDiscoveryFailures(<ExternalProviderFailure>[
        ..._failures,
        ...result.failures,
      ]);
      _loadingMore = false;
    });
  }

  discovery.VideoDiscoveryRequest _request({
    required int page,
    discovery.VideoDiscoveryCategory? category,
    discovery.VideoDiscoveryFeed feed = discovery.VideoDiscoveryFeed.popular,
    int pageSize = _pageSize,
  }) {
    return discovery.VideoDiscoveryRequest(
      category: category ?? _category,
      feed: feed,
      query: _searchController.text.trim(),
      page: page,
      pageSize: pageSize,
      sort: _sort,
      year: _year == 0 ? null : _year,
      genre: _genre.isEmpty ? null : _genre,
      region: _region.isEmpty ? null : _region,
    );
  }

  Future<ProviderBatchResult<discovery.VideoDiscoveryPage>> _safeLoad(
    discovery.VideoDiscoveryRequest request, {
    void Function(ProviderBatchResult<discovery.VideoDiscoveryPage> partial)?
        onProgress,
  }) async {
    try {
      return await _controller.load(request, onProgress: onProgress);
    } on Object catch (error) {
      return ProviderBatchResult<discovery.VideoDiscoveryPage>.failure(
        ExternalProviderFailure.fromException(
          providerId: 'discovery',
          operation: request.isSearch ? 'search' : 'discover',
          error: error,
        ),
      );
    }
  }

  _FlattenedDiscoveryBatch _flatten(
    ProviderBatchResult<discovery.VideoDiscoveryPage> result,
  ) {
    return _FlattenedDiscoveryBatch(
      items: _deduplicate(
        result.items
            .expand((discovery.VideoDiscoveryPage page) => page.items)
            .toList(growable: false),
      ),
      hasMore: result.items.any(
        (discovery.VideoDiscoveryPage page) => page.hasMore,
      ),
    );
  }

  List<discovery.VideoDiscoveryItem> _deduplicate(
    Iterable<discovery.VideoDiscoveryItem> items,
  ) {
    final Set<String> seen = <String>{};
    final List<discovery.VideoDiscoveryItem> result =
        <discovery.VideoDiscoveryItem>[];
    for (final discovery.VideoDiscoveryItem item in items) {
      final Set<String> identities = item.reference.identityKeys;
      if (identities.any(seen.contains)) continue;
      seen.addAll(identities);
      result.add(item);
    }
    return List<discovery.VideoDiscoveryItem>.unmodifiable(result);
  }

  @override
  Widget build(BuildContext context) {
    // 库页外壳里（有 [FushiFloatingChromeScope]）：搜索行 / 筛选行与外壳的
    // 页签同一套 M3E 浮动工具区——叠在内容上、跟着同一份显隐收起，正文从
    // 顶端画起、经 [FushiFloatingChromeInset] 让位，滚上去的内容在胶囊背后
    // 可见，顶部只有外壳那段短渐隐。曾经是 Column[页头, 控件, Expanded(正文)]：
    // 控件区是一整块不透明底，加上外壳工具区，往下一滚顶部两三百 px 全白。
    // 不在外壳里时 [FushiFloatingChromeOverlay] 退化成原来的竖排。
    final bool floating = FushiFloatingChromeScope.maybeOf(context) != null;
    final Widget body = _buildBody();
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: FushiFloatingChromeOverlay(
        chrome: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_headerVisible) _buildHeader(),
            _buildControls(),
          ],
        ),
        child: floating ? body : DiscoveryScrollTopFade(child: body),
      ),
    );
  }

  /// 页头只在独立页面（非 embedded、非 Cupertino）渲染；不渲染时页头上的入口
  /// （放送日历）改放进搜索行，否则浏览页里的视频发现就没有日历入口了。
  bool get _headerVisible => !widget.embedded && !isCupertinoPlatform(context);

  /// 放送日历（2026-08-21 迁入发现页）：条目直达发现详情，同一套 actions。
  void _openCalendar() {
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => AiringCalendarPage(actions: widget.actions),
      ),
    );
  }

  Widget _buildHeader() {
    final List<Widget> actions = <Widget>[
      FushiIconButton(
        key: const ValueKey<String>('video-discovery-open-calendar'),
        icon: Icons.calendar_month_outlined,
        tooltip: t.download_airing_calendar_title,
        label: t.download_airing_calendar_title,
        onTap: _openCalendar,
      ),
      if (widget.actions.onOpenDownloads != null)
        FushiIconButton(
          key: const ValueKey<String>('video-discovery-open-downloads'),
          icon: Icons.download_outlined,
          tooltip: t.download_tasks_tab,
          label: t.download_tasks_tab,
          onTap: widget.actions.onOpenDownloads!,
        ),
      if (widget.actions.onOpenSubscriptions != null)
        FushiIconButton(
          key: const ValueKey<String>('video-discovery-open-subscriptions'),
          icon: Icons.subscriptions_outlined,
          tooltip: t.download_subscriptions_tab,
          label: t.download_subscriptions_tab,
          onTap: widget.actions.onOpenSubscriptions!,
        ),
    ];
    return FushiPageHeader.customTitle(
      title: widget.navigation,
      actions: actions,
    );
  }

  Widget _buildControls() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return _buildControlsForWidth(tokens, constraints.maxWidth);
      },
    );
  }

  Widget _buildControlsForWidth(FushiDesignTokens tokens, double width) {
    final bool compact = width * FushiAppUiScale.of(context) < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        0,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Widget search = FushiSearchField(
                fieldKey: const ValueKey<String>('video-discovery-search'),
                clearButtonKey: const ValueKey<String>(
                  'video-discovery-search-clear',
                ),
                focusId: const FushiFocusId('video-discovery-search'),
                controller: _searchController,
                focusNode: _searchFocusNode,
                hintText: t.video_discovery_search_hint,
                onChanged: _scheduleSearch,
                onSubmitted: _submitSearch,
                onClear: _clearSearch,
              );
              // 「AI 下视频」入口跟搜索框同一行：embedded 于下载页时页头不渲染，
              // 搜索行是三种宽度下唯一都可见的位置。null = 宿主没接线（平台合规
              // 不可用），整颗按钮不渲染；AI 未指派由宿主在点击时引导去配置。
              final ValueChanged<String?>? onAiAcquire =
                  widget.actions.onAiAcquire;
              final Widget? aiEntry = onAiAcquire == null
                  ? null
                  : FushiIconButtonControl.filledTonal(
                      constraints: const BoxConstraints(
                        minWidth: kFushiSearchFieldHeight,
                        minHeight: kFushiSearchFieldHeight,
                      ),
                      key: const ValueKey<String>('video-discovery-ai-acquire'),
                      tooltip: t.ai_video_acquire_entry,
                      onPressed: () => onAiAcquire(_searchController.text),
                      icon: const FushiIcon(Icons.auto_awesome_outlined),
                    );
              // 放送日历：页头不渲染时（embedded 于浏览页 / Cupertino）页头那颗
              // 按钮看不见，同一个 key 挪到搜索行，三种宽度下都可达。
              final Widget? calendarEntry = _headerVisible
                  ? null
                  : FushiIconButtonControl.filledTonal(
                      constraints: const BoxConstraints(
                        minWidth: kFushiSearchFieldHeight,
                        minHeight: kFushiSearchFieldHeight,
                      ),
                      key: const ValueKey<String>(
                        'video-discovery-open-calendar',
                      ),
                      tooltip: t.download_airing_calendar_title,
                      onPressed: _openCalendar,
                      icon: const FushiIcon(Icons.calendar_month_outlined),
                    );
              final List<Widget> trailing = <Widget>[
                for (final Widget entry in <Widget?>[
                  calendarEntry,
                  aiEntry,
                ].whereType<Widget>()) ...<Widget>[
                  SizedBox(width: tokens.spacing.gap),
                  entry,
                ],
              ];
              // 窄屏：搜索框独占一整行（四个控件挤一行时搜索提示被截成「搜索
              // 电影…」，2026-10-04 用户截图）；日历 / AI / 筛选入口不再单占一行
              // （那一行左半边恒空，白占一行纵向空间，2026-10-05 用户截图），
              // 并进下面分类 chip 行的行尾、与排序同排。
              if (compact) return search;
              // 非手机宽度：搜索行只留搜索 + 行尾入口，年份 / 地区 / 题材 /
              // 排序挪进下面那条单行横滑筛选行（四个域发现页同一信息架构）。
              if (trailing.isEmpty) return search;
              return Row(
                children: <Widget>[
                  Expanded(child: search),
                  ...trailing,
                ],
              );
            },
          ),
          SizedBox(height: tokens.spacing.gap),
          Row(
            children: <Widget>[
              Expanded(
                child: HorizontalDragScrollable(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        for (final discovery.VideoDiscoveryCategory? category
                            in <discovery.VideoDiscoveryCategory?>[
                          null,
                          ...discovery.VideoDiscoveryCategory.values,
                        ]) ...<Widget>[
                          FushiSelectableChip(
                            key: ValueKey<String>(
                              'video-discovery-category-${category?.name ?? 'all'}',
                            ),
                            label: _categoryLabel(category),
                            selected: _category == category,
                            focusId: FushiFocusId(
                              'video-discovery-category-${category?.name ?? 'all'}',
                            ),
                            onSelected: (_) {
                              if (_category == category) return;
                              setState(() => _category = category);
                              unawaited(_reload());
                            },
                          ),
                          if (category !=
                              discovery.VideoDiscoveryCategory.values.last)
                            SizedBox(width: tokens.spacing.gap),
                        ],
                        if (!compact) ...<Widget>[
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: tokens.spacing.card,
                            ),
                            child: const SizedBox(
                              height: 24,
                              child: FushiVerticalDivider(width: 1),
                            ),
                          ),
                          _buildYearField(),
                          SizedBox(width: tokens.spacing.gap),
                          _buildRegionMenu(),
                          SizedBox(width: tokens.spacing.gap),
                          _buildGenreMenu(),
                          SizedBox(width: tokens.spacing.gap),
                          _buildSortMenu(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (compact) ...<Widget>[
                ..._compactEntries(tokens),
                SizedBox(width: tokens.spacing.gap),
                _buildSortMenu(compact: true),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 窄屏分类 chip 行行尾的入口：放送日历（页头不渲染时）/ AI 下视频（宿主
  /// 接线时）/ 高级筛选面板。宽屏下前两个在搜索行、筛选控件直接铺在 chip 行里。
  List<Widget> _compactEntries(FushiDesignTokens tokens) {
    const BoxConstraints size = BoxConstraints(
      minWidth: kFushiSearchFieldHeight,
      minHeight: kFushiSearchFieldHeight,
    );
    final ValueChanged<String?>? onAiAcquire = widget.actions.onAiAcquire;
    final int activeFilters = (_year != 0 ? 1 : 0) +
        (_region.isNotEmpty ? 1 : 0) +
        (_genre.isNotEmpty ? 1 : 0);
    return <Widget>[
      if (!_headerVisible) ...<Widget>[
        SizedBox(width: tokens.spacing.gap),
        FushiIconButtonControl.filledTonal(
          constraints: size,
          key: const ValueKey<String>('video-discovery-open-calendar'),
          tooltip: t.download_airing_calendar_title,
          onPressed: _openCalendar,
          icon: const FushiIcon(Icons.calendar_month_outlined),
        ),
      ],
      if (onAiAcquire != null) ...<Widget>[
        SizedBox(width: tokens.spacing.gap),
        FushiIconButtonControl.filledTonal(
          constraints: size,
          key: const ValueKey<String>('video-discovery-ai-acquire'),
          tooltip: t.ai_video_acquire_entry,
          onPressed: () => onAiAcquire(_searchController.text),
          icon: const FushiIcon(Icons.auto_awesome_outlined),
        ),
      ],
      SizedBox(width: tokens.spacing.gap),
      FushiIconButtonControl.filledTonal(
        constraints: size,
        key: const ValueKey<String>('video-discovery-open-filters'),
        tooltip: t.game_filter,
        onPressed: _openFilterSheet,
        icon: FushiBadgeControl.count(
          count: activeFilters,
          isLabelVisible: activeFilters > 0,
          child: const FushiIcon(Icons.tune_rounded),
        ),
      ),
    ];
  }

  Future<void> _openFilterSheet() async {
    int year = _year;
    String region = _region;
    String genre = _genre;
    final bool? apply = await adaptiveModalSheet<bool>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext sheetContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          final FushiDesignTokens tokens = FushiDesignTokens.of(context);
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                0,
                tokens.spacing.page,
                tokens.spacing.page,
              ),
              child: Column(
                key: const ValueKey<String>('video-discovery-filter-sheet'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    t.game_filter,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  SizedBox(height: tokens.spacing.gap),
                  Text(t.video_filter_year),
                  _buildYearField(
                    value: year,
                    onChanged: (int value) => setSheetState(() => year = value),
                  ),
                  SizedBox(height: tokens.spacing.gap),
                  Text(t.video_work_countries),
                  _buildRegionMenu(
                    value: region,
                    onChanged: (String value) =>
                        setSheetState(() => region = value),
                  ),
                  SizedBox(height: tokens.spacing.gap),
                  Text(t.video_work_genres),
                  _buildGenreMenu(
                    value: genre,
                    onChanged: (String value) =>
                        setSheetState(() => genre = value),
                  ),
                  SizedBox(height: tokens.spacing.gap),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: tokens.spacing.gap,
                    children: <Widget>[
                      FushiTextButton(
                        key: const ValueKey<String>(
                          'video-discovery-reset-filters',
                        ),
                        onPressed: () => setSheetState(() {
                          year = 0;
                          region = '';
                          genre = '';
                        }),
                        child: Text(t.reset),
                      ),
                      FushiTextButton(
                        onPressed: () => Navigator.pop(sheetContext, false),
                        child: Text(t.dialog_cancel),
                      ),
                      FushiFilledButton(
                        key: const ValueKey<String>(
                          'video-discovery-apply-filters',
                        ),
                        onPressed: () => Navigator.pop(sheetContext, true),
                        child: Text(t.dialog_done),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted ||
        apply != true ||
        (year == _year && region == _region && genre == _genre)) {
      return;
    }
    setState(() {
      _year = year;
      _region = region;
      _genre = genre;
    });
    unawaited(_reload());
  }

  /// 筛选触发器（[_filterButton] = MD3 FushiCard）的圆角：交给
  /// [FushiPopupMenuButton] 让悬停 / 按压状态层与卡片同形。
  static const BorderRadius _kFilterTriggerRadius =
      BorderRadius.all(Radius.circular(kFushiMd3CardRadius));

  Widget _buildYearField({int? value, ValueChanged<int>? onChanged}) {
    final int selected = value ?? _year;
    final int newestYear = DateTime.now().year + 2;
    return FushiPopupMenuButton<int>(
      key: const ValueKey<String>('video-discovery-filter-year'),
      // MD3 下状态层与 _filterButton 的卡片同圆角（FushiCard 默认圆角）。
      borderRadius: _kFilterTriggerRadius,
      tooltip: t.video_filter_year,
      initialValue: selected,
      onSelected: onChanged ?? _applyYearFilter,
      itemBuilder: (_) => <PopupMenuEntry<int>>[
        PopupMenuItem<int>(value: 0, child: Text(t.home_filter_all)),
        for (int year = newestYear; year >= 1900; year--)
          PopupMenuItem<int>(value: year, child: Text('$year')),
      ],
      child: _filterButton(
        label: selected == 0 ? t.video_filter_year : '$selected',
        active: selected != 0,
      ),
    );
  }

  Widget _buildRegionMenu({String? value, ValueChanged<String>? onChanged}) {
    final String selected = value ?? _region;
    const List<String> regions = <String>['CN', 'JP', 'KR', 'US', 'GB', 'FR'];
    return FushiPopupMenuButton<String>(
      key: const ValueKey<String>('video-discovery-filter-region'),
      // MD3 下状态层与 _filterButton 的卡片同圆角（FushiCard 默认圆角）。
      borderRadius: _kFilterTriggerRadius,
      tooltip: t.video_work_countries,
      initialValue: selected,
      onSelected: onChanged ??
          (String value) {
            setState(() => _region = value);
            unawaited(_reload());
          },
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: '', child: Text(t.home_filter_all)),
        for (final String region in regions)
          PopupMenuItem<String>(value: region, child: Text(region)),
      ],
      child: _filterButton(
        label: selected.isEmpty ? t.video_work_countries : selected,
        active: selected.isNotEmpty,
      ),
    );
  }

  Widget _buildGenreMenu({String? value, ValueChanged<String>? onChanged}) {
    final String selected = value ?? _genre;
    return FushiPopupMenuButton<String>(
      key: const ValueKey<String>('video-discovery-filter-genre'),
      // MD3 下状态层与 _filterButton 的卡片同圆角（FushiCard 默认圆角）。
      borderRadius: _kFilterTriggerRadius,
      tooltip: t.video_work_genres,
      initialValue: selected,
      onSelected: onChanged ??
          (String value) {
            setState(() => _genre = value);
            unawaited(_reload());
          },
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: '', child: Text(t.home_filter_all)),
        for (final String genre in _availableGenres)
          PopupMenuItem<String>(value: genre, child: Text(genre)),
      ],
      child: _filterButton(
        label: selected.isEmpty ? t.video_work_genres : selected,
        active: selected.isNotEmpty,
      ),
    );
  }

  Widget _buildSortMenu({bool compact = false}) {
    return FushiPopupMenuButton<discovery.VideoDiscoverySort>(
      key: const ValueKey<String>('video-discovery-filter-sort'),
      // MD3 下状态层与触发器同形：窄屏是 48 圆形图标格，宽屏是筛选卡片。
      borderRadius: compact
          ? const BorderRadius.all(Radius.circular(24))
          : _kFilterTriggerRadius,
      tooltip: '${t.sort_by}: ${_sortLabel(_sort)}',
      initialValue: _sort,
      onSelected: (discovery.VideoDiscoverySort value) {
        setState(() => _pickedSort = value);
        unawaited(_reload());
      },
      itemBuilder: (_) => <PopupMenuEntry<discovery.VideoDiscoverySort>>[
        for (final discovery.VideoDiscoverySort sort
            in discovery.VideoDiscoverySort.values)
          if (sort != discovery.VideoDiscoverySort.relevance || _searching)
            PopupMenuItem<discovery.VideoDiscoverySort>(
              value: sort,
              child: Text(_sortLabel(sort)),
            ),
      ],
      child: compact
          ? SizedBox(
              width: 48,
              height: 48,
              child: FushiIcon(
                Icons.sort_rounded,
                color: _sort == _defaultSort
                    ? null
                    : Theme.of(context).colorScheme.primary,
              ),
            )
          : _filterButton(
              label: _sort == _defaultSort ? t.sort_by : _sortLabel(_sort),
              active: _sort != _defaultSort,
            ),
    );
  }

  Widget _filterButton({required String label, required bool active}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    // Apple：筛选下拉是无描边的灰阶填充胶囊，选中态整颗换强调色（iOS 26
    // 筛选胶囊）；MD3 保留描边方块 + selected 底。
    final FushiAppleColors? apple =
        isGlassDesign(context) ? appleColorsOf(context) : null;
    // Apple：筛选弹出按钮是控件层的无色透明液态玻璃胶囊（不铺 systemFill
    // 灰底），激活态换更亮的透明底 + 强调色字（与库页筛选下拉同口径）。
    final Color? appleForeground =
        apple == null ? null : (active ? apple.accent : apple.label);
    final Widget card = SizedBox(
      height: _filterControlHeight,
      child: FushiCard(
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.rowHorizontal),
        color: apple != null
            ? Colors.transparent
            : (active ? tokens.surfaces.selected : tokens.surfaces.page),
        borderColor: apple != null
            ? Colors.transparent
            : (active ? colors.primary : tokens.surfaces.outline),
        borderRadius: apple != null
            ? BorderRadius.circular(_filterControlHeight / 2)
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: tokens.type.controlLabel.copyWith(color: appleForeground),
            ),
            SizedBox(width: tokens.spacing.gap / 2),
            FushiIcon(
              Icons.expand_more_rounded,
              size: 18,
              color: appleForeground,
            ),
          ],
        ),
      ),
    );
    if (apple == null) return card;
    return fushiClearGlassBezel(
      context,
      radius: _filterControlHeight / 2,
      lighter: active,
      child: card,
    );
  }

  Widget _buildBody() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (_loading && _works.isEmpty && _popular.isEmpty) {
      // 首屏骨架：Hero + 一条横滑行占住版面，数据到达时原地换成真内容，
      // 而不是一枚居中转圈之后整页跳出来。静态骨架，不挂无限动画。
      return FushiFloatingChromeInsetPadding(
        child: ListView(
          key: const ValueKey<String>('video-discovery-skeleton'),
          physics: const NeverScrollableScrollPhysics(),
          children: <Widget>[
            const DiscoveryHeroSkeleton(),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) =>
                  DiscoveryShelf(
                title: t.video_discovery_hot,
                loading: true,
                shape: DiscoveryCoverShape.landscape,
                titleMaxLines: 1,
                itemWidth: _shelfItemWidth(constraints.maxWidth),
                itemCount: 0,
                itemBuilder: (BuildContext context, int index) =>
                    const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      );
    }
    if (_totalFailure && _works.isEmpty && _popular.isEmpty) {
      return FushiFloatingChromeInsetPadding(
        child: FushiPlaceholderMessage(
          icon: Icons.cloud_off_outlined,
          message: t.video_discovery_load_failed,
          action: FushiFilledButton.icon(
            key: const ValueKey<String>('video-discovery-retry'),
            onPressed: () => unawaited(_reload()),
            icon: const FushiIcon(Icons.refresh_rounded),
            label: Text(t.retry),
          ),
        ),
      );
    }

    final bool searchMode = _hasActiveSearchOrFilter;
    final List<discovery.VideoDiscoveryItem> heroItems = _heroItems;
    final List<discovery.VideoDiscoveryItem> popularRest =
        _popular.sublist(heroItems.length);
    return CustomScrollView(
      key: const PageStorageKey<String>('video-discovery-scroll'),
      controller: _scrollController,
      slivers: <Widget>[
        // 让出叠放在上面的浮动工具区（外壳页签 + 本页搜索 / 筛选行）。
        const SliverToBoxAdapter(child: FushiFloatingChromeInsetSpacer()),
        if (_failures.isNotEmpty)
          SliverToBoxAdapter(
            child: DiscoveryProviderWarningBanner(
              key: const ValueKey<String>('video-discovery-provider-warning'),
              failures: _failures,
              displayNameFor: _controller.displayNameFor,
            ),
          ),
        // 首屏：Hero 轮播（热门前几条）+ 其余热门的横滑行。外层一个 key 承载
        // 「热门」整段，热门全进了轮播时行收起，标题不重复出现。
        if (heroItems.isNotEmpty)
          SliverToBoxAdapter(
            child: Column(
              key: const ValueKey<String>('video-discovery-popular'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                DiscoveryHeroCarousel(
                  key: const ValueKey<String>('video-discovery-hero-carousel'),
                  itemCount: heroItems.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _buildHero(heroItems[index]),
                  onPageChanged: _hydrateHeroAround,
                ),
                if (popularRest.isNotEmpty)
                  _DiscoveryShelf(
                    title: t.video_discovery_hot,
                    items: popularRest,
                    imageResolver: widget.imageResolver,
                    onOpen: _openItem,
                  ),
              ],
            ),
          ),
        if (!searchMode && _seasonalAnime.isNotEmpty)
          SliverToBoxAdapter(
            child: _DiscoveryShelf(
              key: const ValueKey<String>('video-discovery-seasonal-anime'),
              title: t.video_discovery_seasonal_anime,
              items: _seasonalAnime,
              imageResolver: widget.imageResolver,
              onOpen: _openItem,
            ),
          ),
        SliverToBoxAdapter(
          child: FushiSectionTitle(
            searchMode
                ? t.video_discovery_search_results
                : t.video_discovery_all_works,
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              searchMode ? tokens.spacing.card : tokens.spacing.section,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
          ),
        ),
        // 已显示先返回的来源，其余来源还在路上。
        if (_loading)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              child: const FushiLinearProgressIndicator(
                key: ValueKey<String>('video-discovery-partial-loading'),
              ),
            ),
          ),
        if (_works.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: FushiPlaceholderMessage(
              icon: Icons.search_off_rounded,
              message: t.video_discovery_empty,
            ),
          )
        else
          // 2026-10 动效重做：首屏结果卡错峰淡入，翻页补进来的卡在窗口外，瞬间
          // 出现（[DiscoveryCoverGrid] 对已包好的项原样放行，不叠两层）。
          FushiEntranceScope(
            child: DiscoveryCoverGrid(
              itemCount: _works.length,
              itemBuilder: (BuildContext context, int index) =>
                  FushiStaggeredEntrance(
                index: index,
                child: _DiscoveryMediaCard(
                  item: _works[index],
                  landscape: false,
                  imageResolver: widget.imageResolver,
                  onTap: () => _openItem(_works[index]),
                ),
              ),
            ),
          ),
        // 玻璃设计下首页 extendBody，悬浮导航胶囊的高度并进了 MediaQuery 底部
        // padding：页尾垫到胶囊之上，否则最后几行与「加载更多」被胶囊盖住。
        SliverSafeArea(
          top: false,
          sliver: SliverToBoxAdapter(
            child: DiscoveryLoadMoreFooter(loading: _loadingMore),
          ),
        ),
      ],
    );
  }

  /// 首屏 Hero 轮播的一页：横版剧照优先、只有海报时模糊垫底 + 尾侧海报。
  Widget _buildHero(discovery.VideoDiscoveryItem item) {
    final bool hasBackdrop = item.backdropUrl?.trim().isNotEmpty == true;
    final ImageProvider? backdrop = hasBackdrop
        ? widget.imageResolver?.call(item, true) ??
            _networkImage(item.backdropUrl)
        : null;
    final ImageProvider? poster = widget.imageResolver?.call(item, false) ??
        _networkImage(item.posterUrl);
    return DiscoveryHeroBanner(
      key: ValueKey<String>(
        'video-discovery-hero-${item.reference.canonicalIdentityKey}',
      ),
      eyebrow: t.video_discovery_hot,
      title: item.reference.title,
      subtitle: item.reference.originalTitle,
      metaParts: <String>[
        if (item.reference.year != null) '${item.reference.year}',
        _videoDiscoveryCategoryLabel(item.reference.discoveryCategory),
        if (item.score != null) '★ ${item.score!.toStringAsFixed(1)}',
      ],
      summary: _heroSummary(item),
      backdrop: backdrop,
      poster: poster,
      actionLabel: t.video_hero_detail_view,
      actionKey: const ValueKey<String>('video-discovery-hero-open'),
      onOpen: () => _openItem(item),
    );
  }

  void _openItem(discovery.VideoDiscoveryItem item) {
    final ValueChanged<discovery.VideoDiscoveryItem>? onOpen =
        widget.onOpenItem;
    if (onOpen != null) {
      onOpen(item);
      return;
    }
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) =>
            VideoDiscoveryDetailPage(item: item, actions: widget.actions),
      ),
    );
  }

  List<String> get _availableGenres {
    final List<String> result = <String>{
      'Action',
      'Adventure',
      'Animation',
      'Comedy',
      'Crime',
      'Documentary',
      'Drama',
      'Ecchi',
      'Family',
      'Fantasy',
      'History',
      'Horror',
      'Kids',
      'Mahou Shoujo',
      'Mecha',
      'Music',
      'Mystery',
      'News',
      'Psychological',
      'Reality',
      'Romance',
      'Science Fiction',
      'Slice of Life',
      'Soap',
      'Sports',
      'Supernatural',
      'Talk',
      'Thriller',
      'War',
      'Western',
    }.toList()
      ..sort();
    return result;
  }

  String _categoryLabel(discovery.VideoDiscoveryCategory? category) =>
      switch (category) {
        null => t.home_filter_all,
        discovery.VideoDiscoveryCategory.movie => t.collection_relation_movie,
        discovery.VideoDiscoveryCategory.tv => t.series,
        discovery.VideoDiscoveryCategory.anime => t.media_tracking_anime,
      };

  String _sortLabel(discovery.VideoDiscoverySort sort) => switch (sort) {
        discovery.VideoDiscoverySort.relevance => t.search,
        discovery.VideoDiscoverySort.popularity =>
          t.video_discovery_sort_popularity,
        discovery.VideoDiscoverySort.rating => t.video_discovery_sort_rating,
        discovery.VideoDiscoverySort.releaseDate =>
          t.video_discovery_sort_release,
      };
}

/// 横滑行卡宽：手机 240、平板 / 桌面 280（16:9 横卡）。
double _shelfItemWidth(double width) => width < 600 ? 240 : 280;

String _videoDiscoveryCategoryLabel(
  discovery.VideoDiscoveryCategory category,
) =>
    switch (category) {
      discovery.VideoDiscoveryCategory.movie => t.collection_relation_movie,
      discovery.VideoDiscoveryCategory.tv => t.series,
      discovery.VideoDiscoveryCategory.anime => t.media_tracking_anime,
    };

ImageProvider? _networkImage(String? url) {
  final String value = url?.trim() ?? '';
  return value.isEmpty ? null : AppCachedHttpImage(value);
}

/// 视频发现的横滑行：共享 [DiscoveryShelf] 版式 + 本页的横向封面卡；行头
/// 「查看全部」推整组网格页。
class _DiscoveryShelf extends StatelessWidget {
  const _DiscoveryShelf({
    required this.title,
    required this.items,
    required this.onOpen,
    this.imageResolver,
    super.key,
  });

  final String title;
  final List<discovery.VideoDiscoveryItem> items;
  final ValueChanged<discovery.VideoDiscoveryItem> onOpen;
  final VideoDiscoveryImageResolver? imageResolver;

  void _openAll(BuildContext context) {
    unawaited(
      DiscoveryGridPage.open(
        context,
        title: title,
        itemCount: items.length,
        itemBuilder: (BuildContext context, int index) => _DiscoveryMediaCard(
          item: items[index],
          landscape: false,
          imageResolver: imageResolver,
          onTap: () => onOpen(items[index]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return DiscoveryShelf(
          title: title,
          storageKey: 'video-discovery-shelf-$title',
          shape: DiscoveryCoverShape.landscape,
          titleMaxLines: 1,
          itemWidth: _shelfItemWidth(constraints.maxWidth),
          trailing: DiscoveryViewAllButton(onPressed: () => _openAll(context)),
          itemCount: items.length,
          itemBuilder: (BuildContext context, int index) => _DiscoveryMediaCard(
            item: items[index],
            landscape: true,
            imageResolver: imageResolver,
            onTap: () => onOpen(items[index]),
          ),
        );
      },
    );
  }
}

/// 发现卡：共享 [DiscoveryCoverCard]（封面 + 下方标题 / 年份·类型），评分压在
/// 封面右上角的 [CoverBadge]。
class _DiscoveryMediaCard extends StatelessWidget {
  const _DiscoveryMediaCard({
    required this.item,
    required this.landscape,
    required this.onTap,
    this.imageResolver,
  });

  final discovery.VideoDiscoveryItem item;
  final bool landscape;
  final VoidCallback onTap;
  final VideoDiscoveryImageResolver? imageResolver;

  @override
  Widget build(BuildContext context) {
    final String stableId = item.reference.canonicalIdentityKey;
    final DiscoveryCoverShape shape = landscape
        ? DiscoveryCoverShape.landscape
        : DiscoveryCoverShape.portrait;
    final ImageProvider? image =
        imageResolver?.call(item, landscape) ?? _defaultImage(item, landscape);
    final double? score = item.score;
    return DiscoveryCoverCard(
      key: ValueKey<String>('video-discovery-card-$stableId'),
      focusId: FushiFocusId('video-discovery-card-$stableId'),
      title: item.reference.title,
      subtitle: _metadata(),
      shape: shape,
      titleMaxLines: landscape ? 1 : 2,
      onTap: onTap,
      badges: <Widget>[
        if (score != null)
          CoverBadge(
            icon: Icons.star_rounded,
            iconSize: 12,
            label: score.toStringAsFixed(1),
          ),
      ],
      cover: DiscoveryImageCover(
        image: image,
        shape: shape,
        placeholderIcon: Icons.movie_outlined,
      ),
    );
  }

  String _metadata() => <String>[
        if (item.reference.year != null) '${item.reference.year}',
        _videoDiscoveryCategoryLabel(item.reference.discoveryCategory),
      ].join(' · ');

  ImageProvider? _defaultImage(
    discovery.VideoDiscoveryItem item,
    bool landscape,
  ) {
    final String value = (landscape
                ? item.backdropUrl ?? item.posterUrl
                : item.posterUrl ?? item.backdropUrl)
            ?.trim() ??
        '';
    return value.isEmpty ? null : AppCachedHttpImage(value);
  }
}

class _FlattenedDiscoveryBatch {
  const _FlattenedDiscoveryBatch({required this.items, required this.hasMore});

  final List<discovery.VideoDiscoveryItem> items;
  final bool hasMore;
}
