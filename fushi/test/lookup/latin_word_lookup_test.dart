import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/latin_word_lookup.dart';

/// BUG-2847：悬浮球查词（截屏识字 / 剪贴板 / 悬浮字幕）取词未适配英语。
void main() {
  /// 假分词器：记下起点，按「从起点起的最长前缀 ∈ [dict]」回报，否则单个字。
  ({
    List<int> starts,
    String Function({required String text, required int index}) scan,
  })
  fakeScanner(Set<String> dict) {
    final List<int> starts = <int>[];
    String scan({required String text, required int index}) {
      starts.add(index);
      final String rest = text.substring(index);
      for (int len = rest.length; len > 0; len--) {
        if (dict.contains(rest.substring(0, len))) {
          return rest.substring(0, len);
        }
      }
      return text[index];
    }

    return (starts: starts, scan: scan);
  }

  test('点英文单词中间的字母：从词首起查', () {
    final fake = fakeScanner(<String>{'world'});
    expect(
      lookupWordAtIndex('hello world', 8, wordFromIndex: fake.scan),
      'world',
    );
    expect(fake.starts, <int>[6]);
  });

  test('词典没有这个词：用整个单词，不退化成单个字母', () {
    final fake = fakeScanner(<String>{});
    expect(
      lookupWordAtIndex('hello world', 8, wordFromIndex: fake.scan),
      'world',
    );
  });

  test('匹配到短语时用短语', () {
    final fake = fakeScanner(<String>{'look forward to', 'look'});
    expect(
      lookupWordAtIndex('I look forward to it', 3, wordFromIndex: fake.scan),
      'look forward to',
    );
  });

  test('重音字母（含 NFD 组合符）算同一个词', () {
    final fake = fakeScanner(<String>{});
    expect(
      lookupWordAtIndex('un café noir', 6, wordFromIndex: fake.scan),
      'café',
    );
    const String nfd = 'un café noir';
    expect(lookupWordAtIndex(nfd, 4, wordFromIndex: fake.scan), 'café');
  });

  test('日文：起点就是被点的字，原样交给分词器', () {
    final fake = fakeScanner(<String>{'晴れ'});
    expect(lookupWordAtIndex('今日は晴れ', 3, wordFromIndex: fake.scan), '晴れ');
    expect(fake.starts, <int>[3]);
  });

  test('英日混排：日文后紧跟的英文词首不越过日文', () {
    final fake = fakeScanner(<String>{});
    expect(lookupWordAtIndex('これはapple', 5, wordFromIndex: fake.scan), 'apple');
  });

  test('越界返回空串', () {
    final fake = fakeScanner(<String>{});
    expect(lookupWordAtIndex('abc', -1, wordFromIndex: fake.scan), '');
    expect(lookupWordAtIndex('abc', 3, wordFromIndex: fake.scan), '');
  });
}
