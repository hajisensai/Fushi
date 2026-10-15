/// 词状态查询（B-3）：termKey 与查询结果形状。
///
/// 第六轮审查第 20 条：termKey 只按词形会把「上手（じょうず / うわて）」这类同形异读词合并成一条。
/// 改为「词形 + 读音」两段：查询时有读音就精确匹配两段，没有读音（或笔记没填读音）才按词形匹配。
library;

import 'review_log.dart';

final RegExp _htmlTag = RegExp(r'<[^>]*>');
final RegExp _rubyAnnotation = RegExp(r'\[[^\]]*\]');
final RegExp _space = RegExp(r'\s+');

/// 归一化：去 HTML、去 Anki 注音括号 `漢字[かんじ]` 的读音部分、去空白、NFKC 近似（全角 ASCII → 半角）、小写。
String srsNormalizeTerm(String raw) {
  String s = raw.replaceAll(_htmlTag, '');
  s = s.replaceAll(_rubyAnnotation, '');
  s = s.replaceAll('&nbsp;', ' ');
  s = s.replaceAll(_space, '');
  final StringBuffer sb = StringBuffer();
  for (final int c in s.runes) {
    if (c >= 0xFF01 && c <= 0xFF5E) {
      sb.writeCharCode(c - 0xFEE0);
    } else {
      sb.writeCharCode(c);
    }
  }
  return sb.toString().toLowerCase();
}

/// termKey 的词形部分。
String srsTermKey(String expression) => srsNormalizeTerm(expression);

/// 读音部分（空串 = 未知）。
String srsReadingKey(String? reading) =>
    reading == null ? '' : srsNormalizeTerm(reading);

/// 一个词在 SRS 里的状态（多张卡时取「最需要复习的一张」并带卡数）。
class SrsTermStatus {
  const SrsTermStatus({
    required this.cardId,
    required this.noteId,
    required this.queue,
    required this.suspended,
    required this.deckId,
    required this.cardCount,
    this.dueDay,
    this.dueAt,
  });

  final String cardId;
  final String noteId;
  final SrsQueue queue;
  final bool suspended;
  final int? dueDay;
  final int? dueAt;
  final String deckId;
  final int cardCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'cardId': cardId,
    'noteId': noteId,
    'queue': queue.wire,
    'suspended': suspended,
    if (dueDay != null) 'dueDay': dueDay,
    if (dueAt != null) 'dueAt': dueAt,
    'deckId': deckId,
    'cardCount': cardCount,
  };
}

/// 一次查询的词：词形 + 可选读音。
class SrsTermQuery {
  const SrsTermQuery(this.expression, [this.reading]);

  final String expression;
  final String? reading;

  String get termKey => srsTermKey(expression);
  String get readingKey => srsReadingKey(reading);
}

/// 「最需要复习」的排序：未暂停优先，然后学习中 > 到期复习 > 复习 > 新卡，到期早的优先。
int srsTermUrgencyCompare(SrsTermStatus a, SrsTermStatus b) {
  if (a.suspended != b.suspended) return a.suspended ? 1 : -1;
  int rank(SrsQueue q) => switch (q) {
    SrsQueue.learning || SrsQueue.relearning => 0,
    SrsQueue.review => 1,
    SrsQueue.newCard => 2,
  };
  final int r = rank(a.queue).compareTo(rank(b.queue));
  if (r != 0) return r;
  final int ad = a.dueAt ?? (a.dueDay ?? 1 << 40) * 86400000;
  final int bd = b.dueAt ?? (b.dueDay ?? 1 << 40) * 86400000;
  return ad.compareTo(bd);
}
