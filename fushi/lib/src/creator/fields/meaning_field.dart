import 'package:flutter/material.dart';
import 'package:fushi/creator.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:collection/collection.dart';

/// Used to return a formatted text from multiple dictionary entries.
class MeaningField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  MeaningField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Meaning',
          description: 'All dictionary definitions of a term.',
          icon: Icons.translate,
        );

  /// Get the singleton instance of this field.
  static MeaningField get instance => _instance;

  static final MeaningField _instance = MeaningField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'meaning';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_meaning;

  /// Get a single combined text for all meanings in a list of entries.
  static String flattenMeanings({
    required AppModel appModel,
    required List<DictionaryEntry> entries,
    required bool prependDictionaryNames,
  }) {
    StringBuffer meaningBuffer = StringBuffer();

    Map<String, List<DictionaryEntry>> entriesByDictionaryName =
        groupBy<DictionaryEntry, String>(
      entries,
      (entry) => entry.dictionaryName,
    );

    entriesByDictionaryName.forEach((dictionaryName, singleDictionaryEntries) {
      if (prependDictionaryNames) {
        // 词典改名（v95）刻意**不**翻这里：写进 Anki 卡片的正文是历史存档，改名
        // 不回溯——翻了之后同牌组里旧卡真名、新卡新名，比统一真名更难认。而且这个
        // 变量同时是上面 groupBy 的分组 key（与 {single-glossary-<名>} 模板 token
        // 对齐），要翻必须先把「分组键」和「显示文本」拆开。
        meaningBuffer.writeln('【$dictionaryName】');
      }

      for (DictionaryEntry entry in singleDictionaryEntries) {
        String meaning = entry.meaning.trim();
        meaningBuffer.write(meaning);
        meaningBuffer.write('\n');
      }

      meaningBuffer.write('\n');
    });

    return meaningBuffer.toString().trim();
  }
}
