import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart';
import 'package:fushi/utils.dart';

/// 统一发现页：书（小说/有声书）与 galgame 共用的多源在线资源发现视图。
///
/// 结构：媒体域筛选（多域时）+ 来源下拉（默认「全部来源」）+ 搜索框 +
/// 结果列表（目录可下钻、资源可下载）。**「全部来源」只做搜索**：空查询时不
/// 发任何请求，正文列出候选来源让用户先选一个（聚合浏览没有语义，硬做只会
/// 退化成某个恰好支持浏览的源的根目录，见 BUG-1711）。下载分流按条目 payloadKind：
/// torrent → `pushGenericMagnet`（既有 torrent 后端 + 自动入库），
/// http 直链 → `AppModel.discoveryDownloadQueue`（下载完自动入库）。
/// 单源失败亮徽标不拖垮整页（`DiscoveryAggregateResult` 部分成功语义）。
///
/// **构建期零 provider 依赖**：游戏页 IndexedStack 急切构建全部子区，本页
/// 在无 ProviderScope 的 widget 测试里也会被 build——容器只在首帧后加载与
/// 交互时解析（同 `_buildImport` 的 QuickImportSection 约定）。
class MediaDiscoveryPage extends StatefulWidget {
  const MediaDiscoveryPage({
    required this.kinds,
    this.navigation,
    super.key,
  });

  /// 本页覆盖的媒体域（书域传 [novel, audiobook]，游戏域传 [game]）。
  final List<DiscoveryMediaKind> kinds;

  /// 库页壳注入的分段导航（嵌在头部；游戏域自带段条时传 null 由外层包）。
  final Widget? navigation;

  @override
  State<MediaDiscoveryPage> createState() => _MediaDiscoveryPageState();
}

/// 空查询时的页面态。只有 [none] 才该向源发请求——另外两态发出去要么无语义、
/// 要么必然失败，本页据此在首帧就分流（BUG-1711）。
enum _DiscoveryIdle {
  /// 有关键词，或单源且该源支持目录浏览：正常发请求。
  none,

  /// 「全部来源」+ 空查询：聚合没有浏览语义，先让用户选来源。
  pickSource,

  /// 单源 + 空查询，但该源只支持关键词搜索：请求必然收到 unsupported。
  queryRequired,
}

class _MediaDiscoveryPageState extends State<MediaDiscoveryPage> {
  late DiscoveryMediaKind _kind = widget.kinds.first;
  String _sourceId = kDiscoveryAllSourcesId;
  final TextEditingController _queryCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 首帧后解析到的全局模型；无 ProviderScope（纯布局测试）时保持 null，
  /// 页面停留在提示态。
  AppModel? _appModel;

  AppModel? _resolveAppModel() {
    if (_appModel != null) return _appModel;
    try {
      _appModel =
          ProviderScope.containerOf(context, listen: false).read(appProvider);
    } on StateError {
      return null;
    }
    return _appModel;
  }

  /// 目录下钻栈（(源内路径, 显示名)）；只在单源模式下非空。
  final List<(String, String)> _pathStack = <(String, String)>[];

  final List<DiscoveryEntry> _entries = <DiscoveryEntry>[];
  DiscoveryAggregateResult? _result;
  bool _loading = false;
  Object? _error;
  int _page = 1;

  /// 竞态哨兵：晚到的旧请求结果不覆盖新状态。
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 当前（空查询下的）页面态，见 [_DiscoveryIdle]。
  _DiscoveryIdle _idleMode(AppModel appModel) {
    if (_queryCtrl.text.trim().isNotEmpty) return _DiscoveryIdle.none;
    if (_sourceId == kDiscoveryAllSourcesId) return _DiscoveryIdle.pickSource;
    final MediaDiscoverySource? source =
        appModel.mediaDiscoveryService.sourceById(_sourceId);
    if (source != null && !source.capabilities.supportsBrowse) {
      return _DiscoveryIdle.queryRequired;
    }
    return _DiscoveryIdle.none;
  }

  Future<void> _load({bool append = false}) async {
    final AppModel? appModel = _resolveAppModel();
    if (appModel == null) return;
    // 「空查询 = 目录浏览」是错的：聚合模式没有浏览语义（真发出去会被服务层
    // 挡下），只支持搜索的单源也只会换回一块 unsupported 牌坊。这两态一个请求
    // 都不发，正文改成引导态。
    if (_idleMode(appModel) != _DiscoveryIdle.none) {
      _loadSeq++; // 作废在途请求：晚到的结果不许回填引导态
      setState(() {
        _loading = false;
        _error = null;
        _page = 1;
        _entries.clear();
        _result = null;
      });
      return;
    }
    final String query = _queryCtrl.text.trim();
    final bool browsing = query.isEmpty;
    final int seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
      if (!append) {
        _page = 1;
        _entries.clear();
        _result = null;
      }
    });
    try {
      final DiscoveryRequest request = DiscoveryRequest(
        kind: _kind,
        query: browsing ? null : query,
        path: browsing && _pathStack.isNotEmpty ? _pathStack.last.$1 : null,
        page: _page,
      );
      // 追加页（加载更多）不做渐进：旧条目要保序，等整页齐了再接尾。
      final List<DiscoveryEntry> base =
          append ? List<DiscoveryEntry>.of(_entries) : const <DiscoveryEntry>[];
      final DiscoveryAggregateResult result =
          await appModel.mediaDiscoveryService.load(
        request,
        sourceId: _sourceId == kDiscoveryAllSourcesId ? null : _sourceId,
        disabledSourceIds: _sourceId == kDiscoveryAllSourcesId
            ? appModel.discoveryDisabledSourceIds
            : const <String>{},
        // 渐进交付：快源先上屏，不等慢源（模式与漫画全源搜索一致）。
        onUpdate: append
            ? null
            : (DiscoveryAggregateResult partial) {
                if (!mounted || seq != _loadSeq) return;
                setState(() {
                  _result = partial;
                  _entries
                    ..clear()
                    ..addAll(partial.entries);
                });
              },
      );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _result = result;
        _entries
          ..clear()
          ..addAll(base)
          ..addAll(result.entries);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  void _selectKind(DiscoveryMediaKind kind) {
    if (kind == _kind) return;
    setState(() {
      _kind = kind;
      _sourceId = kDiscoveryAllSourcesId;
      _pathStack.clear();
    });
    unawaited(_load());
  }

  void _selectSource(String sourceId) {
    if (sourceId == _sourceId) return;
    setState(() {
      _sourceId = sourceId;
      _pathStack.clear();
    });
    unawaited(_load());
  }

  void _openFolder(DiscoveryFolder folder) {
    setState(() {
      // 聚合模式下点进某源的目录 = 隐式切到该源（深层路径是源内语义）。
      _sourceId = folder.sourceId;
      _pathStack.add((folder.path, folder.title));
    });
    unawaited(_load());
  }

  /// 提交搜索/清空搜索：路径栈属于上一轮浏览，必须先清掉。
  void _submitSearch() {
    _pathStack.clear();
    unawaited(_load());
  }

  void _popFolder() {
    if (_pathStack.isEmpty) return;
    setState(() => _pathStack.removeLast());
    unawaited(_load());
  }

  Future<void> _download(DiscoveryResourceItem item) async {
    final AppModel? appModel = _resolveAppModel();
    if (appModel == null) return;
    switch (item.payloadKind) {
      case DiscoveryPayloadKind.torrent:
        final DiscoveryPayload? payload = item.payload;
        if (payload is! DiscoveryTorrentPayload) return;
        final GenericPushOutcome outcome = await pushGenericMagnet(
          context: context,
          appModel: appModel,
          magnet: payload.magnetUri,
          contentKind: switch (item.kind) {
            DiscoveryMediaKind.novel => AnimeDownloadPlan.kindBook,
            DiscoveryMediaKind.audiobook => AnimeDownloadPlan.kindAudiobook,
            DiscoveryMediaKind.game => AnimeDownloadPlan.kindGame,
            DiscoveryMediaKind.manga => AnimeDownloadPlan.kindAuto,
          },
        );
        FushiToast.show(
          msg: genericPushMessage(outcome),
          severity: outcome == GenericPushOutcome.ok
              ? ToastSeverity.success
              : ToastSeverity.error,
        );
      case DiscoveryPayloadKind.httpFile:
        final bool added = appModel.discoveryDownloadQueue.enqueue(
          item,
          destinationDir: appModel.discoveryDownloadDirFor(item.kind),
        );
        if (added) {
          FushiToast.show(
            msg: t.discovery_download_queued,
            severity: ToastSeverity.success,
          );
        }
    }
  }

  String _kindLabel(DiscoveryMediaKind kind) => switch (kind) {
        DiscoveryMediaKind.novel => t.discovery_kind_novel,
        DiscoveryMediaKind.audiobook => t.discovery_kind_audiobook,
        DiscoveryMediaKind.game => t.game_library,
        DiscoveryMediaKind.manga => t.discovery_kind_manga,
      };

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const List<String> units = <String>['KiB', 'MiB', 'GiB', 'TiB'];
    double value = bytes / 1024;
    int unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }

  String _subtitleFor(
    DiscoveryResourceItem item,
    MediaDiscoveryService service,
  ) {
    final List<String> parts = <String>[
      service.sourceById(item.sourceId)?.displayName ?? item.sourceId,
      if (item.sizeBytes != null) _formatBytes(item.sizeBytes!),
      if (item.dateText != null) item.dateText!,
      if (item.seeders != null) '↑${item.seeders}',
      if (item.note != null) item.note!,
    ];
    return parts.join(' · ');
  }

  Widget _buildControls(BuildContext context) {
    final List<MediaDiscoverySource> sources =
        _appModel?.mediaDiscoveryService.sourcesFor(_kind) ??
            const <MediaDiscoverySource>[];
    return DiscoveryHeaderControls(
      sources: <DiscoverySourceOption>[
        for (final MediaDiscoverySource source in sources)
          DiscoverySourceOption(id: source.id, label: source.displayName),
      ],
      selectedSourceId: _sourceId,
      onSourceSelected: _selectSource,
      searchController: _queryCtrl,
      searchFocusNode: _searchFocus,
      searchHintText: t.discovery_search_hint,
      onSearchSubmitted: (String _) => _submitSearch(),
      onSearchCleared: () {
        _queryCtrl.clear();
        _submitSearch();
      },
      leading: widget.kinds.length > 1
          ? SegmentedButton<DiscoveryMediaKind>(
              segments: <ButtonSegment<DiscoveryMediaKind>>[
                for (final DiscoveryMediaKind kind in widget.kinds)
                  ButtonSegment<DiscoveryMediaKind>(
                    value: kind,
                    label: Text(_kindLabel(kind)),
                  ),
              ],
              selected: <DiscoveryMediaKind>{_kind},
              onSelectionChanged: (Set<DiscoveryMediaKind> selection) =>
                  _selectKind(selection.first),
            )
          : null,
    );
  }

  /// 目录下钻面包屑（只在单源浏览时有内容）。
  Widget _buildBreadcrumb(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: tokens.spacing.page,
        right: tokens.spacing.page,
        top: tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          FushiIconButton(
            icon: Icons.arrow_upward,
            tooltip: t.back,
            label: t.back,
            onTap: _popFolder,
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              _pathStack.map(((String, String) e) => e.$2).join(' / '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 「全部来源」+ 空查询的引导态：把候选来源摆出来让用户点，而不是把某个
  /// 恰好支持浏览的源的根目录冒充成聚合结果。
  Widget _buildSourcePicker(
    BuildContext context,
    MediaDiscoveryService service,
  ) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            t.discovery_source_pick_hint,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        for (final MediaDiscoverySource source in service.sourcesFor(_kind))
          FushiListItem(
            key: ValueKey<String>('discovery_source_pick_${source.id}'),
            leading: const Icon(Icons.travel_explore_outlined),
            title: Text(source.displayName),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _selectSource(source.id),
          ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final AppModel? appModel = _appModel;
    final ThemeData theme = Theme.of(context);
    if (appModel == null) {
      return Center(
        child: Text(
          t.discovery_enter_query_hint,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    final MediaDiscoveryService service = appModel.mediaDiscoveryService;
    final DiscoveryDownloadQueue queue = appModel.discoveryDownloadQueue;

    switch (_idleMode(appModel)) {
      case _DiscoveryIdle.pickSource:
        return _buildSourcePicker(context, service);
      case _DiscoveryIdle.queryRequired:
        return Center(
          child: Text(
            t.discovery_source_query_required,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        );
      case _DiscoveryIdle.none:
        break;
    }

    if (_error != null) {
      return Center(
        child: Text(
          t.discovery_partial_failure,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.error),
        ),
      );
    }
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_entries.isEmpty) {
      // 空查询的两种引导态已在上面分流：能走到这里的空列表就是真·无结果。
      return Center(
        child: Text(
          t.discovery_empty,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    final DiscoveryAggregateResult? result = _result;
    return AnimatedBuilder(
      animation: queue,
      builder: (BuildContext context, Widget? _) => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (result != null && result.hasFailures)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${t.discovery_partial_failure} '
                '(${result.failures.map((ExternalProviderFailure f) => f.providerId).toSet().join(', ')})',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          for (final DiscoveryEntry entry in _entries)
            switch (entry) {
              DiscoveryFolder() => FushiListItem(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(entry.title),
                  // 目录条目不带来源名，用户看不出这是哪个站的目录。
                  subtitle: Text(
                    service.sourceById(entry.sourceId)?.displayName ??
                        entry.sourceId,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openFolder(entry),
                ),
              DiscoveryResourceItem() => FushiListItem(
                  leading: Icon(
                    entry.payloadKind == DiscoveryPayloadKind.torrent
                        ? Icons.link
                        : Icons.insert_drive_file_outlined,
                  ),
                  title: Text(entry.title),
                  titleMaxLines: 2,
                  subtitle: Text(_subtitleFor(entry, service)),
                  trailing: queue.isPending(entry)
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FushiIconButton(
                          icon: Icons.download_outlined,
                          tooltip: t.anime_download_generic_download,
                          label: t.anime_download_generic_download,
                          onTap: () => unawaited(_download(entry)),
                        ),
                  onTap: () => unawaited(_download(entry)),
                ),
            },
          if (result != null && result.hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : TextButton(
                        onPressed: () {
                          _page++;
                          unawaited(_load(append: true));
                        },
                        child: Text(t.discovery_load_more),
                      ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget? navigation = widget.navigation;
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (navigation != null)
            FushiPageHeader.customTitle(
              title: navigation,
              actions: const <Widget>[],
            ),
          _buildControls(context),
          if (_pathStack.isNotEmpty) _buildBreadcrumb(context),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }
}
