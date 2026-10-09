import 'dart:convert';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// dictionary 域控制通道的纯函数部分：词典 / 查词结果 / Anki 配置的 JSON 投影、
/// 按名定位词典、重排序与制卡字段拼装。不碰 [AppModel]，便于单测。

/// 一本词典给 CLI 的投影。`enabled` 与词典管理页的开关同一判据
/// （[Dictionary.isHidden] 对日语）。
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

/// 把 [target] 移到同类型词典列表里的 [position]（1 起算，越界钳到两端），
/// 返回重排后的整组（`order` 已按新下标改写）。与词典管理页 `_reorderDictionaries`
/// 同一语义：只在同一类型分区内排序。
List<Dictionary> ctlReorderDictionaries(
  List<Dictionary> sameType,
  Dictionary target,
  int position,
) {
  final List<Dictionary> clone = List<Dictionary>.of(sameType);
  final int from = clone.indexOf(target);
  if (from < 0) {
    throw CtlFailure.notFound('词典「${target.name}」不在 ${target.type.name} 分区里');
  }
  final Dictionary item = clone.removeAt(from);
  final int to = (position - 1).clamp(0, clone.length);
  clone.insert(to, item);
  for (int i = 0; i < clone.length; i++) {
    clone[i].order = i;
  }
  return clone;
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
  final Map<String, String> fields = <String, String>{
    'expression': word,
    'reading': resolvedReading,
    'matched': word,
    'glossary': resolvedGlossary,
    'sentence': sentence ?? '',
    ...extra,
  };
  return allowDuplicate ? AnkiMiningPayload.withAllowDuplicate(fields) : fields;
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
