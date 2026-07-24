import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/scraper/offline_db_downloader.dart';
import 'package:hibiki/src/media/video/scraper/offline_index.dart';
import 'package:hibiki/src/media/video/scraper/poster_scraper_service.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart' show VideoBookRow;

/// 「批量匹配海报」弹窗。
///
/// 流程：可选先下载离线索引库（约几十 MB，可跳过）→ 逐本流式 [scrapeLibrary]，
/// 列出 ✓ 已应用 / ? 待确认（点击打开单本匹配弹窗预填该本）/ ✗ 失败 / 跳过原因，
/// 顶部总进度、底部取消 → 结尾汇总计数。
///
/// 只处理传入的**本地视频**（远端/流媒体由调用方过滤或由 service 判为 notEligible）。
Future<void> showBatchScrapeDialog({
  required BuildContext context,
  required PosterScraperService service,
  required List<VideoBookRow> books,
  required Directory offlineDbDir,
  required PosterScraperService Function(OfflineIndex offline)
      rebuildWithOffline,
  required void Function(VideoBookRow book) onOpenManual,
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
  });

  final PosterScraperService service;
  final List<VideoBookRow> books;
  final Directory offlineDbDir;

  /// 离线库下载完成后用它重建带离线索引的 service（页面持有全部依赖）。
  final PosterScraperService Function(OfflineIndex offline) rebuildWithOffline;

  /// 点击「待确认」行 → 打开单本匹配弹窗预填该本。
  final void Function(VideoBookRow book) onOpenManual;

  /// 结束（含取消）后回调，供页面刷新库。
  final VoidCallback onFinished;

  /// 仅测试：注入假下载器；缺省用真实 [OfflineDbDownloader]。
  final OfflineDbDownloader? offlineDownloader;

  @override
  State<BatchScrapeDialog> createState() => _BatchScrapeDialogState();
}

enum _Phase { idle, downloading, running, done }

/// 一行结果快照。
class _Row {
  const _Row(this.book, this.outcome);

  final VideoBookRow book;
  final ScrapeOutcome outcome;
}

class _BatchScrapeDialogState extends State<BatchScrapeDialog> {
  late PosterScraperService _service;
  _Phase _phase = _Phase.idle;
  bool _offlineDismissed = false;
  double? _downloadProgress;

  StreamSubscription<BatchScrapeProgress>? _sub;
  final List<_Row> _rows = <_Row>[];
  int _total = 0;
  int _current = 0;

  @override
  void initState() {
    super.initState();
    _service = widget.service;
    _total = widget.books.length;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool get _showOfflineBanner =>
      !_service.hasOfflineIndex && !_offlineDismissed && _phase == _Phase.idle;

  Future<void> _downloadOfflineIndex() async {
    setState(() {
      _phase = _Phase.downloading;
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
        _phase = _Phase.idle;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _offlineDismissed = true;
        _phase = _Phase.idle;
      });
      HibikiToast.show(msg: t.remote_video_list_failed);
    }
  }

  void _start() {
    setState(() {
      _phase = _Phase.running;
      _rows.clear();
      _current = 0;
    });
    _sub = _service.scrapeLibrary(widget.books).listen(
      (BatchScrapeProgress p) {
        if (!mounted) return;
        setState(() {
          _rows.add(_Row(p.book, p.outcome));
          _current = p.index + 1;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _phase = _Phase.done);
        widget.onFinished();
      },
    );
  }

  Future<void> _cancel() async {
    await _sub?.cancel();
    _sub = null;
    if (!mounted) return;
    setState(() => _phase = _Phase.done);
    widget.onFinished();
  }

  ({int applied, int confirm, int skipped}) _summaryCounts() {
    int applied = 0;
    int confirm = 0;
    int skipped = 0;
    for (final _Row row in _rows) {
      switch (row.outcome) {
        case ScrapeApplied():
          applied++;
        case ScrapeNeedsConfirm():
          confirm++;
        case ScrapeNoMatch():
        case ScrapeSkippedNoTitle():
        case ScrapeSkippedProtected():
        case ScrapeNotEligible():
        case ScrapeFailed():
          skipped++;
      }
    }
    return (applied: applied, confirm: confirm, skipped: skipped);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.video_scrape_batch_title),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_showOfflineBanner) _buildOfflineBanner(theme),
            if (_phase == _Phase.downloading) _buildDownloadProgress(),
            if (_phase == _Phase.running || _phase == _Phase.done)
              _buildProgressHeader(theme),
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
    final double? value = _total == 0 ? null : _current / _total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t.video_scrape_batch_progress(current: _current, total: _total)),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: value),
        if (_phase == _Phase.done) ...<Widget>[
          const SizedBox(height: 8),
          Builder(builder: (_) {
            final ({int applied, int confirm, int skipped}) c =
                _summaryCounts();
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

  Widget _buildBody(ThemeData theme) {
    if (widget.books.isEmpty) {
      return Center(child: Text(t.video_scrape_batch_empty));
    }
    if (_phase == _Phase.idle || _phase == _Phase.downloading) {
      return ListView(
        children: <Widget>[
          for (final VideoBookRow book in widget.books)
            ListTile(
              dense: true,
              leading: const Icon(Icons.movie_outlined),
              title: Text(book.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      );
    }
    return ListView.separated(
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) =>
          _buildResultRow(theme, _rows[index]),
    );
  }

  Widget _buildResultRow(ThemeData theme, _Row row) {
    final (IconData icon, Color color, String label, bool tappable) =
        _rowStatus(theme, row.outcome);
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(row.book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(label),
      trailing: tappable ? const Icon(Icons.chevron_right) : null,
      onTap: tappable ? () => widget.onOpenManual(row.book) : null,
    );
  }

  (IconData, Color, String, bool) _rowStatus(
    ThemeData theme,
    ScrapeOutcome outcome,
  ) {
    switch (outcome) {
      case ScrapeApplied():
        return (
          Icons.check_circle_outline,
          Colors.green,
          t.video_scrape_status_applied,
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
    switch (_phase) {
      case _Phase.idle:
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
      case _Phase.downloading:
        return <Widget>[
          TextButton(
            onPressed: null,
            child: Text(t.video_scrape_batch_cancel),
          ),
        ];
      case _Phase.running:
        return <Widget>[
          TextButton(
            onPressed: _cancel,
            child: Text(t.video_scrape_batch_cancel),
          ),
        ];
      case _Phase.done:
        return <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.video_scrape_batch_close),
          ),
        ];
    }
  }
}
