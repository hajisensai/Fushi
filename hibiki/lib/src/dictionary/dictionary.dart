import 'dart:convert';

import 'package:hibiki/language.dart';

enum DictionaryType { term, frequency, pitch }

class Dictionary {
  Dictionary({
    required this.name,
    required this.formatKey,
    required this.order,
    this.type = DictionaryType.term,
    this.metadata = const {},
    this.hiddenLanguages = const [],
    this.collapsedLanguages = const [],
  });

  final String name;
  final String formatKey;
  int order;
  final DictionaryType type;
  final Map<String, String> metadata;
  List<String> hiddenLanguages;
  List<String> collapsedLanguages;

  bool isHidden(Language language) {
    return hiddenLanguages.contains(language.languageCode);
  }

  bool isCollapsed(Language language) {
    return collapsedLanguages.contains(language.languageCode);
  }

  String toJson() {
    return jsonEncode({
      'name': name,
      'formatKey': formatKey,
      'order': order,
      'type': type.name,
      'metadata': jsonEncode(metadata),
      'hiddenLanguages': hiddenLanguages,
      'collapsedLanguages': collapsedLanguages,
    });
  }

  factory Dictionary.fromJson(String json) {
    final map = Map<String, dynamic>.from(jsonDecode(json));
    return Dictionary(
      name: map['name'] as String,
      formatKey: map['formatKey'] as String,
      order: map['order'] as int,
      type: DictionaryType.values.firstWhere(
        (e) => e.name == (map['type'] as String?),
        orElse: () => DictionaryType.term,
      ),
      metadata: Map<String, String>.from(
        jsonDecode(map['metadata'] as String? ?? '{}'),
      ),
      hiddenLanguages: List<String>.from(map['hiddenLanguages'] ?? []),
      collapsedLanguages: List<String>.from(map['collapsedLanguages'] ?? []),
    );
  }

  @override
  bool operator ==(Object other) => other is Dictionary && name == other.name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'Dictionary(name: $name, format: $formatKey, type: ${type.name})';
}
