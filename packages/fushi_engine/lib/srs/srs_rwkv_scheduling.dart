/// [SrsDbStore] 排队时从 RWKV 取回忆率的接口（实现：`SrsRwkvService`；store 不依赖实现，
/// 测试可替换）。
library;

import 'package:fushi_srs/fushi_srs.dart';

/// RWKV-Instant 排队的一张候选复习卡（卡片缓存表里的一行）。
class SrsRwkvCandidate {
  const SrsRwkvCandidate({
    required this.id,
    required this.noteId,
    required this.deckId,
    required this.lastLogId,
  });

  final String id;
  final String noteId;
  final String deckId;

  /// 这张卡最后一条有效日志：实现按它缓存每张卡的最后保留评分，变了才重读这张卡的历史。
  final String? lastLogId;
}

abstract interface class SrsRwkvScheduling {
  /// 现在能用 RWKV 排队：所选模型就绪、状态已建好。false 时 RWKV 牌组的复习卡不出（不退回 FSRS-7 的到期日），
  /// 复习页等它就绪（`SrsStudyState.rwkvPending`）；调用本 getter 不启动服务。
  bool get ready;

  /// RWKV-Instant 排队：[cards] 这些**今天还没答过的**复习卡在今天结束时刻 [atMs]（下一个翻日时刻前 1 ms）的
  /// 回忆率（即时头，按当前状态查询），与 [cards] 同序；某张卡没法打分时是 NaN。「今天内会降到目标线下」= 今天
  /// 到期。实现可以把分数记进按这一个时刻维护的常驻分数表，所以别的时刻一律走 [currentRetrievability]。
  /// 没准备好 / 状态落后需要重建时返回 null（并在后台开始准备）。
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int atMs,
  });

  /// [cards] 在此刻 [nowMs] 的回忆率，直接查询、**不经**排队的常驻分数表（与 [instantRetrievability] 的表
  /// 混用两个时刻的话，两边轮流触发整表重查，排队还可能拿到此刻而不是今天结束时的分数）。用途：
  /// - 排队里**今天已答过**的卡：同日重出看此刻的 R（刚答完 R 高，真掉到目标线下才再出）。按今天结束时的 R
  ///   判的话，答完它在模型看来仍撑不到今天结束，同日间隔守卫一过就又合格，一天里被反复刷、计数降不下来；
  /// - 统计页的可提取度（此刻的 R）。
  /// 其余契约（同序同长、NaN、null）同 [instantRetrievability]。
  Future<List<double>?> currentRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  });

  /// 本机评分已落库（[log] 是这张卡新的最后一条有效日志）。
  Future<void> onAnswered(String cardId, SrsReviewLog log);

  /// 这些卡已被永久清除（srs_purge.dart）：丢掉为它们缓存的分数。
  Future<void> onCardsPurged(List<String> cardIds);
}
