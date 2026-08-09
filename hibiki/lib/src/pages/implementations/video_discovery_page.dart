import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/external_provider.dart';
import 'package:hibiki/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:hibiki/src/media/video/discovery/video_discovery_provider.dart'
    as discovery;
import 'package:hibiki/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:hibiki/utils.dart';

/// Aggregated discovery port consumed by the page. Implementations may fan a
/// request out to TMDB, AniList and Bangumi, but the UI receives one redacted
/// partial-success result and does not depend on provider clients directly.
abstract interface class VideoDiscoveryController {
  Future<ProviderBatchResult<discovery.VideoDiscoveryPage>> load(
    discovery.VideoDiscoveryRequest request,
  );
}

class EmptyVideoDiscoveryController implements VideoDiscoveryController {
  const EmptyVideoDiscoveryController();

  @override
  Future<ProviderBatchResult<discovery.VideoDiscoveryPage>> load(
    discovery.VideoDiscoveryRequest request,
  ) async {
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
  discovery.VideoDiscoveryItem item,
  bool landscape,
);

class VideoDiscoveryPage extends StatefulWidget {
  const VideoDiscoveryPage({
    required this.navigation,
    this.controller,
    this.actions = const VideoDiscoveryActions(),
    this.onOpenItem,
    this.imageResolver,
    super.key,
  });

  final Widget navigation;
  final VideoDiscoveryController? controller;
  final VideoDiscoveryActions actions;
  final ValueChanged<discovery.VideoDiscoveryItem>? onOpenItem;
  final VideoDiscoveryImageResolver? imageResolver;

  @override
  State<VideoDiscoveryPage> createState() => _VideoDiscoveryPageState();
}

class _VideoDiscoveryPageState extends State<VideoDiscoveryPage> {
  static const Duration _searchDebounce = Duration(milliseconds: 350);
  static const int _pageSize = 30;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'video-discovery-search',
  );
  final ScrollController _scrollController = ScrollController();

  Timer? _debounce;
  int _generation = 0;
  int _page = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _totalFailure = false;

  discovery.VideoDiscoveryCategory? _category;
  discovery.VideoDiscoverySort _sort = discovery.VideoDiscoverySort.popularity;
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
  final Set<int> _knownYears = <int>{};
  final Set<String> _knownGenres = <String>{};

  VideoDiscoveryController get _controller =>
      widget.controller ?? const EmptyVideoDiscoveryController();

  bool get _hasActiveSearchOrFilter =>
      _searchController.text.trim().isNotEmpty ||
      _category != null ||
      _sort != discovery.VideoDiscoverySort.popularity ||
      _year != 0 ||
      _region.isNotEmpty ||
      _genre.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant VideoDiscoveryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 600) {
      unawaited(_loadMore());
    }
  }

  void _scheduleSearch(String _) {
    _debounce?.cancel();
    // Invalidate an in-flight response as soon as the input changes. Waiting
    // until the debounce fires would let an older query briefly replace the
    // visible results while the user is already typing the next query.
    _generation += 1;
    _debounce = Timer(_searchDebounce, () => unawaited(_reload()));
  }

  void _submitSearch(String _) {
    _debounce?.cancel();
    unawaited(_reload());
  }

  void _clearSearch() {
    _searchController.clear();
    _debounce?.cancel();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final int generation = ++_generation;
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    setState(() {
      _loading = true;
      _loadingMore = false;
      _totalFailure = false;
      _page = 1;
    });

    if (_hasActiveSearchOrFilter) {
      final ProviderBatchResult<discovery.VideoDiscoveryPage> result =
          await _safeLoad(_request(page: 1));
      if (!mounted || generation != _generation) return;
      final _FlattenedDiscoveryBatch flattened = _flatten(result);
      _rememberFacets(flattened.items);
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
    _rememberFacets(<discovery.VideoDiscoveryItem>[
      ...popular.items,
      ...anime.items,
      ...works.items,
    ]);
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
    _rememberFacets(flattened.items);
    setState(() {
      _page = nextPage;
      _works = _deduplicate(<discovery.VideoDiscoveryItem>[
        ..._works,
        ...flattened.items,
      ]);
      _hasMore = flattened.hasMore;
      _failures = _deduplicateFailures(<ExternalProviderFailure>[
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
    discovery.VideoDiscoveryRequest request,
  ) async {
    try {
      return await _controller.load(request);
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
            .expand(
              (discovery.VideoDiscoveryPage page) => page.items,
            )
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

  List<ExternalProviderFailure> _deduplicateFailures(
    Iterable<ExternalProviderFailure> failures,
  ) {
    final Set<String> seen = <String>{};
    return <ExternalProviderFailure>[
      for (final ExternalProviderFailure failure in failures)
        if (seen.add(
          '${failure.providerId}:${failure.operation}:${failure.kind.name}',
        ))
          failure,
    ];
  }

  void _rememberFacets(Iterable<discovery.VideoDiscoveryItem> items) {
    for (final discovery.VideoDiscoveryItem item in items) {
      final int? year = item.reference.year;
      if (year != null) _knownYears.add(year);
      _knownGenres.addAll(
        item.genres.where((String value) => value.trim().isNotEmpty),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context)) _buildHeader(),
          _buildControls(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final List<Widget> actions = <Widget>[
      if (widget.actions.onOpenDownloads != null)
        HibikiIconButton(
          key: const ValueKey<String>('video-discovery-open-downloads'),
          icon: Icons.download_outlined,
          tooltip: t.download_tasks_tab,
          label: t.download_tasks_tab,
          onTap: widget.actions.onOpenDownloads!,
        ),
      if (widget.actions.onOpenSubscriptions != null)
        HibikiIconButton(
          key: const ValueKey<String>('video-discovery-open-subscriptions'),
          icon: Icons.subscriptions_outlined,
          tooltip: t.download_subscriptions_tab,
          label: t.download_subscriptions_tab,
          onTap: widget.actions.onOpenSubscriptions!,
        ),
    ];
    return HibikiPageHeader.customTitle(
      title: widget.navigation,
      actions: actions,
    );
  }

  Widget _buildControls() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
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
              final Widget search = HibikiSearchField(
                fieldKey: const ValueKey<String>('video-discovery-search'),
                clearButtonKey:
                    const ValueKey<String>('video-discovery-search-clear'),
                focusId: const HibikiFocusId('video-discovery-search'),
                controller: _searchController,
                focusNode: _searchFocusNode,
                hintText: t.video_discovery_search_hint,
                onChanged: _scheduleSearch,
                onSubmitted: _submitSearch,
                onClear: _clearSearch,
              );
              if (constraints.maxWidth < 900) return search;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: search),
                  SizedBox(width: tokens.spacing.gap),
                  _buildYearMenu(),
                  SizedBox(width: tokens.spacing.gap),
                  _buildRegionMenu(),
                  SizedBox(width: tokens.spacing.gap),
                  _buildGenreMenu(),
                  SizedBox(width: tokens.spacing.gap),
                  _buildSortMenu(),
                ],
              );
            },
          ),
          SizedBox(height: tokens.spacing.gap),
          HorizontalDragScrollable(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (final discovery.VideoDiscoveryCategory? category
                      in <discovery.VideoDiscoveryCategory?>[
                    null,
                    ...discovery.VideoDiscoveryCategory.values,
                  ]) ...<Widget>[
                    HibikiSelectableChip(
                      key: ValueKey<String>(
                        'video-discovery-category-${category?.name ?? 'all'}',
                      ),
                      label: _categoryLabel(category),
                      selected: _category == category,
                      focusId: HibikiFocusId(
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
                ],
              ),
            ),
          ),
          if (MediaQuery.sizeOf(context).width < 900) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                _buildYearMenu(),
                _buildRegionMenu(),
                _buildGenreMenu(),
                _buildSortMenu(),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildYearMenu() {
    final List<int> years = _availableYears;
    return PopupMenuButton<int>(
      key: const ValueKey<String>('video-discovery-filter-year'),
      tooltip: t.video_filter_year,
      initialValue: _year,
      onSelected: (int value) {
        setState(() => _year = value);
        unawaited(_reload());
      },
      itemBuilder: (_) => <PopupMenuEntry<int>>[
        PopupMenuItem<int>(value: 0, child: Text(t.home_filter_all)),
        for (final int year in years)
          PopupMenuItem<int>(value: year, child: Text('$year')),
      ],
      child: _filterButton(
        label: _year == 0 ? t.video_filter_year : '$_year',
        active: _year != 0,
      ),
    );
  }

  Widget _buildRegionMenu() {
    const List<String> regions = <String>['CN', 'JP', 'KR', 'US', 'GB', 'FR'];
    return PopupMenuButton<String>(
      key: const ValueKey<String>('video-discovery-filter-region'),
      tooltip: t.video_work_countries,
      initialValue: _region,
      onSelected: (String value) {
        setState(() => _region = value);
        unawaited(_reload());
      },
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: '', child: Text(t.home_filter_all)),
        for (final String region in regions)
          PopupMenuItem<String>(value: region, child: Text(region)),
      ],
      child: _filterButton(
        label: _region.isEmpty ? t.video_work_countries : _region,
        active: _region.isNotEmpty,
      ),
    );
  }

  Widget _buildGenreMenu() {
    return PopupMenuButton<String>(
      key: const ValueKey<String>('video-discovery-filter-genre'),
      tooltip: t.video_work_genres,
      initialValue: _genre,
      onSelected: (String value) {
        setState(() => _genre = value);
        unawaited(_reload());
      },
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: '', child: Text(t.home_filter_all)),
        for (final String genre in _availableGenres)
          PopupMenuItem<String>(value: genre, child: Text(genre)),
      ],
      child: _filterButton(
        label: _genre.isEmpty ? t.video_work_genres : _genre,
        active: _genre.isNotEmpty,
      ),
    );
  }

  Widget _buildSortMenu() {
    return PopupMenuButton<discovery.VideoDiscoverySort>(
      key: const ValueKey<String>('video-discovery-filter-sort'),
      tooltip: t.sort_by,
      initialValue: _sort,
      onSelected: (discovery.VideoDiscoverySort value) {
        setState(() => _sort = value);
        unawaited(_reload());
      },
      itemBuilder: (_) => <PopupMenuEntry<discovery.VideoDiscoverySort>>[
        for (final discovery.VideoDiscoverySort sort
            in discovery.VideoDiscoverySort.values)
          if (sort != discovery.VideoDiscoverySort.relevance ||
              _searchController.text.trim().isNotEmpty)
            PopupMenuItem<discovery.VideoDiscoverySort>(
              value: sort,
              child: Text(_sortLabel(sort)),
            ),
      ],
      child: _filterButton(
        label: _sort == discovery.VideoDiscoverySort.popularity
            ? t.sort_by
            : _sortLabel(_sort),
        active: _sort != discovery.VideoDiscoverySort.popularity,
      ),
    );
  }

  Widget _filterButton({required String label, required bool active}) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return HibikiCard(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal,
        vertical: tokens.spacing.gap,
      ),
      color: active ? tokens.surfaces.selected : tokens.surfaces.page,
      borderColor: active ? colors.primary : tokens.surfaces.outline,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: tokens.type.controlLabel),
          SizedBox(width: tokens.spacing.gap / 2),
          const Icon(Icons.expand_more_rounded, size: 18),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    if (_loading && _works.isEmpty && _popular.isEmpty) {
      return Center(child: adaptiveIndicator(context: context));
    }
    if (_totalFailure && _works.isEmpty && _popular.isEmpty) {
      return HibikiPlaceholderMessage(
        icon: Icons.cloud_off_outlined,
        message: t.video_discovery_load_failed,
        action: FilledButton.icon(
          key: const ValueKey<String>('video-discovery-retry'),
          onPressed: () => unawaited(_reload()),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t.retry),
        ),
      );
    }

    final bool searchMode = _hasActiveSearchOrFilter;
    return CustomScrollView(
      key: const PageStorageKey<String>('video-discovery-scroll'),
      controller: _scrollController,
      slivers: <Widget>[
        if (_failures.isNotEmpty)
          SliverToBoxAdapter(child: _buildProviderWarning()),
        if (!searchMode && _popular.isNotEmpty)
          SliverToBoxAdapter(
            child: _DiscoveryShelf(
              key: const ValueKey<String>('video-discovery-popular'),
              title: t.video_discovery_hot,
              items: _popular,
              imageResolver: widget.imageResolver,
              onOpen: _openItem,
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
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              searchMode ? tokens.spacing.card : tokens.spacing.section,
              tokens.spacing.page,
              tokens.spacing.card,
            ),
            child: Text(
              searchMode
                  ? t.video_discovery_search_results
                  : t.video_discovery_all_works,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ),
        if (_works.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: HibikiPlaceholderMessage(
              icon: Icons.search_off_rounded,
              message: t.video_discovery_empty,
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: readerShelfGridExtentForWidth(
                  MediaQuery.sizeOf(context).width,
                ),
                mainAxisSpacing: tokens.spacing.gap,
                crossAxisSpacing: tokens.spacing.gap,
                childAspectRatio: 0.52,
              ),
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int index) => _DiscoveryMediaCard(
                  item: _works[index],
                  landscape: false,
                  imageResolver: widget.imageResolver,
                  onTap: () => _openItem(_works[index]),
                ),
                childCount: _works.length,
              ),
            ),
          ),
        if (_loadingMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.card),
              child: Center(child: adaptiveIndicator(context: context)),
            ),
          )
        else
          SliverToBoxAdapter(
            child: SizedBox(height: tokens.spacing.section),
          ),
      ],
    );
  }

  Widget _buildProviderWarning() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Set<String> providerIds =
        _failures.map((ExternalProviderFailure e) => e.providerId).toSet();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      child: HibikiCard(
        key: const ValueKey<String>('video-discovery-provider-warning'),
        color: Theme.of(context).colorScheme.tertiaryContainer,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.rowHorizontal,
          vertical: tokens.spacing.rowVertical,
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.cloud_off_outlined),
            SizedBox(width: tokens.spacing.gap),
            Expanded(child: Text(t.video_discovery_provider_warning)),
            if (providerIds.isNotEmpty)
              Text(
                providerIds.join(' · '),
                style: tokens.type.metadata,
              ),
          ],
        ),
      ),
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
        builder: (_) => VideoDiscoveryDetailPage(
          item: item,
          actions: widget.actions,
        ),
      ),
    );
  }

  List<int> get _availableYears {
    final int newest = DateTime.now().year + 2;
    final List<int> result = <int>{
      for (int year = newest; year >= 1900; year--) year,
      ..._knownYears,
    }.toList()
      ..sort((int a, int b) => b.compareTo(a));
    return result;
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
      ..._knownGenres,
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

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          SizedBox(height: tokens.spacing.card),
          SizedBox(
            height: 224,
            child: HorizontalDragScrollable(
              child: ListView.separated(
                key: PageStorageKey<String>('video-discovery-shelf-$title'),
                padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    SizedBox(width: tokens.spacing.gap),
                itemBuilder: (BuildContext context, int index) => SizedBox(
                  width: 260,
                  child: _DiscoveryMediaCard(
                    item: items[index],
                    landscape: true,
                    imageResolver: imageResolver,
                    onTap: () => onOpen(items[index]),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String stableId = item.reference.canonicalIdentityKey;
    final ImageProvider? image =
        imageResolver?.call(item, landscape) ?? _defaultImage(item, landscape);
    return HibikiCard(
      key: ValueKey<String>('video-discovery-card-$stableId'),
      focusId: HibikiFocusId('video-discovery-card-$stableId'),
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            aspectRatio: landscape ? 16 / 9 : 2 / 3,
            child: image == null
                ? ColoredBox(
                    color: tokens.surfaces.group,
                    child: const Center(child: Icon(Icons.movie_outlined)),
                  )
                : PortraitCoverImage(
                    image: image,
                    landscapeSlot: landscape,
                    errorBuilder: (_) => ColoredBox(
                      color: tokens.surfaces.group,
                      child: const Center(
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: EdgeInsets.all(tokens.spacing.gap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.reference.title,
                  maxLines: landscape ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
                Text(
                  _metadata(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _metadata(BuildContext context) => <String>[
        if (item.reference.year != null) '${item.reference.year}',
        switch (item.reference.discoveryCategory) {
          discovery.VideoDiscoveryCategory.movie => t.collection_relation_movie,
          discovery.VideoDiscoveryCategory.tv => t.series,
          discovery.VideoDiscoveryCategory.anime => t.media_tracking_anime,
        },
        if (item.score != null) '★ ${item.score!.toStringAsFixed(1)}',
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
    return value.isEmpty ? null : NetworkImage(value);
  }
}

class _FlattenedDiscoveryBatch {
  const _FlattenedDiscoveryBatch({
    required this.items,
    required this.hasMore,
  });

  final List<discovery.VideoDiscoveryItem> items;
  final bool hasMore;
}
