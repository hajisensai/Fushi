/// 浏览**对端借出的一个扩展源**（热门 / 最新 / 搜索 + 过滤器），与
/// `MihonSourceBrowsePage` 同形，只是每一步都打到对端。
///
/// Cloudflare：挑战页只能在跑着扩展的那台对端上弹，本机弹不了——所以这里不挂
/// `MihonCloudflareAction`，而是把对端回的 `cloudflare` 错误翻译成「去 <设备> 上打开
/// 该源完成验证」。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_client.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_host_impl.dart'
    show mihonFilterFromWire, mihonFilterToWire;
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_registry.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_source_library_adapter.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart'
    show MihonFilterDialog;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/sync/manga_sources/host_manga_source_host.dart';

/// 把对端错误翻译成用户能操作的一句话（浏览页 / 搜索段 / 作品页共用）。
String describeInterconnectSourceError(
  Object error,
  InterconnectRemoteSource source,
) {
  if (error is InterconnectMangaSourceException) {
    if (error.isCloudflare) {
      return t.manga_source_interconnect_cloudflare(
        device: source.peer.displayName,
      );
    }
    if (error.isSourceNotFound ||
        error.code == InterconnectMangaSourceException.codeUnavailable) {
      return t.manga_source_interconnect_unavailable;
    }
    return error.message;
  }
  return '$error';
}

class InterconnectSourceBrowsePage extends ConsumerStatefulWidget {
  const InterconnectSourceBrowsePage({
    required this.source,
    super.key,
    this.transport,
    this.registry,
  });

  final InterconnectRemoteSource source;

  /// 测试注入口；生产恒用 [AppModel] 上的单例。
  final InterconnectMangaSourceTransport? transport;
  final InterconnectMangaSourceRegistry? registry;

  @override
  ConsumerState<InterconnectSourceBrowsePage> createState() =>
      _InterconnectSourceBrowsePageState();
}

class _InterconnectSourceBrowsePageState
    extends ConsumerState<InterconnectSourceBrowsePage> {
  final TextEditingController _searchController = TextEditingController();
  List<OnlineMangaSeries> _items = const <OnlineMangaSeries>[];
  List<MihonFilter> _filters = const <MihonFilter>[];
  RemoteMangaBrowseMode _mode = RemoteMangaBrowseMode.popular;
  bool _loading = true;
  bool _hasNextPage = false;
  int _page = 1;
  int _loadGeneration = 0;
  Object? _error;

  InterconnectMangaSourceTransport get _transport =>
      widget.transport ?? ref.read(appProvider).interconnectMangaSourceClient;

  InterconnectMangaSourceRegistry get _registry =>
      widget.registry ?? ref.read(appProvider).interconnectMangaSourceRegistry;

  InterconnectSourceLibraryAdapter get _adapter =>
      InterconnectSourceLibraryAdapter(
        registry: _registry,
        transport: _transport,
        presetSource: widget.source,
      );

  @override
  void initState() {
    super.initState();
    unawaited(_initialise());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initialise() async {
    if (widget.source.info.supportsFilters) {
      try {
        final List<Map<String, Object?>> wire = await _transport.filters(
          widget.source.peer,
          widget.source.id,
        );
        if (!mounted) return;
        _filters = <MihonFilter>[
          for (final Map<String, Object?> f in wire) mihonFilterFromWire(f),
        ];
      } on Object {
        // 过滤器拿不到不挡浏览：没有过滤器按钮而已。
      }
    }
    await _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (!reset && (_loading || !_hasNextPage)) return;
    final int generation = reset ? ++_loadGeneration : _loadGeneration;
    final int requestedPage = reset ? 1 : _page + 1;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final RemoteMangaBrowsePage response = await _transport.browse(
        widget.source.peer,
        widget.source.id,
        mode: _mode,
        page: requestedPage,
        query: _searchController.text.trim(),
        filters: <Map<String, Object?>>[
          for (final MihonFilter f in _filters) mihonFilterToWire(f),
        ],
      );
      if (!mounted || generation != _loadGeneration) return;
      final List<OnlineMangaSeries> parsed = <OnlineMangaSeries>[
        for (final Map<String, Object?> json in response.items)
          if (OnlineMangaSeries.fromJson(json) case final OnlineMangaSeries s)
            s,
      ];
      setState(() {
        final List<OnlineMangaSeries> previous = reset
            ? const <OnlineMangaSeries>[]
            : _items;
        final Set<String> seen = previous
            .map((OnlineMangaSeries s) => s.key)
            .toSet();
        final List<OnlineMangaSeries> additions = parsed
            .where((OnlineMangaSeries s) => seen.add(s.key))
            .toList();
        _items = <OnlineMangaSeries>[...previous, ...additions];
        _page = requestedPage;
        _hasNextPage =
            response.hasNextPage &&
            parsed.isNotEmpty &&
            (reset || additions.isNotEmpty);
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error;
      });
      if (_items.isNotEmpty) {
        FushiToast.show(
          msg: describeInterconnectSourceError(error, widget.source),
          severity: ToastSeverity.error,
        );
      }
    }
  }

  Future<void> _showFilters() async {
    if (_filters.isEmpty) return;
    final List<MihonFilter>? updated = await showAppDialog<List<MihonFilter>>(
      context: context,
      builder: (BuildContext dialogContext) =>
          MihonFilterDialog(initial: _filters),
    );
    if (updated == null || !mounted) return;
    _filters = updated;
    _mode = RemoteMangaBrowseMode.search;
    await _load(reset: true);
  }

  void _openDetails(OnlineMangaSeries series) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => InterconnectSourceMangaDetailPage(
          source: widget.source,
          series: series,
          transport: widget.transport,
          registry: widget.registry,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: widget.source.name,
      headerBottom: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('interconnect_source_search'),
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: t.mihon_source_search,
                  prefixIcon: const Icon(Icons.search),
                ),
                onSubmitted: (String _) {
                  _mode = RemoteMangaBrowseMode.search;
                  unawaited(_load(reset: true));
                },
              ),
            ),
            if (_filters.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              IconButton(
                tooltip: t.mihon_source_preferences,
                onPressed: _showFilters,
                icon: const Icon(Icons.tune),
              ),
            ],
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SegmentedButton<RemoteMangaBrowseMode>(
                    segments: <ButtonSegment<RemoteMangaBrowseMode>>[
                      ButtonSegment<RemoteMangaBrowseMode>(
                        value: RemoteMangaBrowseMode.popular,
                        label: Text(t.mihon_source_popular),
                      ),
                      if (widget.source.info.supportsLatest)
                        ButtonSegment<RemoteMangaBrowseMode>(
                          value: RemoteMangaBrowseMode.latest,
                          label: Text(t.mihon_source_latest),
                        ),
                    ],
                    selected: <RemoteMangaBrowseMode>{
                      _mode == RemoteMangaBrowseMode.latest
                          ? RemoteMangaBrowseMode.latest
                          : RemoteMangaBrowseMode.popular,
                    },
                    onSelectionChanged: (Set<RemoteMangaBrowseMode> value) {
                      _mode = value.first;
                      unawaited(_load(reset: true));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                InterconnectSourceBadge(device: widget.source.peer.displayName),
              ],
            ),
          ),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_loading && _items.isEmpty) {
      return Center(child: adaptiveIndicator(context: context));
    }
    final Object? error = _error;
    if (error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                describeInterconnectSourceError(error, widget.source),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => unawaited(_load(reset: true)),
                child: Text(t.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(child: Text(t.mihon_source_no_results));
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return GridView.builder(
          padding: withBottomSafeInset(context, const EdgeInsets.all(16)),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: 0.62,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: _items.length + (_hasNextPage ? 1 : 0),
          itemBuilder: (BuildContext context, int index) {
            if (index == _items.length) {
              return Center(
                child: _loading
                    ? adaptiveIndicator(context: context)
                    : IconButton(
                        onPressed: () => unawaited(_load(reset: false)),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
              );
            }
            final OnlineMangaSeries series = _items[index];
            return FushiCard(
              padding: EdgeInsets.zero,
              onTap: () => _openDetails(series),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: InterconnectSourceCover(
                      source: widget.source,
                      series: series,
                      adapter: _adapter,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      series.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// 「互联 · 经 <设备>」小徽标：发现页卡片 / 热门行 / 搜索段与浏览页共用一个形状，
/// 用户一眼分得出这是从哪台设备借来的源。
class InterconnectSourceBadge extends StatelessWidget {
  const InterconnectSourceBadge({required this.device, super.key});

  final String device;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.devices_outlined,
            size: 14,
            color: cs.onSecondaryContainer,
          ),
          const SizedBox(width: 4),
          Text(
            '${t.manga_discovery_source_interconnect_badge} · '
            '${t.manga_source_interconnect_via_device(device: device)}',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: cs.onSecondaryContainer),
          ),
        ],
      ),
    );
  }
}

/// 未入库作品的封面（经对端取，磁盘缓存按源分槽）。
class InterconnectSourceCover extends StatelessWidget {
  const InterconnectSourceCover({
    required this.source,
    required this.series,
    required this.adapter,
    super.key,
  });

  final InterconnectRemoteSource source;
  final OnlineMangaSeries series;
  final InterconnectSourceLibraryAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final String? url = series.coverUrl;
    if (url == null || url.isEmpty) {
      return const ColoredBox(
        color: Colors.black12,
        child: Center(child: Icon(Icons.image_not_supported_outlined)),
      );
    }
    return Image(
      image: RemoteCoverImage(
        url,
        adapter.coverFetcher(source),
        cacheKey: series.key,
      ),
      fit: BoxFit.cover,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          const ColoredBox(
            color: Colors.black12,
            child: Center(child: Icon(Icons.broken_image_outlined)),
          ),
    );
  }
}

/// 源浏览里的作品页入口（与 `MihonMangaDetailPage` 同构）：把对端源翻译成运行时
/// 无关的 seed，页面本体交给 [MangaSeriesPage]。
class InterconnectSourceMangaDetailPage extends ConsumerWidget {
  const InterconnectSourceMangaDetailPage({
    required this.source,
    required this.series,
    super.key,
    this.transport,
    this.registry,
  });

  final InterconnectRemoteSource source;
  final OnlineMangaSeries series;
  final InterconnectMangaSourceTransport? transport;
  final InterconnectMangaSourceRegistry? registry;

  /// 与 [OnlineMangaLibraryEntry] 的身份约定：包 = 互联占位、源 = 对端源 id。
  static OnlineMangaLibraryEntry seedFor(
    InterconnectRemoteSource source,
    OnlineMangaSeries series,
  ) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.interconnectSource,
    extensionPackage: kInterconnectMangaPackage,
    sourceId: source.id,
    series: series,
    chapters: const <OnlineMangaChapter>[],
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel appModel = ref.read(appProvider);
    final InterconnectSourceLibraryAdapter adapter =
        InterconnectSourceLibraryAdapter(
          registry: registry ?? appModel.interconnectMangaSourceRegistry,
          transport: transport ?? appModel.interconnectMangaSourceClient,
          presetSource: source,
        );
    return MangaSeriesPage(
      target: SourceMangaSeriesTarget(
        adapter: adapter,
        // 带着**自己那份**（可能是测试注入的）transport 建服务，与 Aidoku 详情页
        // 不走 `AppModel.onlineMangaLibraryService` 的理由相同。
        service: OnlineMangaLibraryService(
          database: appModel.database,
          rootDirectory: appModel.interconnectMangaLibraryRoot,
          adapter: adapter,
          updateFeed: appModel.updateFeedService,
        ),
        seed: seedFor(source, series),
        sourceLabel: InterconnectSourceLibraryAdapter.sourceLabelFor(
          source.name,
          source.peer.displayName,
        ),
        remoteCoverBuilder: (BuildContext context) => InterconnectSourceCover(
          source: source,
          series: series,
          adapter: adapter,
        ),
      ),
    );
  }
}
