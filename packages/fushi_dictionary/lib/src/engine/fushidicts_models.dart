/// fushidicts 查询/导入结果的纯 Dart 数据类。
///
/// 从 `fushidicts.dart` 切出来：那边持 FFI 绑定 + `rootBundle` 预热（`package:flutter/services`），
/// 而这些结果类被 `DictionarySearchResult` 等模型引用，需要进零 Flutter 的
/// `fushi_dictionary_core.dart` 闭包供无头服务端 `dart compile exe`。`fushidicts.dart`
/// 原样 re-export 本文件，既有 `import 'fushidicts.dart'` 调用方不受影响。
library;

// ── Dart data classes ───────────────────────────────────────────────

class FushiGlossaryEntry {
  const FushiGlossaryEntry({
    required this.dictName,
    required this.glossary,
    required this.definitionTags,
    required this.termTags,
  });
  final String dictName;
  final String glossary;
  final String definitionTags;
  final String termTags;
}

class FushiFrequency {
  const FushiFrequency({required this.value, required this.displayValue});
  final int value;
  final String displayValue;
}

class FushiFrequencyEntry {
  const FushiFrequencyEntry(
      {required this.dictName, required this.frequencies});
  final String dictName;
  final List<FushiFrequency> frequencies;
}

class FushiPitchEntry {
  const FushiPitchEntry({
    required this.dictName,
    required this.pitchPositions,
    this.patterns = const <String>[],
    this.transcriptions = const <String>[],
  });
  final String dictName;
  final List<int> pitchPositions;

  /// Pattern-style accents（Yomitan pitch 规格里 position 为字符串，如
  /// "heiban"）。数字位仍走 [pitchPositions]，两者分流（79c55c2 二期）。
  final List<String> patterns;

  /// IPA transcriptions for this dict's entry (Yomitan `ipa` meta mode). Empty
  /// for plain pitch-accent dicts. Carried alongside pitchPositions because both
  /// share the native PITCH bucket / query path (TODO-687 block3).
  final List<String> transcriptions;
}

/// lookup 排序模式（上游 bc62d2b）。enum index 即 FFI 的 freq_order 编码：
/// auto=0（既有比较器，零行为变化）/ ascending=1 / descending=2 / disabled=3。
enum FushiLookupFrequencyOrder { auto, ascending, descending, disabled }

class FushiTermResult {
  const FushiTermResult({
    required this.expression,
    required this.reading,
    required this.rules,
    required this.glossaries,
    required this.frequencies,
    required this.pitches,
  });
  final String expression;
  final String reading;
  final String rules;
  final List<FushiGlossaryEntry> glossaries;
  final List<FushiFrequencyEntry> frequencies;
  final List<FushiPitchEntry> pitches;
}

class FushiTransformGroup {
  const FushiTransformGroup({required this.name, required this.description});
  final String name;
  final String description;
}

class FushiLookupResult {
  const FushiLookupResult({
    required this.matched,
    required this.deinflected,
    required this.trace,
    required this.term,
    required this.preprocessorSteps,
  });
  final String matched;
  final String deinflected;
  final List<FushiTransformGroup> trace;
  final FushiTermResult term;
  final int preprocessorSteps;
}

class FushiImportResult {
  const FushiImportResult({
    required this.success,
    required this.title,
    required this.termCount,
    required this.metaCount,
    required this.freqCount,
    required this.pitchCount,
    required this.mediaCount,
    required this.kanjiCount,
    required this.detectedType,
    required this.error,
  });
  final bool success;
  final String title;
  final int termCount;
  final int metaCount;
  final int freqCount;
  final int pitchCount;
  final int mediaCount;
  final int kanjiCount;
  final String detectedType;
  final String error;
}

class FushiDictStyle {
  const FushiDictStyle({required this.dictName, required this.styles});
  final String dictName;
  final String styles;
}

class FushiKanjiResult {
  const FushiKanjiResult({
    required this.character,
    required this.onyomi,
    required this.kunyomi,
    required this.radical,
    required this.strokes,
    required this.meanings,
    this.stats = const <String, String>{},
    required this.dictName,
  });

  /// Reconstructs a kanji result from a map decoded out of a
  /// [DictionarySearchResult] JSON payload (e.g. when the popup process
  /// receives a serialized search result across the process boundary). Missing
  /// or null fields degrade to empty/zero so a partial payload never throws.
  factory FushiKanjiResult.fromMap(Map<String, dynamic> map) {
    return FushiKanjiResult(
      character: map['character'] as String? ?? '',
      onyomi: map['onyomi'] as String? ?? '',
      kunyomi: map['kunyomi'] as String? ?? '',
      radical: map['radical'] as String? ?? '',
      strokes: (map['strokes'] as num?)?.toInt() ?? 0,
      meanings: List<String>.from(map['meanings'] as List? ?? const <String>[]),
      stats: (map['stats'] as Map?)?.map(
            (Object? k, Object? v) =>
                MapEntry(k.toString(), v?.toString() ?? ''),
          ) ??
          const <String, String>{},
      dictName: map['dictName'] as String? ?? '',
    );
  }

  final String character;
  final String onyomi;
  final String kunyomi;
  final String radical;
  final int strokes;
  final List<String> meanings;

  /// v2 词典的完整 stats 键值对（JLPT/grade 等，radical/strokes 之外）；
  /// v1 存量词典恒为空 map。
  final Map<String, String> stats;
  final String dictName;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'character': character,
        'onyomi': onyomi,
        'kunyomi': kunyomi,
        'radical': radical,
        'strokes': strokes,
        'meanings': meanings,
        'stats': stats,
        'dictName': dictName,
      };
}
