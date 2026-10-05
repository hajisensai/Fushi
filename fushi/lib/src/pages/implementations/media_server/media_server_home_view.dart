import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_routes.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 一台服务器的首页（2026-10 重做）：页头（连接状态点 + 服务器名 + 切换服务器
/// 菜单）→「继续观看」横滚行（16:9 卡 + 进度，Resume ∪ NextUp 去重）→「媒体库」
/// 背景图卡网格 → 每个库一行「该库最新」+ 行尾「查看全部」进库网格。整页在一个
/// 进场窗口里错峰淡入，重试 / 刷新时重开窗口。
///
/// **每库一行取的是 `/Items/Latest?ParentId=<库>`（剧按系列聚合）**，与 Emby /
/// Jellyfin 官方及主流第三方客户端的首页同形：一行海报，剧卡带未看数角标。此前取
/// 的是库的直接子级（`/Items?ParentId=<库>`），按文件夹组织的库（「动漫」库下面是
/// 「完结动漫 / 新番完结」几个物理文件夹）一行全是灰色文件夹卡。只有服务器没有
/// Latest 端点（飞牛等兼容层，装饰行失败即空）时才退回直接子级。没有单独的全服
/// 「最近添加」行：它就是各库最新行的并集，重复一遍只多一发请求。
///
/// [MediaServerBrowser.listLibraries] 是主干：失败整页错误 + 重试，同时决定页头
/// 的连接状态点。其余都是装饰行：失败即空、该行不显示（契约文档的两档失败语义）。
class MediaServerHomeView extends StatefulWidget {
  const MediaServerHomeView({
    required this.session,
    this.showBackButton = false,
    this.servers = const <MediaServerBrowser>[],
    this.onSwitchServer,
    super.key,
  });

  final MediaServerSession session;

  /// 多台服务器时首页压在服务器列表之上，页头给一个返回箭头；单台直进时列表在
  /// 返回时才出现，箭头同样有效（嵌套栈底下就是列表）。
  final bool showBackButton;

  /// 全部已登录服务器（含当前这台）。多于一台且给了 [onSwitchServer] 时，页头
  /// 服务器名旁出「切换服务器」菜单，不必先退回列表。
  final List<MediaServerBrowser> servers;

  /// 切到另一台服务器（由列表视图把本页替换成那台的首页）。
  final ValueChanged<MediaServerBrowser>? onSwitchServer;

  @override
  State<MediaServerHomeView> createState() => _MediaServerHomeViewState();
}

class _MediaServerHomeViewState extends State<MediaServerHomeView> {
  List<MediaServerLibrary>? _libraries;
  Object? _librariesError;
  List<MediaServerItem> _continueWatching = const <MediaServerItem>[];

  /// 每个库一行的最新 20 条；缺项 = 还没回来或失败（失败的行不显示）。
  final Map<String, List<MediaServerItem>> _libraryRows =
      <String, List<MediaServerItem>>{};

  /// 重试 +1；旧一轮的响应回来时丢掉。也是进场窗口的 replayKey。
  int _generation = 0;

  MediaServerBrowser get _browser => widget.session.browser;

  MediaServerConnectionStatus get _status {
    if (_librariesError != null) return MediaServerConnectionStatus.offline;
    if (_libraries == null) return MediaServerConnectionStatus.connecting;
    return MediaServerConnectionStatus.online;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    setState(() {
      _libraries = null;
      _librariesError = null;
      _continueWatching = const <MediaServerItem>[];
      _libraryRows.clear();
    });
    // 主干与装饰行并行；装饰行各自吞错，不拖累主干。
    unawaited(_loadContinueWatching(generation));
    List<MediaServerLibrary> libraries;
    try {
      libraries = await _browser.listLibraries();
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _librariesError = e);
      return;
    }
    if (!mounted || generation != _generation) return;
    setState(() => _libraries = libraries);
    for (final MediaServerLibrary library in libraries) {
      unawaited(_loadLibraryRow(generation, library));
    }
  }

  Future<List<MediaServerItem>> _decor(
    String what,
    Future<List<MediaServerItem>> Function() fetch,
  ) async {
    try {
      return await fetch();
    } catch (e) {
      debugPrint('[media-server] $what failed: $e');
      return const <MediaServerItem>[];
    }
  }

  Future<void> _loadContinueWatching(int generation) async {
    final List<List<MediaServerItem>> both = await Future.wait(
      <Future<List<MediaServerItem>>>[
        _decor('resume', _browser.listResume),
        _decor('next-up', _browser.listNextUp),
      ],
    );
    if (!mounted || generation != _generation) return;
    // Resume 在前（有断点的优先），NextUp 补上没断点的下一集；同 id 去重。
    final Set<String> seen = <String>{};
    final List<MediaServerItem> merged = <MediaServerItem>[
      for (final List<MediaServerItem> list in both)
        for (final MediaServerItem item in list)
          if (item.isPlayable && seen.add(item.id)) item,
    ];
    setState(() => _continueWatching = merged);
  }

  /// 一个库的首页行：先要该库最新（剧按系列聚合）；拿不到（端点缺失 / 失败 /
  /// 空）才退回库的直接子级。
  Future<void> _loadLibraryRow(
    int generation,
    MediaServerLibrary library,
  ) async {
    final List<MediaServerItem> latest = await _decor(
      'latest ${library.name}',
      () => _browser.listLatest(
        libraryId: library.id,
        limit: kMediaServerRowLimit,
      ),
    );
    if (!mounted || generation != _generation) return;
    if (latest.isNotEmpty) {
      setState(() => _libraryRows[library.id] = latest);
      return;
    }
    try {
      final MediaServerPage page = await _browser.listChildren(
        parentId: library.id,
        limit: kMediaServerRowLimit,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _libraryRows[library.id] = page.items);
    } catch (e) {
      debugPrint('[media-server] library row ${library.name} failed: $e');
    }
  }

  void _openLibrary(MediaServerLibrary library) {
    openMediaServerGrid(
      context,
      widget.session,
      parentId: library.id,
      title: library.name,
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiMotionScheme motion = context.fushiMotion;
    // 本视图是嵌套 Navigator 里的一条路由：页面外壳自带 Scaffold（Material 祖先）
    // 与 M3E 悬浮页头（随滚动收起）。
    return MediaServerPageFrame(
      header: FushiPageHeader.customTitle(
        title: _buildTitle(context, tokens),
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.gap,
        ),
        leading: widget.showBackButton
            ? BackButton(onPressed: () => Navigator.of(context).maybePop())
            : null,
        actions: <Widget>[
          FushiIconButton(
            key: const ValueKey<String>('media-server-home-search'),
            icon: FushiIcons.search,
            tooltip: t.search,
            label: t.search,
            focusId: FushiFocusId('${widget.session.serverId}-home-search'),
            onTap: () => openMediaServerGrid(
              context,
              widget.session,
              parentId: null,
              title: t.search,
            ),
          ),
          FushiIconButton(
            key: const ValueKey<String>('media-server-home-refresh'),
            icon: FushiIcons.refresh,
            tooltip: t.refresh,
            focusId: FushiFocusId('${widget.session.serverId}-home-refresh'),
            onTap: () => unawaited(_load()),
          ),
        ],
      ),
      // 骨架 / 错误 / 正文之间交叉淡入（effects 弹簧，不过冲）。
      body: AnimatedSwitcher(
        duration: motion.effectsDefault.duration,
        switchInCurve: motion.effectsDefault.curve,
        switchOutCurve: motion.effectsDefault.curve,
        child: _buildBody(),
      ),
    );
  }

  /// 页头标题：状态点 + 服务器名 + 多台服务器时的「切换服务器」菜单钮。
  /// Material（M3E）下整组装进一枚标题胶囊（与其它页头的标题胶囊同形同字阶）；
  /// Apple 是大标题粗体收字距。
  Widget _buildTitle(BuildContext context, FushiDesignTokens tokens) {
    final bool apple = isGlassDesign(context);
    final TextStyle style = apple
        ? tokens.type.pageTitle.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          )
        : FushiPageChromeTitle.titleStyleOf(context);
    final ValueChanged<MediaServerBrowser>? onSwitch = widget.onSwitchServer;
    final bool canSwitch = onSwitch != null && widget.servers.length > 1;
    final Widget row = Row(
      mainAxisSize: apple ? MainAxisSize.max : MainAxisSize.min,
      children: <Widget>[
        MediaServerStatusDot(status: _status),
        SizedBox(width: tokens.spacing.gap + 2),
        Flexible(
          child: Text(
            _browser.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (canSwitch)
          FushiPopupMenuButton<String>(
            key: const ValueKey<String>('media-server-home-switch'),
            tooltip: t.media_server_servers_title,
            icon: FushiIcon(
              FushiIcons.expandMore,
              color: apple
                  ? appleColorsOf(context).secondaryLabel
                  : tokens.surfaces.onVariant,
            ),
            initialValue: _browser.serverId,
            onSelected: (String id) {
              if (id == _browser.serverId) return;
              for (final MediaServerBrowser browser in widget.servers) {
                if (browser.serverId == id) onSwitch(browser);
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              for (final MediaServerBrowser browser in widget.servers)
                CheckedPopupMenuItem<String>(
                  value: browser.serverId,
                  checked: browser.serverId == _browser.serverId,
                  child: Text(
                    browser.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
      ],
    );
    if (apple) return row;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: FushiPageChromeCapsule(
        padding: EdgeInsetsDirectional.fromSTEB(20, 4, canSwitch ? 4 : 20, 4),
        child: DefaultTextStyle.merge(style: style, child: row),
      ),
    );
  }

  Widget _buildBody() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Object? error = _librariesError;
    if (error != null) {
      return FushiPlaceholderMessage(
        key: const ValueKey<String>('media-server-home-error'),
        icon: FushiIcons.cloudOff,
        tone: FushiPlaceholderTone.error,
        message: t.jellyfin_libraries_load_failed,
        detail: '$error',
        action: FushiFilledButton.icon(
          key: const ValueKey<String>('media-server-home-retry'),
          onPressed: () => unawaited(_load()),
          icon: const FushiIcon(FushiIcons.refresh),
          label: Text(t.retry),
        ),
      );
    }
    final List<MediaServerLibrary>? libraries = _libraries;
    if (libraries == null) return _buildSkeleton(tokens);
    final String prefix = widget.session.serverId;
    final double cardHeight = mediaServerRowCardHeight(context);
    return FushiEntranceScope(
      key: const ValueKey<String>('media-server-home-content'),
      replayKey: _generation,
      child: CustomScrollView(
        key: PageStorageKey<String>('$prefix-home'),
        slivers: <Widget>[
          if (_continueWatching.isNotEmpty)
            SliverToBoxAdapter(child: _continueRow(prefix)),
          SliverToBoxAdapter(
            key: const ValueKey<String>('media-server-home-libraries'),
            child: FushiStaggeredEntrance(
              index: 0,
              child: FushiSectionTitle(
                t.media_server_libraries_title,
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.card,
                  tokens.spacing.page,
                  tokens.spacing.gap,
                ),
              ),
            ),
          ),
          if (libraries.isEmpty)
            SliverToBoxAdapter(
              child: FushiPlaceholderMessage(
                icon: FushiIcons.collection,
                message: t.media_server_items_empty,
              ),
            )
          else
            _librarySliverGrid(libraries, prefix, tokens),
          for (final MediaServerLibrary library in libraries)
            if ((_libraryRows[library.id] ?? const <MediaServerItem>[])
                .isNotEmpty)
              SliverToBoxAdapter(
                child: _itemRow(
                  key: ValueKey<String>('media-server-home-row-${library.id}'),
                  title: library.name,
                  storageKey: '$prefix-home-row-${library.id}',
                  items: _libraryRows[library.id]!,
                  cardHeight: cardHeight,
                  onViewAll: () => _openLibrary(library),
                  viewAllFocusId: FushiFocusId('$prefix-row-all-${library.id}'),
                ),
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

  /// 加载骨架：「媒体库」标题条 + 一排库卡块 + 一条海报横滚行，与正文同几何
  /// （库卡 16:9 外卡、海报 2:3 + 两行文字），数据回来时版面不跳。
  Widget _buildSkeleton(FushiDesignTokens tokens) {
    final double cardHeight = mediaServerRowCardHeight(context);
    final bool narrow = MediaQuery.sizeOf(context).width < 600;
    Widget titleBar() => Align(
      alignment: AlignmentDirectional.centerStart,
      child: FushiSkeleton(
        width: 120,
        height: 18,
        borderRadius: BorderRadius.circular(9),
      ),
    );
    return FushiSkeletonShimmer(
      key: const ValueKey<String>('media-server-home-skeleton'),
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.card,
          tokens.spacing.page,
          tokens.spacing.section,
        ),
        children: <Widget>[
          titleBar(),
          SizedBox(height: tokens.spacing.gap),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final double cell = narrow
                  ? kMediaServerLibraryCardWidth
                  : kMediaServerLibraryCardWidth + 80;
              final int columns =
                  ((box.maxWidth + tokens.spacing.card) /
                          (cell + tokens.spacing.card))
                      .ceil()
                      .clamp(1, 6)
                      .toInt();
              return Row(
                children: <Widget>[
                  for (int i = 0; i < columns; i++) ...<Widget>[
                    if (i > 0) SizedBox(width: tokens.spacing.card),
                    const Expanded(child: MediaServerLibraryCardSkeleton()),
                  ],
                ],
              );
            },
          ),
          SizedBox(height: tokens.spacing.section),
          titleBar(),
          SizedBox(height: tokens.spacing.gap),
          SizedBox(
            height: cardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 8,
              separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.card),
              itemBuilder: (BuildContext context, int index) => const SizedBox(
                width: kMediaServerRowCardWidth,
                child: MediaServerPosterSkeleton(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「媒体库」背景图卡网格：列宽上限随窗口（手机两列、桌面 ~300），16:9。
  Widget _librarySliverGrid(
    List<MediaServerLibrary> libraries,
    String prefix,
    FushiDesignTokens tokens,
  ) {
    final bool narrow = MediaQuery.sizeOf(context).width < 600;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: narrow
              ? kMediaServerLibraryCardWidth
              : kMediaServerLibraryCardWidth + 80,
          childAspectRatio: 16 / 9,
          mainAxisSpacing: tokens.spacing.card,
          crossAxisSpacing: tokens.spacing.card,
        ),
        delegate: SliverChildBuilderDelegate(
          fushiStaggeredItemBuilder((BuildContext context, int index) {
            final MediaServerLibrary library = libraries[index];
            return MediaServerLibraryCard(
              key: ValueKey<String>('media-server-library-${library.id}'),
              browser: _browser,
              library: library,
              // 库自身封面缺失 / 404 时的拼贴素材：就是下面「每库一行」那 20 条最新。
              fallbackItems:
                  _libraryRows[library.id] ?? const <MediaServerItem>[],
              focusId: FushiFocusId('$prefix-library-${library.id}'),
              onTap: () => _openLibrary(library),
            );
          }),
          childCount: libraries.length,
        ),
      ),
    );
  }

  /// 「继续观看」行：16:9 横卡（视频是横屏的，且要看得出停在哪一集、还剩多少），
  /// 不与下面几行共用 2:3 海报竖卡。
  Widget _continueRow(String prefix) {
    final String storageKey = '$prefix-home-continue';
    final List<MediaServerItem> items = _continueWatching;
    return MediaServerRow(
      key: const ValueKey<String>('media-server-home-continue'),
      title: t.video_continue_watching,
      storageKey: storageKey,
      itemCount: items.length,
      itemWidth: kMediaServerContinueCardWidth,
      rowHeight: mediaServerContinueCardHeight(context),
      itemBuilder: (BuildContext context, int index) {
        final MediaServerItem item = items[index];
        return MediaServerContinueCard(
          key: ValueKey<String>('$storageKey-card-${item.id}'),
          browser: _browser,
          item: item,
          focusId: FushiFocusId('$storageKey-card-${item.id}'),
          onTap: () => openMediaServerItem(
            context,
            widget.session,
            item,
            siblings: items,
          ),
          onLongPress: () =>
              openMediaServerItemDetail(context, widget.session, item),
        );
      },
    );
  }

  Widget _itemRow({
    required Key key,
    required String title,
    required String storageKey,
    required List<MediaServerItem> items,
    required double cardHeight,
    VoidCallback? onViewAll,
    FushiFocusId? viewAllFocusId,
  }) {
    return MediaServerRow(
      key: key,
      title: title,
      storageKey: storageKey,
      itemCount: items.length,
      itemWidth: kMediaServerRowCardWidth,
      rowHeight: cardHeight,
      onViewAll: onViewAll,
      viewAllFocusId: viewAllFocusId,
      itemBuilder: (BuildContext context, int index) {
        final MediaServerItem item = items[index];
        return MediaServerItemCard(
          key: ValueKey<String>('$storageKey-card-${item.id}'),
          browser: _browser,
          item: item,
          focusId: FushiFocusId('$storageKey-card-${item.id}'),
          onTap: () => openMediaServerItem(
            context,
            widget.session,
            item,
            siblings: items,
          ),
          onLongPress: () =>
              openMediaServerItemDetail(context, widget.session, item),
          onInfo: () =>
              openMediaServerItemDetail(context, widget.session, item),
        );
      },
    );
  }
}
