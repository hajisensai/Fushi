/// 统一合集「继续看/继续读」推导（Jellyfin Next-Up 语义的极简版）。
///
/// 不给合集加 currentEpisode 类指针列（消灭状态同步问题）——继续位置纯从成员进度
/// 数据推导。规则：取排序位置**最靠后的「有痕迹」成员**（有进度或已完成）；它已完成
/// → 下一个（没有下一个就它自己）；全无痕迹 → 第 0 个。
library;

/// 成员播放痕迹（合集内已排序，index 0 在前）。
class CollectionMemberProgress {
  const CollectionMemberProgress({
    required this.positionMs,
    required this.completed,
  });

  /// 该成员自己的播放进度毫秒（无进度 = 0 或 null）。
  final int? positionMs;

  /// 该成员是否已标记完成。
  final bool completed;

  bool get _hasTrace => completed || (positionMs ?? 0) > 0;
}

/// 返回「继续」应落在哪个成员下标（0-based，越界安全）。
///
/// - 空列表 → 0（调用方自行处理空态）。
/// - 全无痕迹 → 0（从头开始）。
/// - 有痕迹：取最靠后的有痕迹成员；若它已完成且后面还有成员 → 下一个；否则停在它。
int continueMemberIndex(List<CollectionMemberProgress> members) {
  if (members.isEmpty) return 0;
  int last = -1;
  for (int i = 0; i < members.length; i++) {
    if (members[i]._hasTrace) last = i;
  }
  if (last == -1) return 0;
  if (members[last].completed && last + 1 < members.length) return last + 1;
  return last;
}
