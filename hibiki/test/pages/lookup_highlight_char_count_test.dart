import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/pages/base_source_page.dart';

/// BUG-206 (TODO-139) — 手机查词被查词高亮多选/少选字（错位）。
///
/// 根因：`base_source_page.dart` 里把正文里要高亮的字数取成词典词条 headword
/// （`DictionaryEntry.word`，即去屈折后的词典形/汉字写法）的长度，而不是真正出现在
/// 正文里的**活用形（matched source）**长度。查「うやうやしく」(正文 6 字假名) 时
/// headword 是汉字「恭しい」(3 字)，高亮只覆盖前 3 字 → 「うやう」；若该词跨多个
/// DOM 文本节点（Android 分页 WebView 常见），偏短的覆盖会渲染成两段错位的高亮带，
/// 用户看到的就是「多选/少选字」。
///
/// 修复：`lookupHighlightCharCount` 改用
/// [DictionarySearchResult.bestLength]（FFI 去屈折的 matched 长度，等同 Yomitan
/// `originalTextLength`），经 [Language.getFinalHighlightLength] 读取。
///
/// 撤掉修复（把字数改回 headword 长度）→ 本测试红。
void main() {
  final Language ja = JapaneseLanguage.instance;

  group('lookupHighlightCharCount (BUG-206)', () {
    test(
        'kana body, kanji headword: highlight count = matched inflected length, '
        'NOT headword length', () {
      // 正文里读到的是假名活用形「うやうやしく」(6 字)，去屈折成词典形，词条 headword
      // 是汉字「恭しい」(3 字)。bestLength=6 是 FFI 记录的 matched 源串长度。
      final result = DictionarySearchResult(
        searchTerm: 'うやうやしく見上げた',
        bestLength: 6,
        entries: [
          DictionaryEntry(
              word: '恭しい', reading: 'うやうやしい', meaning: 'respectful'),
        ],
      );

      final int count = lookupHighlightCharCount(
        result: result,
        searchTerm: 'うやうやしく見上げた',
        language: ja,
      );

      // 必须是 6（活用形长度），不能是 3（headword「恭しい」.runes.length）。
      expect(count, 6,
          reason: '高亮须覆盖正文真实出现的活用形「うやうやしく」(6 字)，而非汉字 headword 长度 3');
      expect(count, isNot(3),
          reason: '旧实现取 entries.first.word.runes.length=3，会少选字 → 必须避免');
    });

    test('inflected verb: matched length drives highlight, not dictionary form',
        () {
      // 「食べられた」(5 字) 去屈折 → 词典形「食べる」(3 字)。高亮须覆盖 5 字活用形。
      final result = DictionarySearchResult(
        searchTerm: '食べられた',
        bestLength: 5,
        entries: [
          DictionaryEntry(word: '食べる', reading: 'たべる', meaning: 'to eat'),
        ],
      );

      final int count = lookupHighlightCharCount(
        result: result,
        searchTerm: '食べられた',
        language: ja,
      );

      expect(count, 5, reason: '活用形「食べられた」=5 字，词典形「食べる」=3 字；高亮以活用形长度为准');
    });

    test('no entries → 0 (no highlight), preserving prior behavior', () {
      final result = DictionarySearchResult(
        searchTerm: 'うやうやしく',
        bestLength: 6, // bestLength 可能非 0，但没有词条就不该高亮
      );

      expect(
        lookupHighlightCharCount(
          result: result,
          searchTerm: 'うやうやしく',
          language: ja,
        ),
        0,
        reason: '无词条时返回 0，调用方据此跳过高亮（与修复前一致）',
      );
    });

    test('exact-match (no inflection): count equals the matched word length',
        () {
      // 「猫」非活用，matched=headword，bestLength=1。回归保护：不破坏直配词的高亮。
      final result = DictionarySearchResult(
        searchTerm: '猫',
        bestLength: 1,
        entries: [DictionaryEntry(word: '猫', reading: 'ねこ', meaning: 'cat')],
      );

      expect(
        lookupHighlightCharCount(
          result: result,
          searchTerm: '猫',
          language: ja,
        ),
        1,
      );
    });
  });
}
