/// 三域在线源（小说 LNReader / 漫画 Mihon / 视频 Aniyomi）共用的源浏览页。
///
/// 2026-09-27「浏览」阶段 2：此前 `MihonSourceBrowsePage`、`LnReaderSourceBrowsePage`
/// 与已移除的 Aidoku 源浏览页是三份「形状照抄」的拷贝（注释里各自写着「版式与 Mihon
/// 一致」），每处修复都要改三遍。现在页面只有这一份，差异全部收进
/// [OnlineSourceCatalog] 适配器：
/// - 浏览列表：Mihon / LNReader 是「热门 / 最新」；
/// - 筛选：弹什么框、应用后落到搜索（Mihon）还是回到第一个列表（LNReader 的筛选作用
///   在热门上）；
/// - 封面取图、详情页、Cloudflare 验证入口。
///
/// 交互以视频侧为准：页头搜索框回车搜、筛选按钮；列表分段；2~8 列封面网格；
/// **滚到离底 600 以内自动加载下一页**（视频发现页的口径），末尾那格「加载更多」
/// 保留作键盘 / 手柄可达的兜底。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 一个浏览列表（「热门」「最新」或源声明的 listing）。
@immutable
class OnlineBrowseListing {
  const OnlineBrowseListing({required this.id, required this.label});

  final String id;
  final String label;
}

/// 一次取页的查询：[listingId] 为 null = 搜索（用 [text]）。
@immutable
class OnlineBrowseQuery {
  const OnlineBrowseQuery.listing(String this.listingId)
    : text = '',
      filtered = false;
  const OnlineBrowseQuery.search(this.text)
    : listingId = null,
      filtered = false;
  const OnlineBrowseQuery._({
    required this.listingId,
    required this.text,
    required this.filtered,
  });

  final String? listingId;
  final String text;

  /// 用户是否动过筛选（LNReader 只在动过后才把筛选值带给插件）。
  final bool filtered;

  bool get isSearch => listingId == null;

  OnlineBrowseQuery withFiltered() =>
      OnlineBrowseQuery._(listingId: listingId, text: text, filtered: true);
}

/// 一页结果。
typedef OnlineBrowsePageResult<T> = ({List<T> items, bool hasNextPage});

/// 应用筛选后浏览页落到哪儿。
enum OnlineBrowseFilterTarget {
  /// 切到搜索（Mihon：筛选只作用在 search 上）。
  search,

  /// 回到第一个列表并清空搜索词（LNReader：筛选作用在热门上）。
  firstListing,
}

/// 一个源在浏览页里的全部差异。
abstract class OnlineSourceCatalog<T> {
  /// 页面标题（源名）。
  String get title;

  /// 搜索框占位。
  String get searchHint;

  /// 控件 key 前缀（`<prefix>_search_field` / `_filters` / `_more` / `_item_<key>`）。
  String get keyPrefix;

  /// 进页准备：解析源上下文、拉筛选定义 / 列表清单。失败直接抛，页面显示错误。
  Future<void> prepare();

  /// 浏览列表，[prepare] 之后有效。空 = 只能搜索。
  List<OnlineBrowseListing> get listings;

  /// 有没有筛选可调（[prepare] 之后有效）。
  bool get hasFilters;

  /// 弹筛选框；返回 null = 取消。
  Future<OnlineBrowseFilterTarget?> editFilters(BuildContext context);

  Future<OnlineBrowsePageResult<T>> fetch(OnlineBrowseQuery query, int page);

  /// 条目的稳定身份（去重、控件 key）。
  String keyOf(T item);
  String titleOf(T item);
  Widget buildCover(BuildContext context, T item);

  /// 点封面进详情；null = 只读（试用预览）。
  void Function(BuildContext context, T item)? get openDetail;

  /// 失败给用户看的一句话（行内错误与 toast 共用）。
  ///
  /// 2026-10 体验优化：原先页面直接 `'$error'`，[buildVerifyAction]
  /// 又把同一个错误再画一遍，同一句话上下出现两次。文案只从这里出，
  /// [buildVerifyAction] 只负责「可点的验证入口」，不再重复画错误文字。
  String describeError(Object error) => describeOnlineSourceError(error);

  /// Cloudflare 等站点验证入口；没有待解挑战时返回空占位即可。不要在这里
  /// 再画错误文字（页面已用 [describeError] 画过一次）。
  Widget buildVerifyAction(
    BuildContext context, {
    required Object? error,
    required Future<void> Function() onVerified,
  });

  /// 结果为空时也给验证入口（LNReader 插件被拦时多半只回空列表、不抛错）。
  bool get verifyOnEmpty => false;

  /// 空搜索词不发请求。
  bool get searchRequiresQuery => false;

  /// 切列表时清空搜索框。
  bool get clearQueryOnListingChange => false;

  /// 源不报「还有下一页」时，按「这一页有新条目」推断。
  bool resolveHasNextPage({
    required bool reported,
    required bool reset,
    required int received,
    required int added,
  }) => reported && received > 0 && (reset || added > 0);

  String get emptyText => t.mihon_source_no_results;

  /// 筛选按钮的提示（各源沿用自己原来的叫法：Mihon 叫「来源偏好」，LNReader 叫
  /// 「筛选」）。
  String get filtersTooltip => t.mihon_source_preferences;

  void dispose() {}
}

/// 离底多少像素开始自动加载下一页（与视频发现页同值）。
const double kOnlineBrowseAutoLoadExtent = 600;

class OnlineSourceBrowsePage<T> extends StatefulWidget {
  const OnlineSourceBrowsePage({required this.catalog, super.key, this.footer});

  final OnlineSourceCatalog<T> catalog;

  /// 钉在正文底部的操作条（试用预览的「放弃 / 信任并安装」）。
  ///
  /// BUG-2440：scaffold 的 body 不再扣底部安全区，**底部安全区由 footer 自己套
  /// SafeArea 补**，这里不代劳。
  final Widget? footer;

  @override
  State<OnlineSourceBrowsePage<T>> createState() =>
      _OnlineSourceBrowsePageState<T>();
}

class _OnlineSourceBrowsePageState<T> extends State<OnlineSourceBrowsePage<T>> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _prepared = false;
  List<T> _items = <T>[];
  String? _listingId;
  bool _filtered = false;
  bool _loading = true;
  bool _hasNextPage = false;
  int _page = 1;
  int _generation = 0;
  Object? _error;

  OnlineSourceCatalog<T> get _catalog => widget.catalog;

  @override
  void initState() {
    super.initState();
    unawaited(_initialise());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _catalog.dispose();
    super.dispose();
  }

  Future<void> _initialise() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _catalog.prepare();
      if (!mounted) return;
      _prepared = true;
      _listingId = _catalog.listings.isEmpty
          ? null
          : _catalog.listings.first.id;
      await _load(reset: true);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('OnlineSourceBrowse.prepare', error, stack);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  OnlineBrowseQuery _currentQuery() {
    final String? listing = _listingId;
    final OnlineBrowseQuery query = listing == null
        ? OnlineBrowseQuery.search(_searchController.text.trim())
        : OnlineBrowseQuery.listing(listing);
    return _filtered ? query.withFiltered() : query;
  }

  Future<void> _load({required bool reset}) async {
    if (!_prepared) return;
    if (!reset && (_loading || !_hasNextPage)) return;
    final int generation = reset ? ++_generation : _generation;
    if (reset) _autoLoadMaxExtent = null;
    final int requestedPage = reset ? 1 : _page + 1;
    final OnlineBrowseQuery query = _currentQuery();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final OnlineBrowsePageResult<T> response = await _catalog.fetch(
        query,
        requestedPage,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        final List<T> previous = reset ? <T>[] : _items;
        final Set<String> seen = previous.map(_catalog.keyOf).toSet();
        final List<T> additions = response.items
            .where((T item) => seen.add(_catalog.keyOf(item)))
            .toList(growable: false);
        _items = <T>[...previous, ...additions];
        _page = requestedPage;
        _hasNextPage = _catalog.resolveHasNextPage(
          reported: response.hasNextPage,
          reset: reset,
          received: response.items.length,
          added: additions.length,
        );
        _loading = false;
      });
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('OnlineSourceBrowse.load', error, stack);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error;
      });
      // 已有结果时行内错误不出现（只在空列表时画），这里用 toast；两者互斥。
      if (_items.isNotEmpty) {
        FushiToast.show(
          msg: _catalog.describeError(error),
          severity: ToastSeverity.error,
        );
      }
    }
  }

  Future<void> _retry() => _prepared ? _load(reset: true) : _initialise();

  void _search(String value) {
    if (_catalog.searchRequiresQuery && value.trim().isEmpty) return;
    _listingId = null;
    unawaited(_load(reset: true));
  }

  void _selectListing(String id) {
    _listingId = id;
    if (_catalog.clearQueryOnListingChange) _searchController.clear();
    unawaited(_load(reset: true));
  }

  Future<void> _showFilters() async {
    final OnlineBrowseFilterTarget? target = await _catalog.editFilters(
      context,
    );
    if (target == null || !mounted) return;
    _filtered = true;
    switch (target) {
      case OnlineBrowseFilterTarget.search:
        _listingId = null;
      case OnlineBrowseFilterTarget.firstListing:
        _searchController.clear();
        _listingId = _catalog.listings.isEmpty
            ? null
            : _catalog.listings.first.id;
    }
    await _load(reset: true);
  }

  /// 上一次自动翻页时的可滚动总高度。
  ///
  /// 同一次拖动里后续的滚动通知带的仍是**新页布局前**的度量：源响应很快（命中
  /// 缓存）时 `_loading` 已经回落，这些旧度量照样「离底 < 600」，就会接连再翻一页。
  /// 只有 maxScrollExtent 变了（新一页真的排进了网格）才允许下一次自动翻页。
  double? _autoLoadMaxExtent;

  bool _onScroll(ScrollNotification notification) {
    final ScrollMetrics metrics = notification.metrics;
    if (metrics.axis == Axis.vertical &&
        metrics.extentAfter < kOnlineBrowseAutoLoadExtent &&
        metrics.maxScrollExtent != _autoLoadMaxExtent &&
        _hasNextPage &&
        !_loading) {
      _autoLoadMaxExtent = metrics.maxScrollExtent;
      unawaited(_load(reset: false));
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final String prefix = _catalog.keyPrefix;
    final List<OnlineBrowseListing> listings = _prepared
        ? _catalog.listings
        : const <OnlineBrowseListing>[];
    return FushiPageScaffold(
      title: _catalog.title,
      // 列表分段条与验证入口原本固定在正文顶部：页头浮在正文上之后（脚手架默认
      // extendBodyBehindHeader）会被胶囊盖住，所以随页头一起进 headerBottom，
      // 按「搜索 → 分段 → 验证」纵向堆叠；网格自己让开顶部。
      headerBottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: <Widget>[
                // 共享 M3E 搜索栏（焦点登记 / 回车兜底 / Esc 清空 / 移动端收键盘与
                // 其它搜索框一致）。仍是「提交才搜」，不挂 onQueryChanged。
                Expanded(
                  child: FushiSearchBar(
                    fieldKey: ValueKey<String>('${prefix}_search_field'),
                    focusId: FushiFocusId('$prefix-online-browse-search'),
                    controller: _searchController,
                    focusNode: _searchFocus,
                    hintText: _catalog.searchHint,
                    onSubmitted: _search,
                    onClear: () {
                      _searchController.clear();
                      _search('');
                    },
                  ),
                ),
                if (_prepared && _catalog.hasFilters) ...<Widget>[
                  const SizedBox(width: 8),
                  FushiIconButtonControl.filledTonal(
                    key: ValueKey<String>('${prefix}_filters'),
                    tooltip: _catalog.filtersTooltip,
                    onPressed: _showFilters,
                    icon: const FushiIcon(FushiIcons.filter),
                  ),
                ],
              ],
            ),
          ),
          if (listings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FushiSegmentedStrip<String>(
                key: ValueKey<String>('${prefix}_listing'),
                segments: <ButtonSegment<String>>[
                  for (final OnlineBrowseListing listing in listings)
                    ButtonSegment<String>(
                      value: listing.id,
                      label: Text(listing.label),
                    ),
                ],
                // 搜索态没有列表被选中；分段条仍停在最近的列表上，免得一片空白。
                selected: _listingId ?? listings.first.id,
                onChanged: _selectListing,
                alignment: Alignment.centerLeft,
              ),
            ),
          if (_error != null && _items.isNotEmpty)
            _catalog.buildVerifyAction(
              context,
              error: _error,
              onVerified: () => _load(reset: false),
            ),
        ],
      ),
      // 正文用 body 子树里的 context 构建，才读得到脚手架下发的顶部让位。
      body: widget.footer == null
          ? Builder(builder: _buildResults)
          : Column(
              children: <Widget>[
                // BUG-2440：有 footer 时底部安全区归 footer 自己的 SafeArea 认领，
                // 先从网格的 MediaQuery 里摘掉，免得两边各补一次。
                Expanded(
                  child: Builder(
                    builder: (BuildContext context) => MediaQuery.removePadding(
                      context: context,
                      removeBottom: true,
                      child: Builder(builder: _buildResults),
                    ),
                  ),
                ),
                widget.footer!,
              ],
            ),
    );
  }

  Widget _buildResults(BuildContext context) {
    // 加载 = 与封面网格同轮廓的骨架；错误 / 空态统一 FushiPlaceholderMessage
    // （错误走 errorContainer 色块）。
    if (_loading && _items.isEmpty) {
      return _buildSkeleton();
    }
    final Object? error = _error;
    if (error != null && _items.isEmpty) {
      return SafeArea(
        bottom: false,
        child: FushiPlaceholderMessage(
          key: ValueKey<String>('${_catalog.keyPrefix}_error'),
          icon: FushiIcons.error,
          tone: FushiPlaceholderTone.error,
          message: _catalog.describeError(error),
          action: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiFilledButton.tonalIcon(
                onPressed: () => unawaited(_retry()),
                icon: const FushiIcon(FushiIcons.refresh),
                label: Text(t.retry),
              ),
              const SizedBox(height: 8),
              _catalog.buildVerifyAction(
                context,
                error: error,
                onVerified: _retry,
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return SafeArea(
        bottom: false,
        child: FushiPlaceholderMessage(
          icon: FushiIcons.searchOff,
          message: _catalog.emptyText,
          action: _catalog.verifyOnEmpty
              ? _catalog.buildVerifyAction(
                  context,
                  error: null,
                  onVerified: _retry,
                )
              : null,
        ),
      );
    }
    final String prefix = _catalog.keyPrefix;
    final void Function(BuildContext, T)? open = _catalog.openDetail;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: FushiEntranceScope(
            child: GridView.builder(
              // BUG-2440：scaffold 的 body 不再扣底部安全区，网格最后一行要靠这里
              // 补出手势条那一段；有 footer 时上面已摘掉，这里自动退回纯 16。
              padding: withBottomSafeInset(
                context,
                EdgeInsets.fromLTRB(
                  16,
                  16 + MediaQuery.paddingOf(context).top,
                  16,
                  16,
                ),
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                childAspectRatio: 0.62,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _items.length + (_hasNextPage ? 1 : 0),
              itemBuilder: fushiStaggeredItemBuilder((
                BuildContext context,
                int index,
              ) {
                if (index == _items.length) {
                  return Center(
                    child: _loading
                        ? adaptiveIndicator(context: context)
                        : FushiIconButtonControl.filledTonal(
                            key: ValueKey<String>('${prefix}_more'),
                            size: FushiIconButtonSize.m,
                            onPressed: () => unawaited(_load(reset: false)),
                            icon: const FushiIcon(FushiIcons.add),
                          ),
                  );
                }
                final T item = _items[index];
                return FushiCard(
                  key: ValueKey<String>(
                    '${prefix}_item_${_catalog.keyOf(item)}',
                  ),
                  padding: EdgeInsets.zero,
                  onTap: open == null ? null : () => open(context, item),
                  // FushiCard 内部已按同一圆角 token 裁剪，这里不再多包 ClipRRect。
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(child: _catalog.buildCover(context, item)),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                        child: Text(
                          _catalog.titleOf(item),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.fushiType.titleSmall,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        );
      },
    );
  }

  /// 首屏加载骨架：与结果网格同列数、同比例的封面块 + 两条标题条，整组共享
  /// 一道有界闪光。
  Widget _buildSkeleton() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return FushiSkeletonShimmer(
          child: GridView.builder(
            key: ValueKey<String>('${_catalog.keyPrefix}_skeleton'),
            primary: false,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16,
              16 + MediaQuery.paddingOf(context).top,
              16,
              16,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              childAspectRatio: 0.62,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: columns * 3,
            itemBuilder: (BuildContext context, int index) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: FushiSkeleton(borderRadius: FushiM3eShape.cardRadius),
                ),
                const SizedBox(height: 10),
                FushiSkeleton.line(widthFactor: 0.9),
                const SizedBox(height: 6),
                FushiSkeleton.line(widthFactor: 0.5),
              ],
            ),
          ),
        );
      },
    );
  }
}
