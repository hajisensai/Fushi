import 'package:flutter/material.dart';

import 'package:hibiki/utils.dart';

enum ScrapeBatchItemResult {
  applied,
  needsReview,
  skipped,
  failed,
}

class ScrapeBatchSummary {
  const ScrapeBatchSummary({
    this.applied = 0,
    this.needsReview = 0,
    this.skipped = 0,
    this.failed = 0,
  });

  final int applied;
  final int needsReview;
  final int skipped;
  final int failed;

  ScrapeBatchSummary add(ScrapeBatchItemResult result) {
    return ScrapeBatchSummary(
      applied: applied + (result == ScrapeBatchItemResult.applied ? 1 : 0),
      needsReview:
          needsReview + (result == ScrapeBatchItemResult.needsReview ? 1 : 0),
      skipped: skipped + (result == ScrapeBatchItemResult.skipped ? 1 : 0),
      failed: failed + (result == ScrapeBatchItemResult.failed ? 1 : 0),
    );
  }
}

class ScrapeBatchProgress {
  const ScrapeBatchProgress({
    required this.current,
    required this.total,
    required this.title,
    required this.summary,
  });

  final int current;
  final int total;
  final String title;
  final ScrapeBatchSummary summary;
}

typedef ScrapeBatchProgressCallback = void Function(
  ScrapeBatchProgress progress,
);
typedef ScrapeBatchRunner = Future<ScrapeBatchSummary> Function(
  ScrapeBatchProgressCallback onProgress,
);

Future<ScrapeBatchSummary?> showScrapeBatchDialog({
  required BuildContext context,
  required String mediaLabel,
  required int itemCount,
  required ScrapeBatchRunner runner,
}) {
  return showAppDialog<ScrapeBatchSummary>(
    context: context,
    builder: (BuildContext context) => ScrapeBatchDialog(
      mediaLabel: mediaLabel,
      itemCount: itemCount,
      runner: runner,
    ),
  );
}

class ScrapeBatchDialog extends StatefulWidget {
  const ScrapeBatchDialog({
    super.key,
    required this.mediaLabel,
    required this.itemCount,
    required this.runner,
  });

  final String mediaLabel;
  final int itemCount;
  final ScrapeBatchRunner runner;

  @override
  State<ScrapeBatchDialog> createState() => _ScrapeBatchDialogState();
}

class _ScrapeBatchDialogState extends State<ScrapeBatchDialog> {
  bool _running = false;
  ScrapeBatchProgress? _progress;
  ScrapeBatchSummary? _summary;

  Future<void> _start() async {
    if (_running || widget.itemCount == 0) return;
    setState(() => _running = true);
    ScrapeBatchSummary summary;
    try {
      summary = await widget.runner((ScrapeBatchProgress progress) {
        if (mounted) setState(() => _progress = progress);
      });
    } catch (e, stack) {
      // 各域 runner 的逐项异常已在内层 try 里计成 failed；能抛到这里的是收尾
      // 动作（刷新 provider / 重建页面）或流本身。旧实现直接拿
      // `ScrapeBatchSummary(failed: 1)` 盖掉累计值：500 本已真实写盘，收尾报错就
      // 成了「应用 0 / 失败 1」，计数与真实写入彻底脱节。这里以最后一次进度
      // 回调的累计值为准（它只在逐项落定后上报），不再凭空造一个
      // failed——四类计数只描述条目，非条目级异常走错误日志。
      ErrorLogService.instance.log('ScrapeBatchDialog.run', e, stack);
      summary = _progress?.summary ?? const ScrapeBatchSummary();
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _summary = summary;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ScrapeBatchProgress? progress = _progress;
    final ScrapeBatchSummary? summary = _summary;
    final double value = progress == null || progress.total == 0
        ? 0
        : progress.current / progress.total;
    return PopScope(
      canPop: !_running,
      child: AlertDialog(
        title: Text(t.scrape_all_title(kind: widget.mediaLabel)),
        content: SizedBox(
          width: 440,
          child: summary != null
              ? Text(
                  t.scrape_all_done(
                    applied: summary.applied,
                    review: summary.needsReview,
                    skipped: summary.skipped,
                    failed: summary.failed,
                  ),
                )
              : _running
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        LinearProgressIndicator(value: value),
                        const SizedBox(height: 12),
                        Text(
                          t.scrape_all_running(
                            current: progress?.current ?? 0,
                            total: widget.itemCount,
                          ),
                        ),
                        if (progress != null) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            t.scrape_all_item(title: progress.title),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    )
                  : Text(
                      widget.itemCount == 0
                          ? t.scrape_all_empty
                          : t.scrape_all_confirm(n: widget.itemCount),
                    ),
        ),
        actions: <Widget>[
          if (!_running)
            TextButton(
              onPressed: () => Navigator.of(context).pop(summary),
              child: Text(summary == null ? t.dialog_cancel : t.dialog_close),
            ),
          if (!_running && summary == null && widget.itemCount > 0)
            FilledButton(
              onPressed: _start,
              child: Text(t.scrape_all_start),
            ),
        ],
      ),
    );
  }
}
