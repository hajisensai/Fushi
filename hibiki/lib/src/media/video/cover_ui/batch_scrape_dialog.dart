import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/cover_ui/batch_scrape_controller.dart';
import 'package:hibiki/src/media/video/scraper/offline_db_downloader.dart';
import 'package:hibiki/src/media/video/scraper/offline_index.dart';
import 'package:hibiki/src/media/video/scraper/poster_scraper_service.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart' show VideoBookRow;

/// 「批量匹配海报」弹窗 —— **纯视图**：运行状态归 [BatchScrapeController]
/// （进程级，关弹窗任务照跑），本弹窗只负责渲染与操作转发。
///
/// 流程：可选先下载离线索引库（约几十 MB，可跳过）→ [BatchScrapeController.start]
/// 逐**组**流式跑（工作单位是 [ScrapeGroup]）→ 行状态按三分支语义：
/// - 合集组 ✓ = 已设为合集封面（成员抽帧不动）；? 待确认（点击打开单本匹配弹窗、
///   确认后「设为合集封面」）；
/// - 单本组 ✓ = 已应用到该书；
/// - 目录多成员组 = 跳过（各集保留抽帧画面）。
///
/// 运行中操作：「后台运行」只关弹窗（任务继续，页头入口带进行中角标、可重开本
/// 弹窗续看进度）；「取消」真中止。完成后结果（含待确认队列）保留在控制器里，
/// 重开弹窗可继续逐条确认。
Future<void> showBatchScrapeDialog({
  required BuildContext context,
  required PosterScraperService service,
  required List<VideoBookRow> books,
  required Directory offlineDbDir,
  required PosterScraperService Function(OfflineIndex offline)
      rebuildWithOffline,
  required void Function(VideoBookRow book, int? collectionId) onOpenManual,
  required VoidCallback onFinished,
}) {
  return showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => BatchScrapeDialog(
      service: service,
      books: books,
      offlineDbDir: offlineDbDir,
      rebuildWithOffline: rebuildWithOffline,
      onOpenManual: onOpenManual,
      onFinished: onFinished,
    ),
  );
}

/// 批量匹配海报对话框主体（导出便于 widget 测试）。
class BatchScrapeDialog extends StatefulWidget {
  const BatchScrapeDialog({
    super.key,
    required this.service,
    required this.books,
    required this.offlineDbDir,
    required this.rebuildWithOffline,
    required this.onOpenManual,
    required this.onFinished,
    this.offlineDownloader,
    this.controller,
  });

  final PosterScraperService service;
  final List<VideoBookRow> books;
  final Directory offlineDbDir;

  /// 离线库下载完成后用它重建带离线索引的 service（页面持有全部依赖）。
  final PosterScraperService Function(OfflineIndex offline) rebuildWithOffline;

  /// 点击「待确认」行 → 打开单本匹配弹窗预填该组代表；[int?] 为该组的 DB 合集
  /// id（非 null = 确认后「设为合集封面」；null = 只应用到该书自身）。
  final void Function(VideoBookRow book, int? collectionId) onOpenManual;

  /// 结束（含取消/后台关闭）后回调，供页面刷新库。
  final VoidCallback onFinished;

  /// 仅测试：注入假下载器；缺省用真实 [OfflineDbDownloader]。
  final OfflineDbDownloader? offlineDownloader;

  /// 仅测试：注入独立控制器；缺省用进程级 [BatchScrapeController.instance]。
  final BatchScrapeController? controller;

  @override
  State<BatchScrapeDialog> createState() => _BatchScrapeDialogState();
}

class _BatchScrapeDialogState extends State<BatchScrapeDialog> {
  late PosterScraperService _service;
  late final BatchScrapeController _controller;
  bool _offlineDismissed = false;
  bool _downloading = false;
  double? _downloadProgress;

  /// 开跑前的分组预览（idle 阶段行 = 组，与结果行同粒度）。
  List<ScrapeGroup>? _groups;

  @override
  void initState() {
    super.initState();
    _service = widget.service;
    _controller = widget.controller ?? BatchScrapeController.instance;
    _controller.addListener(_onControllerChanged);
    _controller.attachView();
    if (_controller.phase == BatchScrapePhase.idle) {
      unawaited(_loadGroups());
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadGroups() async {
    final List<ScrapeGroup> groups = await _service.groupLibrary(widget.books);
    if (!mounted) return;
    setState(() => _groups = groups);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.detachView();
    super.dispose();
  }

  bool get _showOfflineBanner =>
      !_service.hasOfflineIndex &&
      !_offlineDismissed &&
      !_downloading &&
      _controller.phase == BatchScrapePhase.idle;

  Future<void> _downloadOfflineIndex() async {
    setState(() {
      _downloading = true;
      _downloadProgress = null;
    });
    final OfflineDbDownloader downloader =
        widget.offlineDownloader ?? OfflineDbDownloader();
    try {
      await widget.offlineDbDir.create(recursive: true);
      await downloader.download(
        targetDir: widget.offlineDbDir,
        onProgress: (int received, int? totalBytes) {
          if (!mounted || totalBytes == null || totalBytes <= 0) return;
          setState(() => _downloadProgress = received / totalBytes);
        },
      );
      final OfflineIndex? offline =
          await PosterScraperService.loadOfflineIndex(widget.offlineDbDir);
      if (!mounted) return;
      setState(() {
        if (offline != null) _service = widget.rebuildWithOffline(offline);
        _offlineDismissed = true;
        _downloading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _offlineDismissed = true;
        _downloading = false;
      });
      HibikiToast.show(msg: t.remote_video_list_failed);
    }
  }

  void _start() {
    _controller.start(service: _service, books: widget.books);
  }

  /// done → 回到 idle 预览（重新开始一轮的入口，复用 idle 流程）。
  void _restart() {
    _controller.resetIfDone();
    unawaited(_loadGroups());
  }

  Future<void> _cancel() async {
    await _controller.cancel();
    widget.onFinished();
  }

  /// 「后台运行」：只关弹窗，任务在控制器里继续；先刷新一次库页（已应用的组
  /// 立即可见）。
  void _runInBackground() {
    widget.onFinished();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BatchScrapePhase phase = _controller.phase;
    return AlertDialog(
      title: Text(t.video_scrape_batch_title),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_showOfflineBanner) _buildOfflineBanner(theme),
            if (_downloading) _buildDownloadProgress(),
            if (phase != BatchScrapePhase.idle) _buildProgressHeader(theme),
            const SizedBox(height: 8),
            SizedBox(height: 320, child: _buildBody(theme)),
          ],
        ),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildOfflineBanner(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.video_scrape_batch_download_index),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: () => setState(() => _offlineDismissed = true),
                  child: Text(t.video_scrape_batch_skip),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _downloadOfflineIndex,
                  child: Text(t.video_scrape_batch_download),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadProgress() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.video_scrape_downloading_index),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: _downloadProgress),
        ],
      ),
    );
  }

  Widget _buildProgressHeader(ThemeData theme) {
    final int total = _controller.total;
    final double? value = total == 0 ? null : _controller.current / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t.video_scrape_batch_progress(
            current: _controller.current, total: total)),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: value),
        if (_controller.phase == BatchScrapePhase.done) ...<Widget>[
          const SizedBox(height: 8),
          Builder(builder: (_) {
            final ({int applied, int confirm, int skipped}) c =
                _controller.summary;
            return Text(
              t.video_scrape_batch_summary(
                applied: c.applied,
                confirm: c.confirm,
                skipped: c.skipped,
              ),
              style: theme.textTheme.bodyMedium,
            );
          }),
        ],
      ],
    );
  }

  /// 组行标题：`标题 (N 集)`（单本组不带集数后缀）。
  String _groupTitle(ScrapeGroup group) => group.members.length > 1
      ? '${group.displayTitle} '
          '${t.video_scrape_group_count(n: group.members.length)}'
      : group.displayTitle;

  Widget _buildBody(ThemeData theme) {
    if (widget.books.isEmpty && _controller.phase == BatchScrapePhase.idle) {
      return Center(child: Text(t.video_scrape_batch_empty));
    }
    if (_controller.phase == BatchScrapePhase.idle) {
      final List<ScrapeGroup>? groups = _groups;
      if (groups == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return ListView(
        children: <Widget>[
          for (final ScrapeGroup group in groups)
            ListTile(
              dense: true,
              leading: const Icon(Icons.movie_outlined),
              title: Text(_groupTitle(group),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      );
    }
    final List<BatchScrapeRow> rows = _controller.rows;
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) =>
          _buildResultRow(theme, rows[index]),
    );
  }

  Widget _buildResultRow(ThemeData theme, BatchScrapeRow row) {
    final (IconData icon, Color color, String label, bool tappable) =
        _rowStatus(theme, row);
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(_groupTitle(row.group),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(label),
      trailing: tappable ? const Icon(Icons.chevron_right) : null,
      onTap: tappable ? () => _openManualForRow(row) : null,
    );
  }

  /// 待确认行：代表书 = 组内首个可覆盖成员（回退组首成员）；合集组把 collectionId
  /// 一并传出（确认后「设为合集封面」，成员抽帧不动）。
  void _openManualForRow(BatchScrapeRow row) {
    final Set<String> coverable = row.coverableUids.toSet();
    final VideoBookRow book = row.group.members.firstWhere(
      (VideoBookRow b) => coverable.contains(b.bookUid),
      orElse: () => row.group.members.first,
    );
    widget.onOpenManual(book, row.group.collectionId);
  }

  (IconData, Color, String, bool) _rowStatus(
      ThemeData theme, BatchScrapeRow row) {
    switch (row.outcome) {
      case ScrapeApplied():
        return (
          Icons.check_circle_outline,
          Colors.green,
          row.group.collectionId != null
              ? t.video_scrape_status_collection_cover_set
              : row.coverableUids.length > 1
                  ? t.video_scrape_status_applied_n(n: row.coverableUids.length)
                  : t.video_scrape_status_applied,
          false,
        );
      case ScrapeNeedsConfirm():
        return (
          Icons.help_outline,
          Colors.orange,
          t.video_scrape_status_needs_confirm,
          true,
        );
      case ScrapeFailed():
        return (
          Icons.error_outline,
          theme.colorScheme.error,
          t.video_scrape_status_failed,
          false,
        );
      case ScrapeSkippedDirectoryGroup():
        return (
          Icons.remove_circle_outline,
          theme.colorScheme.outline,
          t.video_scrape_status_skipped_directory,
          false,
        );
      case ScrapeNoMatch():
      case ScrapeSkippedNoTitle():
      case ScrapeSkippedProtected():
      case ScrapeNotEligible():
        return (
          Icons.remove_circle_outline,
          theme.colorScheme.outline,
          t.video_scrape_status_skipped,
          false,
        );
    }
  }

  List<Widget> _buildActions() {
    if (_downloading) {
      return <Widget>[
        TextButton(
          onPressed: null,
          child: Text(t.video_scrape_batch_cancel),
        ),
      ];
    }
    switch (_controller.phase) {
      case BatchScrapePhase.idle:
        return <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.video_scrape_batch_cancel),
          ),
          FilledButton(
            onPressed: widget.books.isEmpty ? null : _start,
            child: Text(t.video_scrape_batch_start),
          ),
        ];
      case BatchScrapePhase.running:
        return <Widget>[
          TextButton(
            key: const ValueKey<String>('batch_scrape_cancel'),
            onPressed: _cancel,
            child: Text(t.video_scrape_batch_cancel),
          ),
          FilledButton.tonal(
            key: const ValueKey<String>('batch_scrape_background'),
            onPressed: _runInBackground,
            child: Text(t.video_scrape_run_background),
          ),
        ];
      case BatchScrapePhase.done:
        return <Widget>[
          TextButton(
            onPressed: widget.books.isEmpty ? null : _restart,
            child: Text(t.video_scrape_batch_start),
          ),
          FilledButton(
            onPressed: () {
              widget.onFinished();
              Navigator.of(context).pop();
            },
            child: Text(t.video_scrape_batch_close),
          ),
        ];
    }
  }
}
