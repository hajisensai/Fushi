/// 下载中心「任务」tab 里的**互联下载**段：从已配对设备拉到本机的视频 / 书 /
/// 有声书（[InterconnectDownloadManager]）。
///
/// 与 `RemoteDownloadTasksSection`（让 host 代为下载的任务）方向相反：那里的
/// 任务跑在对端，这里的跑在本机。此前这类任务只在库页封面角上有一个进度环，
/// 离开库页就看不到、也没有字节数（BUG-2714）。与其它段同一链式注入形状，
/// 没有任务时是空段。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/utils.dart';

class InterconnectDownloadTasksSection extends ConsumerWidget {
  const InterconnectDownloadTasksSection({
    required this.tasksBuilder,
    super.key,
  });

  final DownloadTasksBuilder tasksBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final InterconnectDownloadManager manager =
        ref.watch(interconnectDownloadManagerProvider);
    final List<DownloadTaskEntry> entries = <DownloadTaskEntry>[
      for (final InterconnectDownloadTask task in manager.tasks.values)
        interconnectDownloadTaskEntry(manager, task),
    ];
    return tasksBuilder(context, entries);
  }
}

/// 一条互联下载任务 → 下载中心条目（纯映射，供测试直接断言）。
DownloadTaskEntry interconnectDownloadTaskEntry(
  InterconnectDownloadManager manager,
  InterconnectDownloadTask task,
) {
  final String entryId = 'interconnect:${task.id}';
  final bool restartable = manager.canRestart(task.id);
  final bool unfinished = task.status == InterconnectDownloadStatus.paused ||
      task.status == InterconnectDownloadStatus.failed;
  return DownloadTaskEntry(
    id: entryId,
    title: task.title,
    kind: switch (task.kind) {
      InterconnectDownloadKind.video => DownloadTaskKind.video,
      InterconnectDownloadKind.book => DownloadTaskKind.novel,
      InterconnectDownloadKind.audiobook => DownloadTaskKind.audiobook,
    },
    status: switch (task.status) {
      InterconnectDownloadStatus.running => DownloadTaskStatus.active,
      InterconnectDownloadStatus.paused => DownloadTaskStatus.paused,
      InterconnectDownloadStatus.completed => DownloadTaskStatus.completed,
      InterconnectDownloadStatus.failed => DownloadTaskStatus.attention,
    },
    createdAt: task.startedAt,
    progress: task.progress,
    collectionKey: 'interconnect',
    collectionTitle: t.download_interconnect_section_title,
    searchTerms: <String>[task.title],
    actions: DownloadTaskActions(
      pause:
          manager.canPause(task.id) ? () async => manager.pause(task.id) : null,
      resume: restartable && task.status == InterconnectDownloadStatus.paused
          ? () => manager.resume(task.id)
          : null,
      retry: restartable && task.status == InterconnectDownloadStatus.failed
          ? () => manager.resume(task.id)
          : null,
      clear: task.status == InterconnectDownloadStatus.completed
          ? () async => manager.clearTask(task.id)
          : null,
      // 未完成任务的「删除」= 放弃续传：勾了删文件就连 `.part` 一起删，不勾只移出
      // 列表（`.part` 留着，下次点下载照样从断点接上）。
      delete: unfinished
          ? ({required bool deleteFiles}) async {
              if (deleteFiles) {
                await manager.discard(task.id);
              } else {
                manager.clearTask(task.id);
              }
            }
          : null,
      deletesFiles: unfinished && restartable,
    ),
    builder: (BuildContext context) => DownloadTaskCard(
      key: ValueKey<String>(entryId),
      taskId: entryId,
      title: task.title,
      status: interconnectDownloadStatusLabel(task),
      subtitle: t.download_interconnect_section_title,
      progress: task.status == InterconnectDownloadStatus.completed
          ? 1
          : task.progress,
      leading: Icon(switch (task.kind) {
        InterconnectDownloadKind.video => Icons.devices_outlined,
        InterconnectDownloadKind.book => Icons.menu_book_outlined,
        InterconnectDownloadKind.audiobook => Icons.headphones_outlined,
      }),
      details: _InterconnectTaskDetails(task: task),
    ),
  );
}

/// 任务行的状态一句话（纯函数）：下载中 / 暂停给「已收 / 总 (百分比)」，只知道
/// 已收就只给已收，连字节都没有（书的传输原语只报比例）就给百分比。
String interconnectDownloadStatusLabel(InterconnectDownloadTask task) {
  final String head = switch (task.status) {
    InterconnectDownloadStatus.running => t.download_task_status_downloading,
    InterconnectDownloadStatus.paused => t.download_task_status_paused,
    InterconnectDownloadStatus.completed => t.download_task_status_completed,
    InterconnectDownloadStatus.failed => t.download_task_status_error,
  };
  if (task.status == InterconnectDownloadStatus.completed) return head;
  final int? received = task.receivedBytes;
  final int? total = task.totalBytes;
  final String? amount;
  if (received != null && total != null && total > 0) {
    final int percent = ((received / total).clamp(0.0, 1.0) * 100).floor();
    amount = '${formatDiscoveryBytes(received)} / '
        '${formatDiscoveryBytes(total)} ($percent%)';
  } else if (received != null) {
    amount = formatDiscoveryBytes(received);
  } else if (task.progress != null) {
    amount = '${(task.progress! * 100).floor()}%';
  } else {
    amount = null;
  }
  return amount == null ? head : '$head · $amount';
}

class _InterconnectTaskDetails extends StatelessWidget {
  const _InterconnectTaskDetails({required this.task});

  final InterconnectDownloadTask task;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? error = task.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(interconnectDownloadStatusLabel(task), style: text.bodySmall),
        if (task.status == InterconnectDownloadStatus.failed && error != null)
          Text(
            error,
            style: text.bodySmall?.copyWith(color: scheme.error),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}
