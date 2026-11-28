/// 统一合集「继续看/继续读」推导（Jellyfin Next-Up 语义的极简版）。
///
/// 不给合集加 currentEpisode 类指针列（消灭状态同步问题）——继续位置纯从成员进度
/// 数据推导。锚点规则（BUG-1542）：取**最近一次播放**的成员（`lastPlayedAt` 最大）；
/// 它已完成 → 它之后第一个还没看完的成员（BUG-5613；之后全看完就最后一个）；否则
/// 停在它。
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

import 'package:fushi/src/media/video/video_episode_start_policy.dart'
    show isEpisodePositionNearEnd;
import 'package:fushi_core/fushi_core.dart' show VideoBookRow;

/// 这一行视频有没有观看痕迹（位置 / 时刻 / 完成标记三判据任一成立）。
///
/// 与 [CollectionMemberProgress] 的痕迹口径**同源**：卡菜单「清除观看进度」按它决定
/// 要不要画那个按钮，合集续播按它决定锚点——两处判据一旦分叉，就会出现「菜单说没
/// 进度可清、续播却仍钉在这一集」的自相矛盾。纯函数，build 里安全。
bool videoBookHasWatchTrace(VideoBookRow book) => CollectionMemberProgress(
  positionMs: book.lastPositionMs,
  completed: book.completedAt != null,
  lastPlayedAt: book.lastPlayedAt,
).hasTrace;

/// 成员播放痕迹（合集内已排序，index 0 在前）。
class CollectionMemberProgress {
  const CollectionMemberProgress({
    required this.positionMs,
    required this.completed,
    this.lastPlayedAt,
    this.durationMs,
  });

  /// 该成员自己的播放进度毫秒（无进度 = 0 或 null）。
  final int? positionMs;

  /// 该成员是否**标记**为看完（`completedAt` 非空）。自 BUG-3491 起播放不再自动
  /// 打勾，这里只剩手动标记、host / 服务器下发的标记与存量旧数据（不做迁移清除）。
  final bool completed;

  /// 该成员最近一次播放的毫秒时刻（`VideoBooks.lastPlayedAt`）。
  /// null / <=0 = 无时刻（v85 前的旧行，或从未播放）。
  final int? lastPlayedAt;

  /// 该成员的片长毫秒（播放器记下的真实时长 / host 下发的时长）；null = 不知道。
  ///
  /// 用来判「进度到了片尾区」（[reachedEnd]）与「已打勾的集正在重看」
  /// （[isRewatching]）。不知道片长时两者都不推断：未打勾的集按原有进度算没看完，
  /// 已打勾的集沿用旧口径算看完。
  final int? durationMs;

  /// 进度已到片尾区（BUG-3491，所有者 2026-10-17 拍板）：断点 > 0 且
  /// [isEpisodePositionNearEnd]（与打开时「从头放还是续播」同一判据）。播放不再
  /// 自动打勾，续播推进 / 已看计数改认它——看到片尾的集等同看完，但列表上不打勾。
  bool get reachedEnd {
    final int position = positionMs ?? 0;
    final int? duration = durationMs;
    if (position <= 0 || duration == null || duration <= 0) return false;
    return isEpisodePositionNearEnd(savedMs: position, durationMs: duration);
  }

  /// 计数意义上的「看过了」（「已看完 x/N」）：手动标记看完，或进度到片尾区。
  bool get countsAsWatched => completed || reachedEnd;

  /// 已标看完、但最近一次是**重看到一半退出**（BUG-3491）：断点 > 0 且不在片尾区
  /// （[isEpisodePositionNearEnd]，与打开时「从头放还是续播」同一判据）。
  ///
  /// 打勾是一次性事实（重看不撤销），所以光看 [completed] 会把「重看第 12 集看到
  /// 一半」当成「第 12 集看完了」，续播直接跳到第 13 集。
  bool get isRewatching {
    if (!completed) return false;
    final int position = positionMs ?? 0;
    final int? duration = durationMs;
    if (position <= 0 || duration == null || duration <= 0) return false;
    return !isEpisodePositionNearEnd(savedMs: position, durationMs: duration);
  }

  /// 续播意义上的「这一集看完了，该看下一集」：进度到片尾区，或已标看完且不在
  /// 重看中。
  bool get isFinished => reachedEnd || (completed && !isRewatching);

  /// 时刻本身就是痕迹：播过就一定有时刻，哪怕位置被拖回 0 且未标完成。
  bool get hasTrace => completed || (positionMs ?? 0) > 0 || _playedAt > 0;

  /// 真正开始看了：已完成或有进度。只有时刻（打开几秒就退出、进度存成 0）的
  /// 成员 [hasTrace] 为真但这里为假——「下一集」据此决定停在它还是推进到它后面。
  bool get hasStarted => completed || (positionMs ?? 0) > 0;

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
/// - 锚点没看完 → 停在锚点。**重看已打勾的集到一半退出**不算看完：停在它
///   （BUG-3491）。
/// - 锚点已看完（[CollectionMemberProgress.isFinished]）→ 它之后第一个还没看完的
///   成员（[firstUnfinishedMemberFrom]，BUG-5613）；之后全都看完（含锚点就是最后
///   一个）→ 最后一个成员。
int continueMemberIndex(List<CollectionMemberProgress> members) {
  final int? anchor = latestPlayedMemberIndex(members);
  if (anchor == null) return 0;
  if (!members[anchor].isFinished) return anchor;
  return firstUnfinishedMemberFrom(members, anchor + 1) ?? members.length - 1;
}

/// 从 [start] 起（含）第一个还没看完（非 [CollectionMemberProgress.isFinished]）
/// 的成员下标；[start] 起全都看完或越界 → null。
///
/// 「锚点看完 → 下一集」的**唯一**推进判据（BUG-5613）：详情大卡
/// [continueMemberIndex]、视频首页「继续观看」与「下一集」（`video_home_layout.dart`）
/// 都经这里，不许各写一份 `anchor + 1`。与 Jellyfin Next-Up 同一语义——锚点之后
/// 已标记看完（在本机、媒体服务器或互联对端标的）或进度到片尾区的集要跳过。标记
/// 已看不写 `lastPlayedAt`（标记不等于播放），锚点仍是最后真正播放的那集；此前只取
/// `anchor + 1`，用户看完第 2 集、再把第 3～9 集标已看后，各处仍说「继续看第 3 集」。
int? firstUnfinishedMemberFrom(
  List<CollectionMemberProgress> members,
  int start,
) {
  for (int i = start < 0 ? 0 : start; i < members.length; i++) {
    if (!members[i].isFinished) return i;
  }
  return null;
}

/// 合集「最近播放」锚点——**唯一判据**（BUG-3370）。详情大卡 / 合集卡进度行的
/// [continueMemberIndex]、视频首页「继续观看」「下一集」「已更新未看」三行
/// （`video_home_layout.dart` 的 `latestPlayedSeriesIndex`）都只经这里选锚点，
/// 不许各写一份。
///
/// - 有时刻：`lastPlayedAt` 最大的成员（并列取位置靠后者，贴连播方向）。
///   **只打开过、进度存成 0 且未完成**的成员同样算——时刻就是「用户刚才在看哪
///   一集」的直接事实（BUG-1542）。跳过它会让首页与大卡分叉：看完第 7 集、跳到
///   第 12 集几秒退出时，大卡说第 12 集、首页说第 8 集。
/// - 无任何时刻（旧库）：位置最靠后的有痕迹成员（v85 前口径）。
/// - 全无痕迹 / 空列表 → null。
int? latestPlayedMemberIndex(List<CollectionMemberProgress> members) {
  final int recent = _mostRecentlyPlayedIndex(members);
  if (recent >= 0) return recent;
  final int traced = _lastTracedIndex(members);
  return traced >= 0 ? traced : null;
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
    if (members[i].hasTrace) last = i;
  }
  return last;
}
