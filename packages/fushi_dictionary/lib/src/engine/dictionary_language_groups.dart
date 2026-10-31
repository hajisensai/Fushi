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
/// * 管理页把各组**首尾相接**地画出来（组序见 [groupDictionariesByLanguage]），
///   用户读到的就是「组 1 全部 → 组 2 全部 → … → 未标注语言组」这一条顺序。
///   跨组的先后**并非无意义**：「未标注语言」组里常是没声明语言的日语包，
///   `ja` / `ja-JP` 也会分成两组，同一次日语查询会同时命中它们，弹窗按全局序排。
/// * 所以每次把一个分区写回（组内重排 [mergeLanguageGroupOrder] /
///   [moveDictionaryWithinLanguageGroup]、改语言换组 [sectionAfterLanguageChange]）
///   都把整个分区规范成「各组按显示顺序首尾相接」（[concatenateLanguageGroups]），
///   调用方再按下标 0..n-1 重编号——写过一次之后，管理页显示的顺序 ==
///   `termDictionaryOrder` / 汉字桶的真实查词顺序，旧数据里的跨组交错随之消掉。
///   从没写过的旧数据仍是交错的全局序（不在读路径上偷偷改用户的查词优先级）。
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

/// 分区的规范顺序：各语言组按显示顺序（[groupDictionariesByLanguage]）首尾相接。
///
/// 这就是管理页从上到下画出来的顺序。写回分区时一律按它重编号，显示顺序与
/// 真实查词顺序才是同一条（见文件头）。
List<Dictionary> concatenateLanguageGroups(List<Dictionary> section) =>
    <Dictionary>[
      for (final DictionaryLanguageGroup group in groupDictionariesByLanguage(
        section,
      ))
        ...group.dictionaries,
    ];

/// 组内重排后的新分区顺序：[reorderedGroup] 是某一组的新顺序；返回整个分区的
/// 规范顺序（[concatenateLanguageGroups]），其中该组换成新顺序，其它组的组内
/// 顺序与组序都不变。调用方按返回下标重编号。
///
/// [reorderedGroup] 必须恰好是 [section] 里该组的全部成员（按 [Dictionary.name]
/// 比对），否则抛 [ArgumentError]——半组写回会丢词典或重复词典。UI 不要拿渲染时
/// 捕获的旧组调它：组成员可能已被别处改过，用 [moveDictionaryWithinLanguageGroup]
/// 从最新分区重算。
List<Dictionary> mergeLanguageGroupOrder(
  List<Dictionary> section,
  List<Dictionary> reorderedGroup,
) {
  if (reorderedGroup.isEmpty) return concatenateLanguageGroups(section);
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
  return <Dictionary>[
    for (final DictionaryLanguageGroup group in groupDictionariesByLanguage(
      section,
    ))
      ...(group.language == language ? reorderedGroup : group.dictionaries),
  ];
}

/// 把 [section] 里名为 [name] 的词典挪到它**所在语言组**的最终下标 [to]（越界
/// 钳到组的两端），返回整个分区的新规范顺序（同 [mergeLanguageGroupOrder]）。
///
/// 组成员一律从 [section]（调用方传最新分区）现算，不信调用方手里的旧组：管理页
/// 的列表是渲染时捕获的，期间别处（ctl 路由、另一窗口、导入）改了语言或增删词典，
/// 拿旧组去合并就会因成员不符抛错。
///
/// 返回 null = 不用写：这本词典已不在分区里，或挪完位置不变。
List<Dictionary>? moveDictionaryWithinLanguageGroup(
  List<Dictionary> section,
  String name,
  int to,
) {
  final int index = section.indexWhere((Dictionary d) => d.name == name);
  if (index < 0) return null;
  final Dictionary moved = section[index];
  final String? language = dictionaryLanguageGroupOf(moved);
  final List<Dictionary> group = <Dictionary>[
    for (final Dictionary d in section)
      if (dictionaryLanguageGroupOf(d) == language) d,
  ];
  final int from = group.indexOf(moved);
  final int target = to.clamp(0, group.length - 1);
  if (target == from) return null;
  group
    ..removeAt(from)
    ..insert(target, moved);
  return mergeLanguageGroupOrder(section, group);
}

/// 改了语言之后 [section] 的新规范顺序：[updated] 是改完语言的那本（按
/// [Dictionary.name] 替换分区里的旧对象），排到它新组的最后；然后整个分区按
/// [concatenateLanguageGroups] 规范化。调用方按返回下标重编号。
///
/// 换到一个分区里原本没有的语言时，新组排在已有的已标注组之后（组序按首次
/// 出现）、「未标注语言」组之前。
List<Dictionary> sectionAfterLanguageChange(
  List<Dictionary> section,
  Dictionary updated,
) => concatenateLanguageGroups(<Dictionary>[
  for (final Dictionary d in section)
    if (d.name != updated.name) d,
  updated,
]);
