import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/kavita/kavita_api_registry.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/manga/kavita/kavita_library_adapter.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';

/// 用户配置里**可用**（启用且有 API key）的 Kavita 服务器。
List<KavitaServerConfig> usableKavitaServers(
  Iterable<KavitaServerConfig> servers,
) => <KavitaServerConfig>[
  for (final KavitaServerConfig server in servers)
    if (server.isUsable) server,
];

/// 浏览 Kavita 上的漫画：服务器 → 库 → 系列，点开系列进通用作品页
/// （[MangaSeriesPage]，入库 / 选章 / 在线直读都与扩展源、互联对端同一套）。
///
/// 只有一台可用服务器时直接进它的库列表。
class KavitaBrowsePage extends ConsumerWidget {
  const KavitaBrowsePage({super.key, this.servers, this.apiFor});

  /// 测试注入口；null = 现读 `prefsRepo.kavitaServers`。
  final List<KavitaServerConfig>? servers;

  /// 测试注入口；null = [KavitaApiRegistry.instance]。
  final KavitaApiFactory? apiFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<KavitaServerConfig> usable = usableKavitaServers(
      servers ?? ref.read(appProvider).prefsRepo.kavitaServers,
    );
    if (usable.length == 1) {
      return KavitaLibrariesPage(server: usable.single, apiFor: apiFor);
    }
    return FushiPageScaffold(
      title: t.kavita_settings_title,
      automaticallyImplyLeading: false,
      headerCompact: true,
      leading: BackButton(
        key: const ValueKey<String>('kavita_browse_back'),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      body: usable.isEmpty
          ? SafeArea(
              bottom: false,
              child: FushiPlaceholderMessage(
                icon: FushiIcons.cloudOff,
                message: t.kavita_server_add,
              ),
            )
          : FushiEntranceScope(
              child: ListView.builder(
                padding: const EdgeInsets.all(
                  16,
                ).copyWith(top: 16 + MediaQuery.paddingOf(context).top),
                itemCount: usable.length,
                itemBuilder: fushiStaggeredItemBuilder((
                  BuildContext context,
                  int index,
                ) {
                  final KavitaServerConfig server = usable[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: FushiCard(
                      padding: EdgeInsets.zero,
                      child: FushiListItem(
                        key: ValueKey<String>('kavita_server_${server.id}'),
                        leading: const FushiListLeadingIcon(
                          FushiIcons.cloud,
                          shape: FushiLeadingShape.cookie,
                          tone: FushiCardTone.primary,
                        ),
                        title: Text(server.displayName),
                        subtitle: Text(server.serverUrl.host),
                        trailing: const FushiIcon(FushiIcons.chevronRight),
                        onTap: () => Navigator.of(context).push(
                          adaptivePageRoute<void>(
                            context: context,
                            builder: (BuildContext context) =>
                                KavitaLibrariesPage(
                                  server: server,
                                  apiFor: apiFor,
                                ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
    );
  }
}

/// 一台 Kavita 服务器上的漫画库（书籍库不列：EPUB / PDF 走书架那条路）。
class KavitaLibrariesPage extends StatefulWidget {
  const KavitaLibrariesPage({required this.server, super.key, this.apiFor});

  final KavitaServerConfig server;
  final KavitaApiFactory? apiFor;

  @override
  State<KavitaLibrariesPage> createState() => _KavitaLibrariesPageState();
}

class _KavitaLibrariesPageState extends State<KavitaLibrariesPage> {
  late final KavitaApi _api =
      (widget.apiFor ?? KavitaApiRegistry.instance.apiFor)(widget.server);
  List<KavitaLibrary> _libraries = const <KavitaLibrary>[];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<KavitaLibrary> libraries = await _api.getLibraries();
      if (!mounted) return;
      setState(() {
        _libraries = <KavitaLibrary>[
          for (final KavitaLibrary library in libraries)
            if (!library.isBookLibrary) library,
        ];
        _loading = false;
      });
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('KavitaBrowse.libraries', error, stack);
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _open(KavitaLibrary library) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => KavitaSeriesGridPage(
          server: widget.server,
          library: library,
          apiFor: widget.apiFor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FushiPageScaffold(
    title: widget.server.displayName,
    automaticallyImplyLeading: false,
    headerCompact: true,
    leading: BackButton(
      key: const ValueKey<String>('kavita_libraries_back'),
      onPressed: () => Navigator.of(context).maybePop(),
    ),
    body: _buildBody(),
  );

  Widget _buildBody() {
    if (_loading && _libraries.isEmpty) {
      return SafeArea(
        bottom: false,
        child: Center(child: adaptiveIndicator(context: context)),
      );
    }
    final Object? error = _error;
    if (error != null && _libraries.isEmpty) {
      return SafeArea(
        bottom: false,
        child: _KavitaErrorView(
          error: error,
          retryKey: const ValueKey<String>('kavita_libraries_retry'),
          onRetry: _load,
        ),
      );
    }
    if (_libraries.isEmpty) {
      return SafeArea(
        bottom: false,
        child: FushiPlaceholderMessage(
          icon: FushiIcons.folder,
          message: t.kavita_browse_libraries_empty,
        ),
      );
    }
    return FushiRefreshIndicator(
      onRefresh: _load,
      child: FushiEntranceScope(
        child: ListView.builder(
          padding: const EdgeInsets.all(
            16,
          ).copyWith(top: 16 + MediaQuery.paddingOf(context).top),
          itemCount: _libraries.length,
          itemBuilder: fushiStaggeredItemBuilder((
            BuildContext context,
            int index,
          ) {
            final KavitaLibrary library = _libraries[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FushiCard(
                padding: EdgeInsets.zero,
                child: FushiListItem(
                  key: ValueKey<String>('kavita_library_${library.id}'),
                  leading: const FushiListLeadingIcon(
                    FushiIcons.manga,
                    shape: FushiLeadingShape.cookie,
                    tone: FushiCardTone.primary,
                  ),
                  title: Text(library.name),
                  trailing: const FushiIcon(FushiIcons.chevronRight),
                  onTap: () => _open(library),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// 一个 Kavita 库里的漫画系列（服务器分页，滚到底自动续页；只列图片归档系列）。
class KavitaSeriesGridPage extends ConsumerStatefulWidget {
  const KavitaSeriesGridPage({
    required this.server,
    required this.library,
    super.key,
    this.apiFor,
  });

  final KavitaServerConfig server;
  final KavitaLibrary library;
  final KavitaApiFactory? apiFor;

  @override
  ConsumerState<KavitaSeriesGridPage> createState() =>
      _KavitaSeriesGridPageState();
}

class _KavitaSeriesGridPageState extends ConsumerState<KavitaSeriesGridPage> {
  static const int _kPageSize = 50;

  late final KavitaApi _api =
      (widget.apiFor ?? KavitaApiRegistry.instance.apiFor)(widget.server);
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  final List<KavitaSeries> _items = <KavitaSeries>[];
  int _nextPage = 1;
  bool _hasMore = true;
  bool _loading = false;
  Object? _error;
  String _query = '';

  /// 每次整页重载自增：在飞的旧请求回来时据此丢弃。
  int _generation = 0;

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
      _nextPage = 1;
      _hasMore = true;
      _loading = false;
      _error = null;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final int generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final KavitaSeriesPage page = await _api.getSeriesPage(
        libraryId: widget.library.id,
        pageNumber: _nextPage,
        pageSize: _kPageSize,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items.addAll(<KavitaSeries>[
          for (final KavitaSeries series in page.items)
            if (series.isArchive) series,
        ]);
        _nextPage = page.pageNumber + 1;
        _hasMore = page.hasMore && page.items.isNotEmpty;
        _loading = false;
      });
      // 首页全被过滤掉（库里多是 EPUB / PDF）时继续往后翻，别停在空屏。
      if (_hasMore && _visible.length < 12) unawaited(_loadMore());
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('KavitaBrowse.series', error, stack);
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

  void _openSeries(KavitaSeries series) {
    final AppModel appModel = ref.read(appProvider);
    final OnlineMangaLibraryService service = appModel
        .onlineMangaLibraryService(OnlineMangaRuntimeKind.kavita);
    final KavitaServerConfig server = widget.server;
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaSeriesPage(
          target: SourceMangaSeriesTarget(
            adapter: service.adapter,
            service: service,
            seed: KavitaLibraryAdapter.entryFor(server: server, series: series),
            sourceLabel: server.displayName,
            remoteCoverBuilder: (BuildContext context) =>
                KavitaSeriesCover(api: _api, server: server, series: series),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FushiPageScaffold(
    title: widget.library.name,
    automaticallyImplyLeading: false,
    headerCompact: true,
    leading: BackButton(
      key: const ValueKey<String>('kavita_series_back'),
      onPressed: () => Navigator.of(context).maybePop(),
    ),
    headerBottom: Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FushiSearchField(
        fieldKey: const ValueKey<String>('kavita_series_search'),
        focusId: const FushiFocusId('kavita-series-search'),
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
    body: _buildResults(),
  );

  Widget _buildResults() {
    if (_items.isEmpty && (_loading || (_hasMore && _error == null))) {
      return SafeArea(
        bottom: false,
        child: Center(child: adaptiveIndicator(context: context)),
      );
    }
    final Object? error = _error;
    if (error != null && _items.isEmpty) {
      return SafeArea(
        bottom: false,
        child: _KavitaErrorView(
          error: error,
          retryKey: const ValueKey<String>('kavita_series_retry'),
          onRetry: _reload,
        ),
      );
    }
    final List<KavitaSeries> visible = _visible;
    if (visible.isEmpty) {
      return SafeArea(
        bottom: false,
        child: FushiPlaceholderMessage(
          icon: FushiIcons.searchOff,
          message: _query.isEmpty
              ? t.kavita_browse_series_empty
              : t.mihon_source_no_results,
        ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return FushiRefreshIndicator(
          onRefresh: _reload,
          child: FushiEntranceScope(
            child: GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(
                16,
              ).copyWith(top: 16 + MediaQuery.paddingOf(context).top),
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
                  key: ValueKey<String>('kavita_series_${series.id}'),
                  padding: EdgeInsets.zero,
                  onTap: () => _openSeries(series),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        child: KavitaSeriesCover(
                          api: _api,
                          server: widget.server,
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

class _KavitaErrorView extends StatelessWidget {
  const _KavitaErrorView({
    required this.error,
    required this.retryKey,
    required this.onRetry,
  });

  final Object error;
  final Key retryKey;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final Object failure = error;
    final String message =
        failure is KavitaApiException &&
            (failure.isUnauthorized || failure.isForbidden)
        ? t.kavita_connect_unauthorized
        : describeOnlineSourceError(failure);
    return FushiPlaceholderMessage(
      icon: FushiIcons.error,
      message: message,
      action: FushiFilledButton.icon(
        key: retryKey,
        onPressed: () => unawaited(onRetry()),
        icon: const FushiIcon(FushiIcons.refresh),
        label: Text(t.retry),
      ),
    );
  }
}

/// Kavita 系列封面。
///
/// 刻意**不用** `Image.network(seriesCoverUrl)`：那条 URL 带 `apiKey` 查询参数，
/// 加载失败时 Flutter 会把整条 URL 写进图片异常文本，再经全局错误钩子落进
/// 可上传的错误日志。改走 [KavitaApi.fetchSeriesCoverBytes]（错误文本已脱敏）+
/// 进程内小缓存。
class KavitaSeriesCover extends StatefulWidget {
  const KavitaSeriesCover({
    required this.api,
    required this.server,
    required this.series,
    super.key,
  });

  final KavitaApi api;
  final KavitaServerConfig server;
  final KavitaSeries series;

  static const int _kCacheCapacity = 200;
  static final LinkedHashMap<String, Uint8List> _cache =
      LinkedHashMap<String, Uint8List>();

  static Uint8List? _cached(String key) {
    final Uint8List? bytes = _cache.remove(key);
    if (bytes != null) _cache[key] = bytes;
    return bytes;
  }

  static void _remember(String key, Uint8List bytes) {
    _cache.remove(key);
    _cache[key] = bytes;
    while (_cache.length > _kCacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
  }

  @override
  State<KavitaSeriesCover> createState() => _KavitaSeriesCoverState();
}

class _KavitaSeriesCoverState extends State<KavitaSeriesCover> {
  Future<Uint8List>? _future;

  String get _cacheKey => '${widget.server.id}:${widget.series.id}';

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(KavitaSeriesCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server.id != widget.server.id ||
        oldWidget.series.id != widget.series.id) {
      _start();
    }
  }

  void _start() {
    final Uint8List? cached = KavitaSeriesCover._cached(_cacheKey);
    if (cached != null) {
      _future = SynchronousFuture<Uint8List>(cached);
      return;
    }
    final String key = _cacheKey;
    _future = widget.api.fetchSeriesCoverBytes(widget.series.id).then((
      Uint8List bytes,
    ) {
      if (bytes.isNotEmpty) KavitaSeriesCover._remember(key, bytes);
      return bytes;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    Widget placeholder(IconData icon) => ColoredBox(
      color: cs.surfaceContainerHighest,
      child: Center(child: FushiIcon(icon, color: cs.onSurfaceVariant)),
    );
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
        final Uint8List? bytes = snapshot.data;
        if (snapshot.hasError) return placeholder(FushiIcons.brokenImage);
        if (bytes == null || bytes.isEmpty) {
          return placeholder(FushiIcons.books);
        }
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stack) =>
                  placeholder(FushiIcons.brokenImage),
        );
      },
    );
  }
}
