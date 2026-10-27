/// 发现源直链下载在**触发它的那一页**上的行内状态（排队 / 下载中 / 完成 / 失败）。
///
/// 动机：Audiobookshelf 条目页的「下载」进的是 [DiscoveryDownloadQueue]，而这条队列
/// 的任务列表只渲染在「浏览」模块的下载页里——iOS 没有浏览模块（下载中心按 App
/// Store 合规不装配），用户点了下载就再也看不到进度。用户自己服务器的下载到本机在
/// iOS 上是保留的（`userConfiguredServersAvailable`，2026-10-27 用户拍板），所以进度
/// 必须就地可见；其它平台同样受益。
///
/// **不另造队列、不另存状态**：直接监听 [DiscoveryDownloadQueue]（这些任务此刻的
/// 唯一真相源），按 `sourceId + id` 取该资源最近一条任务；状态文案与进度换算复用
/// 下载页任务行的同一组纯函数（[discoveryDownloadStatusLabel] /
/// [discoveryDownloadProgress]），两处说法逐字一致。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/discovery/discovery_download_tasks_section.dart'
    show discoveryDownloadProgress, discoveryDownloadStatusLabel;
import 'package:fushi/src/models/app_model.dart' show appProvider;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/engine_listenable.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:material_ui/material_ui.dart';

/// 发现源直链下载队列（[AppModel.discoveryDownloadQueue]，惰性单例、生命周期随
/// AppModel）。只在 widget 里读队列的页面经它取，而不是在 build 里直接读整个
/// [appProvider]：页面的其余依赖都是注入的（如 Audiobookshelf 的 `apiFor`），测试
/// 覆写这一个 provider 即可，不必构造整份 AppModel。
final Provider<DiscoveryDownloadQueue> discoveryDownloadQueueProvider =
    Provider<DiscoveryDownloadQueue>(
      (Ref ref) => ref.read(appProvider).discoveryDownloadQueue,
    );

/// [tasks] 里 `sourceId + id` 对应资源**最近入队**的一条任务（含已结束的）；没有返回
/// null。队列按入队顺序保存任务、重试是就地复活，所以「最后一条」就是当前该看的那条。
DiscoveryDownloadTask? latestDiscoveryDownloadTask(
  Iterable<DiscoveryDownloadTask> tasks, {
  required String sourceId,
  required String id,
}) {
  DiscoveryDownloadTask? latest;
  for (final DiscoveryDownloadTask task in tasks) {
    if (task.item.sourceId == sourceId && task.item.id == id) latest = task;
  }
  return latest;
}

/// 某个资源的行内下载状态；没有任务（或已取消）时渲染 [idleBuilder]（通常是「下载」
/// 按钮，或空）。
class DiscoveryDownloadInlineStatus extends StatelessWidget {
  const DiscoveryDownloadInlineStatus({
    required this.queue,
    required this.sourceId,
    required this.itemId,
    required this.idleBuilder,
    super.key,
  });

  final DiscoveryDownloadQueue queue;
  final String sourceId;
  final String itemId;
  final WidgetBuilder idleBuilder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: EngineListenable(queue),
      builder: (BuildContext context, Widget? _) {
        final DiscoveryDownloadTask? task = latestDiscoveryDownloadTask(
          queue.tasks,
          sourceId: sourceId,
          id: itemId,
        );
        if (task == null || task.status == DiscoveryDownloadStatus.cancelled) {
          return idleBuilder(context);
        }
        return _InlineStatus(queue: queue, task: task);
      },
    );
  }
}

class _InlineStatus extends StatelessWidget {
  const _InlineStatus({required this.queue, required this.task});

  final DiscoveryDownloadQueue queue;
  final DiscoveryDownloadTask task;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String label = discoveryDownloadStatusLabel(
      task,
      queue.maxAutoRetries,
    );
    final bool active = !task.isFinished;
    final bool failed = task.status == DiscoveryDownloadStatus.failed;
    final Widget icon = switch (task.status) {
      DiscoveryDownloadStatus.done => FushiIcon(
        FushiIcons.downloadDone,
        size: 20,
        color: scheme.primary,
      ),
      DiscoveryDownloadStatus.failed => FushiIcon(
        FushiIcons.error,
        size: 20,
        color: scheme.error,
      ),
      DiscoveryDownloadStatus.waitingRetry => FushiIcon(
        FushiIcons.schedule,
        size: 20,
        color: scheme.outline,
      ),
      _ => FushiIcon(FushiIcons.downloading, size: 20, color: scheme.outline),
    };
    return KeyedSubtree(
      key: ValueKey<String>('discovery-inline-status-${task.status.name}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              icon,
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text(
                  label,
                  style: tokens.type.metadata.copyWith(
                    color: failed ? scheme.error : null,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (failed)
                FushiIconButton(
                  key: const ValueKey<String>('discovery-inline-status-retry'),
                  icon: FushiIcons.refresh,
                  tooltip: t.retry,
                  label: t.retry,
                  onTap: () => queue.retry(task),
                ),
            ],
          ),
          if (active) ...<Widget>[
            SizedBox(height: tokens.spacing.gap / 2),
            FushiLinearProgressIndicator(
              value: task.status == DiscoveryDownloadStatus.running
                  ? discoveryDownloadProgress(task)
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}
