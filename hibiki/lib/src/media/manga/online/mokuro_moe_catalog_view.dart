import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_client.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_download_queue.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_progress_labels.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:hibiki/src/media/media_search_text.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/utils.dart';

/// mokuro.moe 目录内容体的外层可见状态快照：标题与动作按钮所需的最小事实。
///
/// 由 [MokuroMoeCatalogViewState] 在状态变更后写入外层传入的
/// [MokuroMoeCatalogView.snapshotNotifier]，对话框壳据此重建标题与 footer
/// 动作。数据只出不进——View 是唯一状态拥有者，壳不回写。
@immutable
class MokuroMoeCatalogSnapshot {
  const MokuroMoeCatalogSnapshot({
    this.seriesName,
    this.inSeriesStage = false,
    this.canDownload = false,
  });

  /// series 阶段的系列名（browse 阶段为 null，外层回退到目录标题文案）。
  final String? seriesName;

  /// 是否处于 series 阶段（决定外层动作按钮组合：返回/下载所选）。
  final bool inSeriesStage;

  /// 「下载所选」是否可用（series 阶段且已选中至少一卷）。
  final bool canDownload;

  // == 去重是本快照的契约核心：ValueNotifier 靠它吞掉与标题/动作无关的
  // setState（加载态、进度重绘），也保证 initState 期间的同值写入不触发
  // build 期 notify。
  @override
  bool operator ==(Object other) =>
      other is MokuroMoeCatalogSnapshot &&
      other.seriesName == seriesName &&
      other.inSeriesStage == inSeriesStage &&
      other.canDownload == canDownload;

  @override
  int get hashCode => Object.hash(seriesName, inSeriesStage, canDownload);
}

/// 内容体所处阶段（下载不再是阶段——它在共享队列里后台进行）。
enum _CatalogStage { browse, series }

/// mokuro.moe「在线目录」内容体（O1）：浏览/搜索系列 → 选卷 → 入队
/// [MokuroMoeDownloadQueue]（app 级共享队列，统一下载中心）。
///
/// 既可被 [MokuroMoeCatalogDialog] 当对话框正文（[embedded] = false：尺寸由
/// 外层约束、动作按钮由对话框 footer 提供），也可 [embedded] = true 直接嵌入
/// 页面（正文撑满可用空间、动作按钮画在 View 内部、不显示关闭按钮）。
///
/// 内容体只负责浏览与 enqueue：下载在队列里后台执行，**关闭宿主不中断**；
/// 进度既在内联面板显示，也与「下载」页任务 tab 同源可见。书架刷新不依赖
/// 关闭回传——书架页直接监听队列的 importedCount 增量。
///
/// 照 [MangaOcrWizardDialog] 范式：依赖全构造注入（[clientOverride] /
/// [queueOverride] 供 widget 测试绕网络/DB），dispose 只摘监听不动队列。
class MokuroMoeCatalogView extends ConsumerStatefulWidget {
  const MokuroMoeCatalogView({
    required this.db,
    this.clientOverride,
    this.queueOverride,
    this.enabledOverride,
    this.embedded = false,
    this.onClose,
    this.snapshotNotifier,
    super.key,
  });

  /// 目标数据库（查已在库书目用；下载落库由队列持有的 db 完成）。
  final HibikiDatabase db;

  /// 测试用 client（null = 按偏好 base URL 构造真实 client）。
  final MokuroMoeClient? clientOverride;

  /// 测试用队列（null = 取 [AppModel.mokuroMoeDownloadQueue] 共享实例）。
  final MokuroMoeDownloadQueue? queueOverride;

  /// Source gate. Production hosts normally pass/read the AppModel preference;
  /// tests can provide it explicitly without constructing an AppModel.
  final bool? enabledOverride;

  /// false = 对话框语境（正文尺寸受外层约束、动作按钮由对话框 footer 提供）；
  /// true = 页面语境（正文撑满可用空间、动作按钮画在 View 内部底行）。
  final bool embedded;

  /// 对话框语境下外壳的关闭动作（壳在 footer 自建关闭按钮，本参数是语境
  /// 契约的一部分）；embedded 页面语境传 null，View 不显示关闭按钮。
  final VoidCallback? onClose;

  /// 外层（对话框壳）监听标题/动作快照用的 notifier；null = 无外层消费
  /// （embedded 页面语境）。生命周期归外层所有，View 只写值不 dispose。
  final ValueNotifier<MokuroMoeCatalogSnapshot>? snapshotNotifier;

  @override
  ConsumerState<MokuroMoeCatalogView> createState() =>
      MokuroMoeCatalogViewState();
}

/// 公开 State：对话框壳经 GlobalKey 调用 [backToBrowse] / [enqueueSelected]
/// 构建 footer 动作，标题经 [stageTitle] / 快照获取。
class MokuroMoeCatalogViewState extends ConsumerState<MokuroMoeCatalogView> {
  late final MokuroMoeClient _client;
  late final MokuroMoeDownloadQueue _queue;
  late bool _enabled;
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

  /// 当前阶段标题（browse = 目录标题文案；series = 系列名）。
  String get stageTitle => _stage == _CatalogStage.browse
      ? t.manga_online_catalog_title
      : (_series?.name ?? t.manga_online_catalog_title);

  @override
  void initState() {
    super.initState();
    _enabled = widget.enabledOverride ??
        (widget.clientOverride != null && widget.queueOverride != null
            ? true
            : ref.read(appProvider).mangaOnlineCatalogEnabled);
    _client = widget.clientOverride ??
        MokuroMoeClient(
          baseUrl: ref.read(appProvider).mangaOnlineCatalogBaseUrl,
        );
    _queue =
        widget.queueOverride ?? ref.read(appProvider).mokuroMoeDownloadQueue;
    // The app-level queue outlives this view. Existing done tasks are
    // history, not completion transitions for the newly opened instance.
    _seenDone.addAll(
      _queue.tasks.where(
        (MokuroMoeDownloadTask task) => task.status == MokuroMoeTaskStatus.done,
      ),
    );
    _queue.addListener(_onQueueChanged);
    if (_enabled) {
      unawaited(_loadLibrary());
      unawaited(_loadExistingBooks());
    }
  }

  @override
  void didUpdateWidget(covariant MokuroMoeCatalogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool? nextOverride = widget.enabledOverride;
    if (nextOverride == null || nextOverride == _enabled) return;
    _enabled = nextOverride;
    if (_enabled) {
      unawaited(_loadLibrary());
      unawaited(_loadExistingBooks());
    } else {
      _library = null;
      _loadError = null;
      _loading = false;
      _series = null;
      _selectedVolumes.clear();
      _stage = _CatalogStage.browse;
      _publishSnapshot();
    }
  }

  @override
  void dispose() {
    // 只摘监听：队列是 app 级服务，下载继续（统一下载中心语义）。
    _queue.removeListener(_onQueueChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    // 每次状态变更后同步外层快照。快照 == 去重保证：与标题/动作无关的
    // setState（加载态/进度重绘、initState 期间 _loadLibrary 的同值写入）
    // 不惊动外层；真正变更都发生在事件回调里，不存在 build 期 notify。
    _publishSnapshot();
  }

  void _publishSnapshot() {
    final bool inSeries = _stage == _CatalogStage.series;
    widget.snapshotNotifier?.value = MokuroMoeCatalogSnapshot(
      seriesName: inSeries ? _series?.name : null,
      inSeriesStage: inSeries,
      canDownload: inSeries && _selectedVolumes.isNotEmpty,
    );
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

  /// 返回浏览阶段（series 阶段动作，供外层 footer 与内嵌动作行共用）。
  void backToBrowse() {
    setState(() {
      _series = null;
      _selectedVolumes.clear();
      _stage = _CatalogStage.browse;
    });
  }

  /// 所选卷入队共享下载队列（保持卷序），toast 提示后清空选择。下载/落库
  /// 全在队列后台进行——宿主可继续浏览或直接关闭。
  void enqueueSelected() {
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

  // ── UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    if (!_enabled) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(tokens.spacing.gap * 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.public_off_outlined,
                color: tokens.surfaces.onVariant,
              ),
              SizedBox(height: tokens.spacing.gap),
              Text(
                t.manga_online_source_disabled,
                style: tokens.type.listSubtitle,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final Widget body = _stage == _CatalogStage.browse
        ? _buildBrowse(tokens)
        : _buildSeries(tokens);
    // 对话框语境：正文原样交给外层约束（动作按钮由对话框 footer 提供）。
    if (!widget.embedded) return body;
    // 页面语境：正文撑满可用空间，series 阶段在底部画动作行。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: body),
        if (_stage == _CatalogStage.series) _buildEmbeddedActions(tokens),
      ],
    );
  }

  /// 页面语境的底部动作行：照 book_css_editor_page.dart 底栏的
  /// OutlinedButton（次要）+ FilledButton（主要）范式；关闭按钮只属于
  /// 对话框语境，这里不画。
  Widget _buildEmbeddedActions(HibikiDesignTokens tokens) {
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.gap),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          OutlinedButton(
            onPressed: backToBrowse,
            child: Text(t.back),
          ),
          SizedBox(width: tokens.spacing.gap),
          FilledButton(
            onPressed: _selectedVolumes.isEmpty ? null : enqueueSelected,
            child: Text(t.manga_online_download_selected),
          ),
        ],
      ),
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
            // 退避重试中也是「未完成任务」，行仍不可再选，得说清它在等什么。
            MokuroMoeTaskStatus.waitingRetry => t.manga_online_retry_waiting(
                attempt: pending!.autoRetries,
                total: _queue.maxAutoRetries,
              ),
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
}
