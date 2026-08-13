import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        VideoDownloadJobFileRow,
        VideoDownloadJobLifecycle,
        VideoDownloadJobRow,
        VideoDownloadJobStage;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/torrent_task_display.dart';
import 'package:fushi/src/media/video/download/video_download_error_presentation.dart';
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

/// 调整单个任务的排队优先级。数值越大越先被取走（DAO 侧 `priority DESC`）。
typedef VideoDownloadJobPriorityAction = Future<void> Function(
  VideoDownloadJobRow job,
  int priority,
);

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
    this.onSetPriority,
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
    VideoDownloadJobPriorityAction? onSetPriority,
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
        onSetPriority: onSetPriority,
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
  final VideoDownloadJobPriorityAction? onSetPriority;
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
              // 共享 MD3 行 + 裸 [Checkbox] 作 leading，整行 onTap 翻转——等价旧
              // CheckboxListTile 的取值/回调/标题，但行高与内边距走设计令牌。
              FushiListItem(
                key: ValueKey<String>(
                  'video-download-job-delete-files-${job.jobId}',
                ),
                density: FushiListDensity.compact,
                padding: EdgeInsets.zero,
                onTap: () => setDialogState(
                  () => deleteFiles = !deleteFiles,
                ),
                leading: Checkbox(
                  value: deleteFiles,
                  onChanged: (bool? value) => setDialogState(
                    () => deleteFiles = value ?? false,
                  ),
                ),
                title: Text(t.download_task_delete_files),
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
              onSetPriority: widget.onSetPriority == null
                  ? null
                  : (int priority) => _runAction(
                        job,
                        (VideoDownloadJobRow row) =>
                            widget.onSetPriority!(row, priority),
                      ),
              // Mobile has no file-manager reveal contract; the action would
              // always fail, so it is not offered there.
              onOpenLocation: widget.locationLoader == null ||
                      currentVideoDownloadRevealHost() == null
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
    final List<VideoDownloadJobFileRow> files =
        await database.getVideoDownloadJobFiles(job.jobId);
    final Iterable<int> sizes = files
        .where((VideoDownloadJobFileRow file) =>
            file.selected && file.sizeBytes != null)
        .map((VideoDownloadJobFileRow file) => file.sizeBytes!);
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
    required this.onSetPriority,
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

  /// 传 null 表示宿主没接这个能力（例如只读的历史面板）。
  final void Function(int priority)? onSetPriority;
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

  /// 优先级只对「还会被取走」的任务有意义。已完成 / 已取消的任务调了也不会重新
  /// 排队，露出来只会让人以为能插队。
  bool get _canSetPriority =>
      job.lifecycle == VideoDownloadJobLifecycle.active ||
      job.lifecycle == VideoDownloadJobLifecycle.needsAttention;

  /// 数值 -> 档位名。非三档的历史值（理论上不会有，但 DB 不拦）按最接近的一档
  /// 显示，不显示裸数字——用户看到 `优先级 · 7` 只会困惑。
  static String _priorityLabel(int priority) {
    if (priority > 0) return t.download_task_priority_high;
    if (priority < 0) return t.download_task_priority_low;
    return t.download_task_priority_normal;
  }

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
                    _defaultLifecycleLabel(job.lifecycle),
                color: statusColor,
                selected: true,
                tone: FushiTagChipTone.surface,
              ),
              FushiTagChip(
                label: stageLabel?.call(job.stage) ??
                    _defaultStageLabel(job.stage),
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
            // 摘要一行 + 点击出详情：原始引擎/后端英文诊断串不再整句铺进卡片
            // （BUG-1540），只展示分类后的本地化摘要；完整原文进对话框可复制。
            InkWell(
              key: ValueKey<String>('video-download-job-error-${job.jobId}'),
              borderRadius: FushiBorderRadius.chip,
              onTap: () => _showErrorDetail(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.info_outline, size: 17, color: colors.error),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        videoDownloadErrorSummary(job.lastError!.trim()),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.error,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      t.download_task_error_view_detail,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.error,
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 16, color: colors.error),
                  ],
                ),
              ),
            ),
          ],
          if ((_canRetry && onRetry != null) ||
              (_canResume && onResume != null) ||
              (_canCancel && onCancel != null) ||
              onOpenDetails != null ||
              onOpenLocation != null ||
              onSetPriority != null ||
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
                  // 优先级只对「还在排队/还没做完」的任务有意义：已完成或已取消
                  // 的任务再调也不会被重新取走，给了只会让人以为能插队。
                  if (onSetPriority != null && _canSetPriority)
                    PopupMenuButton<int>(
                      key: ValueKey<String>(
                        'video-download-job-priority-${job.jobId}',
                      ),
                      enabled: !busy,
                      tooltip: t.download_task_priority,
                      initialValue: job.priority,
                      onSelected: onSetPriority,
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<int>>[
                        PopupMenuItem<int>(
                          value: 1,
                          child: Text(t.download_task_priority_high),
                        ),
                        PopupMenuItem<int>(
                          value: 0,
                          child: Text(t.download_task_priority_normal),
                        ),
                        PopupMenuItem<int>(
                          value: -1,
                          child: Text(t.download_task_priority_low),
                        ),
                      ],
                      child: OutlinedButton.icon(
                        // 外层 PopupMenuButton 已接管点击；这里只借用按钮外观，
                        // onPressed 必须为 null 才不会吞掉菜单的手势。
                        onPressed: null,
                        icon: const Icon(Icons.low_priority, size: 18),
                        label: Text(
                          '${t.download_task_priority} · '
                          '${_priorityLabel(job.priority)}',
                        ),
                      ),
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

  /// Shows the untouched raw `lastError` diagnostics in a copyable dialog.
  Future<void> _showErrorDetail(BuildContext context) async {
    final String raw = job.lastError?.trim() ?? '';
    if (raw.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        final ThemeData theme = Theme.of(dialogContext);
        return AlertDialog(
          key: const ValueKey<String>('video-download-job-error-detail-dialog'),
          title: Text(t.download_task_error_detail_title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    videoDownloadErrorSummary(raw),
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    raw,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: raw));
                if (dialogContext.mounted) {
                  ScaffoldMessenger.maybeOf(dialogContext)?.showSnackBar(
                    SnackBar(content: Text(t.download_task_error_copied)),
                  );
                }
              },
              icon: const Icon(Icons.copy, size: 18),
              label: Text(t.copy),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(t.dialog_close),
            ),
          ],
        );
      },
    );
  }

  static String _defaultLifecycleLabel(String lifecycle) => switch (lifecycle) {
        VideoDownloadJobLifecycle.active => t.download_task_lifecycle_active,
        VideoDownloadJobLifecycle.needsAttention =>
          t.download_task_lifecycle_needs_attention,
        VideoDownloadJobLifecycle.completed =>
          t.download_task_lifecycle_completed,
        VideoDownloadJobLifecycle.failed => t.download_task_lifecycle_failed,
        VideoDownloadJobLifecycle.cancelled =>
          t.download_task_lifecycle_cancelled,
        _ => lifecycle,
      };

  static String _defaultStageLabel(String stage) => switch (stage) {
        VideoDownloadJobStage.enqueue => t.download_task_stage_enqueue,
        VideoDownloadJobStage.download => t.download_task_stage_download,
        VideoDownloadJobStage.organize => t.download_task_stage_organize,
        VideoDownloadJobStage.subtitle => t.download_task_stage_subtitle,
        VideoDownloadJobStage.import => t.download_task_stage_import,
        VideoDownloadJobStage.scrape => t.download_task_stage_scrape,
        _ => stage,
      };

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

/// Desktop hosts that have a file manager to reveal a task path in.
enum VideoDownloadRevealHost { windows, macos, linux }

/// The reveal host of the running platform, or null on mobile where no file
/// manager contract exists and the surface must not offer the action at all.
VideoDownloadRevealHost? currentVideoDownloadRevealHost() {
  if (Platform.isWindows) return VideoDownloadRevealHost.windows;
  if (Platform.isMacOS) return VideoDownloadRevealHost.macos;
  if (Platform.isLinux) return VideoDownloadRevealHost.linux;
  return null;
}

/// A resolved file-manager invocation plus whether its exit code means
/// anything. See [videoDownloadRevealCommand].
class VideoDownloadRevealCommand {
  const VideoDownloadRevealCommand({
    required this.executable,
    required this.arguments,
    required this.exitCodeIsMeaningful,
  });

  final String executable;
  final List<String> arguments;

  /// False when the process reports a status that is unrelated to success, so
  /// spawning it at all is the only signal available.
  final bool exitCodeIsMeaningful;
}

/// Builds the file-manager invocation for [host].
///
/// Windows specifics, measured on Windows 11 by launching each form and
/// reading back the opened window through `Shell.Application`:
/// * `explorer.exe` exits with 1 on every form, including the ones that open
///   and select correctly, so its exit code carries no success signal.
/// * `/select,` and the path must stay two separate argv entries. Dart quotes
///   any argument containing a space, so joining them into `/select,<path>`
///   yields the command line `explorer "/select,C:\dir\file.mkv"`, which
///   explorer answers by opening Documents instead - 3/3 runs, with and
///   without spaces in the path. The split form selected the file in every
///   run.
VideoDownloadRevealCommand videoDownloadRevealCommand({
  required VideoDownloadRevealHost host,
  required String path,
  required bool isDirectory,
}) {
  switch (host) {
    case VideoDownloadRevealHost.windows:
      final String windowsPath = p.normalize(path).replaceAll('/', r'\');
      return VideoDownloadRevealCommand(
        executable: 'explorer',
        arguments: isDirectory
            ? <String>[windowsPath]
            : <String>['/select,', windowsPath],
        exitCodeIsMeaningful: false,
      );
    case VideoDownloadRevealHost.macos:
      return VideoDownloadRevealCommand(
        executable: 'open',
        arguments: isDirectory ? <String>[path] : <String>['-R', path],
        exitCodeIsMeaningful: true,
      );
    case VideoDownloadRevealHost.linux:
      return VideoDownloadRevealCommand(
        executable: 'xdg-open',
        arguments: <String>[isDirectory ? path : p.dirname(path)],
        exitCodeIsMeaningful: true,
      );
  }
}

/// Opens a task path in the platform file manager. Files are selected when the
/// platform supports it; directories are opened directly.
Future<bool> revealVideoDownloadPath(String path) => revealVideoDownloadPathOn(
      path,
      host: currentVideoDownloadRevealHost(),
      typeOf: (String value) =>
          FileSystemEntity.type(value, followLinks: false),
      run: Process.run,
    );

/// Injectable core of [revealVideoDownloadPath] so the per-host argv shape and
/// the exit-code policy stay testable without a real file manager.
@visibleForTesting
Future<bool> revealVideoDownloadPathOn(
  String path, {
  required VideoDownloadRevealHost? host,
  required Future<FileSystemEntityType> Function(String path) typeOf,
  required Future<ProcessResult> Function(
    String executable,
    List<String> arguments,
  ) run,
}) async {
  if (host == null) return false;
  final FileSystemEntityType type = await typeOf(path);
  if (type == FileSystemEntityType.notFound) return false;
  final VideoDownloadRevealCommand command = videoDownloadRevealCommand(
    host: host,
    path: path,
    isDirectory: type == FileSystemEntityType.directory,
  );
  try {
    final ProcessResult result = await run(
      command.executable,
      command.arguments,
    );
    if (!command.exitCodeIsMeaningful) return true;
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
