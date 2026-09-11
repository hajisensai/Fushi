import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

/// 「下载」页任务 tab 的漫画分区：读 `manga_download_jobs`（在线章节 +
/// mokuro.moe 整卷同一张表）输出 [DownloadTaskEntry]，与 torrent / 直链 / 远端
/// 任务并列进统一列表（设计稿 2026-09-12 §4，取代原 `MokuroMoeTasksSection`）。
///
/// 只做映射，不持有任务：动作全部委托 [MangaDownloadService]（取消 / 重试 /
/// 清除），行的真相是表——`watchJobs` 一响就整体重取。独立使用时空表不占位；
/// [tasksBuilder] 把条目接进外层统一列表。
class MangaDownloadTasksSection extends ConsumerStatefulWidget {
  const MangaDownloadTasksSection({
    super.key,
    this.downloadsOverride,
    this.tasksBuilder,
  });

  /// 测试注入服务（null = 取 [AppModel.mangaDownloadService]）。
  final MangaDownloadService? downloadsOverride;

  /// Parent owns unified filtering, sorting and grouping, including empty lists.
  final DownloadTasksBuilder? tasksBuilder;

  @override
  ConsumerState<MangaDownloadTasksSection> createState() =>
      _MangaDownloadTasksSectionState();
}

class _MangaDownloadTasksSectionState
    extends ConsumerState<MangaDownloadTasksSection> {
  MangaDownloadService? _downloads;
  List<MangaDownloadJobRow> _jobs = const <MangaDownloadJobRow>[];
  StreamSubscription<void>? _watch;

  @override
  void initState() {
    super.initState();
    _downloads = widget.downloadsOverride ?? _appService();
    final MangaDownloadService? downloads = _downloads;
    if (downloads == null) return;
    _watch = downloads.watchJobs().listen(
      (_) => unawaited(_reload()),
      onError: (Object error, StackTrace stack) {
        ErrorLogService.instance.log(
          'MangaDownloadTasksSection.watch',
          error,
          stack,
        );
      },
    );
    unawaited(_reload());
  }

  @override
  void dispose() {
    unawaited(_watch?.cancel());
    _watch = null;
    super.dispose();
  }

  /// Do not initialize the database-backed service when one is injected.
  MangaDownloadService? _appService() {
    final AppModel appModel = ref.read(appProvider);
    return appModel.isDatabaseReady ? appModel.mangaDownloadService : null;
  }

  Future<void> _reload() async {
    final MangaDownloadService? downloads = _downloads;
    if (downloads == null) return;
    final List<MangaDownloadJobRow> jobs = await downloads.listJobs();
    if (!mounted) return;
    setState(() => _jobs = jobs);
  }

  @override
  Widget build(BuildContext context) {
    final MangaDownloadService? downloads = _downloads;
    final List<DownloadTaskEntry> entries = <DownloadTaskEntry>[
      if (downloads != null)
        for (final MangaDownloadJobRow job in _jobs)
          mangaDownloadTaskEntry(job, downloads),
    ];
    final DownloadTasksBuilder? builder = widget.tasksBuilder;
    if (builder != null) return builder(context, entries);
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final DownloadTaskEntry entry in entries) entry.builder(context),
      ],
    );
  }
}

/// 一条任务行 → 统一下载中心条目。
///
/// `id = manga:<jobId>`；`collectionKey` 在线章节取 bookKey、mokuro 卷取
/// `mokuro:<系列>`（表里的 bookKey 本来就是这个形状）；动作：未结束可取消、
/// failed / cancelled 可重试（同一行复位，BUG-1433）、已结束可清除。
DownloadTaskEntry mangaDownloadTaskEntry(
  MangaDownloadJobRow job,
  MangaDownloadService downloads,
) {
  final String id = 'manga:${job.jobId}';
  final bool finished = _isFinished(job);
  final bool retryable = job.status == MangaDownloadJobStatus.failed ||
      job.status == MangaDownloadJobStatus.cancelled;
  final double? progress = job.status == MangaDownloadJobStatus.done
      ? 1
      : job.pagesTotal > 0
          ? (job.pagesDone / job.pagesTotal).clamp(0.0, 1.0)
          : null;
  final String? seriesName = mokuroMoeSeriesNameOf(job.bookKey);
  final String collectionTitle = seriesName ?? job.title;
  final String status = _statusLabel(job);
  return DownloadTaskEntry(
    id: id,
    title: job.kind == MangaDownloadJobKind.mokuroVolume
        ? job.title
        : '${job.title} · ${job.chapterTitle}',
    createdAt: job.createdAt,
    kind: DownloadTaskKind.manga,
    status: switch (job.status) {
      MangaDownloadJobStatus.queued => DownloadTaskStatus.queued,
      MangaDownloadJobStatus.running => DownloadTaskStatus.active,
      MangaDownloadJobStatus.done => DownloadTaskStatus.completed,
      MangaDownloadJobStatus.failed => DownloadTaskStatus.attention,
      _ => DownloadTaskStatus.cancelled,
    },
    progress: progress,
    collectionKey: job.bookKey,
    collectionTitle: collectionTitle,
    searchTerms: <String>[job.title, job.chapterTitle, collectionTitle],
    // 单跑道持久队列：没有调度优先级、没有暂停态（cancel 后 retry 是同一行
    // 重跑），任务上也没有可 reveal 的落盘路径。
    actions: DownloadTaskActions(
      retry: retryable ? () => downloads.retry(job.jobId) : null,
      clear: finished ? () => downloads.remove(job.jobId) : null,
      cancel: finished ? null : () => downloads.cancel(job.jobId),
    ),
    builder: (BuildContext context) => DownloadTaskCard(
      key: ValueKey<String>(id),
      taskId: id,
      title: job.kind == MangaDownloadJobKind.mokuroVolume
          ? job.title
          : job.chapterTitle,
      status: status,
      subtitle: collectionTitle,
      progress: progress,
      details: _MangaDownloadTaskRow(
        job: job,
        status: status,
        downloads: downloads,
      ),
    ),
  );
}

bool _isFinished(MangaDownloadJobRow job) =>
    job.status == MangaDownloadJobStatus.done ||
    job.status == MangaDownloadJobStatus.failed ||
    job.status == MangaDownloadJobStatus.cancelled;

String _statusLabel(MangaDownloadJobRow job) => switch (job.status) {
      MangaDownloadJobStatus.queued => t.download_status_queued,
      MangaDownloadJobStatus.running => job.pagesTotal > 0
          ? t.manga_ocr_wizard_page_progress(
              done: job.pagesDone,
              total: job.pagesTotal,
            )
          : t.manga_chapter_download_status_downloading(
              done: '${job.pagesDone}',
              total: '${job.pagesTotal}',
            ),
      MangaDownloadJobStatus.done => t.manga_online_downloaded,
      MangaDownloadJobStatus.cancelled => t.download_status_cancelled,
      _ => '${t.manga_online_failed}: ${job.lastError ?? ''}',
    };

/// 卡片展开后的详情行：状态图标 + 标题 + 状态文案 + 行内动作。
class _MangaDownloadTaskRow extends StatelessWidget {
  const _MangaDownloadTaskRow({
    required this.job,
    required this.status,
    required this.downloads,
  });

  final MangaDownloadJobRow job;
  final String status;
  final MangaDownloadService downloads;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final Widget statusIcon = switch (job.status) {
      MangaDownloadJobStatus.queued =>
        Icon(Icons.schedule_outlined, size: 20, color: scheme.outline),
      MangaDownloadJobStatus.done =>
        Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
      MangaDownloadJobStatus.failed =>
        Icon(Icons.error_outline, size: 20, color: scheme.error),
      MangaDownloadJobStatus.cancelled =>
        Icon(Icons.block_outlined, size: 20, color: scheme.outline),
      _ => eink
          ? const Icon(Icons.downloading_outlined, size: 20)
          : SizedBox(
              width: 20,
              height: 20,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: job.pagesTotal > 0
                      ? (job.pagesDone / job.pagesTotal).clamp(0.0, 1.0)
                      : null,
                ),
              ),
            ),
    };
    final bool errorTone = job.status == MangaDownloadJobStatus.failed;
    final bool retryable = job.status == MangaDownloadJobStatus.failed ||
        job.status == MangaDownloadJobStatus.cancelled;
    return FushiListItem(
      density: FushiListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      subtitleMaxLines: 2,
      titleMaxLines: 2,
      leading: statusIcon,
      title: Text(
        job.kind == MangaDownloadJobKind.mokuroVolume
            ? job.title
            : '${job.title} · ${job.chapterTitle}',
      ),
      subtitle: Text(
        status,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: errorTone ? scheme.error : null,
        ),
      ),
      trailing: retryable
          ? FushiIconButton(
              tooltip: t.retry,
              icon: Icons.refresh,
              size: 20,
              onTap: () => unawaited(downloads.retry(job.jobId)),
            )
          : job.status == MangaDownloadJobStatus.done
              ? null
              : FushiIconButton(
                  tooltip: t.dialog_cancel,
                  icon: Icons.close,
                  size: 20,
                  onTap: () => unawaited(downloads.cancel(job.jobId)),
                ),
    );
  }
}
