/// [SrsDbStore] 排队时从 RWKV 取「此刻回忆率」的接口（实现：`SrsRwkvService`；store 不依赖实现，
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

  /// RWKV-Instant：[cards] 这些复习卡**此刻**的回忆率（即时头，按当前状态查询），与 [cards] 同序；
  /// 某张卡没法打分时是 NaN。没准备好 / 状态落后需要重建时返回 null（并在后台开始准备）。
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  });

  /// 本机评分已落库（[log] 是这张卡新的最后一条有效日志）。
  Future<void> onAnswered(String cardId, SrsReviewLog log);

  /// 这些卡已被永久清除（srs_purge.dart）：丢掉为它们缓存的分数。
  Future<void> onCardsPurged(List<String> cardIds);
}
