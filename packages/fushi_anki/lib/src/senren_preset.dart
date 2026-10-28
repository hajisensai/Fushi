import 'anki_models.dart';

/// Senren（https://brenoaqua.github.io/Senren/）笔记类型预设。
///
/// Senren 的字段名是 camelCase（`word` / `wordAudio` / `pitchAccents` …），和 Lapis /
/// Kiku 的字段名不重合，所以 [LapisPreset] 认不出它；按字段名推默认映射的兜底只认得
/// 一小部分（音高 / 词频排序 / 来源 / 选中文本全是空的）。
class SenrenPreset {
  static const String modelName = 'Senren';

  /// 字段 → Fushi 占位符。未列出的字段故意留空：`sentenceFurigana`（Fushi 没有对应
  /// 占位符）、`sentenceTranslation` / `sentenceCard` / `audioCard` / `notes` /
  /// `dictionaryPreference` 是用户手填或卡型开关。
  static const Map<String, String> defaultFieldMappings = <String, String>{
    'word': '{expression}',
    'reading': '{reading}',
    'sentence': '{sentence}',
    'selectionText': '{popup-selection-text}',
    'definition': '{glossary-first}',
    'wordAudio': '{audio}',
    'sentenceAudio': '{sentence-audio}',
    'picture': '{card-image}',
    'glossary': '{glossary}',
    'pitchPositions': '{pitch-accent-positions}',
    'pitchCategories': '{pitch-accent-categories}',
    'frequencies': '{frequencies}',
    'freqSort': '{frequency-harmonic-rank}',
    'miscInfo': '{source-link} {clip-timestamp}',
  };

  static bool matches(AnkiNoteType noteType) {
    final Set<String> fields = noteType.fields.toSet();
    return noteType.name.toLowerCase().contains('senren') ||
        <String>['word', 'sentence', 'wordAudio'].every(fields.contains);
  }

  static Map<String, String> defaultMappings(AnkiNoteType noteType) => {
    for (final String f in noteType.fields)
      if (defaultFieldMappings.containsKey(f)) f: defaultFieldMappings[f]!,
  };
}
