import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_candidate_tile.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_run_detail_dialog.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 打开可重复进入的后台刮削任务面板。任务由应用级 controller 持有，关闭面板只
/// 隐藏观察器，不会取消网络请求、数据库写入或 sidecar 输出。
Future<void> showVideoSourceScrapeTaskPanel({
  required BuildContext context,
  required VideoSourceScrapeTaskController controller,
  required Future<List<VideoSourceScrapeRunRow>> Function() loadRuns,
  Future<void> Function(VideoSourceScrapeRunRow run)? onRetry,
  Future<SourceLibraryRow?> Function(int sourceId)? loadSource,
}) =>
    showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => _VideoSourceScrapeTaskPanel(
        controller: controller,
        loadRuns: loadRuns,
        onRetry: onRetry,
        loadSource: loadSource,
      ),
    );

class _VideoSourceScrapeTaskPanel extends StatefulWidget {
  const _VideoSourceScrapeTaskPanel({
    required this.controller,
    required this.loadRuns,
    this.onRetry,
    this.loadSource,
  });

  final VideoSourceScrapeTaskController controller;
  final Future<List<VideoSourceScrapeRunRow>> Function() loadRuns;
  final Future<void> Function(VideoSourceScrapeRunRow run)? onRetry;
  final Future<SourceLibraryRow?> Function(int sourceId)? loadSource;

  @override
  State<_VideoSourceScrapeTaskPanel> createState() =>
      _VideoSourceScrapeTaskPanelState();
}

class _VideoSourceScrapeTaskPanelState
    extends State<_VideoSourceScrapeTaskPanel> {
  List<VideoSourceScrapeRunRow> _runs = const <VideoSourceScrapeRunRow>[];
  Object? _historyError;
  bool _loadingHistory = true;
  VideoSourceScrapePhase _lastPhase = VideoSourceScrapePhase.idle;
  final Set<int> _retrying = <int>{};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _lastPhase = widget.controller.progress.phase;
    unawaited(_reloadHistory());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final VideoSourceScrapePhase next = widget.controller.progress.phase;
    final bool becameTerminal = next != _lastPhase &&
        !widget.controller.progress.isRunning &&
        next != VideoSourceScrapePhase.idle;
    _lastPhase = next;
    if (mounted) setState(() {});
    if (becameTerminal) unawaited(_reloadHistory());
  }

  Future<void> _reloadHistory() async {
    if (mounted) {
      setState(() {
        _loadingHistory = true;
        _historyError = null;
      });
    }
    try {
      final List<VideoSourceScrapeRunRow> runs = await widget.loadRuns();
      if (!mounted) return;
      setState(() {
        _runs = runs;
        _loadingHistory = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _historyError = error;
        _loadingHistory = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final VideoSourceScrapeProgress progress = widget.controller.progress;
    final SourceScrapeReport? report = progress.report;
    final bool running = widget.controller.isRunning;
    final VideoSourceScrapeConfirmation? confirmation =
        widget.controller.pendingConfirmation;
    return AlertDialog(
      title: Text(t.video_source_scrape_tasks_open),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 620),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (widget.controller.isBusy ||
                    progress.phase != VideoSourceScrapePhase.idle) ...<Widget>[
                  Text(
                    t.video_source_scrape_tasks_current,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  FushiCard(
                    padding: const EdgeInsets.all(12),
                    child: widget.controller.isScanning
                        ? Text(t.video_source_scrape_phase_scanning)
                        : confirmation != null
                            ? _buildConfirmation(confirmation)
                            : report != null
                                ? _buildReport(report)
                                : _buildProgress(progress),
                  ),
                  const SizedBox(height: 18),
                ],
                Text(
                  t.video_source_scrape_tasks_history,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                _buildHistory(),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
        if (running)
          TextButton(
            onPressed: widget.controller.cancel,
            child: Text(t.dialog_cancel),
          ),
        if (confirmation != null)
          TextButton(
            key: const ValueKey<String>('video-source-confirmation-skip'),
            onPressed: widget.controller.skipPendingConfirmation,
            child: Text(t.video_source_scrape_confirmation_skip),
          ),
      ],
    );
  }

  Widget _buildProgress(VideoSourceScrapeProgress progress) {
    final int total = progress.total;
    final double? value = total <= 0 ? null : progress.current / total;
    final String phase = _phaseLabel(progress.phase);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (progress.isRunning) LinearProgressIndicator(value: value),
        if (progress.isRunning) const SizedBox(height: 12),
        Text(t.video_source_scrape_progress(
          phase: phase,
          current: progress.current,
          total: total,
        )),
        if (progress.sourceLabel case final String label) ...<Widget>[
          const SizedBox(height: 6),
          Text(label),
        ],
        if (progress.currentWorkTitle case final String title) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            t.scrape_all_item(title: title),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (progress.message case final String message) ...<Widget>[
          const SizedBox(height: 6),
          SelectableText(message),
        ],
      ],
    );
  }

  Widget _buildHistory() {
    if (_loadingHistory) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    if (_historyError case final Object error) {
      return SelectableText(error.toString());
    }
    if (_runs.isEmpty) return Text(t.video_source_scrape_tasks_empty);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final VideoSourceScrapeRunRow run in _runs)
          FushiListItem(
            key: ValueKey<String>('video-source-scrape-run-${run.id}'),
            density: FushiListDensity.compact,
            padding: EdgeInsets.zero,
            leading: Icon(_runIcon(run.status)),
            title: Text(
              '${videoSourceScrapeRunStatusLabel(run.status)} · '
              '${run.provider?.toUpperCase() ?? t.nav_video}',
            ),
            subtitle: Text(_runSubtitle(run)),
            subtitleMaxLines: 3,
            onTap: () => unawaited(_openRunDetail(run)),
            trailing: widget.onRetry != null &&
                    run.sourceId != null &&
                    scrapeRunHasUnresolvedWorks(run)
                ? IconButton(
                    tooltip: t.video_source_scrape_rescrape_source,
                    onPressed: _retrying.contains(run.id)
                        ? null
                        : () => unawaited(_retry(run)),
                    icon: _retrying.contains(run.id)
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.replay_outlined),
                  )
                : null,
          ),
      ],
    );
  }

  String _runSubtitle(VideoSourceScrapeRunRow run) {
    final String started = FushiTimeFormat.dateHourMinute(
      DateTime.fromMillisecondsSinceEpoch(run.startedAt),
    );
    final String summary = t.video_source_scrape_last_summary(
      status: videoSourceScrapeRunStatusLabel(run.status),
      succeeded: run.succeededWorks,
      pending: run.pendingConfirmations,
      failed: run.failedWorks,
    );
    final String? error = run.lastError?.trim();
    return error == null || error.isEmpty
        ? '$started\n$summary'
        : '$started\n$summary\n$error';
  }

  Future<void> _retry(VideoSourceScrapeRunRow run) async {
    final Future<void> Function(VideoSourceScrapeRunRow run)? retry =
        widget.onRetry;
    if (retry == null) return;
    setState(() => _retrying.add(run.id));
    try {
      await retry(run);
      await _reloadHistory();
    } finally {
      if (mounted) setState(() => _retrying.remove(run.id));
    }
  }

  /// 点历史条目 = 打开这次 run 的可操作详情：逐条作品的待确认/失败原因，
  /// 以及「手动指定作品」和「重新刮削此来源」。
  Future<void> _openRunDetail(VideoSourceScrapeRunRow run) async {
    final int? sourceId = run.sourceId;
    final Future<SourceLibraryRow?> Function(int sourceId)? loadSource =
        widget.loadSource;
    final SourceLibraryRow? source = sourceId == null || loadSource == null
        ? null
        : await loadSource(sourceId);
    if (!mounted) return;
    final Future<void> Function(VideoSourceScrapeRunRow run)? retry =
        widget.onRetry;
    final bool changed = await showVideoSourceScrapeRunDetailDialog(
      context: context,
      run: run,
      source: source,
      controller: widget.controller,
      onRescrapeSource: retry == null || source == null
          ? null
          : (SourceLibraryRow _) => retry(run),
    );
    if (changed && mounted) await _reloadHistory();
  }

  String _phaseLabel(VideoSourceScrapePhase phase) => switch (phase) {
        VideoSourceScrapePhase.planning => t.video_source_scrape_phase_planning,
        VideoSourceScrapePhase.recognizing =>
          t.video_source_scrape_phase_recognizing,
        VideoSourceScrapePhase.fetching => t.video_source_scrape_phase_fetching,
        VideoSourceScrapePhase.applying => t.video_source_scrape_phase_applying,
        VideoSourceScrapePhase.writingSidecars =>
          t.video_source_scrape_phase_writing_sidecars,
        VideoSourceScrapePhase.completed => t.download_task_status_completed,
        VideoSourceScrapePhase.cancelled => t.download_status_cancelled,
        VideoSourceScrapePhase.interrupted =>
          t.video_source_scrape_status_interrupted,
        VideoSourceScrapePhase.failed => t.download_task_status_error,
        VideoSourceScrapePhase.idle => t.video_source_scrape_tasks_empty,
      };

  IconData _runIcon(String status) => switch (status) {
        'completed' => Icons.check_circle_outline,
        'failed' => Icons.error_outline,
        'cancelled' => Icons.cancel_outlined,
        'interrupted' => Icons.pause_circle_outline,
        _ => Icons.sync,
      };

  Widget _buildConfirmation(VideoSourceScrapeConfirmation confirmation) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          t.video_source_scrape_waiting_confirmation,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(confirmation.localWorkTitle),
        const SizedBox(height: 6),
        Text(t.video_source_scrape_confirmation_hint),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: confirmation.candidates.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) =>
                VideoSourceScrapeCandidateTile(
              candidate: confirmation.candidates[index],
              onSelected: widget.controller.confirmPending,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReport(SourceScrapeReport report) {
    final List<(SourceScrapeIssue, bool)> issues = <(SourceScrapeIssue, bool)>[
      for (final SourceScrapeIssue issue in report.warnings) (issue, false),
      for (final SourceScrapeIssue issue in report.errors) (issue, true),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t.scrape_all_done(
          applied: report.succeededWorks,
          review: report.pendingConfirmations,
          skipped: report.protectedArtifacts,
          failed: report.failedWorks,
        )),
        if (issues.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: issues.length,
              itemBuilder: (BuildContext context, int index) {
                final (SourceScrapeIssue issue, bool isError) = issues[index];
                return FushiListItem(
                  density: FushiListDensity.compact,
                  padding: EdgeInsets.zero,
                  leading: Icon(
                    isError ? Icons.error_outline : Icons.info_outline,
                    color: isError
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(issue.workTitle),
                  subtitle: SelectableText(
                    issue.path == null
                        ? issue.message
                        : '${issue.message}\n${issue.path}',
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
