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
      if (status.byRecall) return t.srs_status_review_by_recall;
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

/// 弹窗一轮可见批次最多带多少个词（popup.js `SRS_STATUS_BATCH_MAX` 同值）；超出的
/// 请求宿主一律拒绝，免得一次把整页隐藏词条也拖进来。
const int kSrsTermStatusBatchMax = 32;

/// [srsLookupTermStatusPayloads] 用的批量查询内核（缺省 [SrsDbStore.lookupTermStatus]，
/// 一批一次）；测试可包一层计调用次数。
typedef SrsTermStatusLookup =
    Future<Map<String, SrsTermStatus>> Function(List<SrsTermQuery> terms);

/// 批量版 [srsLookupTermStatusPayload]（popup.js `srsTermStatusBatch` 桥与扩展
/// `/api/srs/term-status-batch` 共用）：回包与 [terms] 等长同序，没有的词为 null。
///
/// 存储层按词形回结果，同一批里「同形异读」（上手 じょうず / うわて）会互相覆盖，所以按
/// 「词形 + 读音」去重后再分层：每层词形互不相同，一层一次 [lookup]（常见情况就一层）。
/// 日期上下文整批只取一次。
Future<List<Map<String, Object?>?>> srsLookupTermStatusPayloads(
  SrsDbStore? store,
  List<SrsTermQuery> terms, {
  SrsTermStatusLookup? lookup,
}) async {
  final List<Map<String, Object?>?> out = List<Map<String, Object?>?>.filled(
    terms.length,
    null,
  );
  if (store == null || terms.isEmpty) return out;
  final SrsTermStatusLookup run = lookup ?? store.lookupTermStatus;
  // (词形, 读音键) → 首次出现的查询；每层一张 expression → 查询。
  final Map<(String, String), SrsTermQuery> unique =
      <(String, String), SrsTermQuery>{};
  for (final SrsTermQuery q in terms) {
    if (q.expression.trim().isEmpty) continue;
    unique.putIfAbsent((q.expression, q.readingKey), () => q);
  }
  if (unique.isEmpty) return out;
  final List<Map<String, SrsTermQuery>> layers = <Map<String, SrsTermQuery>>[];
  for (final SrsTermQuery q in unique.values) {
    Map<String, SrsTermQuery>? layer;
    for (final Map<String, SrsTermQuery> l in layers) {
      if (!l.containsKey(q.expression)) {
        layer = l;
        break;
      }
    }
    if (layer == null) layers.add(layer = <String, SrsTermQuery>{});
    layer[q.expression] = q;
  }
  final Map<(String, String), SrsTermStatus> hits =
      <(String, String), SrsTermStatus>{};
  for (final Map<String, SrsTermQuery> layer in layers) {
    final Map<String, SrsTermStatus> found = await run(
      layer.values.toList(growable: false),
    );
    for (final SrsTermQuery q in layer.values) {
      final SrsTermStatus? st = found[q.expression];
      if (st != null) hits[(q.expression, q.readingKey)] = st;
    }
  }
  if (hits.isEmpty) return out;
  final SrsDayContext day = await store.dayContext();
  final (int nowMs, _) = store.now();
  final int today = day.dayIndexOf(nowMs);
  for (int i = 0; i < terms.length; i++) {
    final SrsTermStatus? st = hits[(terms[i].expression, terms[i].readingKey)];
    if (st != null) out[i] = srsTermStatusPayload(st, today: today);
  }
  return out;
}

/// 卡片 id → 笔记 id（弹窗 / 扩展只带了 cardId 时用）。
Future<String?> srsNoteIdForCard(SrsDbStore store, String cardId) async =>
    (await store.cardRow(cardId))?.noteId;
