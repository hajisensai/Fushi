import 'anki_models.dart';

/// Senren（https://brenoaqua.github.io/Senren/）笔记类型预设。
///
/// Senren 的字段名是 camelCase（`word` / `wordAudio` / `pitchAccents` …），和 Lapis /
/// Kiku 的字段名不重合，所以 Lapis 预设认不出它；按字段名推默认映射的兜底只认得
/// 一小部分（音高 / 词频排序 / 来源 / 选中文本全是空的）。
///
/// 只负责「认出它」与「它的默认映射」；分派统一走 `NoteTypePresets`。
abstract final class SenrenPreset {
  static const String modelName = 'Senren';

  /// 字段 → Fushi 占位符。未列出的字段故意留空：`sentenceFurigana` / `pitchAccents`
  /// （Fushi 没有对应占位符）、`sentenceTranslation` / `sentenceCard` / `audioCard` /
  /// `notes` / `hint` / `dictionaryPreference` 是用户手填或卡型开关。
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

  /// 改过名的 Senren 副本靠这组字段认：camelCase 的 `selectionText` / `freqSort` /
  /// `pitchCategories` 加上 `word` / `wordAudio` 是 Senren 特有组合。只有
  /// `word` / `sentence` / `wordAudio` 的用户自建笔记类型不算——否则会被套上 Senren
  /// 映射，并在默认选卡时被优先选中。
  static const List<String> signatureFields = <String>[
    'word',
    'wordAudio',
    'selectionText',
    'pitchCategories',
    'freqSort',
  ];

  static bool matches(AnkiNoteType noteType) {
    final Set<String> fields = noteType.fields.toSet();
    return noteType.name.toLowerCase().contains('senren') ||
        signatureFields.every(fields.contains);
  }

  static Map<String, String> defaultMappings(AnkiNoteType noteType) => {
    for (final String f in noteType.fields)
      if (defaultFieldMappings.containsKey(f)) f: defaultFieldMappings[f]!,
  };
}
