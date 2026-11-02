/// 复习（SRS）同步 v2 一轮的进度，全局可听（同步进度条 / 牌组列表 / 同步与历史页消费）。
///
/// 由 [SrsSyncScheduler] 在每一轮开跑时置为非 null、跑完（成功或失败）置回 null；它与常规同步的
/// `syncInProgress` / `syncProgress` 分开：复习同步除了常规同步的通道后置步骤，还会被「立即同步」、
/// 进复习 tab、本机 host 目录写入单独触发，那时常规同步并没有在跑。
library;

import 'package:flutter/foundation.dart';

/// 一轮复习同步此刻走到哪。
@immutable
class SrsSyncProgress {
  const SrsSyncProgress({
    this.stage = SrsSyncStage.preparing,
    this.done = 0,
    this.total = 0,
  });

  final SrsSyncStage stage;

  /// [SrsSyncStage.downloading]：已下载（并已收进本机）的段数；[SrsSyncStage.migrating]：已处理的旧文件数；其它
  /// 阶段为 0。
  final int done;

  /// [SrsSyncStage.downloading]：这一轮要下载的段总数；[SrsSyncStage.migrating]：旧根上要搬的文件数；未知为 0。
  final int total;

  @override
  bool operator ==(Object other) =>
      other is SrsSyncProgress &&
      other.stage == stage &&
      other.done == done &&
      other.total == total;

  @override
  int get hashCode => Object.hash(stage, done, total);
}

/// 一轮里的阶段。
enum SrsSyncStage {
  /// 读位置上的设备 head、定要拉哪些段。
  preparing,

  /// 下载并收进本机（[SrsSyncProgress.done] / [SrsSyncProgress.total]）。
  downloading,

  /// 上传本机的改动。
  uploading,

  /// 补齐卡片引用的媒体文件。
  media,

  /// 把旧版本（同步协议 1）留在位置上的媒体搬进新格式（[srsMigrationProgress]，后台跑、不挡同步一轮）。
  migrating,
}

/// 当前在跑的那一轮复习同步；没在跑为 null。
final ValueNotifier<SrsSyncProgress?> srsSyncProgress =
    ValueNotifier<SrsSyncProgress?>(null);

/// 旧根媒体的后台迁移（阶段恒为 [SrsSyncStage.migrating]）；没在迁移为 null。与 [srsSyncProgress] 分开：迁移不在
/// 同步一轮里跑，两者可能同时在走。
final ValueNotifier<SrsSyncProgress?> srsMigrationProgress =
    ValueNotifier<SrsSyncProgress?>(null);
