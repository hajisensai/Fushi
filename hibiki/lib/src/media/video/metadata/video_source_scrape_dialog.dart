import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:hibiki/utils.dart';

Future<SourceScrapeReport?> showVideoSourceScrapeDialog({
  required BuildContext context,
  required VideoSourceScrapeTaskController controller,
  required Future<SourceScrapeReport> Function() start,
}) =>
    showAppDialog<SourceScrapeReport>(
      context: context,
      builder: (BuildContext context) => _VideoSourceScrapeDialog(
        controller: controller,
        start: start,
      ),
    );

class _VideoSourceScrapeDialog extends StatefulWidget {
  const _VideoSourceScrapeDialog({
    required this.controller,
    required this.start,
  });

  final VideoSourceScrapeTaskController controller;
  final Future<SourceScrapeReport> Function() start;

  @override
  State<_VideoSourceScrapeDialog> createState() =>
      _VideoSourceScrapeDialogState();
}

class _VideoSourceScrapeDialogState extends State<_VideoSourceScrapeDialog> {
  Future<SourceScrapeReport>? _task;
  SourceScrapeReport? _report;
  Object? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    final Future<SourceScrapeReport>? active = widget.controller.activeTask;
    if (active != null) {
      _task = active;
      _observe(active);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _begin() {
    if (_task != null) return;
    final Future<SourceScrapeReport> task = widget.start();
    setState(() => _task = task);
    _observe(task);
  }

  void _observe(Future<SourceScrapeReport> task) {
    unawaited(task.then((SourceScrapeReport report) {
      if (!mounted) return;
      setState(() => _report = report);
    }, onError: (Object error, StackTrace _) {
      if (!mounted) return;
      setState(() => _error = error);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final VideoSourceScrapeProgress progress = widget.controller.progress;
    final SourceScrapeReport? report = _report;
    final bool running = widget.controller.isRunning;
    final VideoSourceScrapeConfirmation? confirmation =
        widget.controller.pendingConfirmation;
    final int total = progress.total;
    final double? value = total <= 0 ? null : progress.current / total;
    return AlertDialog(
      title: Text(t.scrape_all_title(kind: t.nav_video)),
      content: SizedBox(
        width: 480,
        child: confirmation != null
            ? _buildConfirmation(confirmation)
            : report != null
                ? _buildReport(report)
                : _error != null
                    ? SelectableText(_error.toString())
                    : _task == null
                        ? Text(t.scrape_all_confirm(n: 1))
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              LinearProgressIndicator(value: value),
                              const SizedBox(height: 12),
                              Text(t.scrape_all_running(
                                current: progress.current,
                                total: total,
                              )),
                              if (progress.sourceLabel != null) ...<Widget>[
                                const SizedBox(height: 6),
                                Text(progress.sourceLabel!),
                              ],
                              if (progress.currentWorkTitle !=
                                  null) ...<Widget>[
                                const SizedBox(height: 6),
                                Text(
                                  t.scrape_all_item(
                                    title: progress.currentWorkTitle!,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(report),
          child: Text(
            running
                ? t.dialog_close
                : (_task == null && report == null
                    ? t.dialog_cancel
                    : t.dialog_close),
          ),
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
        if (_task == null)
          FilledButton(
            onPressed: _begin,
            child: Text(t.scrape_all_start),
          ),
      ],
    );
  }

  Widget _buildConfirmation(VideoSourceScrapeConfirmation confirmation) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          t.video_source_scrape_confirmation_title,
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
            itemBuilder: (BuildContext context, int index) {
              final VideoSourceScrapeConfirmationCandidate candidate =
                  confirmation.candidates[index];
              final String? original = candidate.work.originalTitle;
              final String details = <String>[
                candidate.lookup.provider.name.toUpperCase(),
                candidate.lookup.externalId,
                if (candidate.work.year != null) '${candidate.work.year}',
                if (original != null && original != candidate.work.title)
                  original,
              ].join(' · ');
              return ListTile(
                key: ValueKey<String>(
                  'video-source-candidate-${candidate.lookup.provider.name}-'
                  '${candidate.lookup.externalId}',
                ),
                contentPadding: EdgeInsets.zero,
                title: Text(candidate.work.title),
                subtitle: Text(details),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => widget.controller.confirmPending(candidate),
              );
            },
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
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
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
