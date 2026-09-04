import 'dart:convert';

import '../language/language.dart';

enum DictionaryType { term, frequency, pitch, kanji }

/// [Dictionary.metadata] 里记录「启动期类型自愈探测已经做过了」的键。
///
/// 为什么需要一个显式的键，而不是从 `hasKanji` 之类的结果反推：反推会把「没探测过」
/// 和「探测过、结果是什么都不用改」压成同一个状态（都表现为「没有标记」）。启动期
/// 的自愈逻辑于是只能对每一本**每次启动都重探一遍**——而 kanji 词典的探测是把整张
/// hash 表扫完、逐槽随机跳读 blobs.bin，纯 kanji 词典还永远触发不了「term+kanji 都
/// 找到」的提前退出条件，所以扫的是全表。手机冷缓存下这就是每本几万次随机页访问，
/// 词典一多，启动直接卡死在这里（用户报告：一次性导入很多词典后 app 打不开）。
///
/// 把「探测过」变成一等状态后，每本词典一生只探一次；导入路径更是连一次都不用探
/// （native 导入时已经数过 term/kanji 记录，结果直接写进来）。
///
/// 值是**探测器版本号**而不是 `'true'`：将来探测逻辑改了，只要 bump
/// [kDictTypeProbeVersion]，存量词典就会自动重探一轮，而不必再发明一个新键。
const String kDictTypeProbeKey = 'typeProbe';

/// 当前类型探测器的版本。改探测语义时 +1（见 [kDictTypeProbeKey]）。
const String kDictTypeProbeVersion = '1';

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

  /// 启动期类型自愈探测是否已经对这本词典做过（且是当前版本的探测器）。
  ///
  /// false = 需要探一次（老词典、或探测器版本 bump 后的存量）。见
  /// [kDictTypeProbeKey] 里关于「为什么不能从探测结果反推」的说明。
  bool get isTypeProbed => metadata[kDictTypeProbeKey] == kDictTypeProbeVersion;

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
