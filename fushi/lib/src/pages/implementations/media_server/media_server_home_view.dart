import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_routes.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/utils.dart';

/// 一台服务器的首页：「媒体库」横滚行 → 「继续观看」（Resume ∪ NextUp 去重）→
/// 「最近添加」→ 每个库一行前 20 条 + 行尾「查看全部」进库网格。
///
/// [MediaServerBrowser.listLibraries] 是主干：失败整页错误 + 重试。其余都是装饰
/// 行：失败即空、该行不显示（契约文档的两档失败语义）。
class MediaServerHomeView extends StatefulWidget {
  const MediaServerHomeView({
    required this.session,
    this.showBackButton = false,
    super.key,
  });

  final MediaServerSession session;

  /// 多台服务器时首页压在服务器列表之上，页头给一个返回箭头；单台直进时列表在
  /// 返回时才出现，箭头同样有效（嵌套栈底下就是列表）。
  final bool showBackButton;

  @override
  State<MediaServerHomeView> createState() => _MediaServerHomeViewState();
}

class _MediaServerHomeViewState extends State<MediaServerHomeView> {
  List<MediaServerLibrary>? _libraries;
  Object? _librariesError;
  List<MediaServerItem> _continueWatching = const <MediaServerItem>[];
  List<MediaServerItem> _latest = const <MediaServerItem>[];

  /// 每个库一行的前 20 条；缺项 = 还没回来或失败（失败的行不显示）。
  final Map<String, List<MediaServerItem>> _libraryRows =
      <String, List<MediaServerItem>>{};

  /// 重试 +1；旧一轮的响应回来时丢掉。
  int _generation = 0;

  MediaServerBrowser get _browser => widget.session.browser;

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
      _latest = const <MediaServerItem>[];
      _libraryRows.clear();
    });
    // 主干与装饰行并行；装饰行各自吞错，不拖累主干。
    unawaited(_loadContinueWatching(generation));
    unawaited(_loadLatest(generation));
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

  Future<void> _loadLatest(int generation) async {
    final List<MediaServerItem> latest = await _decor(
      'latest',
      () => _browser.listLatest(),
    );
    if (!mounted || generation != _generation) return;
    setState(() => _latest = latest);
  }

  Future<void> _loadLibraryRow(
    int generation,
    MediaServerLibrary library,
  ) async {
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
    // 本视图是嵌套 Navigator 里的一条路由：没有 Scaffold 就没有 Material 祖先。
    return Scaffold(
      body: Column(
        children: <Widget>[
          FushiPageHeader(
            title: _browser.displayName,
            compact: true,
            leading: widget.showBackButton
                ? BackButton(onPressed: () => Navigator.of(context).maybePop())
                : null,
            actions: <Widget>[
              FushiIconButton(
                key: const ValueKey<String>('media-server-home-search'),
                icon: Icons.search_rounded,
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
                icon: Icons.refresh_rounded,
                tooltip: t.refresh,
                focusId: FushiFocusId(
                  '${widget.session.serverId}-home-refresh',
                ),
                onTap: () => unawaited(_load()),
              ),
            ],
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Object? error = _librariesError;
    if (error != null) {
      return FushiPlaceholderMessage(
        icon: Icons.cloud_off_outlined,
        message: t.jellyfin_libraries_load_failed,
        detail: '$error',
        action: FilledButton.icon(
          key: const ValueKey<String>('media-server-home-retry'),
          onPressed: () => unawaited(_load()),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t.retry),
        ),
      );
    }
    final List<MediaServerLibrary>? libraries = _libraries;
    if (libraries == null) {
      return Center(child: adaptiveIndicator(context: context));
    }
    final String prefix = widget.session.serverId;
    final double cardHeight = mediaServerRowCardHeight(context);
    final double libraryCardHeight =
        kMediaServerLibraryCardWidth * 9 / 16 +
        textLineHeight(context, tokens.type.listTitle) +
        12 +
        kTextBlockSlack;
    return ListView(
      key: PageStorageKey<String>('$prefix-home'),
      padding: EdgeInsets.only(bottom: tokens.spacing.section),
      children: <Widget>[
        if (libraries.isEmpty)
          FushiPlaceholderMessage(
            icon: Icons.video_library_outlined,
            message: t.media_server_items_empty,
          )
        else
          MediaServerRow(
            key: const ValueKey<String>('media-server-home-libraries'),
            title: t.media_server_libraries_title,
            storageKey: '$prefix-home-libraries',
            itemCount: libraries.length,
            itemWidth: kMediaServerLibraryCardWidth,
            rowHeight: libraryCardHeight,
            itemBuilder: (BuildContext context, int index) {
              final MediaServerLibrary library = libraries[index];
              return MediaServerLibraryCard(
                key: ValueKey<String>('media-server-library-${library.id}'),
                browser: _browser,
                library: library,
                // 库自身封面缺失 / 404 时的拼贴素材：就是下面「每库一行」那 20 条。
                fallbackItems:
                    _libraryRows[library.id] ?? const <MediaServerItem>[],
                focusId: FushiFocusId('$prefix-library-${library.id}'),
                onTap: () => _openLibrary(library),
              );
            },
          ),
        if (_continueWatching.isNotEmpty)
          _itemRow(
            key: const ValueKey<String>('media-server-home-continue'),
            title: t.video_continue_watching,
            storageKey: '$prefix-home-continue',
            items: _continueWatching,
            cardHeight: cardHeight,
          ),
        if (_latest.isNotEmpty)
          _itemRow(
            key: const ValueKey<String>('media-server-home-latest'),
            title: t.home_recently_added,
            storageKey: '$prefix-home-latest',
            items: _latest,
            cardHeight: cardHeight,
          ),
        for (final MediaServerLibrary library in libraries)
          if ((_libraryRows[library.id] ?? const <MediaServerItem>[])
              .isNotEmpty)
            _itemRow(
              key: ValueKey<String>('media-server-home-row-${library.id}'),
              title: library.name,
              storageKey: '$prefix-home-row-${library.id}',
              items: _libraryRows[library.id]!,
              cardHeight: cardHeight,
              onViewAll: () => _openLibrary(library),
              viewAllFocusId: FushiFocusId('$prefix-row-all-${library.id}'),
            ),
      ],
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
        );
      },
    );
  }
}
