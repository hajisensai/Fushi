import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_routes.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/utils.dart';

/// 库 / 文件夹 / BoxSet 的分页网格；搜索框非空时改走 [MediaServerBrowser.search]
/// （同样分页），排序只对浏览生效。
///
/// 翻页**只认** [MediaServerPage.nextStartIndex]：实现侧滤掉非视频域类型后一页的
/// `items.length` 可能小于服务器实际返回的行数，自己拿 `startIndex + items.length`
/// 会把下一页前几条重复取回来（契约文档 + `media_server_grid_view_test`）。
class MediaServerGridView extends StatefulWidget {
  const MediaServerGridView({
    required this.session,
    required this.parentId,
    required this.title,
    super.key,
  });

  final MediaServerSession session;

  /// 媒体库 / 文件夹 / BoxSet id；null = 服务器根。
  final String? parentId;
  final String title;

  @override
  State<MediaServerGridView> createState() => _MediaServerGridViewState();
}

class _MediaServerGridViewState extends State<MediaServerGridView> {
  static const Duration _searchDebounce = Duration(milliseconds: 350);

  final TextEditingController _searchController = TextEditingController();
  late final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'media-server-grid-search-${widget.session.serverId}',
  );
  final ScrollController _scrollController = ScrollController();

  Timer? _debounce;

  /// 每次重置分页（换排序 / 换搜索词 / 重试）都 +1；旧请求回来时与它比对，过期就丢。
  int _generation = 0;
  MediaServerSort _sort = MediaServerSort.name;
  List<MediaServerItem> _items = const <MediaServerItem>[];
  int _nextStartIndex = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;

  /// 首页失败（整页错误 + 重试）与追加页失败（保留已有条目 + 底部重试）分开记。
  Object? _firstPageError;
  bool _loadMoreFailed = false;

  MediaServerBrowser get _browser => widget.session.browser;

  String get _query => _searchController.text.trim();

  bool get _searchMode => _query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_reload());
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
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 600) {
      unawaited(_loadMore());
    }
  }

  /// 一页落地后主动补拉：视口没铺满不会有滚动事件；而 `_items` 为空时根本没挂
  /// `CustomScrollView`（`hasClients == false`），[_onScroll] 会直接 return——搜索
  /// 把关后首页可以是「0 条命中但 hasMore」（BUG-2608 的第三种形状），这时要绕过
  /// 滚动控制器直接续扫，否则用户永远停在「无结果」。
  void _fillViewportAfterPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _onScroll();
      } else if (_hasMore) {
        unawaited(_loadMore());
      }
    });
  }

  Future<MediaServerPage> _fetch(int startIndex) {
    if (_searchMode) {
      return _browser.search(_query, startIndex: startIndex);
    }
    return _browser.listChildren(
      parentId: widget.parentId,
      startIndex: startIndex,
      sort: _sort,
    );
  }

  /// 重置分页并拉第一页。
  Future<void> _reload() async {
    final int generation = ++_generation;
    // 换排序 / 换搜索词是一份新清单：滚回顶部，否则旧偏移落在新清单尾部会立刻
    // 触发一次追加拉取，第一屏看到的是第二页。
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() {
      _loading = true;
      _loadingMore = false;
      _loadMoreFailed = false;
      _firstPageError = null;
      _items = const <MediaServerItem>[];
      _nextStartIndex = 0;
      _hasMore = false;
    });
    try {
      final MediaServerPage page = await _fetch(0);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = List<MediaServerItem>.unmodifiable(page.items);
        _nextStartIndex = page.nextStartIndex;
        _hasMore = page.hasMore;
        _loading = false;
      });
      // 首页没铺满视口时不会有滚动事件，主动再问一页（大字体 / 高窗口）。
      _fillViewportAfterPage();
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _firstPageError = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _loadMoreFailed) return;
    final int generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final MediaServerPage page = await _fetch(_nextStartIndex);
      if (!mounted || generation != _generation) return;
      // 进度守卫：服务器某页回 0 行且 nextStartIndex 没前进，而 totalCount 仍说
      // 有更多——下面的主动补拉会无限续请求，这里把它当作到尾。
      final bool advanced = page.nextStartIndex > _nextStartIndex;
      setState(() {
        _items = List<MediaServerItem>.unmodifiable(<MediaServerItem>[
          ..._items,
          ...page.items,
        ]);
        _nextStartIndex = page.nextStartIndex;
        _hasMore = page.hasMore && advanced;
        _loadingMore = false;
      });
      // 追加页也可能没铺满视口（搜索把关后一页可以只剩几条甚至 0 条，BUG-2608；
      // 浏览滤掉非视频域类型也一样），没有滚动事件就得主动再问一页。
      _fillViewportAfterPage();
    } catch (e) {
      if (!mounted || generation != _generation) return;
      debugPrint('[media-server] load more failed: $e');
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
      });
    }
  }

  void _retryLoadMore() {
    setState(() => _loadMoreFailed = false);
    unawaited(_loadMore());
  }

  void _scheduleSearch(String _) {
    _debounce?.cancel();
    // 输入一变就作废在途响应：等防抖到期再作废会让旧词的结果闪现一帧。
    _generation += 1;
    _debounce = Timer(_searchDebounce, () => unawaited(_reload()));
  }

  void _submitSearch(String _) {
    _debounce?.cancel();
    unawaited(_reload());
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    unawaited(_reload());
  }

  void _changeSort(MediaServerSort? value) {
    if (value == null || value == _sort) return;
    setState(() => _sort = value);
    unawaited(_reload());
  }

  String _sortLabel(MediaServerSort sort) => switch (sort) {
    MediaServerSort.name => t.media_server_sort_name,
    MediaServerSort.dateAdded => t.media_server_sort_date_added,
    MediaServerSort.premiereDate => t.video_discovery_sort_release,
    MediaServerSort.communityRating => t.video_discovery_sort_rating,
  };

  @override
  Widget build(BuildContext context) {
    // 本视图是嵌套 Navigator 里的一条路由：没有 Scaffold 就没有 Material 祖先。
    return Scaffold(
      body: Column(
        children: <Widget>[
          FushiPageHeader(
            title: widget.title,
            compact: true,
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          _buildControls(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String prefix = widget.session.serverId;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        0,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: FushiSearchField(
              fieldKey: const ValueKey<String>('media-server-grid-search'),
              clearButtonKey: const ValueKey<String>(
                'media-server-grid-search-clear',
              ),
              focusId: FushiFocusId('$prefix-grid-search'),
              controller: _searchController,
              focusNode: _searchFocusNode,
              hintText: t.media_server_search_hint,
              onChanged: _scheduleSearch,
              onSubmitted: _submitSearch,
              onClear: _clearSearch,
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          // 搜索走服务器的相关度序，排序只对浏览生效；搜索态禁用而不是藏起来。
          // 下拉里是 DropdownMenu（InputDecorator），在 Row 里必须给定宽。
          SizedBox(
            width: 180,
            child: FushiDropdown<MediaServerSort>(
              key: const ValueKey<String>('media-server-grid-sort'),
              options: MediaServerSort.values,
              initialOption: _sort,
              generateLabel: _sortLabel,
              onChanged: _changeSort,
              enabled: !_searchMode,
              focusId: FushiFocusId('$prefix-grid-sort'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (_loading && _items.isEmpty) {
      return Center(child: adaptiveIndicator(context: context));
    }
    if (_firstPageError != null && _items.isEmpty) {
      return FushiPlaceholderMessage(
        icon: Icons.cloud_off_outlined,
        message: t.media_server_items_load_failed,
        detail: '$_firstPageError',
        action: FilledButton.icon(
          key: const ValueKey<String>('media-server-grid-retry'),
          onPressed: () => unawaited(_reload()),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t.retry),
        ),
      );
    }
    if (_items.isEmpty && (_hasMore || _loadingMore)) {
      // 首页 0 条但服务器还有后续页（搜索把关后常见）：续扫期间显示进度而不是
      // 先闪一下「无结果」。
      return Center(child: adaptiveIndicator(context: context));
    }
    if (_items.isEmpty) {
      return FushiPlaceholderMessage(
        icon: _searchMode
            ? Icons.search_off_rounded
            : Icons.video_library_outlined,
        message: _searchMode
            ? t.video_discovery_empty
            : t.media_server_items_empty,
      );
    }
    final String prefix = widget.session.serverId;
    return CustomScrollView(
      key: PageStorageKey<String>('$prefix-grid-${widget.parentId ?? 'root'}'),
      controller: _scrollController,
      slivers: <Widget>[
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
          sliver: SliverLayoutBuilder(
            builder: (BuildContext context, SliverConstraints constraints) {
              // 行高按「实际列宽 × 3/2（2:3 海报）+ 文字块」精确给：发现页那种
              // `childAspectRatio: 0.50` 是把文字区按列宽的一半留，桌面 210 列宽下
              // 文字块只要 ~60，卡片底部空出一截（像素预览实测）。列数与
              // [SliverGridDelegateWithMaxCrossAxisExtent] 同一算法（ceil）。
              final double gap = tokens.spacing.gap;
              final double maxExtent = readerShelfGridExtentForWidth(
                MediaQuery.sizeOf(context).width,
              );
              final double width = constraints.crossAxisExtent;
              final int columns = ((width + gap) / (maxExtent + gap))
                  .ceil()
                  .clamp(1, 1 << 16)
                  .toInt();
              final double cardWidth = (width - gap * (columns - 1)) / columns;
              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: gap,
                  crossAxisSpacing: gap,
                  mainAxisExtent:
                      cardWidth * 3 / 2 + mediaServerCardTextBlock(context),
                ),
                delegate: _cardDelegate(context, prefix),
              );
            },
          ),
        ),
        if (_loadingMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.card),
              child: Center(child: adaptiveIndicator(context: context)),
            ),
          )
        else if (_loadMoreFailed)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.card),
              child: Center(
                child: TextButton.icon(
                  key: const ValueKey<String>('media-server-grid-retry-more'),
                  onPressed: _retryLoadMore,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(t.retry),
                ),
              ),
            ),
          )
        else
          SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.section)),
      ],
    );
  }

  SliverChildBuilderDelegate _cardDelegate(
    BuildContext context,
    String prefix,
  ) => SliverChildBuilderDelegate((BuildContext context, int index) {
    final MediaServerItem item = _items[index];
    return MediaServerItemCard(
      key: ValueKey<String>('media-server-grid-card-${item.id}'),
      browser: _browser,
      item: item,
      focusId: FushiFocusId('$prefix-grid-card-${item.id}'),
      onTap: () =>
          openMediaServerItem(context, widget.session, item, siblings: _items),
      onLongPress: () =>
          openMediaServerItemDetail(context, widget.session, item),
    );
  }, childCount: _items.length);
}
