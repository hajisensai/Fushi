/// 词状态查询（B-3）：termKey 与查询结果形状。
///
/// 第六轮审查第 20 条：termKey 只按词形会把「上手（じょうず / うわて）」这类同形异读词合并成一条。
/// 改为「词形 + 读音」两段：查询时有读音就精确匹配两段，没有读音（或笔记没填读音）才按词形匹配。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

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
    this.byRecall = false,
  });

  final String cardId;
  final String noteId;
  final SrsQueue queue;
  final bool suspended;
  final int? dueDay;
  final int? dueAt;
  final String deckId;
  final int cardCount;

  /// 所在牌组按 RWKV-Instant 排队：复习卡在此刻回忆率降到目标时出现，[dueDay] 不代表什么时候复习。
  final bool byRecall;

  Map<String, Object?> toJson() => <String, Object?>{
    'cardId': cardId,
    'noteId': noteId,
    'queue': queue.wire,
    'suspended': suspended,
    if (dueDay != null) 'dueDay': dueDay,
    if (dueAt != null) 'dueAt': dueAt,
    'deckId': deckId,
    'cardCount': cardCount,
    if (byRecall) 'byRecall': true,
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

/// 复习库「已知词」快照：一次读出所有（词形, 读音）组合下可见卡片的（队列, 暂停）分布，
/// 之后逐词判「已进入复习队列」不再查库。用于一次要判成百上千个词的场景（曲库按歌词
/// 生词覆盖率排序、歌词页覆盖率）。
///
/// 判据与 `SrsDbStore.lookupTermStatus` 逐词查询**同一口径**：匹配的笔记 = 同词形且
/// （查询没读音 / 笔记没读音 / 读音相同）；在这些笔记的可见卡片里按
/// [srsTermUrgencyCompare] 取最需要复习的一张，它在复习队列（[SrsQueue.review]）里才算
/// 已知。新卡 / 学习中 / 重学都不算。取最急一张只看「先未暂停、再队列名次」，所以只
/// 需要每个读音下出现过哪些（暂停, 队列）组合，不必保留每张卡。
class SrsKnownTermSnapshot {
  SrsKnownTermSnapshot._(this._masks, this.stamp);

  /// [rows]：每行一个（termKey, readingKey, 队列, 是否暂停）组合（可重复）。
  factory SrsKnownTermSnapshot.fromRows(
    Iterable<
      ({String termKey, String readingKey, SrsQueue queue, bool suspended})
    >
    rows,
  ) {
    final Map<String, Map<String, int>> masks = <String, Map<String, int>>{};
    for (final ({
          String termKey,
          String readingKey,
          SrsQueue queue,
          bool suspended,
        })
        r
        in rows) {
      if (r.termKey.isEmpty) continue;
      final Map<String, int> byReading = masks.putIfAbsent(
        r.termKey,
        () => <String, int>{},
      );
      byReading[r.readingKey] =
          (byReading[r.readingKey] ?? 0) | _bit(r.queue, r.suspended);
    }
    final List<String> lines = <String>[
      for (final MapEntry<String, Map<String, int>> t in masks.entries)
        for (final MapEntry<String, int> rd in t.value.entries)
          '${t.key}\u0001${rd.key}\u0001${rd.value}',
    ]..sort();
    final String stamp = sha1.convert(utf8.encode(lines.join('\n'))).toString();
    return SrsKnownTermSnapshot._(masks, stamp);
  }

  /// 空快照（复习库里没有任何卡）。
  factory SrsKnownTermSnapshot.empty() => SrsKnownTermSnapshot.fromRows(
    const <
      ({String termKey, String readingKey, SrsQueue queue, bool suspended})
    >[],
  );

  final Map<String, Map<String, int>> _masks;

  /// 快照内容指纹：已知判定所依赖的分布一变它就变（复习一次但队列没变则不变）。
  final String stamp;

  // 位：暂停与否各占 3 位，每 3 位按急迫名次（0 学习中 / 重学，1 复习，2 新卡）。
  static int _rank(SrsQueue q) => switch (q) {
    SrsQueue.learning || SrsQueue.relearning => 0,
    SrsQueue.review => 1,
    SrsQueue.newCard => 2,
  };

  static int _bit(SrsQueue q, bool suspended) =>
      1 << (_rank(q) + (suspended ? 3 : 0));

  /// 这个词是否「已进入复习队列」（见类注释）。
  bool isKnown(SrsTermQuery query) {
    final Map<String, int>? byReading = _masks[query.termKey];
    if (byReading == null) return false;
    final String rk = query.readingKey;
    int mask = 0;
    for (final MapEntry<String, int> e in byReading.entries) {
      if (rk.isEmpty || e.key.isEmpty || e.key == rk) mask |= e.value;
    }
    final int active = mask & 0x7;
    final int group = active != 0 ? active : (mask >> 3) & 0x7;
    // 最急一张的名次 = group 里最低的置位；它是「复习」= 没有学习中、有复习。
    return group & 0x1 == 0 && group & 0x2 != 0;
  }
}
