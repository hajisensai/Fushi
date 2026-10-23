/// 书库里的 Audiobookshelf 标签页：选服务器 / 媒体库 → 搜索 → 封面网格（分页）；顶部
/// 「继续收听」一行来自服务器记的进行中条目。点封面进条目详情页（根导航栈，整页接管，
/// 不需要在标签页内部再嵌一层 Navigator 去处理返回键）。
///
/// 依赖全部走构造参数（服务器清单 + 取协议层实例的函数），不读 Riverpod：测试可以直接
/// 塞假的协议层，AppModel 的共享实例由 `home_reader_page.dart` 接线。
library;

import 'dart:async';

import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_item_page.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_ui_helpers.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart'
    show
        MediaServerBodyInset,
        MediaServerRow,
        kMediaServerRowCardWidth,
        mediaServerCardTextBlock;
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:material_ui/material_ui.dart';

/// 每页条数。
const int kAudiobookshelfPageSize = 40;

class AudiobookshelfLibraryView extends StatefulWidget {
  const AudiobookshelfLibraryView({
    required this.servers,
    required this.apiFor,
    super.key,
  });

  /// 已登录、已启用的服务器（至少一台）。
  final List<AudiobookshelfServerConfig> servers;

  /// 取服务器的共享协议层实例；未登录返回 null。
  final AudiobookshelfApi? Function(AudiobookshelfServerConfig server) apiFor;

  @override
  State<AudiobookshelfLibraryView> createState() =>
      _AudiobookshelfLibraryViewState();
}

class _AudiobookshelfLibraryViewState extends State<AudiobookshelfLibraryView> {
  late AudiobookshelfServerConfig _server = widget.servers.first;
  List<AudiobookshelfLibrary> _libraries = const <AudiobookshelfLibrary>[];
  AudiobookshelfLibrary? _library;
  final List<AudiobookshelfItem> _items = <AudiobookshelfItem>[];
  List<AudiobookshelfInProgressEntry> _continue =
      const <AudiobookshelfInProgressEntry>[];

  int _page = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  Object? _error;

  String _query = '';
  Timer? _debounce;
  int _generation = 0;
  int _epoch = 0;

  final ScrollController _scroll = ScrollController();

  AudiobookshelfApi? get _api => widget.apiFor(_server);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_loadServer());
  }

  @override
  void didUpdateWidget(AudiobookshelfLibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 服务器清单变了（登出 / 删除）：当前服务器不在了就换到第一台重来。
    if (!widget.servers.any((s) => s.id == _server.id)) {
      _server = widget.servers.first;
      _library = null;
      unawaited(_loadServer());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // ── 加载 ──────────────────────────────────────────────────────────────

  Future<void> _loadServer() async {
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _items.clear();
    });
    try {
      final AudiobookshelfApi api =
          _api ?? (throw StateError('not signed in to ${_server.displayName}'));
      final List<AudiobookshelfLibrary> libraries = await api.libraries();
      if (generation != _generation || !mounted) return;
      _libraries = <AudiobookshelfLibrary>[
        for (final AudiobookshelfLibrary l in libraries)
          if (l.mediaType != AudiobookshelfMediaType.unknown) l,
      ];
      _library = _libraries.isEmpty
          ? null
          : _libraries.firstWhere(
              (AudiobookshelfLibrary l) => l.id == _library?.id,
              orElse: () => _libraries.first,
            );
      await _loadFirstPage(generation);
      unawaited(_loadContinue(generation));
    } catch (e) {
      if (generation != _generation || !mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadFirstPage([int? knownGeneration]) async {
    final int generation = knownGeneration ?? ++_generation;
    final AudiobookshelfLibrary? library = _library;
    final AudiobookshelfApi? api = _api;
    if (library == null || api == null) {
      setState(() => _loading = false);
      return;
    }
    if (knownGeneration == null) {
      setState(() {
        _loading = true;
        _error = null;
        _items.clear();
        _page = 0;
      });
    }
    try {
      final List<AudiobookshelfItem> fetched;
      bool hasMore = false;
      if (_query.isEmpty) {
        final AudiobookshelfItemPage page = await api.libraryItems(
          library.id,
          limit: kAudiobookshelfPageSize,
        );
        fetched = page.items;
        hasMore = page.hasMore;
      } else {
        // 搜索服务端不分页：一次拿全。
        fetched = await api.search(library.id, _query, limit: 60);
      }
      if (generation != _generation || !mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(_playable(fetched));
        _page = 0;
        _hasMore = hasMore;
        _loading = false;
        _loadMoreFailed = false;
        _epoch++;
      });
      _fillViewportIfShort();
    } catch (e) {
      if (generation != _generation || !mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final AudiobookshelfLibrary? library = _library;
    final AudiobookshelfApi? api = _api;
    if (library == null || api == null) return;
    if (_loading || _loadingMore || !_hasMore || _query.isNotEmpty) return;
    final int generation = _generation;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    try {
      final AudiobookshelfItemPage page = await api.libraryItems(
        library.id,
        page: _page + 1,
        limit: kAudiobookshelfPageSize,
      );
      if (generation != _generation || !mounted) return;
      setState(() {
        _items.addAll(_playable(page.items));
        _page += 1;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
      _fillViewportIfShort();
    } catch (_) {
      if (generation != _generation || !mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
      });
    }
  }

  Future<void> _loadContinue(int generation) async {
    final AudiobookshelfApi? api = _api;
    if (api == null) return;
    try {
      final List<AudiobookshelfInProgressEntry> entries = await api
          .itemsInProgress();
      if (generation != _generation || !mounted) return;
      setState(() => _continue = entries);
    } catch (_) {
      // 「继续收听」只是锦上添花：取不到就不显示这一行。
    }
  }

  /// 只有电子书 / 补充文件、确定没有音频的条目不列（点了也没法播）。
  static List<AudiobookshelfItem> _playable(
    Iterable<AudiobookshelfItem> items,
  ) => <AudiobookshelfItem>[
    for (final AudiobookshelfItem item in items)
      if (!item.hasNoAudio) item,
  ];

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 600) unawaited(_loadMore());
  }

  /// 第一页没填满视口就没有滚动可言，补取下一页（否则永远翻不动）。
  void _fillViewportIfShort() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent <= 0) unawaited(_loadMore());
    });
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final String query = value.trim();
      if (query == _query) return;
      _query = query;
      unawaited(_loadFirstPage());
    });
  }

  // ── 选择 ──────────────────────────────────────────────────────────────

  Future<void> _pickLibrary() async {
    final AudiobookshelfLibrary? picked =
        await showFushiChoiceDialog<AudiobookshelfLibrary>(
          context: context,
          title: t.audiobookshelf_browse_choose_library,
          selected: _library,
          options: <FushiChoiceOption<AudiobookshelfLibrary>>[
            for (final AudiobookshelfLibrary l in _libraries)
              FushiChoiceOption<AudiobookshelfLibrary>(value: l, label: l.name),
          ],
        );
    if (picked == null || picked.id == _library?.id || !mounted) return;
    _library = picked;
    _query = '';
    unawaited(_loadFirstPage());
  }

  Future<void> _pickServer() async {
    final AudiobookshelfServerConfig? picked =
        await showFushiChoiceDialog<AudiobookshelfServerConfig>(
          context: context,
          title: t.discovery_audiobookshelf_settings_title,
          selected: _server,
          options: <FushiChoiceOption<AudiobookshelfServerConfig>>[
            for (final AudiobookshelfServerConfig s in widget.servers)
              FushiChoiceOption<AudiobookshelfServerConfig>(
                value: s,
                label: s.displayName,
              ),
          ],
        );
    if (picked == null || picked.id == _server.id || !mounted) return;
    _server = picked;
    _library = null;
    _query = '';
    _continue = const <AudiobookshelfInProgressEntry>[];
    unawaited(_loadServer());
  }

  void _openItem(AudiobookshelfItem item) {
    final AudiobookshelfApi? api = _api;
    if (api == null) return;
    unawaited(
      Navigator.of(context, rootNavigator: true).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext _) => AudiobookshelfItemDetailPage(
            server: _server,
            api: api,
            item: item,
          ),
        ),
      ),
    );
  }

  // ── 界面 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return MediaServerBodyInset(
      builder: (BuildContext context, double top) => _body(context, top),
    );
  }

  Widget _body(BuildContext context, double top) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Object? error = _error;
    if (error != null && _items.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: FushiPlaceholderMessage(
          icon: FushiIcons.cloudOff,
          tone: FushiPlaceholderTone.error,
          message: t.audiobookshelf_browse_load_failed,
          detail: audiobookshelfDescribeError(error),
          action: FushiFilledButton.icon(
            onPressed: () => unawaited(_loadServer()),
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(t.retry),
          ),
        ),
      );
    }
    return FushiEntranceScope(
      replayKey: _epoch,
      child: CustomScrollView(
        controller: _scroll,
        slivers: <Widget>[
          SliverToBoxAdapter(child: SizedBox(height: top)),
          SliverToBoxAdapter(child: _controls(tokens)),
          if (_query.isEmpty && _continue.isNotEmpty)
            SliverToBoxAdapter(child: _continueRow(context)),
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: FushiLoadingView(),
            )
          else if (_items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: FushiPlaceholderMessage(
                icon: _query.isEmpty ? FushiIcons.books : FushiIcons.searchOff,
                message: _query.isEmpty
                    ? t.audiobookshelf_browse_empty
                    : t.audiobookshelf_browse_no_results,
              ),
            )
          else
            _grid(context, tokens),
          if (_loadingMore)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(tokens.spacing.card),
                child: const FushiLoadingView(compact: true),
              ),
            )
          else if (_loadMoreFailed)
            SliverToBoxAdapter(
              child: Center(
                child: FushiTextButton.icon(
                  onPressed: () => unawaited(_loadMore()),
                  icon: const FushiIcon(FushiIcons.refresh),
                  label: Text(t.retry),
                ),
              ),
            )
          else
            SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.section)),
        ],
      ),
    );
  }

  Widget _controls(FushiDesignTokens tokens) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: tokens.spacing.gap,
            children: <Widget>[
              if (widget.servers.length > 1)
                FushiTextButton.icon(
                  onPressed: _pickServer,
                  icon: const FushiIcon(FushiIcons.expandMore),
                  label: Text(_server.displayName),
                ),
              if (_library != null)
                FushiTextButton.icon(
                  onPressed: _libraries.length > 1 ? _pickLibrary : null,
                  icon: const FushiIcon(FushiIcons.expandMore),
                  label: Text(_library!.name),
                ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          FushiSearchBar(
            hintText: t.audiobookshelf_browse_search_hint,
            onQueryChanged: _onQueryChanged,
          ),
        ],
      ),
    );
  }

  Widget _continueRow(BuildContext context) {
    final AudiobookshelfApi? api = _api;
    if (api == null) return const SizedBox.shrink();
    final double cardHeight =
        kMediaServerRowCardWidth + mediaServerCardTextBlock(context);
    return MediaServerRow(
      title: t.audiobookshelf_browse_continue,
      itemCount: _continue.length,
      itemWidth: kMediaServerRowCardWidth,
      rowHeight: cardHeight,
      storageKey: 'abs-continue-${_server.id}',
      itemBuilder: (BuildContext context, int index) {
        final AudiobookshelfItem item = _continue[index].item;
        return _ItemCard(
          api: api,
          serverId: _server.id,
          item: item,
          onTap: () => _openItem(item),
        );
      },
    );
  }

  Widget _grid(BuildContext context, FushiDesignTokens tokens) {
    final AudiobookshelfApi? api = _api;
    if (api == null) return const SliverToBoxAdapter(child: SizedBox.shrink());
    final double gap = tokens.spacing.card;
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      sliver: SliverLayoutBuilder(
        builder: (BuildContext context, SliverConstraints constraints) {
          final double width = constraints.crossAxisExtent;
          final double maxExtent = readerShelfGridExtentForWidth(width);
          final int columns = ((width + gap) / (maxExtent + gap)).ceil().clamp(
            1,
            1 << 16,
          );
          final double cardWidth = (width - gap * (columns - 1)) / columns;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: gap + tokens.spacing.gap / 2,
              crossAxisSpacing: gap,
              // 有声书封面是方的：封面高 = 卡宽，再加标题块。
              mainAxisExtent: cardWidth + mediaServerCardTextBlock(context),
            ),
            delegate: SliverChildBuilderDelegate(
              fushiStaggeredItemBuilder((BuildContext context, int index) {
                final AudiobookshelfItem item = _items[index];
                return _ItemCard(
                  key: ValueKey<String>('abs-${_server.id}-${item.id}'),
                  api: api,
                  serverId: _server.id,
                  item: item,
                  onTap: () => _openItem(item),
                );
              }),
              childCount: _items.length,
            ),
          );
        },
      ),
    );
  }
}

/// 一张封面卡：方形封面 + 书名 + 「作者 · 时长」。
class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.api,
    required this.serverId,
    required this.item,
    required this.onTap,
    super.key,
  });

  final AudiobookshelfApi api;
  final String serverId;
  final AudiobookshelfItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String subtitle = audiobookshelfCardSubtitle(item);
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => shelfCoverCard(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 1,
              child: ShelfCoverFrame(
                child: PortraitCoverImage(
                  image: AppCachedHttpImage(
                    api.coverUri(item.id, width: 400).toString(),
                    cacheKey: 'abs:$serverId:${item.id}',
                  ),
                  errorBuilder: (_) =>
                      const ShelfCoverPlaceholder(icon: FushiIcons.brokenImage),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: shelfCardTitleStyle(context),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
