import 'dart:convert';

import '../language/language.dart';

enum DictionaryType { term, frequency, pitch, kanji }

class Dictionary {
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

  /// TODO-609：在线来源词典的版本号（yomitan index.json 的 revision），导入时
  /// 由 [readSourceMetadataFromIndex] 落进 [metadata]。本地/旧词典缺则空串。
  String get revision => metadata['revision'] ?? '';

  /// TODO-609：远端 index.json 的可访问 URL（yomidevs releases/latest 天然可更新）。
  String get indexUrl => metadata['indexUrl'] ?? '';

  /// TODO-609：词典包（zip）的下载 URL，更新时据此重新下载并强制重导。
  String get downloadUrl => metadata['downloadUrl'] ?? '';

  /// TODO-609：是否可在线检查更新（三条件与门）。必须 yomitan index 声明
  /// `isUpdatable` 且远端 index URL + 下载 URL 都存在，缺一不可——旧词典 / 本地
  /// 导入词典 metadata 为空 → 三条件全不满足 → false（不显示更新按钮、不崩）。
  bool get isUpdatable =>
      metadata['isUpdatable'] == 'true' &&
      indexUrl.isNotEmpty &&
      downloadUrl.isNotEmpty;

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

  @override
  bool operator ==(Object other) => other is Dictionary && name == other.name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() =>
      'Dictionary(name: $name, format: $formatKey, type: ${type.name})';
}
