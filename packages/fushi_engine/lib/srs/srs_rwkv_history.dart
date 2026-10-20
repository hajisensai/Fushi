/// Fushi 复习日志 → RWKV 回放行（`FrwkvReview`）。规则对齐上游 kuma3（native/fushi_rwkv/README.md
/// 「回放哪些复习」「逐字段」），换成 Fushi 的事件模型：
///
/// - 只看有效评分日志（[SrsCardHistory.effectiveRatings] 口径：撤销的、被判等价的导入日志已排除）；
/// - 最近一次重置（[srsIsReset]，相当于 Anki 的 Forget）之前的评分丢弃；
/// - 只保留最近一次学习序列：某卡出现「非学习评分之后又一条学习评分」时，从最后一次这样的起点算起；
/// - card_type 是上游的 RwkvReviewState：学习序列起点 0，否则 learn 1 / review 2 / relearn 3；
///   同一调度日里再次复习 review 卡时改写为 3（上一条是 review+Again 或 relearn+Again/Hard）或 4；
/// - elapsed 是距本卡上一条保留评分的调度日差 / 秒差，首条 -1；
/// - day_offset 用**同一个**日界（当前的 [SrsDayContext]），保证按时间排序后单调不减；
/// - 卡 / 笔记 / 牌组 / 预设 id 是 53 位数字 id（[SrsIds.ankiNumericId]），预设 = 参数归属牌组。
library;

import 'dart:typed_data';

import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 一张卡的 RWKV 输入：数字身份与日志视图。
class SrsRwkvCard {
  const SrsRwkvCard({
    required this.cardId,
    required this.noteId,
    required this.deckId,
    required this.presetId,
    required this.history,
  });

  final int cardId;
  final int? noteId;
  final int? deckId;
  final int? presetId;
  final SrsCardHistory history;
}

/// 回放保留下来的评分（时间顺序）。
List<SrsReviewLog> srsRwkvKeptRatings(SrsCardHistory history) {
  final List<SrsReviewLog> eff = history.effective;
  int start = 0;
  for (int i = eff.length - 1; i >= 0; i--) {
    if (srsIsReset(eff[i])) {
      start = i + 1;
      break;
    }
  }
  final List<SrsReviewLog> ratings = <SrsReviewLog>[
    for (final SrsReviewLog l in eff.sublist(start))
      if (l.isRatingReview && l.rating != null) l,
  ];
  int from = 0;
  for (int i = ratings.length - 1; i > 0; i--) {
    if (ratings[i].reviewType == SrsReviewType.learn &&
        ratings[i - 1].reviewType != SrsReviewType.learn) {
      from = i;
      break;
    }
  }
  return ratings.sublist(from);
}

int _typeOf(String reviewType) => switch (reviewType) {
  SrsReviewType.learn => 1,
  SrsReviewType.review => 2,
  SrsReviewType.relearn => 3,
  _ => 4,
};

/// 第 [index] 条保留评分的 card_type（上游 RwkvReviewState）。
int _cardType(List<SrsReviewLog> kept, int index, SrsDayContext day) {
  final SrsReviewLog log = kept[index];
  if (index == 0) {
    return log.reviewType == SrsReviewType.learn ? 0 : _typeOf(log.reviewType);
  }
  final SrsReviewLog prev = kept[index - 1];
  if (log.reviewType == SrsReviewType.review &&
      day.dayIndexOf(log.occurredAt) == day.dayIndexOf(prev.occurredAt)) {
    final bool relearning =
        (prev.reviewType == SrsReviewType.review && prev.rating == 1) ||
        (prev.reviewType == SrsReviewType.relearn &&
            (prev.rating == 1 || prev.rating == 2));
    return relearning ? 3 : 4;
  }
  return _typeOf(log.reviewType);
}

void _add(
  RwkvRows rows,
  SrsRwkvCard card, {
  required int ease,
  required int at,
  required int? previousAt,
  required int cardType,
  required int? durationMs,
  required SrsDayContext day,
}) {
  final int today = day.dayIndexOf(at);
  rows.add(
    cardId: card.cardId,
    noteId: card.noteId,
    deckId: card.deckId,
    presetId: card.presetId,
    ease: ease,
    durationMs: durationMs != null && durationMs > 0 ? durationMs : null,
    cardType: cardType,
    dayOffset: today,
    elapsedDays: previousAt == null
        ? -1
        : (today - day.dayIndexOf(previousAt)).clamp(0, 1 << 40),
    elapsedSeconds: previousAt == null
        ? -1
        : ((at - previousAt) ~/ 1000).clamp(0, 1 << 50),
  );
}

/// 全量回放行的构建器：按块 [addCard]（不必一次把整个 collection 的历史留在内存里），
/// [build] 按评分时刻排序（同一时刻按加入顺序，确定性）。
class SrsRwkvReplayBuilder {
  SrsRwkvReplayBuilder(this.day);

  final SrsDayContext day;
  final RwkvRows _rows = RwkvRows(1024);
  final List<int> _times = <int>[];

  int get length => _rows.length;

  void addCard(SrsRwkvCard card) {
    final List<SrsReviewLog> kept = srsRwkvKeptRatings(card.history);
    for (int i = 0; i < kept.length; i++) {
      final SrsReviewLog log = kept[i];
      _add(
        _rows,
        card,
        ease: log.rating!,
        at: log.occurredAt,
        previousAt: i == 0 ? null : kept[i - 1].occurredAt,
        cardType: _cardType(kept, i, day),
        durationMs: log.durationMs,
        day: day,
      );
      _times.add(log.occurredAt);
    }
  }

  /// 排好序的行，与最后一条的时刻（无评分时 null；增量追加据此判断新日志是否「在它之后」）。
  (RwkvRows, int?) build() {
    final List<int> times = _times;
    final List<int> order = List<int>.generate(times.length, (int i) => i)
      ..sort((int a, int b) {
        final int byTime = times[a].compareTo(times[b]);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    final Uint8List source = _rows.bytes;
    final Uint8List sorted = Uint8List(source.length);
    for (int i = 0; i < order.length; i++) {
      sorted.setRange(
        i * kFrwkvReviewSize,
        (i + 1) * kFrwkvReviewSize,
        source,
        order[i] * kFrwkvReviewSize,
      );
    }
    return (
      RwkvRows.fromBytes(sorted),
      times.isEmpty ? null : times[order.last],
    );
  }
}

/// 一组卡的全量回放行（见 [SrsRwkvReplayBuilder]）。
(RwkvRows, int?) srsRwkvReplayRows(List<SrsRwkvCard> cards, SrsDayContext day) {
  final SrsRwkvReplayBuilder builder = SrsRwkvReplayBuilder(day);
  cards.forEach(builder.addCard);
  return builder.build();
}

/// 一条新评分（刚写入的 [log]，已是 [card] 历史里的最后一条有效日志）的回放行：
/// 增量追加用。不是该卡最后一条保留评分（撤销 / 重置 / 学习序列重启等改写了历史）时返回 null，
/// 调用方改做全量重建。
RwkvRows? srsRwkvAppendRow(
  SrsRwkvCard card,
  SrsReviewLog log,
  SrsDayContext day,
) {
  final List<SrsReviewLog> kept = srsRwkvKeptRatings(card.history);
  if (kept.isEmpty || kept.last.id != log.id) return null;
  final int i = kept.length - 1;
  if (i == 0 && card.history.effectiveRatings.length > 1) {
    // 学习序列重启：上游丢弃了这张卡更早的评分，增量追加无法撤回它们。
    return null;
  }
  final RwkvRows rows = RwkvRows(1);
  _add(
    rows,
    card,
    ease: log.rating!,
    at: log.occurredAt,
    previousAt: i == 0 ? null : kept[i - 1].occurredAt,
    cardType: _cardType(kept, i, day),
    durationMs: log.durationMs,
    day: day,
  );
  return rows;
}

/// 「这张卡此刻作答」的行（作答时排程用；ease 由原生侧逐个替换）。[queue] 是卡当前所在队列。
RwkvRows srsRwkvAnswerRow(
  SrsRwkvCard card, {
  required int nowMs,
  required SrsQueue queue,
  required SrsDayContext day,
}) {
  final List<SrsReviewLog> kept = srsRwkvKeptRatings(card.history);
  final String reviewType = SrsReviewType.ofQueue(queue);
  final int cardType;
  if (kept.isEmpty || queue == SrsQueue.newCard) {
    cardType = 0;
  } else {
    final SrsReviewLog prev = kept.last;
    final bool sameDay =
        day.dayIndexOf(nowMs) == day.dayIndexOf(prev.occurredAt);
    if (reviewType == SrsReviewType.review && sameDay) {
      final bool relearning =
          (prev.reviewType == SrsReviewType.review && prev.rating == 1) ||
          (prev.reviewType == SrsReviewType.relearn &&
              (prev.rating == 1 || prev.rating == 2));
      cardType = relearning ? 3 : 4;
    } else {
      cardType = _typeOf(reviewType);
    }
  }
  final RwkvRows rows = RwkvRows(1);
  _add(
    rows,
    card,
    ease: 0,
    at: nowMs,
    previousAt: kept.isEmpty || queue == SrsQueue.newCard
        ? null
        : kept.last.occurredAt,
    cardType: cardType,
    durationMs: null,
    day: day,
  );
  return rows;
}
