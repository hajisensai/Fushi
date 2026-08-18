/// 一次刮削记录的可操作详情。
///
/// 「待确认 2，失败 4」以前只是摘要行上的两个死数字：产生它们的候选列表随批次
/// 结束就没了，run 表里只剩计数，用户既看不到是哪几个作品、也没有任何入口去处理
/// （BUG-1720 / BUG-1721）。本对话框把 summaryJson 里逐条作品级事实读回来，并给
/// 每条提供**手动指定作品**——选中的身份走 rescrapeWorkWithLookup，与批次内确认、
/// 与下载导入后的精确刮削共用同一条落库路径，不新开第二套绑定保存。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_candidate_tile.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 与后台任务面板、来源摘要行共用的 run 状态文案。
String videoSourceScrapeRunStatusLabel(String status) => switch (status) {
      'completed' => t.download_task_status_completed,
      'cancelled' => t.download_status_cancelled,
      'interrupted' => t.video_source_scrape_status_interrupted,
      'failed' => t.download_task_status_error,
      'running' => t.video_source_scrape_action,
      _ => status,
    };

/// 返回 true 表示这次交互改动了库（重刮了来源或手动绑定了作品），调用方应刷新。
Future<bool> showVideoSourceScrapeRunDetailDialog({
  required BuildContext context,
  required VideoSourceScrapeRunRow run,
  SourceLibraryRow? source,
  VideoSourceScrapeTaskController? controller,
  Future<void> Function(SourceLibraryRow source)? onRescrapeSource,
}) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => _VideoSourceScrapeRunDetailDialog(
        run: run,
        source: source,
        controller: controller,
        onRescrapeSource: onRescrapeSource,
      ),
    ) ??
    false;

class _VideoSourceScrapeRunDetailDialog extends StatefulWidget {
  const _VideoSourceScrapeRunDetailDialog({
    required this.run,
    required this.source,
    required this.controller,
    required this.onRescrapeSource,
  });

  final VideoSourceScrapeRunRow run;
  final SourceLibraryRow? source;
  final VideoSourceScrapeTaskController? controller;
  final Future<void> Function(SourceLibraryRow source)? onRescrapeSource;

  @override
  State<_VideoSourceScrapeRunDetailDialog> createState() =>
      _VideoSourceScrapeRunDetailDialogState();
}

class _VideoSourceScrapeRunDetailDialogState
    extends State<_VideoSourceScrapeRunDetailDialog> {
  late final SourceScrapeReport? _report =
      decodeSourceScrapeReport(widget.run.summaryJson);

  /// 已经手动绑定过、不必再出现在待办里的作品名。
  final Set<String> _resolved = <String>{};
  String? _busyWorkTitle;
  String? _error;
  bool _changed = false;

  bool get _canBindManually =>
      widget.source != null &&
      (widget.controller?.supportsManualBinding ?? false);

  List<(SourceScrapeIssue, bool)> get _issues {
    final SourceScrapeReport? report = _report;
    if (report == null) return const <(SourceScrapeIssue, bool)>[];
    return <(SourceScrapeIssue, bool)>[
      for (final SourceScrapeIssue issue in report.warnings)
        if (!_resolved.contains(issue.workTitle)) (issue, false),
      for (final SourceScrapeIssue issue in report.errors)
        if (!_resolved.contains(issue.workTitle)) (issue, true),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final VideoSourceScrapeRunRow run = widget.run;
    final SourceLibraryRow? source = widget.source;
    final List<(SourceScrapeIssue, bool)> issues = _issues;
    final String? lastError = run.lastError?.trim();
    return AlertDialog(
      title: Text(t.video_source_scrape_run_detail_title),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(FushiTimeFormat.dateHourMinute(
                  DateTime.fromMillisecondsSinceEpoch(run.startedAt),
                )),
                const SizedBox(height: 6),
                Text(t.video_source_scrape_last_summary(
                  status: videoSourceScrapeRunStatusLabel(run.status),
                  succeeded: run.succeededWorks,
                  pending: run.pendingConfirmations,
                  failed: run.failedWorks,
                )),
                if (lastError != null && lastError.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  SelectableText(lastError),
                ],
                const SizedBox(height: 12),
                if (issues.isEmpty)
                  Text(t.video_source_scrape_run_no_issues)
                else
                  for (final (SourceScrapeIssue issue, bool isError) in issues)
                    _buildIssue(issue, isError),
                if (_error case final String error) ...<Widget>[
                  const SizedBox(height: 12),
                  SelectableText(error),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(_changed),
          child: Text(t.dialog_close),
        ),
        if (source != null && widget.onRescrapeSource != null)
          TextButton(
            key: const ValueKey<String>('video-source-run-rescrape'),
            onPressed: _busyWorkTitle == null
                ? () => unawaited(_rescrapeSource(source))
                : null,
            child: Text(t.video_source_scrape_rescrape_source),
          ),
      ],
    );
  }

  Widget _buildIssue(SourceScrapeIssue issue, bool isError) {
    final bool busy = _busyWorkTitle == issue.workTitle;
    return FushiListItem(
      key: ValueKey<String>('video-source-run-issue-${issue.workTitle}'),
      density: FushiListDensity.compact,
      padding: EdgeInsets.zero,
      leading: Icon(
        isError ? Icons.error_outline : Icons.info_outline,
        color: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary,
      ),
      title: Text(issue.workTitle),
      subtitleMaxLines: 4,
      subtitle: SelectableText(
        issue.path == null ? issue.message : '${issue.message}\n${issue.path}',
      ),
      trailing: !_canBindManually
          ? null
          : busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  tooltip: t.video_source_scrape_manual_search_title,
                  onPressed: _busyWorkTitle != null
                      ? null
                      : () => unawaited(_bindManually(issue)),
                  icon: const Icon(Icons.search),
                ),
    );
  }

  Future<void> _rescrapeSource(SourceLibraryRow source) async {
    final Future<void> Function(SourceLibraryRow source)? rescrape =
        widget.onRescrapeSource;
    if (rescrape == null) return;
    await rescrape(source);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _bindManually(SourceScrapeIssue issue) async {
    final SourceLibraryRow? source = widget.source;
    final VideoSourceScrapeTaskController? controller = widget.controller;
    if (source == null || controller == null) return;
    final VideoSourceScrapeConfirmationCandidate? candidate =
        await showAppDialog<VideoSourceScrapeConfirmationCandidate>(
      context: context,
      builder: (BuildContext context) => _ManualBindingDialog(
        controller: controller,
        source: source,
        workTitle: issue.workTitle,
      ),
    );
    if (candidate == null || !mounted) return;
    setState(() {
      _busyWorkTitle = issue.workTitle;
      _error = null;
    });
    try {
      await controller.rescrapeWorkWithLookup(
        source: source,
        workTitle: issue.workTitle,
        lookup: candidate.lookup,
      );
      if (!mounted) return;
      setState(() {
        _changed = true;
        _resolved.add(issue.workTitle);
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busyWorkTitle = null);
    }
  }
}

/// 手动搜索资料源并挑一个作品。结果行与批次内确认是同一个
/// [VideoSourceScrapeCandidateTile]，选中后返回同一种候选对象。
class _ManualBindingDialog extends StatefulWidget {
  const _ManualBindingDialog({
    required this.controller,
    required this.source,
    required this.workTitle,
  });

  final VideoSourceScrapeTaskController controller;
  final SourceLibraryRow source;
  final String workTitle;

  @override
  State<_ManualBindingDialog> createState() => _ManualBindingDialogState();
}

class _ManualBindingDialogState extends State<_ManualBindingDialog> {
  late final TextEditingController _query =
      TextEditingController(text: widget.workTitle);
  List<VideoSourceScrapeConfirmationCandidate>? _results;
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_searching) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final List<VideoSourceScrapeConfirmationCandidate> results =
          await widget.controller.searchManualCandidates(
        source: widget.source,
        workTitle: widget.workTitle,
        query: _query.text,
      );
      if (!mounted) return;
      setState(() => _results = results);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _results = const <VideoSourceScrapeConfirmationCandidate>[];
        _error = error.toString();
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<VideoSourceScrapeConfirmationCandidate>? results = _results;
    return AlertDialog(
      title: Text(t.video_source_scrape_manual_search_title),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(t.video_source_scrape_manual_search_hint),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey<String>('video-source-manual-query'),
                  controller: _query,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => unawaited(_search()),
                  decoration: InputDecoration(
                    labelText: t.video_source_scrape_manual_search_title,
                  ),
                ),
                const SizedBox(height: 12),
                if (_searching)
                  const Center(child: CircularProgressIndicator.adaptive())
                else if (results != null && results.isEmpty)
                  Text(t.video_source_scrape_manual_search_empty)
                else if (results != null)
                  for (final VideoSourceScrapeConfirmationCandidate candidate
                      in results)
                    VideoSourceScrapeCandidateTile(
                      candidate: candidate,
                      onSelected: (
                        VideoSourceScrapeConfirmationCandidate selected,
                      ) =>
                          Navigator.of(context).pop(selected),
                    ),
                if (_error case final String error) ...<Widget>[
                  const SizedBox(height: 12),
                  SelectableText(error),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        TextButton(
          key: const ValueKey<String>('video-source-manual-search'),
          onPressed: _searching ? null : () => unawaited(_search()),
          child: Text(t.video_source_scrape_manual_search_action),
        ),
      ],
    );
  }
}
