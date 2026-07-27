import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/media/manga/online/mokuro_moe_download_queue.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_progress_labels.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';

/// 「下载」页任务 tab 的漫画目录下载区：渲染 [MokuroMoeDownloadQueue] 的任务
/// 列表（与 torrent 任务并列，统一下载中心）。队列为空时不占位。
///
/// 行内可取消排队/执行中的任务；已结束任务经「清除已完成」批量清掉。任务
/// 数据与「在线目录」对话框内联面板同源（同一队列实例 + 同一进度换算）。
class MokuroMoeTasksSection extends ConsumerWidget {
  const MokuroMoeTasksSection({super.key, this.queueOverride});

  /// 测试注入队列（null = 取 [AppModel.mokuroMoeDownloadQueue]）。
  final MokuroMoeDownloadQueue? queueOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel appModel = ref.read(appProvider);
    // DownloadsPage is also rendered by lightweight widget-test/AppModel seams
    // before the database is opened. Do not make an empty optional task section
    // force-create its database-backed queue during that pre-init window.
    if (queueOverride == null && !appModel.isDatabaseReady) {
      return const SizedBox.shrink();
    }
    final MokuroMoeDownloadQueue queue =
        queueOverride ?? appModel.mokuroMoeDownloadQueue;
    return ListenableBuilder(
      listenable: queue,
      builder: (BuildContext context, Widget? _) {
        final List<MokuroMoeDownloadTask> tasks = queue.tasks;
        if (tasks.isEmpty) return const SizedBox.shrink();
        final ThemeData theme = Theme.of(context);
        final bool hasFinished =
            tasks.any((MokuroMoeDownloadTask t) => t.isFinished);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${t.manga_online_queue_section} '
                      '(${queue.finishedCount}/${queue.totalCount})',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (hasFinished)
                    TextButton(
                      onPressed: queue.clearFinished,
                      child: Text(t.download_clear_finished),
                    ),
                ],
              ),
            ),
            // BUG-1177：任务列表原先死钳 maxHeight 220。它是 Column 里的**非弹性**
            // 兄弟，而同一列里还有别的内容和一个 Expanded 主体；小屏（手机横屏、矮
            // 窗口）上 220 + 头部 + 分隔线就能把 Expanded 压成负高度 → 竖向 RenderFlex
            // overflow。改为在有界高度下取可用高的四成（下限 120，仍不超过原来的
            // 220），无界高度时退回原值。
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
    MokuroMoeDownloadQueue queue,
    MokuroMoeDownloadTask task,
  ) {
    final ColorScheme scheme = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final Widget statusIcon = switch (task.status) {
      MokuroMoeTaskStatus.queued =>
        Icon(Icons.schedule_outlined, size: 20, color: scheme.outline),
      MokuroMoeTaskStatus.done =>
        Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
      MokuroMoeTaskStatus.failed =>
        Icon(Icons.error_outline, size: 20, color: scheme.error),
      MokuroMoeTaskStatus.cancelled =>
        Icon(Icons.block_outlined, size: 20, color: scheme.outline),
      MokuroMoeTaskStatus.running => eink
          ? const Icon(Icons.downloading_outlined, size: 20)
          : SizedBox(
              width: 20,
              height: 20,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: mokuroMoeProgressValue(task.lastEvent),
                ),
              ),
            ),
    };
    final String subtitle = switch (task.status) {
      MokuroMoeTaskStatus.queued => t.download_status_queued,
      MokuroMoeTaskStatus.running => mokuroMoeStageLabel(task.lastEvent),
      MokuroMoeTaskStatus.done => t.manga_online_downloaded,
      MokuroMoeTaskStatus.cancelled => t.download_status_cancelled,
      MokuroMoeTaskStatus.failed =>
        '${t.manga_online_failed}: ${task.error ?? ''}',
    };
    return HibikiListItem(
      density: HibikiListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      subtitleMaxLines: 2,
      // BUG-1177：漫画标题（常带卷号/作者）在窄屏单行只看得到开头几个字；这一行在
      // 可滚动列表里，行高自由。
      titleMaxLines: 2,
      leading: statusIcon,
      title: Text(task.title),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color:
              task.status == MokuroMoeTaskStatus.failed ? scheme.error : null,
        ),
      ),
      trailing: task.isFinished
          ? null
          : HibikiIconButton(
              tooltip: t.dialog_cancel,
              icon: Icons.close,
              size: 20,
              onTap: () => queue.cancel(task),
            ),
    );
  }
}
