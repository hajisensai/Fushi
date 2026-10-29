/// 「Fushi 卡片」笔记类型的字段名（单一真相源）。
///
/// 2026-10-29 改名：字段名即键名（Anki 里看到的、模板里写的、制卡映射的键都是同一个名字），
/// 不再沿用 Lapis 的历史命名。旧名（= Lapis 字段名）作**别名**保留：
/// - 读 / 写入口（AnkiConnect、`.apkg` 导入、映射偏好、复习页字段表）经 [canonical] /
///   [canonicalizeFields] 把旧名认成新名；
/// - 内置字段的 ID 仍按**旧名**派生（[legacyNameOf]），旧卡的字段值、同步日志、词状态零迁移。
///
/// Lapis 内置类型本身保持 Lapis 官方字段名，不受本表影响。
library;

class FushiCardFields {
  const FushiCardFields._();

  static const String term = 'Term';
  static const String termFurigana = 'TermFurigana';
  static const String termReading = 'TermReading';
  static const String termAudio = 'TermAudio';
  static const String lookupSelection = 'LookupSelection';
  static const String definitionMedia = 'DefinitionMedia';
  static const String media = 'Media';
  static const String frequencyRank = 'FrequencyRank';
  static const String source = 'Source';

  /// 新名 → 旧名（= Lapis 字段名）。只列改过名的字段。
  static const Map<String, String> legacyNames = <String, String>{
    term: 'Expression',
    termFurigana: 'ExpressionFurigana',
    termReading: 'ExpressionReading',
    termAudio: 'ExpressionAudio',
    lookupSelection: 'SelectionText',
    definitionMedia: 'DefinitionPicture',
    media: 'Picture',
    frequencyRank: 'FreqSort',
    source: 'MiscInfo',
  };

  /// 旧名 → 新名。
  static final Map<String, String> _aliases = <String, String>{
    for (final MapEntry<String, String> e in legacyNames.entries)
      e.value: e.key,
  };

  /// 把旧名认成新名；已经是新名或本来就没改名的字段原样返回。
  static String canonical(String name) => _aliases[name] ?? name;

  /// 字段 ID 的派生种子：改过名的用旧名（保持 ID 不变），其余用自己。
  static String legacyNameOf(String name) => legacyNames[name] ?? name;

  /// 从「字段名 → 值」里按**新名**取值；该字段还是旧名（Lapis 笔记、旧导入）时回退到旧名。
  static String? value(Map<String, String> fields, String name) =>
      fields[name] ?? fields[legacyNameOf(name)];

  /// 把一组「字段名 → 值」里的旧名统一成新名。新旧名同时出现时新名的值优先。
  static Map<String, String> canonicalizeFields(Map<String, String> fields) {
    final Map<String, String> out = <String, String>{};
    for (final MapEntry<String, String> e in fields.entries) {
      final String name = canonical(e.key);
      if (name != e.key && fields.containsKey(name)) continue;
      out[name] = e.value;
    }
    return out;
  }

  /// 把 [byName] 的键对到 [noteTypeFields] 实际有的名字上：键本身是字段就不动；不是，但它的
  /// 新名 / 旧名别名是字段（Anki 里已导出的 Fushi 卡片还是旧名、或映射偏好存的还是旧名），
  /// 就改用那个别名。对不上的键原样保留（交给调用方按原有规则过滤 / 报错）。
  /// 别名对应的字段名已被别的键占用时不改，避免覆盖用户配置。
  static Map<String, T> alignToFields<T>(
    Map<String, T> byName,
    Iterable<String> noteTypeFields,
  ) {
    final Set<String> fields = noteTypeFields.toSet();
    if (fields.isEmpty) return byName;
    final Map<String, T> out = <String, T>{};
    for (final MapEntry<String, T> e in byName.entries) {
      if (fields.contains(e.key)) out[e.key] = e.value;
    }
    for (final MapEntry<String, T> e in byName.entries) {
      if (fields.contains(e.key)) continue;
      final String? alias = _counterpart(e.key);
      if (alias != null && fields.contains(alias) && !out.containsKey(alias)) {
        out[alias] = e.value;
      } else {
        out[e.key] = e.value;
      }
    }
    return out;
  }

  /// 改名前后互为别名的另一个名字；没改过名的字段返回 null。
  static String? _counterpart(String name) {
    final String? legacy = legacyNames[name];
    if (legacy != null) return legacy;
    return _aliases[name];
  }
}
