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

/// 服务阶段（界面显示用）。
enum SrsRwkvPhase {
  /// 还没启动（没有 RWKV 牌组时不启动）。
  idle,

  /// 正在下载所选模型的权重（[SrsRwkvStatus.done] / [SrsRwkvStatus.total] 是字节）。
  downloading,

  /// 正在加载 / 恢复快照或检查点 / 全量回放。
  preparing,

  /// 可以排程。
  ready,

  /// 出错（[SrsRwkvStatus.error]）；下次需要时重试。
  failed,
}

class SrsRwkvStatus {
  const SrsRwkvStatus(this.phase, {this.done = 0, this.total = 0, this.error});

  final SrsRwkvPhase phase;

  /// 进度：下载时是字节，全量回放时是条数。
  final int done;
  final int total;
  final Object? error;
}

/// RWKV 准备状态的来源：复习页 / 牌组列表在「等 RWKV」时显示它、听它的「就绪」重新排队、出错时经它重试。
/// 本机复习是 `SrsRwkvService` 自己；远程复习时 RWKV 在主机上跑，由远程库把主机的状态转过来
/// （`SrsRemoteStore`，见 srs_remote_store.dart 信封里的 `rk`）。
abstract interface class SrsRwkvStatusSource {
  SrsRwkvStatus get status;

  /// 每次状态变化（含同一阶段的进度、以及已就绪后再报的「就绪」）发一条。
  Stream<SrsRwkvStatus> get statusChanges;

  bool get ready;

  /// 开始准备；[force] 不受失败后的重试间隔限制（界面上的「重试」）。
  Future<void> start({bool force = false});
}
