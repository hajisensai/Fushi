/// 复习（SRS）同步进度的给人看的那一层：阶段文案 + 进度条数值。
///
/// 数据源是 [srsSyncProgress]（调度器每轮开跑置非 null、跑完置回 null）；同步进度条、
/// 「同步与历史」页状态卡和「立即同步」的忙碌提示共用这里，避免三处各写一份文案。
library;

import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/utils.dart';

/// 一轮复习同步此刻的一行描述，如「同步复习数据 (123/2048)」。
String srsSyncProgressLine(SrsSyncProgress p) {
  switch (p.stage) {
    case SrsSyncStage.preparing:
      return t.srs_sync_progress_preparing;
    case SrsSyncStage.downloading:
      if (p.total <= 0) return t.srs_sync_progress_downloading;
      return t.srs_sync_progress_downloading_count(
        done: p.done.clamp(0, p.total),
        total: p.total,
      );
    case SrsSyncStage.uploading:
      return t.srs_sync_progress_uploading;
    case SrsSyncStage.media:
      return t.srs_sync_progress_media;
    case SrsSyncStage.migrating:
      if (p.total <= 0) return t.srs_sync_progress_migrating;
      return t.srs_sync_progress_migrating_count(
        done: p.done.clamp(0, p.total),
        total: p.total,
      );
  }
}

/// 进度条数值（0..1）：只有「下载 / 迁移且知道总数」时是确定进度，其余阶段为 null（不确定进度条）。
double? srsSyncProgressFraction(SrsSyncProgress p) {
  if (p.stage != SrsSyncStage.downloading &&
      p.stage != SrsSyncStage.migrating) {
    return null;
  }
  if (p.total <= 0) return null;
  return (p.done / p.total).clamp(0.0, 1.0);
}
