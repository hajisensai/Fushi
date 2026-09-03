import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_book.dart';

/// TODO-1192：锁定 EPUB **每章字数**的抽取与计数接线。
///
/// 计数口径本身由 `fushi/test/stats/study_char_count_test.dart` 锁定
/// （[countStudyChars]，全仓唯一）；本文件只管 [EpubBook] 这一层：正文抽取是否剥掉
/// 振假名、越界索引是否安全、以及「改口径必须 bump 版本号」这条不变式。
///
/// 沿革：字数曾用 `chapterPlainText().length`（含标点/括号/空白，比 hoshi 高约
/// 10~20%，v1）→ `japaneseCharCount` 的 ttu 白名单（v2/v3）→ [countStudyChars]
/// （v4）。v3 的白名单只收 ASCII 字母数字 + 假名 + 汉字 + 全角字母数字 + 半角片假名，
/// 对非日语内容是错的（英语按字母计、变音字母漏计、俄/韩/希腊/阿拉伯/泰整脚本记 0），
/// 所以 v4 换成了按文字自身分词方式计的「学习单位」。
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
  group('EpubBook.chapterCharacterCount', () {
    test('振假名（rt）不计入，标点不计入', () {
      final EpubBook book = _bookWithHtml(
        '<p><ruby>漢<rt>かん</rt></ruby><ruby>字<rt>じ</rt></ruby>を読む。</p>',
      );
      // plainText = 漢字を読む。（振假名已剥离）→ 学习单位 漢字を読む = 5，。剔除。
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

    test('英文章节按词计，不再逐字母（v3→v4 的核心变化）', () {
      final EpubBook book = _bookWithHtml('<p>I do not know.</p>');
      expect(book.chapterPlainText(0), 'I do not know.');
      expect(book.chapterCharacterCount(0), 4,
          reason: 'v3 会算成 11（逐字母），英文书的字数因此虚高约 5 倍');
    });

    test('俄文章节不再记 0（v3 整脚本漏计 → 进度分母为 0）', () {
      final EpubBook book = _bookWithHtml('<p>Привет мир</p>');
      expect(book.chapterCharacterCount(0), 2,
          reason: 'v3 记 0，computeBookProgress 分母为 0 后进度退化成章号/章数');
    });

    test('越界索引 → 0', () {
      final EpubBook book = _bookWithHtml('<p>本文</p>');
      expect(book.chapterCharacterCount(-1), 0);
      expect(book.chapterCharacterCount(5), 0);
    });
  });

  group('kChapterCharCountCaliber', () {
    test('口径已到 v4（改计数口径必须 +1 版本号才能触发重算）', () {
      // 若有人改了口径却忘了 bump 版本号，已按旧口径算好的每章缓存不会再重算、
      // 继续偏离——本断言把「改口径必 bump 版本」钉死。
      expect(kChapterCharCountCaliber, greaterThanOrEqualTo(4));
    });
  });
}
