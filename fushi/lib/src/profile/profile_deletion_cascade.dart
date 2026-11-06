/// 删 Profile 时随行清理的、不在主库 `profiles` 外键级联里的数据（反馈 8TaOy2i-lL 现象 3）。
///
/// 主库里挂在 profile 上的表靠外键 `ON DELETE CASCADE` 跟着删；复习（SRS）数据在另一个文件 `srs.db`、按
/// `profiles.uid` 归属，外键管不到——以前删 Profile 只删 `profiles` 行，卡、复习记录、媒体目录全部留成无主副本。
/// [ProfileViewModel.deleteProfile] 经这个接口：删之前先统计（确认框）、先备份（失败即中止删除），删掉
/// `profiles` 行之后再清。实现见 `srs/srs_profile_cleanup.dart`。
library;

import 'package:fushi_core/fushi_core.dart' show ProfileRow;

/// 删掉一个 Profile 会连带删掉的复习数据规模（确认框里写明）。
class ProfileDeletionImpact {
  const ProfileDeletionImpact({
    required this.srsNotes,
    required this.srsCards,
    required this.srsReviews,
    required this.hasSrsData,
  });

  const ProfileDeletionImpact.none()
    : srsNotes = 0,
      srsCards = 0,
      srsReviews = 0,
      hasSrsData = false;

  final int srsNotes;
  final int srsCards;
  final int srsReviews;

  /// srs.db 里有这个 Profile 的任何行，或它有复习媒体目录。
  final bool hasSrsData;
}

/// 已备份、等 `profiles` 行删掉后执行的清理。
abstract interface class ProfileDeletionCleanup {
  /// 删除前自动做的复习数据备份文件（撤销途径）；没有要备份的数据时为 null。
  String? get backupPath;

  /// 删除时的规模（与确认框同口径）。
  ProfileDeletionImpact get impact;

  /// 删掉本机的复习数据（srs.db 行 + 媒体 / 样式目录）。只动本机，远端已同步的集合不碰。
  Future<void> run();
}

/// 删除前备份失败：删除已中止，Profile 原样保留。
class ProfileDeletionBackupException implements Exception {
  const ProfileDeletionBackupException(this.cause);

  final Object cause;

  @override
  String toString() => 'ProfileDeletionBackupException: $cause';
}

/// 删 Profile 的级联清理。
abstract interface class ProfileDeletionCascade {
  /// [profile] 被删时会连带删掉的数据规模。
  Future<ProfileDeletionImpact> impactOf(ProfileRow profile);

  /// 备份 [profile] 的复习数据并返回之后要执行的清理。备份失败抛 [ProfileDeletionBackupException]
  /// （调用方据此中止删除）。
  Future<ProfileDeletionCleanup> prepare(ProfileRow profile);

  /// 一次性存量扫描：清掉 srs.db 里不属于 [live] 中任何 Profile 的数据（同样先备份）。已扫过就什么都不做。
  /// 返回清掉的无主 uid 数。
  Future<int> sweepOrphans(List<ProfileRow> live);
}

/// 一次删除的结果（UI 提示 / 控制通道回报）。
class ProfileDeletionOutcome {
  const ProfileDeletionOutcome({required this.impact, this.backupPath});

  final ProfileDeletionImpact impact;
  final String? backupPath;
}
