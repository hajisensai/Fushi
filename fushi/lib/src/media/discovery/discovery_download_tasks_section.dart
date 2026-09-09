import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart'
    show showDownloadTaskDeleteConfirm;
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/misc/engine_listenable.dart';

/// 「下载」页任务 tab 的发现页直链下载区：渲染 [DiscoveryDownloadQueue] 的任务
/// 列表（游戏 / 小说 / 有声书等 HTTP 直链，与 torrent 任务、漫画目录队列并列，
/// 统一下载中心）。独立使用时空队列不占位；[tasksBuilder] 将任务接入统一列表。
///
/// BUG-1936：发现页点「下载」后 toast 说「已加入下载」，但这条队列此前在整个
/// app 里只有游戏库的占位卡在读，下载页任务 tab 根本没接——用户看到的就是
/// 「说加入了、哪儿都没有」。队列是这些任务此刻的唯一真相源（内存队列、app
/// 生命周期常驻），这里直接监听它，不另存一份。
///
/// 行内可取消排队/执行中的任务、重试失败/取消的任务；已结束任务经「清除已完成」
/// 批量清掉。范式与 `MokuroMoeTasksSection` 相同。
class DiscoveryDownloadTasksSection extends ConsumerWidget {
  const DiscoveryDownloadTasksSection({
    super.key,
    this.queueOverride,
    this.tasksBuilder,
    this.pathRevealer,
    this.revealHostProbe,
  });

  /// Parent owns unified filtering, sorting and grouping, including empty queues.
  final DownloadTasksBuilder? tasksBuilder;

  /// 测试注入队列（null = 取 [AppModel.discoveryDownloadQueue]）。
  final DiscoveryDownloadQueue? queueOverride;

  /// 测试注入文件管理器调用（null = [revealInFileManager]）。
  final Future<bool> Function(String path)? pathRevealer;

  /// 测试注入平台探针（null = [currentRevealHost]）。移动端返回 null → 整条
  /// 「打开文件位置」入口隐藏，不画点了没反应的按钮。
  final RevealHost? Function()? revealHostProbe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DiscoveryDownloadQueue? queue = queueOverride ?? _appQueue(ref);
    if (queue == null) {
      return tasksBuilder?.call(context, const <DownloadTaskEntry>[]) ??
          const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: EngineListenable(queue),
      builder: (BuildContext context, Widget? _) {
        final List<DiscoveryDownloadTask> tasks = queue.tasks;
        if (tasksBuilder != null) {
          return tasksBuilder!(context, <DownloadTaskEntry>[
            for (final DiscoveryDownloadTask task in tasks)
              _buildEntry(queue, task),
          ]);
        }
        if (tasks.isEmpty) return const SizedBox.shrink();
        final ThemeData theme = Theme.of(context);
        final bool hasFinished = tasks.any(
          (DiscoveryDownloadTask t) => t.isFinished,
        );
        final bool hasRetryable = tasks.any(
          (DiscoveryDownloadTask t) => _canRetry(t),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${t.download_direct_queue_section} '
                      '(${queue.finishedCount}/${queue.totalCount})',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (hasRetryable)
                    TextButton(
                      key: const ValueKey<String>(
                        'discovery-download-retry-all',
                      ),
                      onPressed: queue.retryAllFailed,
                      child: Text(t.retry),
                    ),
                  if (hasFinished)
                    TextButton(
                      key: const ValueKey<String>(
                        'discovery-download-clear-finished',
                      ),
                      onPressed: queue.clearFinished,
                      child: Text(t.download_clear_finished),
                    ),
                ],
              ),
            ),
            // 高度策略同漫画目录区（BUG-1184）：有界高度下取可用高的四成
            // （120..220），无界时退回 220，免得把同列的 Expanded 主体压成负高。
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double maxHeight = constraints.maxHeight.isFinite
                    ? (constraints.maxHeight * 0.4).clamp(120.0, 220.0)
                    : 220.0;
                return ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: tasks.length,
                    itemBuilder: (BuildContext context, int index) =>
                        _buildTaskRow(context, theme, queue, tasks[index]),
                  ),
                );
              },
            ),
            const Divider(height: 1),
          ],
        );
      },
    );
  }

  DownloadTaskEntry _buildEntry(
    DiscoveryDownloadQueue queue,
    DiscoveryDownloadTask task,
  ) {
    final String id = 'direct:${task.taskId}';
    final double? progress = task.status == DiscoveryDownloadStatus.done
        ? 1
        : discoveryDownloadProgress(task);
    return DownloadTaskEntry(
      id: id,
      title: task.item.title,
      createdAt: task.createdAt,
      // 直链队列同样是单跑道内存队列：无调度优先级、无暂停态（续传靠 retry 走
      // ResumableDownloader 的 Range）。删除只能移出列表——文件删除被显式关掉
      // （见本文件 offerDeleteFiles: false 处的说明），故只填 clear 不填 delete。
      actions: DownloadTaskActions(
        retry: _canRetry(task) ? () async => queue.retry(task) : null,
        clear: task.isFinished ? () async => queue.remove(task) : null,
        cancel: task.isFinished ? null : () async => queue.cancel(task),
      ),
      kind: switch (task.item.kind) {
        DiscoveryMediaKind.novel => DownloadTaskKind.novel,
        DiscoveryMediaKind.audiobook => DownloadTaskKind.audiobook,
        DiscoveryMediaKind.game => DownloadTaskKind.game,
        DiscoveryMediaKind.manga => DownloadTaskKind.manga,
      },
      status: switch (task.status) {
        DiscoveryDownloadStatus.queued => DownloadTaskStatus.queued,
        DiscoveryDownloadStatus.running => DownloadTaskStatus.active,
        DiscoveryDownloadStatus.waitingRetry => DownloadTaskStatus.queued,
        DiscoveryDownloadStatus.done => DownloadTaskStatus.completed,
        DiscoveryDownloadStatus.failed => DownloadTaskStatus.attention,
        DiscoveryDownloadStatus.cancelled => DownloadTaskStatus.cancelled,
      },
      progress: progress,
      // No collection identity in direct resources: never infer it from titles.
      searchTerms: <String>[task.item.sourceId],
      builder: (BuildContext context) => DownloadTaskCard(
        key: ValueKey<String>(id),
        taskId: id,
        title: task.item.title,
        status: discoveryDownloadStatusLabel(task, queue.maxAutoRetries),
        subtitle: discoveryMediaKindLabel(task.item.kind),
        progress: progress,
        details: _buildTaskRow(context, Theme.of(context), queue, task),
      ),
    );
  }

  Widget _buildTaskRow(
    BuildContext context,
    ThemeData theme,
    DiscoveryDownloadQueue queue,
    DiscoveryDownloadTask task,
  ) {
    final ColorScheme scheme = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final Widget statusIcon = switch (task.status) {
      DiscoveryDownloadStatus.queued => Icon(
        Icons.schedule_outlined,
        size: 20,
        color: scheme.outline,
      ),
      DiscoveryDownloadStatus.done => Icon(
        Icons.check_circle_outline,
        size: 20,
        color: scheme.primary,
      ),
      DiscoveryDownloadStatus.failed => Icon(
        Icons.error_outline,
        size: 20,
        color: scheme.error,
      ),
      DiscoveryDownloadStatus.waitingRetry => Icon(
        Icons.autorenew,
        size: 20,
        color: scheme.error,
      ),
      DiscoveryDownloadStatus.cancelled => Icon(
        Icons.block_outlined,
        size: 20,
        color: scheme.outline,
      ),
      DiscoveryDownloadStatus.running =>
        eink
            ? const Icon(Icons.downloading_outlined, size: 20)
            : SizedBox(
                width: 20,
                height: 20,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: discoveryDownloadProgress(task),
                  ),
                ),
              ),
    };
    final String subtitle =
        '${discoveryMediaKindLabel(task.item.kind)} · '
        '${discoveryDownloadStatusLabel(task, queue.maxAutoRetries)}';
    final bool errorTone =
        task.status == DiscoveryDownloadStatus.failed ||
        task.status == DiscoveryDownloadStatus.waitingRetry;
    final String rowKey =
        'discovery-download-${task.item.sourceId}-${task.item.id}';
    // 状态相关的那一个动作（重试 / 取消）；done 没有。
    final Widget? statusAction = switch (task.status) {
      DiscoveryDownloadStatus.failed ||
      DiscoveryDownloadStatus.cancelled => FushiIconButton(
        tooltip: t.retry,
        icon: Icons.refresh,
        size: 20,
        onTap: () => queue.retry(task),
      ),
      DiscoveryDownloadStatus.done => null,
      DiscoveryDownloadStatus.queued ||
      DiscoveryDownloadStatus.running ||
      DiscoveryDownloadStatus.waitingRetry => FushiIconButton(
        tooltip: t.dialog_cancel,
        icon: Icons.close,
        size: 20,
        onTap: () => queue.cancel(task),
      ),
    };
    final String? path = discoveryDownloadRevealTarget(task);
    final String? revealTarget =
        (revealHostProbe ?? currentRevealHost)() == null ? null : path;
    return FushiListItem(
      key: ValueKey<String>(rowKey),
      density: FushiListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      subtitleMaxLines: 2,
      titleMaxLines: 2,
      leading: statusIcon,
      title: Text(task.item.title),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: errorTone ? scheme.error : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (revealTarget != null)
            FushiIconButton(
              key: ValueKey<String>('$rowKey-location'),
              tooltip: t.download_task_open_location,
              icon: Icons.folder_open_outlined,
              size: 20,
              onTap: () => _openLocation(context, revealTarget),
            ),
          if (statusAction != null) statusAction,
          FushiIconButton(
            key: ValueKey<String>('$rowKey-delete'),
            tooltip: t.download_task_delete,
            icon: Icons.delete_outline,
            size: 20,
            enabledColor: scheme.error,
            onTap: () => _confirmDelete(context, queue, task),
          ),
        ],
      ),
    );
  }

  /// 在系统文件管理器里定位这条任务的落盘物。
  ///
  /// 失败（路径已不在 / 启动失败）必须出声——与视频下载任务面板同一口径，
  /// 不能让按钮点了什么都不发生。
  Future<void> _openLocation(BuildContext context, String path) async {
    final bool revealed = await (pathRevealer ?? revealInFileManager)(path);
    if (revealed || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.download_task_location_open_failed)),
    );
  }

  /// 行内「删除任务」：确认后把这行从队列摘掉（文件不动）。
  ///
  /// 复用下载中心的删除确认框以保持两处口径一致，但 `offerDeleteFiles: false`
  /// ——直链任务完成后文件已经入库，一个列表操作不该连库里的文件一起删；
  /// 未完成任务删掉的只是任务，`.part` 留着下次续传。
  Future<void> _confirmDelete(
    BuildContext context,
    DiscoveryDownloadQueue queue,
    DiscoveryDownloadTask task,
  ) async {
    final bool? confirmed = await showDownloadTaskDeleteConfirm(
      context,
      title: task.item.title,
      keySuffix: 'discovery-${task.item.sourceId}-${task.item.id}',
      offerDeleteFiles: false,
    );
    if (confirmed == null) return;
    queue.remove(task);
  }

  /// 生产队列。与漫画目录区同一道门：DownloadsPage 会在数据库打开前被轻量
  /// widget 测试 / AppModel 桩渲染，空的可选任务区不该在这个窗口里去拉组装点。
  static DiscoveryDownloadQueue? _appQueue(WidgetRef ref) {
    final AppModel appModel = ref.read(appProvider);
    return appModel.isDatabaseReady ? appModel.discoveryDownloadQueue : null;
  }

  /// 手动重试可用的任务（与 [DiscoveryDownloadQueue.retry] 的受理条件同口径）。
  static bool _canRetry(DiscoveryDownloadTask task) =>
      task.status == DiscoveryDownloadStatus.failed ||
      task.status == DiscoveryDownloadStatus.cancelled;
}

/// 「打开文件位置」的目标路径（纯函数，供测试直接断言）。
///
/// 已下完的取落盘文件本身（文件管理器会选中它），否则退回目标目录；两者都没有
/// （目录未定 / 测试桩）返回 null —— 调用方据此整条隐藏按钮，不画点了没反应的入口。
String? discoveryDownloadRevealTarget(DiscoveryDownloadTask task) {
  final String file = task.filePath?.trim() ?? '';
  if (file.isNotEmpty) return file;
  final String dir = task.destinationDir.trim();
  return dir.isEmpty ? null : dir;
}

/// 任务进度 0..1；总大小未知（服务端没给 Content-Length）返回 null → 不定进度。
double? discoveryDownloadProgress(DiscoveryDownloadTask task) {
  final int? total = task.totalBytes;
  if (total == null || total <= 0) return null;
  return (task.receivedBytes / total).clamp(0.0, 1.0);
}

/// 任务行的状态一句话（纯函数，供测试直接断言）。
///
/// 下载中：有总大小给「已收/总 (百分比)」，没有只给已收字节；完成：入库摘要
/// 优先（用户点名的是「入库了什么」，不是「下完了」）；失败/退避：带错误原文。
String discoveryDownloadStatusLabel(
  DiscoveryDownloadTask task,
  int maxAutoRetries,
) {
  switch (task.status) {
    case DiscoveryDownloadStatus.queued:
      return t.download_status_queued;
    case DiscoveryDownloadStatus.running:
      final int? total = task.totalBytes;
      final String received = formatDiscoveryBytes(task.receivedBytes);
      if (total == null || total <= 0) {
        return '${t.download_task_status_downloading} · $received';
      }
      final int percent = ((task.receivedBytes / total).clamp(0.0, 1.0) * 100)
          .round();
      return '${t.download_task_status_downloading} · '
          '$received / ${formatDiscoveryBytes(total)} ($percent%)';
    case DiscoveryDownloadStatus.done:
      final String? summary = task.importOutcome?.summary?.trim();
      return summary == null || summary.isEmpty
          ? t.download_task_status_completed
          : '${t.download_task_status_completed} · $summary';
    case DiscoveryDownloadStatus.cancelled:
      return t.download_status_cancelled;
    case DiscoveryDownloadStatus.failed:
      return '${t.manga_online_failed}: ${task.error ?? ''}';
    case DiscoveryDownloadStatus.waitingRetry:
      return '${t.manga_online_retry_waiting(attempt: task.autoRetries, total: maxAutoRetries)}: ${task.error ?? ''}';
  }
}
