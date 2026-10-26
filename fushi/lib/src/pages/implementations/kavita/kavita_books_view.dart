/// 书架页的「Kavita」子标签：浏览 Kavita 书籍库里的 EPUB 并阅读 / 下载。
///
/// 结构：页头主位放库页壳交来的分段条（与其它库页视图同构）；正文是服务器选择
/// （多台可用服务器时）+ 书籍系列网格（服务器分页、滚到底续页、本地搜索）。点开
/// 系列进 [KavitaBookSeriesPage]（章列表 / 阅读 / 下载）。
///
/// 只列 EPUB 系列（`seriesFormat == epub`）；PDF 在 v1 不支持，不列出空壳。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/kavita/kavita_api_registry.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/manga/kavita/kavita_library_adapter.dart'
    show KavitaApiFactory;
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/kavita/kavita_browse_page.dart'
    show KavitaSeriesCover, usableKavitaServers;
import 'package:fushi/src/pages/implementations/kavita/kavita_book_series_page.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';

class KavitaBooksView extends ConsumerStatefulWidget {
  const KavitaBooksView({
    required this.navigation,
    super.key,
    this.servers,
    this.apiFor,
  });

  /// 库页壳交来的分段条，作为页头主位。
  final Widget navigation;

  /// 测试注入口；null = 现读 `prefsRepo.kavitaServers`。
  final List<KavitaServerConfig>? servers;

  /// 测试注入口；null = [KavitaApiRegistry.instance]。
  final KavitaApiFactory? apiFor;

  @override
  ConsumerState<KavitaBooksView> createState() => _KavitaBooksViewState();
}

class _KavitaBooksViewState extends ConsumerState<KavitaBooksView> {
  static const int _kPageSize = 50;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  final List<KavitaSeries> _items = <KavitaSeries>[];
  List<KavitaLibrary> _libraries = const <KavitaLibrary>[];
  int _libraryIndex = 0;
  int _nextPage = 1;
  bool _hasMore = true;
  bool _loading = false;
  Object? _error;
  String _query = '';
  String? _serverId;
  int _generation = 0;

  List<KavitaServerConfig> get _servers => usableKavitaServers(
    widget.servers ?? ref.read(appProvider).prefsRepo.kavitaServers,
  );

  KavitaServerConfig? get _server {
    final List<KavitaServerConfig> servers = _servers;
    if (servers.isEmpty) return null;
    for (final KavitaServerConfig s in servers) {
      if (s.id == _serverId) return s;
    }
    return servers.first;
  }

  KavitaApi _api(KavitaServerConfig server) =>
      (widget.apiFor ?? KavitaApiRegistry.instance.apiFor)(server);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final ScrollPosition position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 600) {
      unawaited(_loadMore());
    }
  }

  Future<void> _reload() async {
    _generation += 1;
    setState(() {
      _items.clear();
      _libraries = const <KavitaLibrary>[];
      _libraryIndex = 0;
      _nextPage = 1;
      _hasMore = true;
      _loading = false;
      _error = null;
    });
    final KavitaServerConfig? server = _server;
    if (server == null) {
      setState(() => _hasMore = false);
      return;
    }
    final int generation = _generation;
    try {
      final List<KavitaLibrary> all = await _api(server).getLibraries();
      if (!mounted || generation != _generation) return;
      setState(() {
        _libraries = <KavitaLibrary>[
          for (final KavitaLibrary l in all)
            if (l.isBookLibrary) l,
        ];
        _hasMore = _libraries.isNotEmpty;
      });
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('KavitaBooks.libraries', error, stack);
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _hasMore = false;
      });
      return;
    }
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final KavitaServerConfig? server = _server;
    if (server == null || _loading || !_hasMore) return;
    if (_libraryIndex >= _libraries.length) {
      setState(() => _hasMore = false);
      return;
    }
    final int generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final KavitaSeriesPage page = await _api(server).getSeriesPage(
        libraryId: _libraries[_libraryIndex].id,
        pageNumber: _nextPage,
        pageSize: _kPageSize,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items.addAll(<KavitaSeries>[
          for (final KavitaSeries s in page.items)
            if (s.isEpub) s,
        ]);
        if (page.hasMore && page.items.isNotEmpty) {
          _nextPage = page.pageNumber + 1;
        } else {
          // 当前库翻完，转下一个书籍库。
          _libraryIndex += 1;
          _nextPage = 1;
          _hasMore = _libraryIndex < _libraries.length;
        }
        _loading = false;
      });
      if (_hasMore && _visible.length < 12) unawaited(_loadMore());
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('KavitaBooks.series', error, stack);
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  List<KavitaSeries> get _visible => filterByMediaSearch<KavitaSeries>(
    _items,
    _query,
    (KavitaSeries series) => <String>{
      series.displayName,
      series.name,
      if (series.originalName != null) series.originalName!,
    },
  );

  void _openSeries(KavitaServerConfig server, KavitaSeries series) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => KavitaBookSeriesPage(
          server: server,
          series: series,
          api: _api(server),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<KavitaServerConfig> servers = _servers;
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          FushiPageHeader.customTitle(title: widget.navigation),
          if (servers.length > 1) _serverPicker(servers),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: FushiSearchField(
              fieldKey: const ValueKey<String>('kavita_books_search'),
              focusId: const FushiFocusId('kavita-books-search'),
              controller: _searchController,
              focusNode: _searchFocus,
              hintText: t.mihon_source_search,
              onChanged: (String value) => setState(() => _query = value),
              onSubmitted: (String value) => setState(() => _query = value),
              onClear: () {
                _searchController.clear();
                setState(() => _query = '');
              },
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _serverPicker(List<KavitaServerConfig> servers) {
    final KavitaServerConfig? current = _server;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: adaptiveSegmentedButton<String>(
        context: context,
        segments: <ButtonSegment<String>>[
          for (final KavitaServerConfig s in servers)
            ButtonSegment<String>(value: s.id, label: Text(s.displayName)),
        ],
        selected: <String>{current?.id ?? servers.first.id},
        onSelectionChanged: (Set<String> ids) {
          final String id = ids.first;
          if (id == current?.id) return;
          _serverId = id;
          unawaited(_reload());
        },
      ),
    );
  }

  Widget _body() {
    if (_server == null) {
      return FushiPlaceholderMessage(
        icon: FushiIcons.cloudOff,
        message: t.kavita_server_add,
      );
    }
    if (_items.isEmpty && (_loading || (_hasMore && _error == null))) {
      return Center(child: adaptiveIndicator(context: context));
    }
    final Object? error = _error;
    if (error != null && _items.isEmpty) {
      return FushiPlaceholderMessage(
        icon: FushiIcons.error,
        message:
            error is KavitaApiException &&
                (error.isUnauthorized || error.isForbidden)
            ? t.kavita_connect_unauthorized
            : t.kavita_connect_failed(reason: ''),
        action: FushiFilledButton.icon(
          key: const ValueKey<String>('kavita_books_retry'),
          onPressed: () => unawaited(_reload()),
          icon: const FushiIcon(FushiIcons.refresh),
          label: Text(t.retry),
        ),
      );
    }
    final List<KavitaSeries> visible = _visible;
    if (visible.isEmpty) {
      return FushiPlaceholderMessage(
        icon: FushiIcons.books,
        message: _query.isEmpty
            ? t.kavita_books_empty
            : t.mihon_source_no_results,
      );
    }
    final KavitaServerConfig server = _server!;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return FushiRefreshIndicator(
          onRefresh: _reload,
          child: FushiEntranceScope(
            child: GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                childAspectRatio: 0.62,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: visible.length,
              itemBuilder: fushiStaggeredItemBuilder((
                BuildContext context,
                int index,
              ) {
                final KavitaSeries series = visible[index];
                return FushiCard(
                  key: ValueKey<String>('kavita_book_${series.id}'),
                  padding: EdgeInsets.zero,
                  onTap: () => _openSeries(server, series),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        child: KavitaSeriesCover(
                          api: _api(server),
                          server: server,
                          series: series,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          series.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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
}
