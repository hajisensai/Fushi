import 'dart:convert';

import '../engine/hoshidicts.dart' show HoshiKanjiResult;
import 'dictionary_entry.dart';

class DictionarySearchResult {
  factory DictionarySearchResult.fromJson(String json) {
    final map = Map<String, dynamic>.from(jsonDecode(json));
    final entriesJson = List<String>.from(map['entries'] ?? []);
    final kanjiJson = List<dynamic>.from(map['kanjiResults'] ?? const []);
    return DictionarySearchResult(
      searchTerm: map['searchTerm'] as String,
      bestLength: map['bestLength'] as int? ?? 0,
      scrollPosition: map['scrollPosition'] as int? ?? 0,
      entries: entriesJson.map(DictionaryEntry.fromJson).toList(),
      kanjiResults: kanjiJson
          .map((dynamic e) =>
              HoshiKanjiResult.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
  DictionarySearchResult({
    required this.searchTerm,
    this.entries = const [],
    this.bestLength = 0,
    this.scrollPosition = 0,
    this.kanjiResults = const [],
  });

  final String searchTerm;
  final List<DictionaryEntry> entries;
  final int bestLength;
  int scrollPosition;

  /// Per-character kanji dictionary results for a single-character lookup
  /// (onyomi / kunyomi / radical / strokes / meanings). Empty for multi-char
  /// terms or when no kanji dictionary is loaded. S4 populates this so the S5
  /// popup can render the kanji card; it does NOT replace [entries] (a single
  /// kanji can be both a term headword and a kanji entry).
  final List<HoshiKanjiResult> kanjiResults;

  String? popupJson;

  /// Returns a copy carrying [kanji] in [kanjiResults] while preserving the
  /// term [entries], [popupJson], [bestLength] and [scrollPosition]. Used by the
  /// search path to attach a single-kanji lookup's kanji-dictionary results to a
  /// freshly built term result without mutating the (final) term fields.
  DictionarySearchResult withKanjiResults(List<HoshiKanjiResult> kanji) {
    final DictionarySearchResult copy = DictionarySearchResult(
      searchTerm: searchTerm,
      entries: entries,
      bestLength: bestLength,
      scrollPosition: scrollPosition,
      kanjiResults: kanji,
    );
    copy.popupJson = popupJson;
    return copy;
  }

  String toJson() {
    return jsonEncode({
      'searchTerm': searchTerm,
      'bestLength': bestLength,
      'scrollPosition': scrollPosition,
      'entries': entries.map((e) => e.toJson()).toList(),
      'kanjiResults': kanjiResults.map((k) => k.toMap()).toList(),
    });
  }
}
