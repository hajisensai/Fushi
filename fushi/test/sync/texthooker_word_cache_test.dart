import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/texthooker_word_cache.dart';

void main() {
  test('same id with grown text (progressive fold) re-tokenizes', () {
    int calls = 0;
    final TexthookerWordCache cache = TexthookerWordCache(
      tokenize: (String text) {
        calls++;
        return text.split('');
      },
    );
    expect(cache.wordsFor('l1', 'エル・プ'), <String>['エ', 'ル', '・', 'プ']);
    expect(calls, 1);
    // 折叠把同 id 的文本换成整句：必须重新分词，不能沿用前缀的结果。
    final List<String> grown = cache.wordsFor('l1', 'エル・プサイ');
    expect(grown, <String>['エ', 'ル', '・', 'プ', 'サ', 'イ']);
    expect(calls, 2);
    // 同 id 同文本仍只分一次。
    expect(cache.wordsFor('l1', 'エル・プサイ'), same(grown));
    expect(calls, 2);
  });

  test('evicts the oldest entry beyond maxEntries', () {
    final TexthookerWordCache cache = TexthookerWordCache(
      tokenize: (String text) => <String>[text],
      maxEntries: 2,
    );
    cache.wordsFor('a', 'A');
    cache.wordsFor('b', 'B');
    cache.wordsFor('c', 'C');
    expect(cache.length, 2);
  });
}
