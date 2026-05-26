import 'dart:convert';

import 'dictionary_entry.dart';

class DictionarySearchResult {
  factory DictionarySearchResult.fromJson(String json) {
    final map = Map<String, dynamic>.from(jsonDecode(json));
    final entriesJson = List<String>.from(map['entries'] ?? []);
    return DictionarySearchResult(
      searchTerm: map['searchTerm'] as String,
      bestLength: map['bestLength'] as int? ?? 0,
      scrollPosition: map['scrollPosition'] as int? ?? 0,
      entries: entriesJson.map(DictionaryEntry.fromJson).toList(),
    );
  }
  DictionarySearchResult({
    required this.searchTerm,
    this.entries = const [],
    this.bestLength = 0,
    this.scrollPosition = 0,
  });

  final String searchTerm;
  final List<DictionaryEntry> entries;
  final int bestLength;
  int scrollPosition;

  String? popupJson;

  String toJson() {
    return jsonEncode({
      'searchTerm': searchTerm,
      'bestLength': bestLength,
      'scrollPosition': scrollPosition,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
  }
}
