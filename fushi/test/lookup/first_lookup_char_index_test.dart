import 'package:test/test.dart';
import 'package:fushi/src/lookup/sentence_extraction.dart';

/// 反馈 q9Jcu_Zr2_：文本钩子「新句自动查词」的起查字——句首的空白、引号括号与
/// 标点不是词，自动查词要落在第一个可查的字上。
void main() {
  test('跳过句首空白与开引号，落在第一个可查字', () {
    expect(firstLookupCharIndex('今日は晴れ'), 0);
    expect(firstLookupCharIndex('「今日は晴れ」'), 1);
    expect(firstLookupCharIndex('　『……ああ』'), 4);
    expect(firstLookupCharIndex('（ため息）'), 1);
    expect(firstLookupCharIndex('  "Hello"'), 3);
  });

  test('踊り字、长音、数字都算可查字', () {
    expect(firstLookupCharIndex('「々」'), 1);
    expect(firstLookupCharIndex('…ーっ'), 1);
    expect(firstLookupCharIndex('──３人'), 2);
  });

  test('整句没有可查字时返回 null，调用方据此不弹卡', () {
    expect(firstLookupCharIndex(''), isNull);
    expect(firstLookupCharIndex('「……」'), isNull);
    expect(firstLookupCharIndex('！？　'), isNull);
  });

  test('起查下标交给 lookupQueryFromIndex 得到非空查询串', () {
    const String line = '「永遠に続く」';
    final int index = firstLookupCharIndex(line)!;
    expect(lookupQueryFromIndex(line, index), '永遠に続く」');
  });
}
