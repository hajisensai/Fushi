/// 查词弹窗的复习（SRS）词状态（计划 PR5 / C-1）：popup.js `srsTermStatus` 桥与
/// 浏览器扩展 `/api/srs/term-status` 共用的回包。
///
/// 回包形状（null = 复习库里没有这个词 / 模块关着）：
/// `{queue, dueLabel, suspended, cardId, noteId, cardCount, tooltip}`。`dueLabel` /
/// `tooltip` 由这里按 app 当前语言本地化好，JS 侧不带任何语言串。
library;

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/i18n/strings.g.dart';

/// 卡片状态的短标签（「复习中 · 3天后」/「今天到期」/「学习中」/「新卡」/「已暂停」）。
String srsTermStatusLabel(SrsTermStatus status, {required int today}) {
  if (status.suspended) return t.srs_status_suspended;
  switch (status.queue) {
    case SrsQueue.newCard:
      return t.srs_status_new;
    case SrsQueue.learning:
    case SrsQueue.relearning:
      return t.srs_status_learning;
    case SrsQueue.review:
      final int? due = status.dueDay;
      if (due == null || due <= today) return t.srs_status_due;
      return t.srs_status_review_in(n: due - today);
  }
}

/// 一条状态 → 桥回包。
Map<String, Object?> srsTermStatusPayload(
  SrsTermStatus status, {
  required int today,
}) => <String, Object?>{
  'queue': status.queue.wire,
  'dueLabel': srsTermStatusLabel(status, today: today),
  'suspended': status.suspended,
  'cardId': status.cardId,
  'noteId': status.noteId,
  'cardCount': status.cardCount,
  'tooltip': status.cardCount > 1
      ? t.srs_status_open_tooltip_many(n: status.cardCount)
      : t.srs_status_open_tooltip,
};

/// 在 [store] 里查一个词（词形 + 可选读音）；没有返回 null。[store] 为 null（模块关着）
/// 时也返回 null，不做任何 IO。
Future<Map<String, Object?>?> srsLookupTermStatusPayload(
  SrsDbStore? store, {
  required String expression,
  required String reading,
}) async {
  if (store == null || expression.trim().isEmpty) return null;
  final Map<String, SrsTermStatus> hits = await store.lookupTermStatus(
    <SrsTermQuery>[
      SrsTermQuery(expression, reading.trim().isEmpty ? null : reading),
    ],
  );
  final SrsTermStatus? status = hits[expression];
  if (status == null) return null;
  final SrsDayContext day = await store.dayContext();
  final (int nowMs, _) = store.now();
  return srsTermStatusPayload(status, today: day.dayIndexOf(nowMs));
}

/// 卡片 id → 笔记 id（弹窗 / 扩展只带了 cardId 时用）。
Future<String?> srsNoteIdForCard(SrsDbStore store, String cardId) async =>
    (await store.cardRow(cardId))?.noteId;
