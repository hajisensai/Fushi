import 'package:hibiki/src/sync/ttu_models.dart';

/// 三方判定结果：要么给出自动同步方向，要么标记为冲突（需用户裁决）。
class ProgressResolution {
  const ProgressResolution._(this.direction, this.isConflict);
  factory ProgressResolution.synced() =>
      const ProgressResolution._(SyncDirection.synced, false);
  factory ProgressResolution.auto(SyncDirection d) =>
      ProgressResolution._(d, false);
  factory ProgressResolution.conflict() =>
      const ProgressResolution._(SyncDirection.synced, true);

  final SyncDirection direction; // isConflict 时无意义
  final bool isConflict;

  @override
  bool operator ==(Object other) =>
      other is ProgressResolution &&
      other.direction == direction &&
      other.isConflict == isConflict;
  @override
  int get hashCode => Object.hash(direction, isConflict);
}

/// 基于「共同祖先 base」的三方分叉检测（纯函数，全部输入为毫秒时间戳）。
/// - 单边存在 / 单边偏离 base → 自动方向（与历史 last-write-wins 在这些场景一致）。
/// - 双边都偏离 base 且彼此不等，或无 base 而双边不等 → 冲突。
ProgressResolution resolveProgressSync({
  required int? local,
  required int? remote,
  required int? base,
}) {
  if (local == null && remote == null) return ProgressResolution.synced();
  if (local == null) return ProgressResolution.auto(SyncDirection.importFromTtu);
  if (remote == null) return ProgressResolution.auto(SyncDirection.exportToTtu);
  if (local == remote) return ProgressResolution.synced();
  // 此处 local != remote。
  if (base != null && local == base) {
    return ProgressResolution.auto(SyncDirection.importFromTtu); // 仅远端动
  }
  if (base != null && remote == base) {
    return ProgressResolution.auto(SyncDirection.exportToTtu); // 仅本地动
  }
  // base==null 双边不等，或双边都偏离 base → 真分叉。
  return ProgressResolution.conflict();
}
