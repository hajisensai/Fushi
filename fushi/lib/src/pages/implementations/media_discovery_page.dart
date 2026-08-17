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
import 'package:fushi/src/pages/implementations/download_actions.dart';
import 'package:fushi/utils.dart';

/// 统一发现页：书（小说/有声书）与 galgame 共用的多源在线资源发现视图。
///
/// 结构：媒体域筛选（多域时）+ 源下拉（默认「全部源」聚合）+ 搜索框 +
/// 结果列表（目录可下钻、资源可下载）。下载分流按条目 payloadKind：
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

/// 源下拉「全部源」哨兵（DropdownMenu 泛型不便用 null）。
const String _kAllSources = '';

class _MediaDiscoveryPageState extends State<MediaDiscoveryPage> {
  late DiscoveryMediaKind _kind = widget.kinds.first;
  String _sourceId = _kAllSources;
  final TextEditingController _queryCtrl = TextEditingController();

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
    super.dispose();
  }

  Future<void> _load({bool append = false}) async {
    final AppModel? appModel = _resolveAppModel();
    if (appModel == null) return;
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
      final DiscoveryAggregateResult result =
          await appModel.mediaDiscoveryService.load(
        request,
        sourceId: _sourceId == _kAllSources ? null : _sourceId,
        disabledSourceIds: _sourceId == _kAllSources
            ? appModel.discoveryDisabledSourceIds
            : const <String>{},
      );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _result = result;
        _entries.addAll(result.entries);
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
      _sourceId = _kAllSources;
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
        DiscoveryMediaKind.manga => t.library_view_browse,
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.kinds.length > 1)
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: SegmentedButton<DiscoveryMediaKind>(
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
              ),
            ),
          Row(
            children: <Widget>[
              DropdownMenu<String>(
                key: const ValueKey<String>('discovery_source_menu'),
                initialSelection: _sourceId,
                requestFocusOnTap: false,
                onSelected: (String? value) =>
                    _selectSource(value ?? _kAllSources),
                dropdownMenuEntries: <DropdownMenuEntry<String>>[
                  DropdownMenuEntry<String>(
                    value: _kAllSources,
                    label: t.discovery_all_sources,
                  ),
                  for (final MediaDiscoverySource source in sources)
                    DropdownMenuEntry<String>(
                      value: source.id,
                      label: source.displayName,
                    ),
                ],
              ),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('discovery_search_field'),
                  controller: _queryCtrl,
                  decoration: InputDecoration(
                    hintText: t.discovery_search_hint,
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (String _) {
                    _pathStack.clear();
                    unawaited(_load());
                  },
                ),
              ),
            ],
          ),
          if (_pathStack.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.gap),
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
            ),
        ],
      ),
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
      final bool idle = _queryCtrl.text.trim().isEmpty && _result == null;
      return Center(
        child: Text(
          idle ? t.discovery_enter_query_hint : t.discovery_empty,
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
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }
}
