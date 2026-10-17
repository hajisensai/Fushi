/// 从 Anki 导入时的事件规则（铁律 C）：导入事件的全部内容只由来源数据决定。
library;

import 'hlc.dart';
import 'review_log.dart';

/// 导入事件的 writerId。
const String srsAnkiWriterId = 'anki';

/// 从 Anki 导入的 revlog 的 HLC：(revlog id 毫秒, 0, "anki")。
Hlc srsImportedRevlogHlc(int ankiRevlogId) =>
    Hlc(ankiRevlogId, 0, srsAnkiWriterId);

/// 导入锚点的 HLC：(T, **1**, "anki")。
///
/// 第六轮审查第 5 条（锚点同刻）：锚点时刻 T 就是来源最后一条排程相关 revlog 的时刻，两者物理时间相同、
/// writerId 都是 "anki"；修订版 8 只靠 eventId（随机哈希）兜底，锚点可能排到它自己那条 revlog 前面，
/// 让 revlog 变成「最后一条有效日志」。计数器取 1，锚点恒排在同一毫秒的全部来源 revlog（计数器 0）之后。
Hlc srsImportAnchorHlc(int anchorMs) => Hlc(anchorMs, 1, srsAnkiWriterId);

/// 一条来源 revlog 的最小形状。
class SrsAnkiRevlogRow {
  const SrsAnkiRevlogRow({
    required this.id,
    required this.ease,
    required this.type,
    required this.ivl,
    required this.factor,
  });

  /// revlog id = 复习毫秒时刻。
  final int id;

  /// 1..4（Manual / Rescheduled 等为 0）。
  final int ease;

  /// 0 learn, 1 review, 2 relearn, 3 filtered, 4 manual, 5 rescheduled。
  final int type;
  final int ivl;
  final int factor;

  /// 排程相关：评分类与 Manual / Rescheduled 都算，Filtered 不算。
  bool get schedulingRelevant => type != 3;

  /// Anki 的「遗忘 / 重置」：Manual 且 ivl 与 factor 都归零。
  bool get isReset => type == 4 && ivl == 0 && factor == 0;
}

/// 锚点决策。
class SrsAnchorDecision {
  const SrsAnchorDecision._(this.write, this.anchorMs, this.reason);

  /// 不写锚点。
  const SrsAnchorDecision.skip(String reason) : this._(false, null, reason);

  /// 写锚点，时刻 [anchorMs]。
  const SrsAnchorDecision.at(int anchorMs) : this._(true, anchorMs, null);

  final bool write;
  final int? anchorMs;
  final String? reason;
}

/// 决定是否为一张来源卡写锚点、锚点时刻是多少。
///
/// - 锚点时刻 T = 最后一条排程相关 revlog 的时刻；一条都没有且不是新卡（历史被裁）→ T = 来源集合创建时刻 crt。
/// - 不写：最后那条 revlog 与某条原生日志等价（Fushi 导出 → Anki 没复习 → 回导，往返是空操作）。
/// - 不写：来源卡是新卡**且**一条排程相关 revlog 都没有（从没学过）。
///   第六轮审查「Anki 里遗忘的卡回导」：修订版 8 对所有新卡都不写锚点，遗忘过的卡（Anki 里更晚的重置）
///   会保留 Fushi 的旧状态，违反「真实发生更晚的事件赢」。现在只要有排程相关 revlog（包括重置那条 Manual），
///   就照常写锚点，锚点结果是新卡状态。
SrsAnchorDecision srsDecideAnchor({
  required bool sourceIsNew,
  required List<SrsAnkiRevlogRow> revlogs,
  required int collectionCreatedMs,
  required bool Function(SrsAnkiRevlogRow last) equivalentToNative,
}) {
  SrsAnkiRevlogRow? last;
  for (final SrsAnkiRevlogRow r in revlogs) {
    if (!r.schedulingRelevant) continue;
    if (last == null || r.id > last.id) last = r;
  }
  if (last == null) {
    if (sourceIsNew)
      return const SrsAnchorDecision.skip('new card, no history');
    return SrsAnchorDecision.at(collectionCreatedMs);
  }
  if (equivalentToNative(last)) {
    return const SrsAnchorDecision.skip('round trip without new reviews');
  }
  return SrsAnchorDecision.at(last.id);
}

/// 导入锚点结果里的 scheduler 恒为 fushi，且**不参与**卡片归属判定：
/// 卡片归谁排程只由显式的移交事件决定（[SrsCardHistory.scheduler]）。
///
/// 第六轮审查「handOff 卡回导」：修订版 8 里，Anki 里复习过 → 锚点把 scheduler 改回 fushi（卡被收回）；
/// 没复习过 → 不写锚点（卡仍只读）。同一个操作两种结果。改为：导入从不改归属；
/// 收回只能由显式的「收回到 Fushi」动作（SrsCardOps.reclaim，也是一条 handOff 事件）完成。
/// 这样锚点内容仍只由来源决定（铁律 C），不读本机状态。
const String srsAnchorScheduler = SrsScheduler.fushi;
