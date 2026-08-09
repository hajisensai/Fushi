import 'dart:convert';

import '../engine/fushidicts.dart' show FushiKanjiResult;
import 'dictionary_entry.dart';

class DictionarySearchResult {
  factory DictionarySearchResult.fromJson(String json) {
    final map = Map<String, dynamic>.from(jsonDecode(json));
    final entriesJson = List<String>.from(map['entries'] ?? []);
    final kanjiJson = List<dynamic>.from(map['kanjiResults'] ?? const []);
    return DictionarySearchResult(
      searchTerm: map['searchTerm'] as String,
      bestLength: map['bestLength'] as int? ?? 0,
      truncated: map['truncated'] as bool? ?? false,
      scrollPosition: map['scrollPosition'] as int? ?? 0,
      entries: entriesJson.map(DictionaryEntry.fromJson).toList(),
      kanjiResults: kanjiJson
          .map((dynamic e) =>
              FushiKanjiResult.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
  DictionarySearchResult({
    required this.searchTerm,
    this.entries = const [],
    this.bestLength = 0,
    this.scrollPosition = 0,
    this.kanjiResults = const [],
    this.truncated = false,
  });

  final String searchTerm;
  final List<DictionaryEntry> entries;
  final int bestLength;
  int scrollPosition;

  /// 本次结果是否因 `maximumTerms` 被截断（还有更多词头没返回）。
  ///
  /// BUG-1472：以前消费方靠 `entries.length < maximumTerms` **反推**有没有被截断。
  /// 那个反推在预算单位 = glossary 注释行时勉强成立，改成按词头计预算后就彻底错位
  /// （一个词头能带 N 条 entries，两个数字不再可比）。截断是构造结果的人才知道的
  /// 事实，让它显式带出来，消费方不再猜。
  final bool truncated;

  /// Per-character kanji dictionary results for a single-character lookup
  /// (onyomi / kunyomi / radical / strokes / meanings). Empty for multi-char
  /// terms or when no kanji dictionary is loaded. S4 populates this so the S5
  /// popup can render the kanji card; it does NOT replace [entries] (a single
  /// kanji can be both a term headword and a kanji entry).
  final List<FushiKanjiResult> kanjiResults;

  String? popupJson;

  /// Returns a copy carrying [kanji] in [kanjiResults] while preserving the
  /// term [entries], [popupJson], [bestLength] and [scrollPosition]. Used by the
  /// search path to attach a single-kanji lookup's kanji-dictionary results to a
  /// freshly built term result without mutating the (final) term fields.
  DictionarySearchResult withKanjiResults(List<FushiKanjiResult> kanji) {
    final DictionarySearchResult copy = DictionarySearchResult(
      searchTerm: searchTerm,
      entries: entries,
      bestLength: bestLength,
      scrollPosition: scrollPosition,
      kanjiResults: kanji,
      truncated: truncated,
    );
    copy.popupJson = popupJson;
    return copy;
  }

  String toJson() {
    return jsonEncode({
      'searchTerm': searchTerm,
      'bestLength': bestLength,
      'truncated': truncated,
      'scrollPosition': scrollPosition,
      'entries': entries.map((e) => e.toJson()).toList(),
      'kanjiResults': kanjiResults.map((k) => k.toMap()).toList(),
    });
  }
}
