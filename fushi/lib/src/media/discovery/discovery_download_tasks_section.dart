import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

/// 「下载」页任务 tab 的发现页直链下载区：渲染 [DiscoveryDownloadQueue] 的任务
/// 列表（游戏 / 小说 / 有声书等 HTTP 直链，与 torrent 任务、漫画目录队列并列，
/// 统一下载中心）。队列为空时不占位。
///
/// BUG-1936：发现页点「下载」后 toast 说「已加入下载」，但这条队列此前在整个
/// app 里只有游戏库的占位卡在读，下载页任务 tab 根本没接——用户看到的就是
/// 「说加入了、哪儿都没有」。队列是这些任务此刻的唯一真相源（内存队列、app
/// 生命周期常驻），这里直接监听它，不另存一份。
///
/// 行内可取消排队/执行中的任务、重试失败/取消的任务；已结束任务经「清除已完成」
/// 批量清掉。范式与 `MokuroMoeTasksSection` 相同。
class DiscoveryDownloadTasksSection extends ConsumerWidget {
  const DiscoveryDownloadTasksSection({super.key, this.queueOverride});

  /// 测试注入队列（null = 取 [AppModel.discoveryDownloadQueue]）。
  final DiscoveryDownloadQueue? queueOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DiscoveryDownloadQueue? queue = queueOverride ?? _appQueue(ref);
    if (queue == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: queue,
      builder: (BuildContext context, Widget? _) {
        final List<DiscoveryDownloadTask> tasks = queue.tasks;
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
    return FushiListItem(
      key: ValueKey<String>(
        'discovery-download-${task.item.sourceId}-${task.item.id}',
      ),
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
      trailing: switch (task.status) {
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
      },
    );
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
