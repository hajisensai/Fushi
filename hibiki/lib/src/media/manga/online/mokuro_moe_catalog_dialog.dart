import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/import/import_dialog_frame.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_client.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_download_queue.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_progress_labels.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:hibiki/src/media/media_search_text.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/utils.dart';

/// mokuro.moe「在线目录」对话框（O1）：浏览/搜索系列 → 选卷 → 入队
/// [MokuroMoeDownloadQueue]（app 级共享队列，统一下载中心）。
///
/// 对话框只负责浏览与 enqueue：下载在队列里后台执行，**关闭对话框不中断**；
/// 进度既在本对话框内联面板显示，也与「下载」页任务 tab 同源可见。书架刷新
/// 不再依赖关闭回传——书架页直接监听队列的 importedCount 增量。
///
/// 照 [MangaOcrWizardDialog] 范式：依赖全构造注入（[clientOverride] /
/// [queueOverride] 供 widget 测试绕网络/DB），dispose 只摘监听不动队列。
class MokuroMoeCatalogDialog extends ConsumerStatefulWidget {
  const MokuroMoeCatalogDialog({
    required this.db,
    this.clientOverride,
    this.queueOverride,
    super.key,
  });

  /// 目标数据库（查已在库书目用；下载落库由队列持有的 db 完成）。
  final HibikiDatabase db;

  /// 测试用 client（null = 按偏好 base URL 构造真实 client）。
  final MokuroMoeClient? clientOverride;

  /// 测试用队列（null = 取 [AppModel.mokuroMoeDownloadQueue] 共享实例）。
  final MokuroMoeDownloadQueue? queueOverride;

  @override
  ConsumerState<MokuroMoeCatalogDialog> createState() =>
      _MokuroMoeCatalogDialogState();
}

/// 对话框所处阶段（下载不再是阶段——它在共享队列里后台进行）。
enum _CatalogStage { browse, series }

class _MokuroMoeCatalogDialogState
    extends ConsumerState<MokuroMoeCatalogDialog> {
  late final MokuroMoeClient _client;
  late final MokuroMoeDownloadQueue _queue;
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

  /// 已在库的书身份 key（`sanitizeTtuFilename(title)`；含队列本次新导入的）。
  final Set<String> _existingBookKeys = <String>{};

  /// 已处理过完成回调的任务（防重复计 ✓/重复 toast——队列每次 notify 都全量扫）。
  final Set<MokuroMoeDownloadTask> _seenDone = <MokuroMoeDownloadTask>{};

  @override
  void initState() {
    super.initState();
    _client = widget.clientOverride ??
        MokuroMoeClient(
          baseUrl: ref.read(appProvider).mangaOnlineCatalogBaseUrl,
        );
    _queue =
        widget.queueOverride ?? ref.read(appProvider).mokuroMoeDownloadQueue;
    // The app-level queue outlives this dialog. Existing done tasks are
    // history, not completion transitions for the newly opened instance.
    _seenDone.addAll(
      _queue.tasks.where(
        (MokuroMoeDownloadTask task) => task.status == MokuroMoeTaskStatus.done,
      ),
    );
    _queue.addListener(_onQueueChanged);
    unawaited(_loadLibrary());
    unawaited(_loadExistingBooks());
  }

  @override
  void dispose() {
    // 只摘监听：队列是 app 级服务，下载继续（统一下载中心语义）。
    _queue.removeListener(_onQueueChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 队列广播：完成的任务标 ✓（写进 _existingBookKeys，与书架身份同源）并
  /// toast 一次；其余变更（进度/状态）只触发重绘。
  void _onQueueChanged() {
    if (!mounted) return;
    bool completed = false;
    for (final MokuroMoeDownloadTask task in _queue.tasks) {
      if (task.status != MokuroMoeTaskStatus.done) continue;
      if (!_seenDone.add(task)) continue;
      _existingBookKeys.add(sanitizeTtuFilename(task.title));
      _selectedVolumes.remove(task.volumeName);
      completed = true;
    }
    setState(() {});
    if (completed) {
      HibikiToast.show(msg: t.manga_ocr_wizard_done);
    }
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
    // G6：与库页搜索同一归一化口径——「ふぇいと」要能命中「フェイト」，此前
    // 裸 toLowerCase 子串让同一批日文标题在书架能搜到、在这里搜不到。
    return filterByMediaSearch(
        all, _query, (MokuroMoeSeries s) => <String>[s.name]);
  }

  void _openSeries(MokuroMoeSeries series) {
    setState(() {
      _series = series;
      _selectedVolumes.clear();
      _stage = _CatalogStage.series;
    });
  }

  void _backToBrowse() {
    setState(() {
      _series = null;
      _selectedVolumes.clear();
      _stage = _CatalogStage.browse;
    });
  }

  /// 所选卷入队共享下载队列（保持卷序），toast 提示后清空选择。下载/落库
  /// 全在队列后台进行——本对话框可继续浏览或直接关闭。
  void _enqueueSelected() {
    final MokuroMoeSeries? series = _series;
    if (series == null || _selectedVolumes.isEmpty) return;
    final List<String> volumes = series.volumes
        .map((MokuroMoeVolume v) => v.name)
        .where(_selectedVolumes.contains)
        .toList();
    _queue.enqueue(seriesName: series.name, volumeNames: volumes);
    setState(() => _selectedVolumes.clear());
    HibikiToast.show(msg: t.manga_online_queue_added);
  }

  void _close() => Navigator.pop(context);

  // ── UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return _buildDialog(tokens);
  }

  Widget _buildDialog(HibikiDesignTokens tokens) {
    // 外框走统一 ImportDialogFrame（审计 §1-K：与书/有声书/视频导入同一 chrome）；
    // 浏览/系列阶段的内容与动作按钮不变（标题槽自带单行省略）。
    return ImportDialogFrame(
      leadingIcon: Icons.cloud_download_outlined,
      title: _stage == _CatalogStage.browse
          ? t.manga_online_catalog_title
          : (_series?.name ?? t.manga_online_catalog_title),
      // BUG-1184：正文原先是死的 560×440。宽度会被对话框约束钳住（无害），但**高度**
      // 440 是硬的——矮窗口 / 手机横屏下超出对话框可用高度就直接溢出。改为不超过屏高
      // 的六成，宽屏行为不变。
      body: SizedBox(
        width: 560,
        height: math.min(440.0, MediaQuery.sizeOf(context).height * 0.6),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_queue.hasUnfinished) _buildQueuePanel(tokens),
        Expanded(
          child: ListView.builder(
            itemCount: series.volumes.length,
            itemBuilder: (BuildContext context, int index) =>
                _buildVolumeRow(tokens, series.volumes[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildVolumeRow(HibikiDesignTokens tokens, MokuroMoeVolume volume) {
    final MokuroMoeSeries? series = _series;
    final bool imported = _isImported(volume.name);
    final MokuroMoeDownloadTask? pending =
        series == null ? null : _queue.pendingTask(series.name, volume.name);
    final String? subtitleText = imported
        ? t.manga_online_downloaded
        : switch (pending?.status) {
            MokuroMoeTaskStatus.running =>
              mokuroMoeStageLabel(pending!.lastEvent),
            MokuroMoeTaskStatus.queued => t.download_status_queued,
            _ => null,
          };
    final Widget? subtitle = subtitleText == null
        ? null
        : Text(subtitleText,
            style: tokens.type.listSubtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis);
    final bool selectable = !imported && pending == null;
    // 手排行（MD3 tokens 间距），不走 ListTile（MD3 守卫：普通 chrome 统一走
    // 共享 tokens 布局）。
    return InkWell(
      borderRadius: tokens.radii.controlRadius,
      onTap: !selectable
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
                onChanged: !selectable
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

  /// 共享队列的内联进度面板（有未完成任务时显示）：`x/y · 当前卷阶段` +
  /// 进度条 + 取消当前卷。与「下载」页任务 tab 同源（同队列 + 同换算）。
  Widget _buildQueuePanel(HibikiDesignTokens tokens) {
    final MokuroMoeDownloadTask? running = _queue.runningTask;
    final String label = running == null
        ? t.download_status_queued
        : '${running.title} · ${mokuroMoeStageLabel(running.lastEvent)}';
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  // 「第 x / y 卷」：x = 已收尾数 + 当前执行中的这卷（保持原语义）。
                  '${t.manga_online_queue_progress(done: _queue.finishedCount + (running != null ? 1 : 0), total: _queue.totalCount)}'
                  ' · $label',
                  style: tokens.type.listSubtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (running != null)
                HibikiIconButton(
                  tooltip: t.dialog_cancel,
                  icon: Icons.close,
                  size: 18,
                  onTap: () => _queue.cancel(running),
                ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          LinearProgressIndicator(
              value: mokuroMoeProgressValue(running?.lastEvent)),
        ],
      ),
    );
  }

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
            onPressed: _selectedVolumes.isEmpty ? null : _enqueueSelected,
            child: Text(t.manga_online_download_selected),
          ),
          adaptiveDialogAction(
            context: context,
            onPressed: _close,
            child: Text(t.dialog_close),
          ),
        ];
    }
  }
}
