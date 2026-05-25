import 'dart:convert';

class DictionaryEntry {
  factory DictionaryEntry.fromJson(String json) {
    final map = Map<String, dynamic>.from(jsonDecode(json));
    return DictionaryEntry(
      dictionaryName: map['dictionaryName'] as String? ?? '',
      word: map['word'] as String? ?? '',
      reading: map['reading'] as String? ?? '',
      meaning: map['meaning'] as String? ?? '',
      extra: (map['extra'] ?? '').toString(),
      popularity: (map['popularity'] as num?)?.toDouble() ?? 0,
    );
  }
  DictionaryEntry({
    this.id,
    this.dictionaryName = '',
    this.word = '',
    this.reading = '',
    this.meaning = '',
    this.extra = '',
    this.popularity = 0,
  });

  int? id;

  final String dictionaryName;

  final String word;

  final String reading;

  final String meaning;

  final String extra;

  final double popularity;

  int get wordLength => word.length;

  String get plainMeaning => meaningToPlainText(meaning);

  static String meaningToPlainText(String meaning) {
    if (meaning.isEmpty) return meaning;
    try {
      final dynamic parsed = jsonDecode(meaning);
      return _structuredToText(parsed).trim();
    } catch (_) {
      return meaning;
    }
  }

  static String _structuredToText(dynamic content) {
    if (content is String) return content;
    if (content is List) {
      return content.map(_structuredToText).join();
    }
    if (content is Map) {
      final dynamic tag = content['tag'];
      final dynamic inner = content['content'];
      final String childText = inner != null ? _structuredToText(inner) : '';
      if (tag == 'br') return '\n';
      if (tag == 'li') return '• $childText\n';
      if (tag == 'img') return (content['description'] ?? '') as String;
      return childText;
    }
    return content?.toString() ?? '';
  }

  Map<dynamic, dynamic> workingArea = {};

  String toJson() {
    return jsonEncode({
      'dictionaryName': dictionaryName,
      'word': word,
      'reading': reading,
      'meaning': meaning,
      'extra': extra,
      'popularity': popularity,
    });
  }

  @override
  bool operator ==(Object other) =>
      other is DictionaryEntry &&
      other.word == word &&
      other.reading == reading &&
      other.meaning == meaning;

  @override
  int get hashCode => Object.hash(word, reading, meaning);

  bool get isEmpty => word.isEmpty && reading.isEmpty && meaning.isEmpty;

  @override
  String toString() =>
      'DictionaryEntry(word: $word, reading: $reading, meaning: $meaning)';
}
