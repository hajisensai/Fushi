import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';

/// TODO-1192：锁定「实义字符计数」口径（对齐 hoshi/ttu getCharacterCount）。
///
/// 统计字数 / 书的总字数曾用 `chapterPlainText().length`，把标点、括号（「」『』
/// （）等）、全/半角空白、全角标点都算进去，比 hoshi 高约 10~20%。改用
/// [japaneseCharCount] 后只数假名 / 汉字 / 叠字符 / 字母数字。撤销修复即转红。
EpubBook _bookWithHtml(String html) {
  return EpubBook(
    title: 'test',
    chapters: <EpubChapter>[
      EpubChapter(
        id: 'ch1',
        href: 'ch1.xhtml',
        mediaType: 'application/xhtml+xml',
        html: html,
      ),
    ],
  );
}

void main() {
  group('japaneseCharCount', () {
    test('剔除标点/括号/空白，只数假名与汉字', () {
      const String s = '「こんにちは、世界。」';
      // 実義字符：こんにちは(5) + 世界(2) = 7；「」、。 全部剔除。
      expect(japaneseCharCount(s), 7);
      // 严格小于原始长度（含标点/括号）——即比旧口径低。
      expect(japaneseCharCount(s), lessThan(s.length));
    });

    test('全角标点 / 括号 / 全角空白一律不计', () {
      expect(japaneseCharCount('（）【】「」『』、。！？　'), 0);
    });

    test('半角字母数字计入（含小写）', () {
      // A B C 1 2 3 d e f = 9；空格与 ! 剔除。
      expect(japaneseCharCount('ABC123 def!'), 9);
    });

    test('叠字/重复符号计入（々〆〇〻 ゝゞ ヽヾ ー）', () {
      expect(japaneseCharCount('人々'), 2); // 人 + 々
      expect(japaneseCharCount('コーヒー'), 4); // コ ー ヒ ー（长音符也计）
    });

    test('半角片假名计入', () {
      expect(japaneseCharCount('ｶﾀｶﾅ'), 4);
    });

    test('BMP 外扩展B汉字（代理对）按码点计一字，不重复计', () {
      const String s = '𠮷野家'; // 𠮷 = U+20BB7（代理对，占 2 个 UTF-16 码元）
      expect(s.length, 4, reason: 'UTF-16 长度：代理对 2 + 野 + 家 = 4');
      expect(japaneseCharCount(s), 3, reason: '按码点计：𠮷 野 家 = 3');
    });

    test('空串 / 纯符号 → 0', () {
      expect(japaneseCharCount(''), 0);
      expect(japaneseCharCount('！？…—'), 0);
    });
  });

  group('EpubBook.chapterCharacterCount', () {
    test('振假名（rt）不计入，标点不计入', () {
      final EpubBook book = _bookWithHtml(
        '<p><ruby>漢<rt>かん</rt></ruby><ruby>字<rt>じ</rt></ruby>を読む。</p>',
      );
      // plainText = 漢字を読む。（振假名已剥离）→ 実義字符 漢字を読む = 5，。剔除。
      expect(book.chapterPlainText(0), '漢字を読む。');
      expect(book.chapterCharacterCount(0), 5);
    });

    test('含大量标点的段落：实义计数严格低于原始长度（比旧口径低）', () {
      final EpubBook book = _bookWithHtml(
        '<p>「ねえ、」と彼女は言った。──そして、笑った！</p>',
      );
      final String plain = book.chapterPlainText(0);
      expect(book.chapterCharacterCount(0), lessThan(plain.length));
      expect(book.chapterCharacterCount(0), greaterThan(0));
    });

    test('越界索引 → 0', () {
      final EpubBook book = _bookWithHtml('<p>本文</p>');
      expect(book.chapterCharacterCount(-1), 0);
      expect(book.chapterCharacterCount(5), 0);
    });
  });
}
