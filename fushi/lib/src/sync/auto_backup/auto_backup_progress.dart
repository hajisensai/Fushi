/// 自动备份在跑时的进度信号（首页「后台任务」入口读它，见 `sync_background_activity.dart`）。
///
/// 只依赖 Flutter 基础库：后台任务入口与底层光晕组件都能听，不必 import 自动备份的编排。
library;

import 'package:flutter/foundation.dart' show ValueNotifier, immutable;

/// 一次自动备份的进度。
@immutable
class AutoBackupProgress {
  const AutoBackupProgress({this.fraction});

  /// 0..1；null = 还在准备（VACUUM INTO、裁剪类别），没有可分的量。
  final double? fraction;

  @override
  bool operator ==(Object other) =>
      other is AutoBackupProgress && other.fraction == fraction;

  @override
  int get hashCode => fraction.hashCode;
}

/// 非 null = 有一次自动备份在跑。
final ValueNotifier<AutoBackupProgress?> autoBackupProgress =
    ValueNotifier<AutoBackupProgress?>(null);
