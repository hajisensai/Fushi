import 'dart:convert';

import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// 把 Hibiki 查词结果包装成 Yomitan `termEntries` 顶层响应形状（宽松兼容）。
///
/// 形状对照 `Kuuuube/yomitan-api` 的 termEntries.md：
/// `{ index, dictionaryEntries: [...], originalTextLength }`。
/// 展示字段（term/reading/glossary/frequency/pitch/wordClasses）真实，
/// 内部字段（score/sequences/tags 元数据/...）填合理默认——Hibiki 在导入时
/// 已丢弃这些数据，运行期无法还原。
Map<String, dynamic> buildYomitanTermEntriesResponse(
  DictionarySearchResult? result,
  int index,
) {
  final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
  if (result != null) {
    for (int i = 0; i < result.entries.length; i++) {
      entries.add(_buildDictionaryEntry(result.entries[i], i));
    }
  }
  return <String, dynamic>{
    'index': index,
    'dictionaryEntries': entries,
    'originalTextLength': result?.bestLength ?? 0,
  };
}

Map<String, dynamic> _buildDictionaryEntry(
  DictionaryEntry entry,
  int dictIndex,
) {
  final Map<String, dynamic> extra = _decodeExtra(entry.extra);
  final String matched = (extra['matched'] as String?) ?? entry.word;
  final String deinflected = (extra['deinflected'] as String?) ?? entry.word;
  final List<String> wordClasses = _splitTags(extra['definitionTags']);

  return <String, dynamic>{
    'type': 'term',
    'isPrimary': true,
    'textProcessorRuleChainCandidates': <List<String>>[<String>[]],
    'inflectionRuleChainCandidates': <Map<String, dynamic>>[
      <String, dynamic>{'source': 'algorithm', 'inflectionRules': <String>[]},
    ],
    'score': 0,
    'frequencyOrder': 0,
    'dictionaryIndex': dictIndex,
    'dictionaryAlias': entry.dictionaryName,
    'sourceTermExactMatchCount': 0,
    'matchPrimaryReading': false,
    'maxOriginalTextLength': matched.length,
    'headwords': <Map<String, dynamic>>[
      <String, dynamic>{
        'index': 0,
        'headwordIndex': 0,
        'term': entry.word,
        'reading': entry.reading,
        'sources': <Map<String, dynamic>>[
          <String, dynamic>{
            'originalText': matched,
            'transformedText': matched,
            'deinflectedText': deinflected,
            'matchType': 'exact',
            'matchSource': 'term',
            'isPrimary': true,
          },
        ],
        'tags': <dynamic>[],
        'wordClasses': wordClasses,
      },
    ],
    'definitions': <Map<String, dynamic>>[
      <String, dynamic>{
        'index': 0,
        'headwordIndices': <int>[0],
        'dictionary': entry.dictionaryName,
        'dictionaryIndex': dictIndex,
        'dictionaryAlias': entry.dictionaryName,
        'id': 0,
        'score': 0,
        'frequencyOrder': 0,
        'sequences': <int>[],
        'isPrimary': true,
        'tags': <dynamic>[],
        'entries': _glossaryEntries(entry.meaning),
      },
    ],
    'pronunciations': _pronunciations(extra['pitches']),
    'frequencies': _frequencies(extra['frequencies']),
  };
}

Map<String, dynamic> _decodeExtra(String extra) {
  try {
    final dynamic decoded = jsonDecode(extra);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    // extra 字段非合法 JSON：退化为空 metadata，不带音高/频率。
  }
  return <String, dynamic>{};
}

List<String> _splitTags(dynamic tags) {
  if (tags is! String) return <String>[];
  return tags
      .split(RegExp(r'\s+'))
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);
}

/// glossary：以 `[` 或 `{` 开头当 structured-content JSON 原样解析透传，否则当纯字符串。
List<dynamic> _glossaryEntries(String meaning) {
  final String trimmed = meaning.trimLeft();
  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    try {
      final dynamic decoded = jsonDecode(meaning);
      if (decoded is List) return decoded;
      return <dynamic>[decoded];
    } catch (_) {
      // 看似 JSON 但解析失败：退回当作纯文本 glossary。
    }
  }
  return <dynamic>[meaning];
}

List<Map<String, dynamic>> _frequencies(dynamic raw) {
  if (raw is! List) return <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  int idx = 0;
  for (final dynamic dictEntry in raw) {
    if (dictEntry is! Map) continue;
    final String dict = dictEntry['dictName']?.toString() ?? '';
    final dynamic values = dictEntry['values'];
    if (values is! List) continue;
    for (final dynamic v in values) {
      if (v is! Map) continue;
      final dynamic display = v['display'];
      out.add(<String, dynamic>{
        'index': idx++,
        'headwordIndex': 0,
        'dictionary': dict,
        'dictionaryIndex': 0,
        'dictionaryAlias': dict,
        'hasReading': false,
        'frequencyMode': 'rank-based',
        'frequency': (v['value'] as num?)?.toInt() ?? 0,
        'displayValue':
            (display is String && display.isNotEmpty) ? display : null,
        'displayValueParsed': false,
      });
    }
  }
  return out;
}

List<Map<String, dynamic>> _pronunciations(dynamic raw) {
  if (raw is! List) return <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  int idx = 0;
  for (final dynamic dictEntry in raw) {
    if (dictEntry is! Map) continue;
    final String dict = dictEntry['dictName']?.toString() ?? '';
    final dynamic positions = dictEntry['positions'];
    final List<int> pos = (positions is List)
        ? positions.whereType<num>().map((num n) => n.toInt()).toList()
        : <int>[];
    out.add(<String, dynamic>{
      'index': idx++,
      'headwordIndex': 0,
      'dictionary': dict,
      'dictionaryIndex': 0,
      'dictionaryAlias': dict,
      // 一个词典对一词可给多个候选 downstep：把 positions 列表摊平成
      // 多个 TermPronunciation（每个 int 一个 pitch-accent 对象）。
      // 注意 positions 是标量 number，不是 [p]。
      'pronunciations': pos
          .map(
            (int p) => <String, dynamic>{
              'type': 'pitch-accent',
              'positions': p,
              'nasalPositions': <int>[],
              'devoicePositions': <int>[],
              'tags': <dynamic>[],
            },
          )
          .toList(),
    });
  }
  return out;
}
