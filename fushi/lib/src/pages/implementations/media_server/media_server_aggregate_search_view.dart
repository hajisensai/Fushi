import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_routes.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show shellContentLayoutOf, shellRedesignActive;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockSize;
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show SliverFushiCoverBlocks;
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';

/// 一台服务器对一次搜索的结果：命中的第一页，或这台失败的原因。失败只属于这一台，
/// 不影响其它服务器的结果（[searchMediaServerSession] 把它收成数据而不是抛出）。
class MediaServerSearchOutcome {
  const MediaServerSearchOutcome.hits(this.session, this.page) : error = null;

  const MediaServerSearchOutcome.failed(this.session, Object this.error)
    : page = null;

  final MediaServerSession session;
  final MediaServerPage? page;
  final Object? error;

  List<MediaServerItem> get items => page?.items ?? const <MediaServerItem>[];

  /// 这台还有下一页：行尾出「查看全部」进这台的完整搜索网格。
  bool get hasMore => page?.hasMore ?? false;
}

/// 在一台服务器上搜 [query] 的第一页；失败收进结果（聚合搜索里每台互不连累）。
Future<MediaServerSearchOutcome> searchMediaServerSession(
  MediaServerSession session,
  String query,
) async {
  try {
    return MediaServerSearchOutcome.hits(
      session,
      await session.browser.search(query),
    );
  } on Object catch (error) {
    debugPrint('[media-server] search failed on ${session.serverId}: $error');
    return MediaServerSearchOutcome.failed(session, error);
  }
}

/// 打开「搜索所有服务器」。
void openMediaServerAggregateSearch(
  BuildContext context,
  List<MediaServerSession> sessions,
) {
  // 二级页面：与服务器首页同样压在根 Navigator 上（分区列表页也能直接打开）。
  Navigator.of(context, rootNavigator: true).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => MediaServerAggregateSearchView(sessions: sessions),
    ),
  );
}

/// 同时在多台媒体服务器上搜索（用户反馈 WzyI2H87rw）：每台并发发第一页，按服务器
/// 分组成一条横滚行，先回来的先显示；某台失败只在它那一组里显示错误 + 重试。行尾
/// 「查看全部」进那台服务器的搜索网格（带上同一个关键词，分页照旧）。
class MediaServerAggregateSearchView extends StatefulWidget {
  const MediaServerAggregateSearchView({required this.sessions, super.key});

  final List<MediaServerSession> sessions;

  @override
  State<MediaServerAggregateSearchView> createState() =>
      _MediaServerAggregateSearchViewState();
}

class _MediaServerAggregateSearchViewState
    extends State<MediaServerAggregateSearchView> {
  static const Duration _searchDebounce = Duration(milliseconds: 350);

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'media-server-aggregate-search',
  );
  Timer? _debounce;

  /// 当前这次搜索的关键词；空 = 还没搜。
  String _query = '';

  /// 每次换词 +1：旧词的结果晚回来时与它比对，过期就丢。也是进场窗口的 replayKey。
  int _generation = 0;

  /// serverId → 结果；缺项 = 这台还在搜。
  final Map<String, MediaServerSearchOutcome> _outcomes =
      <String, MediaServerSearchOutcome>{};

  @override
  void dispose() {
    _debounce?.cancel();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _scheduleSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, _search);
  }

  void _submitSearch(String _) {
    _debounce?.cancel();
    _search();
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    _search();
  }

  void _search() {
    final String query = _searchController.text.trim();
    final int generation = ++_generation;
    setState(() {
      _query = query;
      _outcomes.clear();
    });
    if (query.isEmpty) return;
    for (final MediaServerSession session in widget.sessions) {
      unawaited(_searchOne(session, query, generation));
    }
  }

  Future<void> _searchOne(
    MediaServerSession session,
    String query,
    int generation,
  ) async {
    final MediaServerSearchOutcome outcome = await searchMediaServerSession(
      session,
      query,
    );
    if (!mounted || generation != _generation) return;
    setState(() => _outcomes[session.serverId] = outcome);
  }

  void _retry(MediaServerSession session) {
    setState(() => _outcomes.remove(session.serverId));
    unawaited(_searchOne(session, _query, _generation));
  }

  Widget _searchBar() => FushiSearchBar(
    fieldKey: const ValueKey<String>('media-server-aggregate-search'),
    clearButtonKey: const ValueKey<String>(
      'media-server-aggregate-search-clear',
    ),
    focusId: const FushiFocusId('media-server-aggregate-search'),
    controller: _searchController,
    focusNode: _searchFocusNode,
    hintText: t.media_server_search_hint,
    autofocus: true,
    onQueryChanged: _scheduleSearch,
    onSubmitted: _submitSearch,
    onClear: _clearSearch,
  );

  @override
  Widget build(BuildContext context) {
    final bool redesign = shellRedesignActive(context);
    return MediaServerPageShell(
      title: t.media_server_search_all,
      legacyHeader: FushiPageHeader(
        title: t.media_server_search_all,
        compact: true,
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
        bottom: redesign ? null : _searchBar(),
      ),
      // 页头大字下搜索框是正文顶上固定的一行（换词时结果区重建，输入框不动）。
      body: (BuildContext context, double top) {
        if (!redesign) return _buildBody(top);
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(height: top),
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                0,
                tokens.spacing.page,
                tokens.spacing.gap,
              ),
              child: _searchBar(),
            ),
            Expanded(child: _buildBody(0)),
          ],
        );
      },
    );
  }

  Widget _buildBody(double top) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (_query.isNotEmpty && mediaServerBlocksActive(context)) {
      return _buildBlockBody(tokens, top);
    }
    if (_query.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: FushiPlaceholderMessage(
          icon: FushiIcons.travelExplore,
          message: t.media_server_search_hint,
        ),
      );
    }
    return FushiEntranceScope(
      replayKey: _generation,
      child: CustomScrollView(
        key: const PageStorageKey<String>('media-server-aggregate-search'),
        slivers: <Widget>[
          SliverToBoxAdapter(child: SizedBox(height: top)),
          for (final MediaServerSession session in widget.sessions)
            SliverToBoxAdapter(
              key: ValueKey<String>(
                'media-server-aggregate-group-${session.serverId}',
              ),
              child: _buildGroup(session, tokens),
            ),
          SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(
              child: SizedBox(height: tokens.spacing.section),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroup(MediaServerSession session, FushiDesignTokens tokens) {
    final MediaServerSearchOutcome? outcome = _outcomes[session.serverId];
    final String name = session.browser.displayName;
    if (outcome == null) {
      return _groupMessage(
        tokens,
        name,
        FushiSkeletonShimmer(
          child: SizedBox(
            height: mediaServerRowCardHeight(context),
            child: Row(
              children: <Widget>[
                for (int i = 0; i < 3; i++) ...<Widget>[
                  const SizedBox(
                    width: kMediaServerRowCardWidth,
                    child: MediaServerPosterSkeleton(),
                  ),
                  SizedBox(width: tokens.spacing.card),
                ],
              ],
            ),
          ),
        ),
      );
    }
    final Object? error = outcome.error;
    if (error != null) {
      return _groupMessage(
        tokens,
        name,
        FushiPlaceholderMessage(
          icon: FushiIcons.cloudOff,
          tone: FushiPlaceholderTone.error,
          message: t.media_server_items_load_failed,
          detail: '$error',
          action: FushiTextButton.icon(
            key: ValueKey<String>(
              'media-server-aggregate-retry-${session.serverId}',
            ),
            onPressed: () => _retry(session),
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(t.retry),
          ),
        ),
      );
    }
    final List<MediaServerItem> items = outcome.items;
    if (items.isEmpty && !outcome.hasMore) {
      return _groupMessage(
        tokens,
        name,
        Text(t.video_discovery_empty, style: tokens.type.metadata),
      );
    }
    final String storageKey = '${session.serverId}-aggregate-search';
    return MediaServerRow(
      title: name,
      storageKey: storageKey,
      itemCount: items.length,
      itemWidth: kMediaServerRowCardWidth,
      rowHeight: mediaServerRowCardHeight(context),
      onViewAll: () => openMediaServerGrid(
        context,
        session,
        parentId: null,
        title: name,
        initialQuery: _query,
      ),
      viewAllFocusId: FushiFocusId('$storageKey-all'),
      itemBuilder: (BuildContext context, int index) {
        final MediaServerItem item = items[index];
        return MediaServerItemCard(
          key: ValueKey<String>('$storageKey-card-${item.id}'),
          browser: session.browser,
          item: item,
          focusId: FushiFocusId('$storageKey-card-${item.id}'),
          onTap: () =>
              openMediaServerItem(context, session, item, siblings: items),
          onLongPress: () => openMediaServerItemDetail(context, session, item),
        );
      },
    );
  }

  /// 重设计外壳、库页布局为拼贴 / 规整色块时的结果：每台服务器一段——色块分区
  /// 标题（有结果时行尾「查看全部」）+ 一行封面色块（拼贴首块 + 半高卡 / 一行
  /// 规整块；其余进那台的搜索网格）。搜索中是一行色块骨架，失败 / 无结果是一段
  /// 文字，与原版式同一套状态。
  Widget _buildBlockBody(FushiDesignTokens tokens, double top) {
    return FushiEntranceScope(
      replayKey: _generation,
      child: CustomScrollView(
        key: const PageStorageKey<String>('media-server-aggregate-search'),
        slivers: <Widget>[
          SliverToBoxAdapter(child: SizedBox(height: top)),
          for (final MediaServerSession session in widget.sessions)
            ..._blockGroupSlivers(session, tokens),
          SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(
              child: SizedBox(height: tokens.spacing.section),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _blockGroupSlivers(
    MediaServerSession session,
    FushiDesignTokens tokens,
  ) {
    final MediaServerSearchOutcome? outcome = _outcomes[session.serverId];
    final String name = session.browser.displayName;
    final String storageKey = '${session.serverId}-aggregate-search';
    final List<MediaServerItem> items =
        outcome?.items ?? const <MediaServerItem>[];
    // 「查看全部」：这台搜到了东西（或首页被把关滤空但还有后续页）。
    final bool canViewAll =
        outcome != null &&
        outcome.error == null &&
        (outcome.items.isNotEmpty || outcome.hasMore);
    final EdgeInsets inset = EdgeInsets.symmetric(
      horizontal: tokens.spacing.page,
    );
    final Widget content;
    if (outcome == null) {
      content = SliverPadding(
        padding: inset,
        sliver: const SliverToBoxAdapter(
          child: FushiSkeletonShimmer(child: MediaServerBlockSkeleton()),
        ),
      );
    } else if (outcome.error != null) {
      content = SliverToBoxAdapter(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.cloudOff,
          tone: FushiPlaceholderTone.error,
          message: t.media_server_items_load_failed,
          detail: '${outcome.error}',
          action: FushiTextButton.icon(
            key: ValueKey<String>(
              'media-server-aggregate-retry-${session.serverId}',
            ),
            onPressed: () => _retry(session),
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(t.retry),
          ),
        ),
      );
    } else if (items.isEmpty) {
      content = SliverPadding(
        padding: inset,
        sliver: SliverToBoxAdapter(
          child: outcome.hasMore
              ? const FushiSkeletonShimmer(child: MediaServerBlockSkeleton())
              : Text(t.video_discovery_empty, style: tokens.type.metadata),
        ),
      );
    } else {
      content = SliverPadding(
        padding: inset,
        sliver: SliverFushiCoverBlocks(
          layout: shellContentLayoutOf(context),
          itemCount: items.length,
          maxRows: 1,
          itemBuilder:
              (BuildContext context, int index, FushiCoverBlockSize size) {
                final MediaServerItem item = items[index];
                return MediaServerItemBlock(
                  key: ValueKey<String>('$storageKey-card-${item.id}'),
                  browser: session.browser,
                  item: item,
                  size: size,
                  focusId: FushiFocusId('$storageKey-card-${item.id}'),
                  onTap: () => openMediaServerItem(
                    context,
                    session,
                    item,
                    siblings: items,
                  ),
                  onLongPress: () =>
                      openMediaServerItemDetail(context, session, item),
                );
              },
        ),
      );
    }
    return <Widget>[
      SliverToBoxAdapter(
        key: ValueKey<String>(
          'media-server-aggregate-group-${session.serverId}',
        ),
        child: MediaServerBlockSectionTitle(
          name,
          onViewAll: canViewAll
              ? () => openMediaServerGrid(
                  context,
                  session,
                  parentId: null,
                  title: name,
                  initialQuery: _query,
                )
              : null,
          viewAllFocusId: FushiFocusId('$storageKey-all'),
        ),
      ),
      content,
    ];
  }

  /// 没有卡片可排的一组（搜索中 / 失败 / 无结果）：同款区块标题 + 一段内容。
  Widget _groupMessage(FushiDesignTokens tokens, String title, Widget child) {
    return FushiStaggeredEntrance(
      index: 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSectionTitle(
            title,
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.section,
              tokens.spacing.page,
              tokens.spacing.gap / 2,
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
