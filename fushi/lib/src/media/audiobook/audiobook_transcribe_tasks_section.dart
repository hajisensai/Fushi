import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';
import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/engine_listenable.dart';
import 'package:fushi/utils.dart';

/// 「下载」页任务 tab 的有声书「转录后入库」区：把
/// [AudiobookTranscribeImportQueue] 的任务接进统一任务列表，与 torrent / 直链 /
/// 漫画任务并列（同 `DiscoveryDownloadTasksSection` 的范式：队列是唯一真相源，
/// 这里只监听、不另存）。
///
/// 动作：未结束的可取消（转录进度保留，重试从断点接着跑）；失败 / 已取消的可
/// 重试；已结束的可移出列表（只动清单，不碰书库与文件）。
class AudiobookTranscribeTasksSection extends ConsumerWidget {
  const AudiobookTranscribeTasksSection({
    super.key,
    required this.tasksBuilder,
    this.queueOverride,
  });

  final DownloadTasksBuilder tasksBuilder;

  /// 测试注入队列（null = 取 [AppModel.audiobookTranscribeImportQueue]）。
  final AudiobookTranscribeImportQueue? queueOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AudiobookTranscribeImportQueue? queue =
        queueOverride ?? _appQueue(ref);
    if (queue == null) {
      return tasksBuilder(context, const <DownloadTaskEntry>[]);
    }
    return ListenableBuilder(
      listenable: EngineListenable(queue),
      builder: (BuildContext context, Widget? _) =>
          tasksBuilder(context, <DownloadTaskEntry>[
            for (final AudiobookTranscribeJob job in queue.jobs)
              _buildEntry(queue, job),
          ]),
    );
  }

  DownloadTaskEntry _buildEntry(
    AudiobookTranscribeImportQueue queue,
    AudiobookTranscribeJob job,
  ) {
    final String id = 'audiobook-transcribe:${job.id}';
    final bool retryable =
        job.status == AudiobookTranscribeJobStatus.failed ||
        job.status == AudiobookTranscribeJobStatus.cancelled;
    final double? progress = job.status == AudiobookTranscribeJobStatus.done
        ? 1
        : job.progress;
    final String status = audiobookTranscribeJobStatusLabel(job);
    return DownloadTaskEntry(
      id: id,
      title: job.title,
      createdAt: job.createdAt,
      kind: DownloadTaskKind.audiobook,
      status: switch (job.status) {
        AudiobookTranscribeJobStatus.queued => DownloadTaskStatus.queued,
        AudiobookTranscribeJobStatus.running => DownloadTaskStatus.active,
        AudiobookTranscribeJobStatus.done => DownloadTaskStatus.completed,
        AudiobookTranscribeJobStatus.failed => DownloadTaskStatus.attention,
        AudiobookTranscribeJobStatus.cancelled => DownloadTaskStatus.cancelled,
      },
      progress: progress,
      searchTerms: <String>[job.title],
      // 单跑道队列：没有暂停态、没有调度优先级（同直链队列）。
      actions: DownloadTaskActions(
        cancel: job.isTerminal ? null : () => queue.cancel(job.id),
        retry: retryable ? () => queue.retry(job.id) : null,
        clear: job.isTerminal ? () => queue.remove(job.id) : null,
      ),
      builder: (BuildContext context) => DownloadTaskCard(
        key: ValueKey<String>(id),
        taskId: id,
        title: job.title,
        status: status,
        subtitle: t.audiobook_transcribe_task_subtitle,
        progress: progress,
        details: _buildDetails(context, queue, job, status, retryable),
      ),
    );
  }

  Widget _buildDetails(
    BuildContext context,
    AudiobookTranscribeImportQueue queue,
    AudiobookTranscribeJob job,
    String status,
    bool retryable,
  ) {
    final ThemeData theme = Theme.of(context);
    final bool failed = job.status == AudiobookTranscribeJobStatus.failed;
    final String rowKey = 'audiobook-transcribe-${job.id}';
    return FushiListItem(
      key: ValueKey<String>(rowKey),
      density: FushiListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      titleMaxLines: 2,
      subtitleMaxLines: 3,
      // M3E：行首状态用形状色块（tonal）区分——运行中 primary cookie、完成
      // tertiary、失败 error、排队 / 取消 neutral。
      leading: FushiListLeadingIcon(
        switch (job.status) {
          AudiobookTranscribeJobStatus.queued => FushiIcons.schedule,
          AudiobookTranscribeJobStatus.running => FushiIcons.voice,
          AudiobookTranscribeJobStatus.done => FushiIcons.success,
          AudiobookTranscribeJobStatus.failed => FushiIcons.error,
          AudiobookTranscribeJobStatus.cancelled => FushiIcons.block,
        },
        shape: job.status == AudiobookTranscribeJobStatus.running
            ? FushiLeadingShape.cookie
            : FushiLeadingShape.circle,
        tone: switch (job.status) {
          AudiobookTranscribeJobStatus.queued => FushiCardTone.neutral,
          AudiobookTranscribeJobStatus.running => FushiCardTone.primary,
          AudiobookTranscribeJobStatus.done => FushiCardTone.tertiary,
          AudiobookTranscribeJobStatus.failed => FushiCardTone.error,
          AudiobookTranscribeJobStatus.cancelled => FushiCardTone.neutral,
        },
        size: 36,
        iconSize: 20,
      ),
      title: Text(job.title),
      subtitle: Text(
        status,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: context.fushiType.bodySmall.copyWith(
          color: failed ? theme.colorScheme.error : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (retryable)
            FushiIconButton(
              key: ValueKey<String>('$rowKey-retry'),
              tooltip: t.retry,
              icon: FushiIcons.refresh,
              size: 20,
              onTap: () => queue.retry(job.id),
            ),
          if (!job.isTerminal)
            FushiIconButton(
              key: ValueKey<String>('$rowKey-cancel'),
              tooltip: t.dialog_cancel,
              icon: FushiIcons.close,
              size: 20,
              onTap: () => queue.cancel(job.id),
            ),
          if (job.isTerminal)
            FushiIconButton(
              key: ValueKey<String>('$rowKey-clear'),
              tooltip: t.download_clear_finished,
              icon: FushiIcons.deleteSweep,
              size: 20,
              onTap: () => queue.remove(job.id),
            ),
        ],
      ),
    );
  }

  /// 生产队列。与直链区同一道门：数据库没开（轻量 widget 测试 / 桩）不去拉
  /// 组装点；本机没有 ASR 的平台不建这条队列。
  static AudiobookTranscribeImportQueue? _appQueue(WidgetRef ref) {
    final AppModel appModel = ref.read(appProvider);
    if (!appModel.isDatabaseReady || !isAsrSupported) return null;
    return appModel.audiobookTranscribeImportQueue;
  }
}

/// 任务行的状态一句话（纯函数，供测试直接断言）。运行中带当前步骤与百分比；
/// 完成时区分「已入库」与「同名书已在库被跳过」；失败带错误原文。
String audiobookTranscribeJobStatusLabel(AudiobookTranscribeJob job) {
  switch (job.status) {
    case AudiobookTranscribeJobStatus.queued:
      return t.download_status_queued;
    case AudiobookTranscribeJobStatus.running:
      final String step = switch (job.phase) {
        null || AudiobookTranscribeJobPhase.preparing =>
          t.audiobook_transcribe_status_preparing,
        AudiobookTranscribeJobPhase.downloadingModel =>
          t.audiobook_transcribe_status_downloading_model,
        AudiobookTranscribeJobPhase.transcribing =>
          t.audiobook_transcribe_status_transcribing,
        AudiobookTranscribeJobPhase.importing =>
          t.audiobook_transcribe_status_importing,
      };
      final double? progress = job.progress;
      return progress == null
          ? step
          : '$step · ${(progress.clamp(0.0, 1.0) * 100).round()}%';
    case AudiobookTranscribeJobStatus.done:
      return job.resultKey == null
          ? t.audiobook_transcribe_status_skipped
          : t.audiobook_transcribe_status_done;
    case AudiobookTranscribeJobStatus.failed:
      return '${t.manga_online_failed}: ${job.error ?? ''}';
    case AudiobookTranscribeJobStatus.cancelled:
      return t.download_status_cancelled;
  }
}
