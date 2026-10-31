import 'dart:convert';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart' show PendingMineRow;
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/anki/pending_mining/pending_mining_anki_repository.dart'
    show PendingFlushReport;
import 'package:fushi/src/creator/fields/frequency_field.dart'
    show FrequencyField;
import 'package:fushi/src/creator/fields/pitch_accent_field.dart'
    show PitchAccentField;

/// dictionary 域控制通道的纯函数部分：词典 / 查词结果 / Anki 配置的 JSON 投影、
/// 按名定位词典、重排序与制卡字段拼装。不碰 [AppModel]，便于单测。

/// 一本词典给 CLI 的投影。`enabled` 与词典管理页的开关同一判据
/// （[Dictionary.isHidden] 对日语）。
///
/// 混合词典（term + 内附汉字，BUG-3573）另带汉字部分的两项：`kanjiEnabled`
/// （「汉字」分区里的开关，[Dictionary.isKanjiPartHidden]）与 `kanjiOrder`
/// （在「汉字」分区的排序键，[Dictionary.kanjiSectionOrder]；用户没在汉字分区排过时
/// 等于术语 `order`）。纯 kanji 词典的汉字分区开关 / 位置就是 `enabled` / `order`。
Map<String, Object?> ctlDictionaryJson(Dictionary dictionary) =>
    <String, Object?>{
      'name': dictionary.name,
      'displayName': dictionary.effectiveDisplayName,
      'type': dictionary.type.name,
      'order': dictionary.order,
      'enabled': !dictionary.isHidden(JapaneseLanguage.instance),
      'format': dictionary.formatKey,
      'revision': dictionary.revision,
      'updatable': dictionary.isUpdatable,
      if (dictionary.hasEmbeddedKanji) ...<String, Object?>{
        'kanjiEnabled': !dictionary.isKanjiPartHidden,
        'kanjiOrder': dictionary.kanjiSectionOrder,
      },
      // 显示名 / 内容语言的用户覆盖（null = 没改过，走包内声明）。
      'customDisplayName': dictionary.displayName,
      'languageOverride': dictionary.languageOverride,
      if (dictionary.effectiveSourceLanguage != null)
        'sourceLanguage': dictionary.effectiveSourceLanguage,
      if (dictionary.effectiveTargetLanguage != null)
        'targetLanguage': dictionary.effectiveTargetLanguage,
    };

/// 词典按「类型 → 顺序」排好，与词典管理页分区展示的顺序一致。
List<Dictionary> ctlSortedDictionaries(List<Dictionary> dictionaries) {
  final List<Dictionary> sorted = List<Dictionary>.of(dictionaries);
  sorted.sort((Dictionary a, Dictionary b) {
    final int byType = a.type.index.compareTo(b.type.index);
    return byType != 0 ? byType : a.order.compareTo(b.order);
  });
  return sorted;
}

/// 按名字找词典：先真名精确，再显示名精确，最后忽略大小写；
/// 多本同时命中同一档时报歧义（不猜）。找不到抛 404。
Dictionary resolveCtlDictionary(List<Dictionary> dictionaries, String query) {
  final String q = query.trim();
  final List<bool Function(Dictionary)> tiers = <bool Function(Dictionary)>[
    (Dictionary d) => d.name == q,
    (Dictionary d) => d.effectiveDisplayName == q,
    (Dictionary d) =>
        d.name.toLowerCase() == q.toLowerCase() ||
        d.effectiveDisplayName.toLowerCase() == q.toLowerCase(),
  ];
  for (final bool Function(Dictionary) matches in tiers) {
    final List<Dictionary> hits = dictionaries.where(matches).toList();
    if (hits.length == 1) return hits.single;
    if (hits.length > 1) {
      throw CtlFailure.badRequest(
        '「$q」匹配到多本词典：${hits.map((Dictionary d) => d.name).join('、')}，请用真名',
      );
    }
  }
  throw CtlFailure.notFound('没有名为「$q」的词典（fushi_cli dict ls 查看）');
}

/// 把 [target] 移到它**所在语言组**里的 [position]（1 起算，越界钳到组的两端），
/// 返回重排后的整个分区（`order` 已按新下标改写）。与词典管理页
/// `_reorderDictionaries` 同一语义（反馈 D_Nz5R4vSH）：分区按「有效语言」分组
/// （[groupDictionariesByLanguage]），排序只在组内进行；组内挪完后经
/// [mergeLanguageGroupOrder] 填回该组原占的槽位，其它组的词典位置一个不动。
/// 分区里只有一个语言组时就是整个分区内排序。
///
/// [sameType] 是一个分区（已按分区顺序排好）；[section] 是分区名（报错用），
/// 缺省按 [target] 自身类型。混合词典在「汉字」分区排序时传 `kanji`。
List<Dictionary> ctlReorderDictionaries(
  List<Dictionary> sameType,
  Dictionary target,
  int position, {
  DictionaryType? section,
}) {
  final int sectionIndex = sameType.indexWhere(
    (Dictionary d) => d.name == target.name,
  );
  if (sectionIndex < 0) {
    throw CtlFailure.notFound(
      '词典「${target.name}」不在 ${(section ?? target.type).name} 分区里',
    );
  }
  final Dictionary member = sameType[sectionIndex];
  final String? language = dictionaryLanguageGroupOf(member);
  final List<Dictionary> group = <Dictionary>[
    for (final Dictionary d in sameType)
      if (dictionaryLanguageGroupOf(d) == language) d,
  ];
  group.remove(member);
  group.insert((position - 1).clamp(0, group.length), member);
  final List<Dictionary> merged = mergeLanguageGroupOrder(sameType, group);
  for (int i = 0; i < merged.length; i++) {
    merged[i].order = i;
  }
  return merged;
}

/// 校验 `PUT /api/admin/dictionaries/:name` 的汉字部分参数（BUG-3573）。
///
/// - `kanjiEnabled` 只对混合词典有意义：纯 kanji 词典的开关就是 `enabled`，纯术语
///   词典没有汉字部分——给了就 400，而不是静默写一个没人读的键。
/// - `kanjiPosition`（1 起算）对「汉字」分区里的任何一本都可用（纯 kanji 词典与
///   `position` 等价）。
void ctlCheckKanjiPartParams(
  Dictionary target, {
  bool? kanjiEnabled,
  int? kanjiPosition,
}) {
  if (kanjiEnabled != null && !target.hasEmbeddedKanji) {
    throw CtlFailure.badRequest(
      target.type == DictionaryType.kanji
          ? '「${target.name}」是汉字词典，开关用 enabled'
          : '「${target.name}」没有内附汉字部分，kanjiEnabled 不适用',
    );
  }
  if (kanjiPosition != null) {
    if (!target.isInKanjiSection) {
      throw CtlFailure.badRequest(
        '「${target.name}」不在「汉字」分区里，kanjiPosition 不适用',
      );
    }
    if (kanjiPosition < 1) {
      throw const CtlFailure.badRequest('kanjiPosition 从 1 起算');
    }
  }
}

/// 查词结果的结构化投影：词条 / 读音 / 词典 / 纯文本释义。
///
/// [maxMeaningChars] 截断单条释义（0 = 不截断），防止整本大辞典的长释义灌满终端。
Map<String, Object?> ctlSearchResultJson(
  String term,
  DictionarySearchResult? result, {
  int maxMeaningChars = 0,
}) {
  if (result == null) {
    return <String, Object?>{
      'term': term,
      'bestLength': 0,
      'truncated': false,
      'entries': const <Object?>[],
    };
  }
  return <String, Object?>{
    'term': term,
    'bestLength': result.bestLength,
    'truncated': result.truncated,
    'headwordCount': result.headwordCount,
    'kanjiCount': result.kanjiResults.length,
    'entries': <Map<String, Object?>>[
      for (final DictionaryEntry entry in result.entries)
        <String, Object?>{
          'word': entry.word,
          'reading': entry.reading,
          'dictionary': entry.dictionaryName,
          'meaning': _clip(entry.plainMeaning.trim(), maxMeaningChars),
          if (entry.popularity != 0) 'popularity': entry.popularity,
        },
    ],
  };
}

String _clip(String text, int max) =>
    max <= 0 || text.length <= max ? text : '${text.substring(0, max)}…';

/// `anki mine` 的制卡字段：显式给的优先；没给读音 / 释义时，从查词结果里与
/// [word] 同词头的词条补（读音取第一条，释义按词典分组、`【词典名】` 打头，
/// 与 [MeaningField.flattenMeanings] 同一版式，换行转 `<br>` 写进 HTML 字段）。
///
/// 只补「CLI 能可靠拿到」的字段；音调 / 频率 / 词典图片等由 popup.js 现场渲染的
/// 字段 CLI 侧拿不到，留空（Anki 字段映射里引用到的会是空串）。
Map<String, String> buildCtlMineFields({
  required String word,
  String? reading,
  String? sentence,
  String? glossary,
  Map<String, String> extra = const <String, String>{},
  DictionarySearchResult? lookup,
  bool allowDuplicate = false,
}) {
  final List<DictionaryEntry> sameWord = lookup == null
      ? const <DictionaryEntry>[]
      : lookup.entries
            .where((DictionaryEntry e) => e.word == word)
            .toList(growable: false);
  final String resolvedReading =
      reading ?? (sameWord.isEmpty ? '' : sameWord.first.reading);
  final List<DictionaryEntry> glossEntries = sameWord
      .where(
        (DictionaryEntry e) =>
            resolvedReading.isEmpty ||
            e.reading.isEmpty ||
            e.reading == resolvedReading,
      )
      .toList(growable: false);
  final String resolvedGlossary = glossary ?? _glossaryHtml(glossEntries);
  // 词头级的振假名 / 频率 / 音调：同一个词头的各词典条目共享这份数据（引擎把它写进
  // 每条的 extra），取第一条即可。值由创作器字段的同名生成函数算出，与弹窗制卡
  // 填进同名字段（furiganaPlain / freqHarmonicRank / frequenciesHtml /
  // pitchPositions / pitchCategories）的语义一致。
  final DictionaryEntry? headword = glossEntries.isNotEmpty
      ? glossEntries.first
      : (sameWord.isEmpty ? null : sameWord.first);
  final Map<String, String> fields = <String, String>{
    'expression': word,
    'reading': resolvedReading,
    'matched': word,
    'glossary': resolvedGlossary,
    'sentence': sentence ?? '',
    if (headword != null) ...ctlHeadwordMineFields(headword, resolvedReading),
    ...extra,
  };
  return allowDuplicate ? AnkiMiningPayload.withAllowDuplicate(fields) : fields;
}

/// 一个词头的无头制卡字段：`furiganaPlain`（与弹窗 `constructFuriganaPlain` 同格式：
/// 有注音的段 `漢字[かな]`、无注音的段后跟空格）、频率与音调（创作器字段的生成函数）。
/// 空值不写，免得盖掉调用方 / 模板的缺省。
Map<String, String> ctlHeadwordMineFields(
  DictionaryEntry entry,
  String reading,
) {
  final Map<String, String> out = <String, String>{};
  if (reading.isNotEmpty && reading != entry.word) {
    final StringBuffer furigana = StringBuffer();
    for (final RubyTextData segment in LanguageUtils.distributeFurigana(
      entry: entry.reading == reading
          ? entry
          : DictionaryEntry(
              dictionaryName: entry.dictionaryName,
              word: entry.word,
              reading: reading,
              meaning: entry.meaning,
              extra: entry.extra,
            ),
    )) {
      final String? ruby = segment.ruby;
      furigana.write(
        ruby != null && ruby.isNotEmpty
            ? '${segment.text}[$ruby]'
            : '${segment.text} ',
      );
    }
    out['furiganaPlain'] = furigana.toString();
  }
  for (final MapEntry<String, String> e in <String, String>{
    ...FrequencyField.extraValuesFromEntry(entry),
    ...PitchAccentField.extraValuesFromEntry(entry: entry),
  }.entries) {
    if (e.value.isNotEmpty) out[e.key] = e.value;
  }
  return out;
}

String _glossaryHtml(List<DictionaryEntry> entries) {
  if (entries.isEmpty) return '';
  final Map<String, List<String>> byDictionary = <String, List<String>>{};
  for (final DictionaryEntry entry in entries) {
    final String meaning = entry.plainMeaning.trim();
    if (meaning.isEmpty) continue;
    byDictionary
        .putIfAbsent(entry.dictionaryName, () => <String>[])
        .add(meaning);
  }
  const HtmlEscape escape = HtmlEscape(HtmlEscapeMode.element);
  return byDictionary.entries
      .map(
        (MapEntry<String, List<String>> group) => <String>[
          '【${escape.convert(group.key)}】',
          for (final String m in group.value)
            escape.convert(m).replaceAll('\n', '<br>'),
        ].join('<br>'),
      )
      .join('<br><br>');
}

/// Anki 牌组列表投影，标出当前选中的那个。
List<Map<String, Object?>> ctlAnkiDecksJson(
  List<AnkiDeck> decks,
  AnkiSettings settings,
) => <Map<String, Object?>>[
  for (final AnkiDeck deck in decks)
    <String, Object?>{
      'id': deck.id,
      'name': deck.name,
      'selected':
          deck.id == settings.selectedDeckId ||
          (settings.selectedDeckId == null &&
              deck.name == settings.selectedDeckName),
    },
];

/// Anki 笔记类型列表投影（含字段名），标出当前选中的那个。
List<Map<String, Object?>> ctlAnkiModelsJson(
  List<AnkiNoteType> noteTypes,
  AnkiSettings settings,
) => <Map<String, Object?>>[
  for (final AnkiNoteType type in noteTypes)
    <String, Object?>{
      'id': type.id,
      'name': type.name,
      'fields': type.fields,
      'selected':
          type.id == settings.selectedNoteTypeId ||
          (settings.selectedNoteTypeId == null &&
              type.name == settings.selectedNoteTypeName),
    },
];

/// 推荐词典目录条目的投影：`index` 是该目录里的位置，`installed` 与词典管理页
/// 「推荐词典」弹窗同一判据（调用方传入）。
Map<String, Object?> ctlRecommendedDictionaryJson(
  RecommendedDictionary rec, {
  required int index,
  required bool installed,
  required bool isDefault,
}) => <String, Object?>{
  'index': index,
  'name': rec.name,
  'key': rec.matchPrefix,
  'category': rec.category.name,
  'size': rec.sizeEstimate,
  'description': rec.description,
  'installed': installed,
  'default': isDefault,
};

/// 在推荐词典目录里按 `key`（matchPrefix）或展示名定位一条；精确优先，其次忽略大小写。
RecommendedDictionary resolveCtlRecommendedDictionary(
  List<RecommendedDictionary> catalog,
  String query,
) {
  final String q = query.trim();
  final List<bool Function(RecommendedDictionary)> tiers =
      <bool Function(RecommendedDictionary)>[
        (RecommendedDictionary r) => r.matchPrefix == q || r.name == q,
        (RecommendedDictionary r) =>
            r.matchPrefix.toLowerCase() == q.toLowerCase() ||
            r.name.toLowerCase() == q.toLowerCase(),
      ];
  for (final bool Function(RecommendedDictionary) matches in tiers) {
    final List<RecommendedDictionary> hits = catalog.where(matches).toList();
    if (hits.length == 1) return hits.single;
    if (hits.length > 1) {
      throw CtlFailure.badRequest(
        '「$q」匹配到多条推荐词典：${hits.map((RecommendedDictionary r) => r.matchPrefix).join('、')}',
      );
    }
  }
  throw CtlFailure.notFound('推荐词典目录里没有「$q」（fushi_cli dict recommended 查看）');
}

/// 待发队列一行给 CLI 的投影。
Map<String, Object?> ctlPendingMineJson(PendingMineRow row) =>
    <String, Object?>{
      'id': row.id,
      'expression': row.expression,
      'reading': row.reading,
      'status': row.status,
      'attempts': row.attempts,
      'createdAt': row.createdAt,
      if (row.lastError != null) 'lastError': row.lastError,
      if (row.lastAttemptAt != null) 'lastAttemptAt': row.lastAttemptAt,
      // 来自其他设备中转的卡（本机作为落地设备替它交给 Anki）。
      if (row.originDeviceId != null) 'originDeviceId': row.originDeviceId,
    };

/// 按 id（或唯一前缀）在队列里定位一行；多行同前缀报歧义，找不到 404。
PendingMineRow resolveCtlPendingMine(List<PendingMineRow> rows, String query) {
  final String q = query.trim();
  final List<PendingMineRow> exact = rows
      .where((PendingMineRow r) => r.id == q)
      .toList();
  if (exact.length == 1) return exact.single;
  final List<PendingMineRow> hits = rows
      .where((PendingMineRow r) => q.isNotEmpty && r.id.startsWith(q))
      .toList();
  if (hits.length == 1) return hits.single;
  if (hits.length > 1) {
    throw CtlFailure.badRequest('id 前缀「$q」匹配到多张待发卡，请给更长的 id');
  }
  throw CtlFailure.notFound('待发队列里没有「$q」（fushi_cli anki pending 查看）');
}

/// 一次补发结果的投影。
Map<String, Object?> ctlFlushReportJson(PendingFlushReport report) =>
    <String, Object?>{
      'delivered': report.delivered,
      'failed': report.failed,
      'remaining': report.remaining,
      'unreachable': report.unreachable,
      'skipped': report.skipped,
      'awaitingConfirmation': report.awaitingConfirmation,
    };

/// 词典内容语言覆盖的取值：`auto`（或 `-`）= 恢复自动（null），其余当 BCP-47 码原样用。
String? ctlParseLanguageOverride(String raw) {
  final String v = raw.trim();
  if (v.isEmpty) throw const CtlFailure.badRequest('language 不能为空');
  final String lower = v.toLowerCase();
  return (lower == 'auto' || lower == '-') ? null : v;
}
