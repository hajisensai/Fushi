/// 「有没有同步类后台任务在跑」的底层信号：常规同步任务板 + 复习同步 / 旧文件迁移
/// 进度。
///
/// 只依赖这几个数据源本身（不碰同步 UI / AppModel），所以首页「后台任务」入口与
/// 底层组件（悬浮球吉祥物光晕 `mascot_glow.dart`）都能直接听，不必把底层接到同步
/// UI 上。
library;

import 'package:flutter/foundation.dart' show Listenable;
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/sync/sync_task_board.dart';

/// 同步类任务的全部数据源；入口与明细都听它。
final Listenable syncBackgroundTasksListenable = Listenable.merge(<Listenable>[
  syncTasks,
  srsSyncProgress,
  srsMigrationProgress,
]);

/// 有没有同步类任务在跑（外壳只在这一位翻转时重建）。已结束、只因有失败而留在
/// 明细里的那几轮不算。
bool hasActiveSyncTasks() =>
    syncTasks.value.any((SyncTask task) => task.isActive) ||
    srsSyncProgress.value != null ||
    srsMigrationProgress.value != null;
