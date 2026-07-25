import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_client.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/utils.dart';

/// 测试注入口：替换真实 [MokuroMoeVolumeDownloader.run]（widget 测试绕网络/DB）。
typedef MokuroMoeVolumeRunner = Stream<MokuroMoeVolumeDownloadEvent> Function({
  required String seriesName,
  required String volumeName,
});

/// mokuro.moe「在线目录」对话框（O1）：浏览/搜索系列 → 选卷 → 顺序逐卷
/// 下载（断点续传）→ 现有 `.mokuro` 导入链落库。
///
/// 照 [MangaOcrWizardDialog] 范式：依赖全构造注入（[clientOverride] /
/// [runnerOverride] 供 widget 测试绕网络），阶段机 [_CatalogStage]，dispose
/// 取消订阅。关闭时 `Navigator.pop(context, <int 本次成功导入卷数>)`——调用方
/// 据 `> 0` 决定是否刷新书架。
class MokuroMoeCatalogDialog extends ConsumerStatefulWidget {
  const MokuroMoeCatalogDialog({
    required this.db,
    this.clientOverride,
    this.runnerOverride,
    super.key,
  });

  /// 目标数据库（漫画行写入此处）。
  final HibikiDatabase db;

  /// 测试用 client（null = 按偏好 base URL 构造真实 client）。
  final MokuroMoeClient? clientOverride;

  /// 测试用下载编排（null = 真实 [MokuroMoeVolumeDownloader]）。
  final MokuroMoeVolumeRunner? runnerOverride;

  @override
  ConsumerState<MokuroMoeCatalogDialog> createState() =>
      _MokuroMoeCatalogDialogState();
}

/// 对话框所处阶段。
enum _CatalogStage { browse, series, downloading }

class _MokuroMoeCatalogDialogState
    extends ConsumerState<MokuroMoeCatalogDialog> {
  late final MokuroMoeClient _client;
  final TextEditingController _searchCtrl = TextEditingController();

  _CatalogStage _stage = _CatalogStage.browse;

  // browse。
  List<MokuroMoeSeries>? _library;
  bool _loading = false;
  String? _loadError;
  String _query = '';

  // series。
  MokuroMoeSeries? _series;
  final Set<String> _selectedVolumes = <String>{};

  /// 已在库的书身份 key（`sanitizeTtuFilename(title)`；含本次会话新导入的）。
  final Set<String> _existingBookKeys = <String>{};

  // downloading。
  StreamSubscription<MokuroMoeVolumeDownloadEvent>? _sub;
  MokuroMoeVolumeDownloader? _activeDownloader;
  bool _cancelRequested = false;
  String? _activeVolume;
  MokuroMoeVolumeDownloadEvent? _lastEvent;
  int _queueIndex = 0;
  int _queueTotal = 0;
  String? _downloadError;

  /// 本次会话成功导入（新建行）的卷数——关闭时回传给调用方。
  int _importedCount = 0;

  @override
  void initState() {
    super.initState();
    _client = widget.clientOverride ??
        MokuroMoeClient(
          baseUrl: ref.read(appProvider).mangaOnlineCatalogBaseUrl,
        );
    unawaited(_loadLibrary());
    unawaited(_loadExistingBooks());
  }

  @override
  void dispose() {
    // 对话框被任何途径关掉（Esc/barrier/pop）都不能留下后台孤儿下载：
    // cancel 保留 .part，下次打开同卷续传。
    _activeDownloader?.cancel();
    unawaited(_sub?.cancel());
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLibrary() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final List<MokuroMoeSeries> library = await _client.fetchLibrary();
      if (!mounted) return;
      setState(() {
        _library = library;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  Future<void> _loadExistingBooks() async {
    final List<EpubBookRow> rows = await widget.db.getAllEpubBooks();
    if (!mounted) return;
    setState(() {
      _existingBookKeys
          .addAll(rows.map((EpubBookRow r) => sanitizeTtuFilename(r.title)));
    });
  }

  /// 一卷的入库身份 key（与导入侧 [MokuroMoeVolumeDownloader.volumeTitle] 同源）。
  String _volumeKey(String volume) => sanitizeTtuFilename(
      MokuroMoeVolumeDownloader.volumeTitle(_series?.name ?? '', volume));

  bool _isImported(String volume) =>
      _existingBookKeys.contains(_volumeKey(volume));

  List<MokuroMoeSeries> get _filteredSeries {
    final List<MokuroMoeSeries> all = _library ?? const <MokuroMoeSeries>[];
    final String q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((MokuroMoeSeries s) => s.name.toLowerCase().contains(q))
        .toList();
  }

  void _openSeries(MokuroMoeSeries series) {
    setState(() {
      _series = series;
      _selectedVolumes.clear();
      _downloadError = null;
      _stage = _CatalogStage.series;
    });
  }

  void _backToBrowse() {
    setState(() {
      _series = null;
      _selectedVolumes.clear();
      _downloadError = null;
      _stage = _CatalogStage.browse;
    });
  }

  Future<void> _downloadSelected() async {
    final MokuroMoeSeries? series = _series;
    if (series == null || _selectedVolumes.isEmpty) return;
    final List<String> queue = series.volumes
        .map((MokuroMoeVolume v) => v.name)
        .where(_selectedVolumes.contains)
        .toList();
    setState(() {
      _stage = _CatalogStage.downloading;
      _cancelRequested = false;
      _downloadError = null;
      _queueIndex = 0;
      _queueTotal = queue.length;
    });
    for (int i = 0; i < queue.length; i++) {
      if (!mounted || _cancelRequested) break;
      setState(() {
        _queueIndex = i;
        _activeVolume = queue[i];
        _lastEvent = null;
      });
      final bool ok = await _runVolume(series.name, queue[i]);
      if (!mounted) return;
      if (!ok) break; // 失败/取消即停队列（错误已展示；续传靠 .part）。
    }
    if (!mounted) return;
    setState(() {
      _activeVolume = null;
      _activeDownloader = null;
      _stage = _CatalogStage.series;
    });
  }

  /// 跑一卷；成功（含「已在库跳过」）返回 true。
  Future<bool> _runVolume(String seriesName, String volumeName) {
    final Completer<bool> completer = Completer<bool>();
    final Stream<MokuroMoeVolumeDownloadEvent> stream;
    if (widget.runnerOverride != null) {
      _activeDownloader = null;
      stream = widget.runnerOverride!(
          seriesName: seriesName, volumeName: volumeName);
    } else {
      final MokuroMoeVolumeDownloader downloader =
          MokuroMoeVolumeDownloader(client: _client);
      _activeDownloader = downloader;
      stream = downloader.run(
        db: widget.db,
        seriesName: seriesName,
        volumeName: volumeName,
      );
    }
    _sub = stream.listen(
      (MokuroMoeVolumeDownloadEvent event) {
        if (!mounted) return;
        setState(() {
          _lastEvent = event;
          if (event.stage == MokuroMoeDownloadStage.done) {
            // 新建行与「已在库」都标记 ✓（不可重复下）；只有新建行计数。
            _existingBookKeys.add(_volumeKey(volumeName));
            _selectedVolumes.remove(volumeName);
            if (!event.skippedExisting && event.bookKey != null) {
              _importedCount++;
            }
          }
        });
        if (event.stage == MokuroMoeDownloadStage.done) {
          HibikiToast.show(msg: t.manga_ocr_wizard_done);
        }
      },
      onError: (Object e) {
        if (mounted && e is! MokuroMoeDownloadCancelled) {
          setState(() => _downloadError = '${t.manga_online_failed}: $e');
        }
        if (!completer.isCompleted) completer.complete(false);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(_lastEvent?.stage == MokuroMoeDownloadStage.done);
        }
      },
    );
    return completer.future;
  }

  void _cancelDownload() {
    _cancelRequested = true;
    final MokuroMoeVolumeDownloader? downloader = _activeDownloader;
    if (downloader != null) {
      downloader.cancel();
    } else {
      // 注入 runner（测试）没有 cancel 通道：直接掐订阅结束本卷。
      unawaited(_sub?.cancel());
      setState(() {
        _activeVolume = null;
        _stage = _CatalogStage.series;
      });
    }
  }

  void _close() => Navigator.pop(context, _importedCount);

  // ── UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // Esc/返回键关闭也必须带上 _importedCount 回传（否则调用方拿 null，
    // 已导入的卷丢失书架刷新信号）——统一拦下来走 _close。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          _close();
        }
      },
      child: _buildDialog(tokens),
    );
  }

  Widget _buildDialog(HibikiDesignTokens tokens) {
    return AlertDialog(
      title: Text(
        _stage == _CatalogStage.browse
            ? t.manga_online_catalog_title
            : (_series?.name ?? t.manga_online_catalog_title),
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 560,
        height: 440,
        child: _stage == _CatalogStage.browse
            ? _buildBrowse(tokens)
            : _buildSeries(tokens),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildBrowse(HibikiDesignTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: t.manga_online_search_hint,
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (String value) => setState(() => _query = value),
        ),
        SizedBox(height: tokens.spacing.gap),
        Expanded(child: _buildBrowseBody(tokens)),
      ],
    );
  }

  Widget _buildBrowseBody(HibikiDesignTokens tokens) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? error = _loadError;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '${t.manga_online_load_failed}: $error',
              style: tokens.type.listSubtitle
                  .copyWith(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: tokens.spacing.gap),
            OutlinedButton(
              onPressed: _loadLibrary,
              child: Text(t.retry),
            ),
          ],
        ),
      );
    }
    final List<MokuroMoeSeries> series = _filteredSeries;
    // 千余系列：GridView.builder 懒构建。
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 128,
        childAspectRatio: 0.58,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: series.length,
      itemBuilder: (BuildContext context, int index) =>
          _buildSeriesTile(tokens, series[index]),
    );
  }

  Widget _buildSeriesTile(HibikiDesignTokens tokens, MokuroMoeSeries series) {
    // 无封面占位：MD3 tokens 面色（overlay = 最高 tonal 层），不裸引 scheme 角色。
    final Widget placeholder = ColoredBox(
      color: tokens.surfaces.overlay,
      child: Icon(Icons.menu_book_outlined, color: tokens.surfaces.onVariant),
    );
    return InkWell(
      borderRadius: tokens.radii.cardRadius,
      onTap: () => _openSeries(series),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: tokens.radii.cardRadius,
              child: series.cover.isEmpty
                  ? placeholder
                  : Image(
                      image: CachedNetworkImageProvider(
                        _client.coverUrl(series.cover),
                        cacheKey: 'mokuromoe|${series.name}',
                      ),
                      fit: BoxFit.cover,
                      errorBuilder:
                          (BuildContext _, Object __, StackTrace? ___) =>
                              placeholder,
                    ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            series.name,
            style: tokens.type.metadata,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildSeries(HibikiDesignTokens tokens) {
    final MokuroMoeSeries? series = _series;
    if (series == null) return const SizedBox.shrink();
    final bool downloading = _stage == _CatalogStage.downloading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (downloading) _buildDownloadPanel(tokens),
        if (_downloadError != null)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: Text(
              _downloadError!,
              style: tokens.type.listSubtitle
                  .copyWith(color: Theme.of(context).colorScheme.error),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: series.volumes.length,
            itemBuilder: (BuildContext context, int index) =>
                _buildVolumeRow(tokens, series.volumes[index], downloading),
          ),
        ),
      ],
    );
  }

  Widget _buildVolumeRow(
    HibikiDesignTokens tokens,
    MokuroMoeVolume volume,
    bool downloading,
  ) {
    final bool imported = _isImported(volume.name);
    final bool active = downloading && _activeVolume == volume.name;
    final Widget? subtitle = imported
        ? Text(t.manga_online_downloaded, style: tokens.type.listSubtitle)
        : (active
            ? Text(_stageLabel(),
                style: tokens.type.listSubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis)
            : null);
    // 手排行（MD3 tokens 间距），不走 ListTile（MD3 守卫：普通 chrome 统一走
    // 共享 tokens 布局）。
    return InkWell(
      borderRadius: tokens.radii.controlRadius,
      onTap: imported || downloading
          ? null
          : () => setState(() {
                if (!_selectedVolumes.remove(volume.name)) {
                  _selectedVolumes.add(volume.name);
                }
              }),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap,
          vertical: tokens.spacing.gap / 2,
        ),
        child: Row(
          children: <Widget>[
            if (imported)
              Icon(Icons.check_circle, color: tokens.surfaces.primary)
            else
              Checkbox(
                value: _selectedVolumes.contains(volume.name),
                onChanged: downloading
                    ? null
                    : (bool? checked) => setState(() {
                          if (checked == true) {
                            _selectedVolumes.add(volume.name);
                          } else {
                            _selectedVolumes.remove(volume.name);
                          }
                        }),
              ),
            SizedBox(width: tokens.spacing.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    volume.name,
                    style: tokens.type.listTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null) subtitle,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadPanel(HibikiDesignTokens tokens) {
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '${t.manga_online_queue_progress(done: _queueIndex + 1, total: _queueTotal)}'
            ' · ${_stageLabel()}',
            style: tokens.type.listSubtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          LinearProgressIndicator(value: _progressValue()),
        ],
      ),
    );
  }

  /// 当前卷的确定性进度（0..1）；未知总量阶段回 null（转圈条）。
  double? _progressValue() {
    final MokuroMoeVolumeDownloadEvent? event = _lastEvent;
    if (event == null) return null;
    switch (event.stage) {
      case MokuroMoeDownloadStage.downloadingCbz:
        final int? total = event.totalBytes;
        if (total == null || total <= 0) return null;
        return (event.receivedBytes / total).clamp(0.0, 1.0);
      case MokuroMoeDownloadStage.importing:
        if (event.pagesTotal <= 0) return null;
        return (event.pagesDone / event.pagesTotal).clamp(0.0, 1.0);
      case MokuroMoeDownloadStage.done:
        return 1;
      case MokuroMoeDownloadStage.downloadingMokuro:
      case MokuroMoeDownloadStage.extracting:
        return null;
    }
  }

  String _stageLabel() {
    final MokuroMoeVolumeDownloadEvent? event = _lastEvent;
    switch (event?.stage) {
      case null:
      case MokuroMoeDownloadStage.downloadingMokuro:
        return t.manga_online_stage_mokuro;
      case MokuroMoeDownloadStage.downloadingCbz:
        final int received = event!.receivedBytes;
        final int? total = event.totalBytes;
        final String bytes = total != null && total > 0
            ? '${_mb(received)} / ${_mb(total)} MB'
            : '${_mb(received)} MB';
        return '${t.manga_online_stage_cbz} $bytes';
      case MokuroMoeDownloadStage.extracting:
        return t.manga_online_stage_extract;
      case MokuroMoeDownloadStage.importing:
        return event!.pagesTotal > 0
            ? t.manga_ocr_wizard_page_progress(
                done: event.pagesDone, total: event.pagesTotal)
            : t.manga_ocr_wizard_importing;
      case MokuroMoeDownloadStage.done:
        return t.manga_ocr_wizard_done;
    }
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  List<Widget> _buildActions() {
    switch (_stage) {
      case _CatalogStage.browse:
        return <Widget>[
          adaptiveDialogAction(
            context: context,
            onPressed: _close,
            child: Text(t.dialog_close),
          ),
        ];
      case _CatalogStage.series:
        return <Widget>[
          adaptiveDialogAction(
            context: context,
            onPressed: _backToBrowse,
            child: Text(t.back),
          ),
          adaptiveDialogAction(
            context: context,
            onPressed: _selectedVolumes.isEmpty ? null : _downloadSelected,
            child: Text(t.manga_online_download_selected),
          ),
          adaptiveDialogAction(
            context: context,
            onPressed: _close,
            child: Text(t.dialog_close),
          ),
        ];
      case _CatalogStage.downloading:
        return <Widget>[
          adaptiveDialogAction(
            context: context,
            onPressed: _cancelDownload,
            child: Text(t.dialog_cancel),
          ),
        ];
    }
  }
}
