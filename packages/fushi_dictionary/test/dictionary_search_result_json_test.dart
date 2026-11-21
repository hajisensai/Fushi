import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// BUG-5064：`DictionarySearchResult.fromJson` 的 `entries` 两种形式——规范的「逐条
/// toJson 字符串」与查词历史里出现过的「JSON 对象」——都要还原成同一份结果；别的
/// 类型照旧报格式错误。

DictionarySearchResult _sample() => DictionarySearchResult(
  searchTerm: '猫',
  bestLength: 1,
  headwordCount: 1,
  scrollPosition: 2,
  entries: <DictionaryEntry>[
    DictionaryEntry(
      dictionaryName: 'JMdict',
      word: '猫',
      reading: 'ねこ',
      meaning: 'cat',
      extra: 'n',
      popularity: 3,
    ),
  ],
);

void main() {
  test('规范格式往返不变，判为规范', () {
    final String json = _sample().toJson();
    final DictionarySearchResult back = DictionarySearchResult.fromJson(json);
    expect(back.toJson(), json);
    expect(
      DictionarySearchResult.hasCanonicalEntries(
        jsonDecode(json) as Map<String, dynamic>,
      ),
      isTrue,
    );
  });

  test('entries 存成对象：还原出同一份结果，判为非规范', () {
    final String canonical = _sample().toJson();
    final Map<String, dynamic> map =
        jsonDecode(canonical) as Map<String, dynamic>;
    map['entries'] = <Object?>[
      for (final Object? e in map['entries'] as List<Object?>)
        jsonDecode(e! as String),
    ];

    expect(DictionarySearchResult.hasCanonicalEntries(map), isFalse);
    final DictionarySearchResult back = DictionarySearchResult.fromJson(
      jsonEncode(map),
    );
    expect(back.toJson(), canonical);
  });

  test('entries 元素既不是字符串也不是对象：报格式错误', () {
    expect(
      () => DictionarySearchResult.fromJson(
        jsonEncode(<String, Object?>{
          'searchTerm': '猫',
          'entries': <Object?>[42],
        }),
      ),
      throwsFormatException,
    );
    expect(
      () => DictionarySearchResult.fromJson('[1, 2]'),
      throwsFormatException,
    );
  });
}
