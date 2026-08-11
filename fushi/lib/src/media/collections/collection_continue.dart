/// 统一合集「继续看/继续读」推导（Jellyfin Next-Up 语义的极简版）。
///
/// 不给合集加 currentEpisode 类指针列（消灭状态同步问题）——继续位置纯从成员进度
/// 数据推导。锚点规则（BUG-1542）：取**最近一次播放**的成员（`lastPlayedAt` 最大）；
/// 它已完成 → 下一个（没有下一个就它自己）；否则停在它。
///
/// 为什么锚点是时刻而不是位置：`lastPlayedAt` 落库前（schema v85）这里只有「有没有
/// 进度」的静态事实，只能退而取**排序位置最靠后**的有痕迹成员。那等价于假设「用户
/// 永远按集号单调前进」——用户回头看 PV 或补看早期某集后，锚点仍被 234 集里位置最
/// 靠后的那个残留痕迹钉死（用户实报：刚退出 PV 第 1 集，头部却显示「继续看 第233
/// 集」）。时刻是「用户刚才在看哪一集」的直接事实，位置只是它的一个巧合代理。
///
/// 旧库无时刻数据时（迁移回填不到 `lastPlayedAt` 的成员）自动退回位置口径，行为与
/// v85 前逐字节一致。
library;

/// 成员播放痕迹（合集内已排序，index 0 在前）。
class CollectionMemberProgress {
  const CollectionMemberProgress({
    required this.positionMs,
    required this.completed,
    this.lastPlayedAt,
  });

  /// 该成员自己的播放进度毫秒（无进度 = 0 或 null）。
  final int? positionMs;

  /// 该成员是否已标记完成。
  final bool completed;

  /// 该成员最近一次播放的毫秒时刻（`VideoBooks.lastPlayedAt`）。
  /// null / <=0 = 无时刻（v85 前的旧行，或从未播放）。
  final int? lastPlayedAt;

  /// 时刻本身就是痕迹：播过就一定有时刻，哪怕位置被拖回 0 且未标完成。
  bool get _hasTrace => completed || (positionMs ?? 0) > 0 || _playedAt > 0;

  int get _playedAt {
    final int? at = lastPlayedAt;
    return at != null && at > 0 ? at : 0;
  }
}

/// 返回「继续」应落在哪个成员下标（0-based，越界安全）。
///
/// - 空列表 → 0（调用方自行处理空态）。
/// - 全无痕迹 → 0（从头开始）。
/// - 有时刻：锚点 = `lastPlayedAt` 最大的成员（并列取位置靠后者，贴连播方向）。
/// - 无任何时刻（旧库）：锚点 = 位置最靠后的有痕迹成员（v85 前口径）。
/// - 锚点已完成且后面还有成员 → 下一个；否则停在锚点。
int continueMemberIndex(List<CollectionMemberProgress> members) {
  if (members.isEmpty) return 0;
  int anchor = _mostRecentlyPlayedIndex(members);
  if (anchor < 0) anchor = _lastTracedIndex(members);
  if (anchor < 0) return 0;
  if (members[anchor].completed && anchor + 1 < members.length) {
    return anchor + 1;
  }
  return anchor;
}

/// `lastPlayedAt` 最大的成员下标；全员无时刻 → -1。并列取靠后者。
int _mostRecentlyPlayedIndex(List<CollectionMemberProgress> members) {
  int best = -1;
  int bestAt = 0;
  for (int i = 0; i < members.length; i++) {
    final int at = members[i]._playedAt;
    if (at > 0 && at >= bestAt) {
      best = i;
      bestAt = at;
    }
  }
  return best;
}

/// 位置最靠后的有痕迹成员下标；全无痕迹 → -1。
int _lastTracedIndex(List<CollectionMemberProgress> members) {
  int last = -1;
  for (int i = 0; i < members.length; i++) {
    if (members[i]._hasTrace) last = i;
  }
  return last;
}
