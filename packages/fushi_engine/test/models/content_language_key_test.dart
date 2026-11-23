import 'package:fushi_engine/models/content_language.dart';
import 'package:test/test.dart';

void main() {
  test('contentLanguageKey：主语言子标签小写，写法不同的同一种语言归成一个键', () {
    expect(contentLanguageKey('zh-Hant-TW'), 'zh');
    expect(contentLanguageKey('zh_TW'), 'zh');
    expect(contentLanguageKey('ZH'), 'zh');
    expect(contentLanguageKey(' ja-JP '), 'ja');
    expect(contentLanguageKey('ja'), 'ja');
  });

  test('contentLanguageKey：空、und、不像语言标签的值为未知（空串）', () {
    expect(contentLanguageKey(null), '');
    expect(contentLanguageKey(''), '');
    expect(contentLanguageKey('   '), '');
    expect(contentLanguageKey('und'), '');
    expect(contentLanguageKey('x'), '');
    expect(contentLanguageKey('123'), '');
    expect(contentLanguageKey('abcdefghi'), '');
    expect(contentLanguageKey('日本語'), '');
  });
}
