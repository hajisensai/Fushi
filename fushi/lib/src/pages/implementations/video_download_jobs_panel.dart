import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        VideoDownloadJobLifecycle,
        VideoDownloadJobRow,
        VideoDownloadJobStage;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/torrent_task_display.dart';
import 'package:fushi/utils.dart';

typedef VideoDownloadJobAction = Future<void> Function(
  VideoDownloadJobRow job,
);

typedef VideoDownloadJobLocationLoader = Future<String?> Function(
  VideoDownloadJobRow job,
);

typedef VideoDownloadJobDeleteAction = Future<void> Function(
  VideoDownloadJobRow job, {
  required bool deleteFiles,
});

typedef VideoDownloadPathRevealer = Future<bool> Function(String path);

typedef VideoDownloadJobMetricsLoader = Future<Map<String, TorrentSnapshot>>
    Function(
  Iterable<VideoDownloadJobRow> jobs,
);

typedef VideoDownloadJobSelectedSizeLoader = Future<Map<String, int>> Function(
  Iterable<VideoDownloadJobRow> jobs,
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

/// Compact task surface for schema-v78 durable video downloads.
///
/// Retrying and cancelling are deliberately action ports rather than direct DB
/// writes. The pipeline owns lease release, backend cancellation and restart
/// reconciliation, so callers should wire these callbacks to that service.
class VideoDownloadJobsPanel extends StatefulWidget {
  const VideoDownloadJobsPanel({
    required this.store,
    super.key,
    this.onRetry,
    this.onResume,
    this.onCancel,
    this.onOpenDetails,
    this.locationLoader,
    this.onDelete,
    this.pathRevealer = revealVideoDownloadPath,
    this.metricsLoader,
    this.selectedSizeLoader,
    this.lifecycleLabel,
    this.stageLabel,
  });

  factory VideoDownloadJobsPanel.database({
    required FushiDatabase database,
    Key? key,
    VideoDownloadJobAction? onRetry,
    VideoDownloadJobAction? onResume,
    VideoDownloadJobAction? onCancel,
    VideoDownloadJobAction? onOpenDetails,
    VideoDownloadJobLocationLoader? locationLoader,
    VideoDownloadJobDeleteAction? onDelete,
    VideoDownloadPathRevealer pathRevealer = revealVideoDownloadPath,
    VideoDownloadJobMetricsLoader? metricsLoader,
    VideoDownloadJobSelectedSizeLoader? selectedSizeLoader,
    String Function(String lifecycle)? lifecycleLabel,
    String Function(String stage)? stageLabel,
  }) =>
      VideoDownloadJobsPanel(
        key: key,
        store: DatabaseVideoDownloadJobsPanelStore(database),
        onRetry: onRetry,
        onResume: onResume,
        onCancel: onCancel,
        onOpenDetails: onOpenDetails,
        locationLoader: locationLoader,
        onDelete: onDelete,
        pathRevealer: pathRevealer,
        metricsLoader: metricsLoader,
        selectedSizeLoader: selectedSizeLoader ??
            (Iterable<VideoDownloadJobRow> jobs) =>
                _loadSelectedSizes(database, jobs),
        lifecycleLabel: lifecycleLabel,
        stageLabel: stageLabel,
      );

  final VideoDownloadJobsPanelStore store;
  final VideoDownloadJobAction? onRetry;
  final VideoDownloadJobAction? onResume;
  final VideoDownloadJobAction? onCancel;
  final VideoDownloadJobAction? onOpenDetails;
  final VideoDownloadJobLocationLoader? locationLoader;
  final VideoDownloadJobDeleteAction? onDelete;
  final VideoDownloadPathRevealer pathRevealer;
  final VideoDownloadJobMetricsLoader? metricsLoader;
  final VideoDownloadJobSelectedSizeLoader? selectedSizeLoader;

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
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t.download_task_action_failed(error: '$error')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busyJobIds.remove(job.jobId));
    }
  }

  Future<void> _openLocation(VideoDownloadJobRow job) async {
    final VideoDownloadJobLocationLoader? loader = widget.locationLoader;
    if (loader == null) return;
    await _runAction(job, (VideoDownloadJobRow value) async {
      final String? path = await loader(value);
      if (!mounted) return;
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.download_task_location_missing)),
        );
        return;
      }
      if (!await widget.pathRevealer(path) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.download_task_location_open_failed)),
        );
      }
    });
  }

  Future<void> _confirmDelete(VideoDownloadJobRow job) async {
    if (widget.onDelete == null) return;
    bool deleteFiles = false;
    final bool? choice = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (
          BuildContext context,
          void Function(void Function()) setDialogState,
        ) =>
            AlertDialog(
          title: Text(t.download_task_delete),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t.download_task_delete_confirm(title: job.title)),
              const SizedBox(height: 12),
              CheckboxListTile(
                key: ValueKey<String>(
                  'video-download-job-delete-files-${job.jobId}',
                ),
                value: deleteFiles,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(t.download_task_delete_files),
                onChanged: (bool? value) => setDialogState(
                  () => deleteFiles = value ?? false,
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(t.dialog_cancel),
            ),
            FilledButton(
              key: ValueKey<String>(
                'video-download-job-delete-confirm-${job.jobId}',
              ),
              onPressed: () => Navigator.pop(dialogContext, deleteFiles),
              child: Text(t.dialog_delete),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _runAction(
      job,
      (VideoDownloadJobRow value) =>
          widget.onDelete!(value, deleteFiles: choice),
    );
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
          return _VideoDownloadJobList(
            jobs: jobs,
            metricsLoader: widget.metricsLoader,
            selectedSizeLoader: widget.selectedSizeLoader,
            itemBuilder: (
              BuildContext context,
              VideoDownloadJobRow job,
              TorrentSnapshot? snapshot,
              int? selectedSizeBytes,
            ) =>
                _VideoDownloadJobCard(
              key: ValueKey<String>(
                'video-download-job-${job.jobId}',
              ),
              job: job,
              snapshot: snapshot,
              selectedSizeBytes: selectedSizeBytes,
              busy: _busyJobIds.contains(job.jobId),
              onRetry: widget.onRetry == null
                  ? null
                  : () => _runAction(job, widget.onRetry!),
              onResume: widget.onResume == null
                  ? null
                  : () => _runAction(job, widget.onResume!),
              onCancel: widget.onCancel == null
                  ? null
                  : () => _runAction(job, widget.onCancel!),
              onOpenDetails: widget.onOpenDetails == null
                  ? null
                  : () => _runAction(job, widget.onOpenDetails!),
              onOpenLocation: widget.locationLoader == null
                  ? null
                  : () => _openLocation(job),
              onDelete:
                  widget.onDelete == null ? null : () => _confirmDelete(job),
              lifecycleLabel: widget.lifecycleLabel,
              stageLabel: widget.stageLabel,
            ),
          );
        },
      ),
    );
  }
}

Future<Map<String, int>> _loadSelectedSizes(
  FushiDatabase database,
  Iterable<VideoDownloadJobRow> jobs,
) async {
  final Map<String, int> result = <String, int>{};
  await Future.wait(jobs.map((VideoDownloadJobRow job) async {
    final files = await database.getVideoDownloadJobFiles(job.jobId);
    final Iterable<int> sizes = files
        .where((file) => file.selected && file.sizeBytes != null)
        .map((file) => file.sizeBytes!);
    if (sizes.isNotEmpty) {
      result[job.jobId] = sizes.fold(0, (int sum, int size) => sum + size);
    }
  }));
  return Map<String, int>.unmodifiable(result);
}

typedef _VideoDownloadJobItemBuilder = Widget Function(
  BuildContext context,
  VideoDownloadJobRow job,
  TorrentSnapshot? snapshot,
  int? selectedSizeBytes,
);

class _VideoDownloadJobList extends StatefulWidget {
  const _VideoDownloadJobList({
    required this.jobs,
    required this.metricsLoader,
    required this.selectedSizeLoader,
    required this.itemBuilder,
  });

  final List<VideoDownloadJobRow> jobs;
  final VideoDownloadJobMetricsLoader? metricsLoader;
  final VideoDownloadJobSelectedSizeLoader? selectedSizeLoader;
  final _VideoDownloadJobItemBuilder itemBuilder;

  @override
  State<_VideoDownloadJobList> createState() => _VideoDownloadJobListState();
}

class _VideoDownloadJobListState extends State<_VideoDownloadJobList> {
  static const Duration _refreshInterval = Duration(seconds: 3);

  Timer? _timer;
  bool _loading = false;
  Map<String, TorrentSnapshot> _snapshots = const <String, TorrentSnapshot>{};
  Map<String, int> _selectedSizes = const <String, int>{};

  @override
  void initState() {
    super.initState();
    _restartMetrics();
  }

  @override
  void didUpdateWidget(_VideoDownloadJobList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool jobsChanged =
        _jobIdentity(oldWidget.jobs) != _jobIdentity(widget.jobs);
    if (oldWidget.metricsLoader != widget.metricsLoader || jobsChanged) {
      _restartMetrics();
    }
    if (oldWidget.selectedSizeLoader != widget.selectedSizeLoader ||
        jobsChanged) {
      _loadSelectedSizesOnce();
    }
  }

  String _jobIdentity(List<VideoDownloadJobRow> jobs) => jobs
      .map((VideoDownloadJobRow job) =>
          '${job.jobId}:${job.backendTaskId ?? job.torrentHash ?? ''}')
      .join('|');

  void _restartMetrics() {
    _timer?.cancel();
    _timer = null;
    _loadSelectedSizesOnce();
    if (widget.metricsLoader == null) {
      _snapshots = const <String, TorrentSnapshot>{};
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshMetrics());
    });
    _timer = Timer.periodic(
      _refreshInterval,
      (_) => unawaited(_refreshMetrics()),
    );
  }

  void _loadSelectedSizesOnce() {
    final VideoDownloadJobSelectedSizeLoader? loader =
        widget.selectedSizeLoader;
    if (loader == null) return;
    unawaited(loader(widget.jobs).then((Map<String, int> sizes) {
      if (mounted) setState(() => _selectedSizes = sizes);
    }));
  }

  Future<void> _refreshMetrics() async {
    final VideoDownloadJobMetricsLoader? loader = widget.metricsLoader;
    if (!mounted || loader == null || _loading || !TickerMode.of(context)) {
      return;
    }
    _loading = true;
    try {
      final Map<String, TorrentSnapshot> next = await loader(widget.jobs);
      if (mounted) setState(() => _snapshots = next);
    } on Object {
      // 实时指标失败不影响持久任务本身的展示；保留上一帧避免数据闪烁。
    } finally {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: widget.jobs.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (BuildContext context, int index) {
          final VideoDownloadJobRow job = widget.jobs[index];
          return widget.itemBuilder(
            context,
            job,
            _snapshots[job.jobId],
            _selectedSizes[job.jobId],
          );
        },
      );
}

class _VideoDownloadJobCard extends StatelessWidget {
  const _VideoDownloadJobCard({
    required this.job,
    required this.snapshot,
    required this.selectedSizeBytes,
    required this.busy,
    required this.onRetry,
    required this.onResume,
    required this.onCancel,
    required this.onOpenDetails,
    required this.onOpenLocation,
    required this.onDelete,
    required this.lifecycleLabel,
    required this.stageLabel,
    super.key,
  });

  final VideoDownloadJobRow job;
  final TorrentSnapshot? snapshot;
  final int? selectedSizeBytes;
  final bool busy;
  final VoidCallback? onRetry;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;
  final VoidCallback? onOpenDetails;
  final VoidCallback? onOpenLocation;
  final VoidCallback? onDelete;
  final String Function(String lifecycle)? lifecycleLabel;
  final String Function(String stage)? stageLabel;

  bool get _canRetry =>
      job.resourceProvider != 'legacy-import-report' &&
      (job.lifecycle == VideoDownloadJobLifecycle.needsAttention ||
          job.lifecycle == VideoDownloadJobLifecycle.failed);

  bool get _canResume => job.lifecycle == VideoDownloadJobLifecycle.cancelled;

  bool get _canCancel => job.lifecycle == VideoDownloadJobLifecycle.active;

  double get _progress =>
      snapshot?.progress.clamp(0, 1).toDouble() ??
      (job.lifecycle == VideoDownloadJobLifecycle.completed
          ? 1
          : job.stageProgress.clamp(0, 1));

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final Color statusColor = _statusColor(colors);
    return FushiCard(
      padding: const EdgeInsets.all(12),
      onTap: busy ? null : onOpenDetails,
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
              if (onOpenDetails != null) ...<Widget>[
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  color: colors.onSurfaceVariant,
                  size: 20,
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              FushiTagChip(
                label: _torrentStatusLabel ??
                    lifecycleLabel?.call(job.lifecycle) ??
                    job.lifecycle,
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
          _TaskMetrics(
            snapshot: snapshot,
            selectedSizeBytes: selectedSizeBytes,
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
              (_canResume && onResume != null) ||
              (_canCancel && onCancel != null) ||
              onOpenDetails != null ||
              onOpenLocation != null ||
              onDelete != null) ...<Widget>[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  if (onOpenDetails != null)
                    OutlinedButton.icon(
                      key: ValueKey<String>(
                        'video-download-job-details-${job.jobId}',
                      ),
                      onPressed: busy ? null : onOpenDetails,
                      icon: const Icon(Icons.info_outline, size: 18),
                      label: Text(t.download_task_details),
                    ),
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
                  if (_canResume && onResume != null)
                    FilledButton.tonalIcon(
                      key: ValueKey<String>(
                        'video-download-job-resume-${job.jobId}',
                      ),
                      onPressed: busy ? null : onResume,
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow, size: 18),
                      label: Text(t.download_task_resume),
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
                  if (onOpenLocation != null)
                    OutlinedButton.icon(
                      key: ValueKey<String>(
                        'video-download-job-location-${job.jobId}',
                      ),
                      onPressed: busy ? null : onOpenLocation,
                      icon: const Icon(Icons.folder_open_outlined, size: 18),
                      label: Text(t.download_task_open_location),
                    ),
                  if (onDelete != null)
                    TextButton.icon(
                      key: ValueKey<String>(
                        'video-download-job-delete-${job.jobId}',
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.error,
                      ),
                      onPressed: busy ? null : onDelete,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(t.download_task_delete),
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

  String? get _torrentStatusLabel {
    final TorrentSnapshot? value = snapshot;
    if (value == null) {
      if (job.lifecycle == VideoDownloadJobLifecycle.completed) {
        return t.download_task_status_completed;
      }
      if (job.lifecycle == VideoDownloadJobLifecycle.active &&
          job.stage == VideoDownloadJobStage.download) {
        return t.download_task_status_downloading;
      }
      return null;
    }
    return switch (torrentDisplayStatusFor(value.state)) {
      TorrentDisplayStatus.downloading => t.download_task_status_downloading,
      TorrentDisplayStatus.seeding => t.download_task_status_seeding,
      TorrentDisplayStatus.completed => t.download_task_status_completed,
      TorrentDisplayStatus.paused => t.download_task_status_paused,
      TorrentDisplayStatus.queued => t.download_task_status_queued,
      TorrentDisplayStatus.stalled => t.download_task_status_stalled,
      TorrentDisplayStatus.checking => t.download_task_status_checking,
      TorrentDisplayStatus.fetchingMetadata => t.download_task_status_metadata,
      TorrentDisplayStatus.moving => t.download_task_status_moving,
      TorrentDisplayStatus.error => t.download_task_status_error,
      TorrentDisplayStatus.unknown => null,
    };
  }

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

/// Opens a task path in the platform file manager. Files are selected when the
/// platform supports it; directories are opened directly.
Future<bool> revealVideoDownloadPath(String path) async {
  final FileSystemEntityType type =
      await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return false;
  try {
    late final ProcessResult result;
    if (Platform.isWindows) {
      final String windowsPath = p.normalize(path).replaceAll('/', r'\');
      result = await Process.run(
        'explorer',
        type == FileSystemEntityType.directory
            ? <String>[windowsPath]
            : <String>['/select,', windowsPath],
      );
    } else if (Platform.isMacOS) {
      result = await Process.run(
        'open',
        type == FileSystemEntityType.directory
            ? <String>[path]
            : <String>['-R', path],
      );
    } else {
      result = await Process.run(
        'xdg-open',
        <String>[
          type == FileSystemEntityType.directory ? path : p.dirname(path),
        ],
      );
    }
    return result.exitCode == 0;
  } on Object {
    return false;
  }
}

class _TaskMetrics extends StatelessWidget {
  const _TaskMetrics({required this.snapshot, this.selectedSizeBytes});

  final TorrentSnapshot? snapshot;
  final int? selectedSizeBytes;

  @override
  Widget build(BuildContext context) {
    final TorrentSnapshot? value = snapshot;
    final List<(String, String)> metrics = <(String, String)>[
      (
        t.anime_download_sort_size,
        (value?.totalSizeBytes ?? -1) < 0 && selectedSizeBytes == null
            ? '—'
            : FushiByteFormat.bytes(
                (value?.totalSizeBytes ?? -1) >= 0
                    ? value!.totalSizeBytes
                    : selectedSizeBytes,
              ),
      ),
      (
        t.download_detail_seeds_label,
        _peerMetric(value?.numSeeds, value?.swarmSeeds),
      ),
      (
        t.download_detail_tab_peers,
        _peerMetric(value?.numLeechs, value?.swarmLeechs),
      ),
      (
        '↓',
        value == null
            ? '—'
            : FushiByteFormat.speed(value.downRateBps.toDouble()),
      ),
      (
        '↑',
        value == null ? '—' : FushiByteFormat.speed(value.upRateBps.toDouble()),
      ),
      (
        t.download_task_eta,
        value == null
            ? '—'
            : formatTorrentEta(
                  amountLeft: value.amountLeft,
                  downRateBps: value.downRateBps,
                ) ??
                '∞',
      ),
      (
        t.download_task_ratio,
        value == null
            ? '—'
            : formatShareRatio(
                  uploadedBytes: value.uploadedBytes,
                  downloadedBytes: value.downloadedBytes,
                ) ??
                '—',
      ),
    ];
    return Wrap(
      spacing: 18,
      runSpacing: 8,
      children: metrics
          .map(
            ((String, String) metric) => SizedBox(
              width: 118,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    metric.$1,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    metric.$2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  static String _peerMetric(int? connected, int? swarm) {
    if (connected == null || connected < 0) return '—';
    return swarm == null || swarm < 0 ? '$connected' : '$connected ($swarm)';
  }
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
