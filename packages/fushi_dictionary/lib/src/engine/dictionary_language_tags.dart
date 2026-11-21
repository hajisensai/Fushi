/// 词典管理页的「内容语言标签」：每本词典的有效语言只当**标签**用——行上挂一枚
/// 语言 tag、列表上方按语言筛选，**与排序无关**（拍板台 zBzX4B7037，取代反馈
/// D_Nz5R4vSH 时的「按语言分组、组内排序」：分组让新导入、自带语言声明的词典
/// 和没声明语言的老词典分在两组，彼此无法排先后）。
///
/// 查词优先级的唯一真相源是每本词典的全局 [Dictionary.order]（混合词典在「汉字」
/// 分区是 [Dictionary.kanjiSectionOrder]）：管理页从上到下就是这条序列，改语言
/// 不动任何序号。所有者已否决「查词时按内容语言 / 学习语言过滤词典」：本文件只
/// 服务管理页的标签与筛选，查词照旧查所有启用的词典。
library;

import 'dictionary.dart';

/// 把 BCP-47 标签规范成统一大小写，避免 `JA` / `ja`、`zh-hant` / `zh-Hant`
/// 被当成两种语言：主语言小写、4 字母文字子标签首字母大写、2 字母 / 3 位数字
/// 地区子标签大写，其余子标签小写；`_` 当 `-`。空白 / 空串返回 null。
String? canonicalDictionaryLanguageTag(String? tag) {
  final String trimmed = tag?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final List<String> parts = trimmed
      .split(RegExp('[-_]'))
      .where((String part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  final List<String> canonical = <String>[parts.first.toLowerCase()];
  for (final String part in parts.skip(1)) {
    if (part.length == 4 && RegExp(r'^[A-Za-z]{4}$').hasMatch(part)) {
      canonical.add(
        '${part.substring(0, 1).toUpperCase()}${part.substring(1).toLowerCase()}',
      );
    } else if (RegExp(r'^([A-Za-z]{2}|\d{3})$').hasMatch(part)) {
      canonical.add(part.toUpperCase());
    } else {
      canonical.add(part.toLowerCase());
    }
  }
  return canonical.join('-');
}

/// 这本词典的语言标签：用户手动指定（[Dictionary.languageOverride]）优先，其次
/// 包内 `index.json` 的 `sourceLanguage`（即 [Dictionary.effectiveSourceLanguage]），
/// 都没有返回 null（「未标注语言」）。
String? dictionaryLanguageTagOf(Dictionary dictionary) =>
    canonicalDictionaryLanguageTag(dictionary.effectiveSourceLanguage);

/// 一个分区里出现过的语言标签（筛选项），按在分区里首次出现的先后；有未标注
/// 语言的行时末尾放一个 null。对任意行类型：[languageOf] 给出一行的规范化
/// 语言标签（null = 未标注）。词典管理页把本机词典与服务器托管词典混排在同一个
/// 分区里（服务器行按 host 报的 `sourceLanguage`），筛选项也按这一份规则算。
List<String?> dictionaryLanguageTagsIn<T>(
  Iterable<T> section,
  String? Function(T row) languageOf,
) {
  final Set<String> labelled = <String>{};
  bool unlabelled = false;
  for (final T row in section) {
    final String? language = languageOf(row);
    if (language == null) {
      unlabelled = true;
    } else {
      labelled.add(language);
    }
  }
  return <String?>[...labelled, if (unlabelled) null];
}

/// 把 [section] 里键为 [key] 的行挪到整个分区的最终下标 [to]（越界钳到两端），
/// 返回新顺序；调用方按返回下标重编号。语言不参与：任何两本词典都能互相排先后。
///
/// 返回 null = 不用写：这一行已不在分区里，或挪完位置不变。
List<T>? moveDictionarySectionRow<T>(
  List<T> section,
  String Function(T row) keyOf,
  String key,
  int to,
) {
  final int from = section.indexWhere((T row) => keyOf(row) == key);
  if (from < 0) return null;
  final int target = to.clamp(0, section.length - 1);
  if (target == from) return null;
  final List<T> next = List<T>.of(section);
  final T moved = next.removeAt(from);
  next.insert(target, moved);
  return next;
}
