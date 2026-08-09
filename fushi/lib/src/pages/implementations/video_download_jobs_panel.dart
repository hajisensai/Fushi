import 'package:flutter/material.dart';
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, VideoDownloadJobLifecycle, VideoDownloadJobRow;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

typedef VideoDownloadJobAction = Future<void> Function(
  VideoDownloadJobRow job,
);

/// Narrow read port used by [VideoDownloadJobsPanel].
///
/// Production can use [DatabaseVideoDownloadJobsPanelStore], while widget tests
/// and alternate hosts can provide a stream without constructing the app model.
abstract interface class VideoDownloadJobsPanelStore {
  Stream<List<VideoDownloadJobRow>> watchJobs();
}

final class DatabaseVideoDownloadJobsPanelStore
    implements VideoDownloadJobsPanelStore {
  const DatabaseVideoDownloadJobsPanelStore(this.database);

  final FushiDatabase database;

  @override
  Stream<List<VideoDownloadJobRow>> watchJobs() =>
      database.watchVideoDownloadJobs();
}

/// Compact task surface for schema-v71 durable video downloads.
///
/// Retrying and cancelling are deliberately action ports rather than direct DB
/// writes. The pipeline owns lease release, backend cancellation and restart
/// reconciliation, so callers should wire these callbacks to that service.
class VideoDownloadJobsPanel extends StatefulWidget {
  const VideoDownloadJobsPanel({
    required this.store,
    super.key,
    this.onRetry,
    this.onCancel,
    this.lifecycleLabel,
    this.stageLabel,
  });

  factory VideoDownloadJobsPanel.database({
    required FushiDatabase database,
    Key? key,
    VideoDownloadJobAction? onRetry,
    VideoDownloadJobAction? onCancel,
    String Function(String lifecycle)? lifecycleLabel,
    String Function(String stage)? stageLabel,
  }) =>
      VideoDownloadJobsPanel(
        key: key,
        store: DatabaseVideoDownloadJobsPanelStore(database),
        onRetry: onRetry,
        onCancel: onCancel,
        lifecycleLabel: lifecycleLabel,
        stageLabel: stageLabel,
      );

  final VideoDownloadJobsPanelStore store;
  final VideoDownloadJobAction? onRetry;
  final VideoDownloadJobAction? onCancel;

  /// Optional localization hooks. The persisted values remain visible by
  /// default, which is useful for diagnosing a stopped pipeline stage.
  final String Function(String lifecycle)? lifecycleLabel;
  final String Function(String stage)? stageLabel;

  @override
  State<VideoDownloadJobsPanel> createState() => _VideoDownloadJobsPanelState();
}

class _VideoDownloadJobsPanelState extends State<VideoDownloadJobsPanel> {
  late Stream<List<VideoDownloadJobRow>> _jobs;
  final Set<String> _busyJobIds = <String>{};

  @override
  void initState() {
    super.initState();
    _jobs = widget.store.watchJobs();
  }

  @override
  void didUpdateWidget(VideoDownloadJobsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      _jobs = widget.store.watchJobs();
    }
  }

  Future<void> _runAction(
    VideoDownloadJobRow job,
    VideoDownloadJobAction action,
  ) async {
    if (_busyJobIds.contains(job.jobId)) return;
    setState(() => _busyJobIds.add(job.jobId));
    try {
      await action(job);
    } finally {
      if (mounted) setState(() => _busyJobIds.remove(job.jobId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surface,
      child: StreamBuilder<List<VideoDownloadJobRow>>(
        stream: _jobs,
        builder: (
          BuildContext context,
          AsyncSnapshot<List<VideoDownloadJobRow>> snapshot,
        ) {
          if (snapshot.hasError) {
            return _MessageState(
              icon: Icons.error_outline,
              message: t.error_load_failed,
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final List<VideoDownloadJobRow> jobs = snapshot.data!;
          if (jobs.isEmpty) {
            return _MessageState(
              icon: Icons.downloading_outlined,
              message: t.anime_download_no_tasks,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            itemCount: jobs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (BuildContext context, int index) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: _VideoDownloadJobCard(
                  key: ValueKey<String>(
                    'video-download-job-${jobs[index].jobId}',
                  ),
                  job: jobs[index],
                  busy: _busyJobIds.contains(jobs[index].jobId),
                  onRetry: widget.onRetry == null
                      ? null
                      : () => _runAction(jobs[index], widget.onRetry!),
                  onCancel: widget.onCancel == null
                      ? null
                      : () => _runAction(jobs[index], widget.onCancel!),
                  lifecycleLabel: widget.lifecycleLabel,
                  stageLabel: widget.stageLabel,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _VideoDownloadJobCard extends StatelessWidget {
  const _VideoDownloadJobCard({
    required this.job,
    required this.busy,
    required this.onRetry,
    required this.onCancel,
    required this.lifecycleLabel,
    required this.stageLabel,
    super.key,
  });

  final VideoDownloadJobRow job;
  final bool busy;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final String Function(String lifecycle)? lifecycleLabel;
  final String Function(String stage)? stageLabel;

  bool get _canRetry =>
      job.resourceProvider != 'legacy-import-report' &&
      (job.lifecycle == VideoDownloadJobLifecycle.needsAttention ||
          job.lifecycle == VideoDownloadJobLifecycle.failed);

  bool get _canCancel => job.lifecycle == VideoDownloadJobLifecycle.active;

  double get _progress => job.lifecycle == VideoDownloadJobLifecycle.completed
      ? 1
      : job.stageProgress.clamp(0, 1);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final Color statusColor = _statusColor(colors);
    return FushiCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(_statusIcon(), color: statusColor, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      job.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (_details.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        _details,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              FushiTagChip(
                label: lifecycleLabel?.call(job.lifecycle) ?? job.lifecycle,
                color: statusColor,
                selected: true,
                tone: FushiTagChipTone.surface,
              ),
              FushiTagChip(
                label: stageLabel?.call(job.stage) ?? job.stage,
                tone: FushiTagChipTone.surface,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 5,
                  color: statusColor,
                  semanticsValue: _progressLabel,
                ),
              ),
              const SizedBox(width: 10),
              Text(_progressLabel, style: theme.textTheme.labelMedium),
            ],
          ),
          if (job.lastError?.trim().isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.info_outline, size: 17, color: colors.error),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    job.lastError!.trim(),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if ((_canRetry && onRetry != null) ||
              (_canCancel && onCancel != null)) ...<Widget>[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  if (_canRetry && onRetry != null)
                    FilledButton.tonalIcon(
                      key: ValueKey<String>(
                        'video-download-job-retry-${job.jobId}',
                      ),
                      onPressed: busy ? null : onRetry,
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: Text(t.retry),
                    ),
                  if (_canCancel && onCancel != null)
                    OutlinedButton.icon(
                      key: ValueKey<String>(
                        'video-download-job-cancel-${job.jobId}',
                      ),
                      onPressed: busy ? null : onCancel,
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.close, size: 18),
                      label: Text(t.cancel),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String get _details => <String>[
        job.mediaKind,
        if (job.year != null) '${job.year}',
        if (job.resourceTitle?.trim().isNotEmpty ?? false)
          job.resourceTitle!.trim(),
      ].join(' · ');

  String get _progressLabel => '${(_progress * 100).round()}%';

  Color _statusColor(ColorScheme colors) => switch (job.lifecycle) {
        VideoDownloadJobLifecycle.needsAttention => colors.tertiary,
        VideoDownloadJobLifecycle.failed => colors.error,
        VideoDownloadJobLifecycle.completed => colors.primary,
        VideoDownloadJobLifecycle.cancelled => colors.outline,
        _ => colors.secondary,
      };

  IconData _statusIcon() => switch (job.lifecycle) {
        VideoDownloadJobLifecycle.needsAttention => Icons.warning_amber,
        VideoDownloadJobLifecycle.failed => Icons.error_outline,
        VideoDownloadJobLifecycle.completed => Icons.check_circle_outline,
        VideoDownloadJobLifecycle.cancelled => Icons.block,
        _ => Icons.downloading_outlined,
      };
}

class _MessageState extends StatelessWidget {
  const _MessageState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
