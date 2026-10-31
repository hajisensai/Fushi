/// 词典管理页「按词典语言分组、组内独立排序」的**唯一推导处**（反馈 D_Nz5R4vSH：
/// 英语、日语两套词典放在一起管理和排序，希望能分开）。
///
/// ## 为什么不新增「组内序号」列
///
/// 查词优先级的真相源仍是每本词典的全局 [Dictionary.order]（混合词典在「汉字」
/// 分区是 [Dictionary.kanjiSectionOrder]）：引擎分桶、`termDictionaryOrder`、
/// 弹窗排序都只按它排，**一行都不用改**。分组只是这条全局序列按「有效语言」
/// 切出来的子序列：
///
/// * 组内顺序 = 全局序列里该组成员的相对先后——旧用户升级后零迁移，同组内的
///   相对顺序天然不变；
/// * 组内重排（[mergeLanguageGroupOrder]）只在**该组成员原来占的那些槽位**里
///   重新分配，其它组的词典一个槽位都不动；
/// * 组与组之间的交错顺序不被任何 UI 暴露，也就不影响用户能感知的优先级——
///   日语查询基本只命中日语词典，跨组的相对先后没有意义。
///
/// 所有者已否决「查词时按内容语言 / 学习语言过滤词典」：本文件只服务管理与排序，
/// 查词照旧查所有启用的词典。
library;

import 'dictionary.dart';

/// 一组词典：同一「有效语言」的词典，按分区顺序排好。
class DictionaryLanguageGroup {
  const DictionaryLanguageGroup({
    required this.language,
    required this.dictionaries,
  });

  /// 规范化后的 BCP-47 标签（见 [canonicalDictionaryLanguageTag]）；
  /// null = 「未标注语言」组（既没有手动指定、包内也没声明）。
  final String? language;

  /// 组内词典，保持传入分区列表里的先后。
  final List<Dictionary> dictionaries;
}

/// 把 BCP-47 标签规范成统一大小写，避免 `JA` / `ja`、`zh-hant` / `zh-Hant`
/// 被分成两组：主语言小写、4 字母文字子标签首字母大写、2 字母 / 3 位数字地区
/// 子标签大写，其余子标签小写；`_` 当 `-`。空白 / 空串返回 null。
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

/// 这本词典归哪一组：用户手动指定（[Dictionary.languageOverride]）优先，其次
/// 包内 `index.json` 的 `sourceLanguage`（即 [Dictionary.effectiveSourceLanguage]），
/// 都没有返回 null（「未标注语言」组）。
String? dictionaryLanguageGroupOf(Dictionary dictionary) =>
    canonicalDictionaryLanguageTag(dictionary.effectiveSourceLanguage);

/// 把一个分区（已按分区顺序排好）切成语言组。
///
/// 组的先后按「该组第一本词典在分区里出现的先后」——用户以前把哪种语言的词典
/// 排在前面，升级后那一组就在前面；「未标注语言」组固定放最后。组内保持分区顺序。
List<DictionaryLanguageGroup> groupDictionariesByLanguage(
  List<Dictionary> section,
) {
  final Map<String, List<Dictionary>> labelled = <String, List<Dictionary>>{};
  final List<Dictionary> unlabelled = <Dictionary>[];
  for (final Dictionary dictionary in section) {
    final String? language = dictionaryLanguageGroupOf(dictionary);
    if (language == null) {
      unlabelled.add(dictionary);
    } else {
      labelled.putIfAbsent(language, () => <Dictionary>[]).add(dictionary);
    }
  }
  return <DictionaryLanguageGroup>[
    for (final MapEntry<String, List<Dictionary>> entry in labelled.entries)
      DictionaryLanguageGroup(language: entry.key, dictionaries: entry.value),
    if (unlabelled.isNotEmpty)
      DictionaryLanguageGroup(language: null, dictionaries: unlabelled),
  ];
}

/// 组内重排后的新分区顺序：[reorderedGroup] 是某一组的新顺序，按分区里该组成员
/// 原来占的槽位依次填回，其它组的词典原位不动。
///
/// [reorderedGroup] 必须恰好是 [section] 里该组的全部成员（按 [Dictionary.name]
/// 比对），否则抛 [ArgumentError]——半组写回会把别组词典挤出槽位、静默改掉它们
/// 的查词优先级。
List<Dictionary> mergeLanguageGroupOrder(
  List<Dictionary> section,
  List<Dictionary> reorderedGroup,
) {
  if (reorderedGroup.isEmpty) return List<Dictionary>.of(section);
  final String? language = dictionaryLanguageGroupOf(reorderedGroup.first);
  final List<String> currentMembers = <String>[
    for (final Dictionary d in section)
      if (dictionaryLanguageGroupOf(d) == language) d.name,
  ];
  final List<String> newMembers = <String>[
    for (final Dictionary d in reorderedGroup) d.name,
  ];
  if (currentMembers.length != newMembers.length ||
      !Set<String>.of(currentMembers).containsAll(newMembers) ||
      Set<String>.of(newMembers).length != newMembers.length) {
    throw ArgumentError.value(
      newMembers,
      'reorderedGroup',
      'must be exactly the members of language group "$language" '
          '(${currentMembers.join(', ')})',
    );
  }
  final Iterator<Dictionary> next = reorderedGroup.iterator;
  return <Dictionary>[
    for (final Dictionary d in section)
      if (dictionaryLanguageGroupOf(d) == language)
        (next..moveNext()).current
      else
        d,
  ];
}

/// 比 [others] 里所有词典在任何分区的排序键都大的下一个序号。
///
/// 改了语言、换到别的组的词典用它当新序号：在新组（以及它出现的每个分区）里
/// 排最后。同时看 [Dictionary.order] 与 [Dictionary.kanjiSectionOrder]，因为
/// 混合词典在「汉字」分区有自己的序号空间。
int dictionaryOrderTailOf(Iterable<Dictionary> others) {
  int tail = -1;
  for (final Dictionary d in others) {
    if (d.order > tail) tail = d.order;
    if (d.kanjiSectionOrder > tail) tail = d.kanjiSectionOrder;
  }
  return tail + 1;
}
