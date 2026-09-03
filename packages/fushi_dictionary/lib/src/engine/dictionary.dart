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
      languageOverride: map['languageOverride'] as String?,
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
    this.languageOverride,
  });

  final String name;
  final String formatKey;
  int order;
  final DictionaryType type;
  final Map<String, String> metadata;
  List<String> hiddenLanguages;
  List<String> collapsedLanguages;

  /// 用户**手动指定**的词典内容语言（BCP-47，如 `ja` / `zh-Hant`）。null = 未指定。
  ///
  /// 与 [hiddenLanguages] / [collapsedLanguages] 同属「用户设置」：重导或在线更新
  /// 词典时由 `preservedSettings` 继承，不会被包内 index.json 冲掉。这与
  /// [sourceLanguage]（自动、随包刷新）是两个字段，不要合并。
  String? languageOverride;

  /// yomitan `index.json` 声明的**词头语言**（词典在解释哪种语言）。
  /// 导入时由 `readSourceMetadataFromIndex` 落进 [metadata]；旧词典/本地包缺则空串。
  String get sourceLanguage => metadata['sourceLanguage'] ?? '';

  /// yomitan `index.json` 声明的**释义语言**（词典用哪种语言解释）。
  ///
  /// 日中词典就是 `sourceLanguage: ja` + `targetLanguage: zh`——这正是「词头日文、
  /// 释义中文」这件事的结构性真值，不需要靠字符检测猜。
  String get targetLanguage => metadata['targetLanguage'] ?? '';

  /// 词头区（`.expression` / 振假名）实际该用的语言：用户指定优先，其次 index.json
  /// 的 sourceLanguage，都没有则 null（调用方不猜，见 `content_font_chain.dart`）。
  String? get effectiveSourceLanguage => _firstNonEmpty(
        <String?>[languageOverride, sourceLanguage],
      );

  /// 释义区实际该用的语言：用户指定优先（用户指定的是「这本词典是什么语言的」，
  /// 对单语词典而言词头和释义同语言），其次 index.json 的 targetLanguage。
  String? get effectiveTargetLanguage => _firstNonEmpty(
        <String?>[languageOverride, targetLanguage],
      );

  static String? _firstNonEmpty(List<String?> candidates) {
    for (final String? candidate in candidates) {
      final String trimmed = candidate?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

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
      'languageOverride': languageOverride,
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
