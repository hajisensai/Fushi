/// 互联下载任务进首页「后台任务」入口（进度环 + 明细弹层）的那一层映射。
///
/// 从已配对设备拉书 / 有声书 / 视频的任务此前只在库页封面上有一个进度遮罩，离开
/// 库页就看不到；独立管理页（`interconnect_download_tasks_page.dart`）要从设置里
/// 一层层点进去。首页外壳的后台任务环本来就汇总同步与补刮，这里把还在跑的互联
/// 下载也接进去：一项任务一段弧，明细行写清走到哪一步（「有声书 45%」）。
library;

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:material_ui/material_ui.dart' show IconData;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/background_task.dart' show BackgroundTask;
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/storage/storage_usage_service.dart'
    show formatStorageBytes;

/// 阶段名（卡片副行 / 弹层明细共用）。
String interconnectDownloadStageLabel(InterconnectDownloadStage stage) =>
    switch (stage) {
      InterconnectDownloadStage.content => t.download_task_status_downloading,
      InterconnectDownloadStage.importing =>
        t.interconnect_download_stage_importing,
      InterconnectDownloadStage.audiobook => t.section_audiobook,
    };

/// 「阶段名 + 百分比」：导入阶段不可测、只写阶段名；其余阶段还没有首个回报时
/// 同样只写阶段名（不显示假的 0%）。[percent] 取 [InterconnectDownloadBadgeState]
/// 的整数口径（-1 = 未知）。
String interconnectDownloadStageStatus(
  InterconnectDownloadStage stage,
  int percent,
) {
  final String label = interconnectDownloadStageLabel(stage);
  if (stage == InterconnectDownloadStage.importing || percent < 0) {
    return label;
  }
  return '$label $percent%';
}

/// 明细第二行：多阶段任务列出走过 / 正在走的阶段（「下载 ✓ · 有声书 45%」），
/// 再接本阶段的字节。单阶段任务只写字节；都没有时为 null。
String? interconnectDownloadDetailLine(InterconnectDownloadTask task) {
  final List<String> parts = <String>[];
  final InterconnectDownloadStage? current = task.stage;
  if (current != null && task.stages.length > 1) {
    final int at = task.stages.indexOf(current);
    for (int i = 0; i < task.stages.length; i++) {
      final InterconnectDownloadStage stage = task.stages[i];
      final String label = interconnectDownloadStageLabel(stage);
      if (i < at) {
        parts.add('$label ✓');
      } else if (i == at) {
        parts.add(
          interconnectDownloadStageStatus(stage, _percentOf(task.progress)),
        );
      } else {
        parts.add(label);
      }
    }
  }
  final int? received = task.receivedBytes;
  if (received != null) {
    final int? total = task.totalBytes;
    parts.add(
      total == null
          ? formatStorageBytes(received)
          : '${formatStorageBytes(received)} / ${formatStorageBytes(total)}',
    );
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

int _percentOf(double? progress) =>
    progress == null ? -1 : (progress * 100).floor();

IconData _iconOf(InterconnectDownloadTask task) {
  if (task.stage == InterconnectDownloadStage.audiobook) {
    return FushiIcons.audiobook;
  }
  return switch (task.kind) {
    InterconnectDownloadKind.book => FushiIcons.books,
    InterconnectDownloadKind.audiobook => FushiIcons.audiobook,
    InterconnectDownloadKind.video => FushiIcons.video,
    InterconnectDownloadKind.music => FushiIcons.music,
  };
}

/// 一条在跑的互联下载 → 后台任务的一项。
BackgroundTask interconnectDownloadToBackgroundTask(
  InterconnectDownloadTask task, {
  VoidCallback? onOpen,
}) {
  final InterconnectDownloadStage? stage = task.stage;
  final int percent = _percentOf(task.progress);
  final String status = stage == null
      ? (percent < 0
            ? t.download_task_status_downloading
            : '${t.download_task_status_downloading} $percent%')
      : interconnectDownloadStageStatus(stage, percent);
  return BackgroundTask(
    id: 'interconnect-download-${task.id}',
    icon: _iconOf(task),
    line: '${task.title} · $status',
    fraction: stage == InterconnectDownloadStage.importing
        ? null
        : task.progress,
    detail: interconnectDownloadDetailLine(task),
    onOpen: onOpen,
    openLabel: onOpen == null ? null : t.interconnect_download_tasks_title,
  );
}

/// 此刻在跑的互联下载（按开始时刻排）。暂停 / 已结束的不进后台任务——暂停是用户
/// 主动停的，失败落在书架卡片副行与互联下载管理页上（那里能重试 / 清记录）。
List<BackgroundTask> interconnectDownloadBackgroundTasks(
  InterconnectDownloadManager manager, {
  VoidCallback? onOpen,
}) {
  final List<InterconnectDownloadTask> running =
      <InterconnectDownloadTask>[
        for (final InterconnectDownloadTask task in manager.tasks.values)
          if (task.isRunning) task,
      ]..sort(
        (InterconnectDownloadTask a, InterconnectDownloadTask b) =>
            (a.startedAt ?? 0).compareTo(b.startedAt ?? 0),
      );
  return <BackgroundTask>[
    for (final InterconnectDownloadTask task in running)
      interconnectDownloadToBackgroundTask(task, onOpen: onOpen),
  ];
}

/// 有没有互联下载在跑（外壳只在这一位翻转时重建）。
bool hasRunningInterconnectDownloads(InterconnectDownloadManager manager) =>
    manager.tasks.values.any((InterconnectDownloadTask task) => task.isRunning);
