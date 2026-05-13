import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';

EpubBook _bookWithHtml(String html) {
  return EpubBook(
    title: 'test',
    chapters: <EpubChapter>[
      EpubChapter(
          id: 'ch1',
          href: 'ch1.xhtml',
          mediaType: 'application/xhtml+xml',
          html: html),
    ],
  );
}

void main() {
  group('EpubBook.chapterPlainText', () {
    test('preserves ruby base text, strips rt annotation', () {
      final EpubBook book = _bookWithHtml(
        '<p><ruby>漢<rt>かん</rt></ruby><ruby>字<rt>じ</rt></ruby>を読む</p>',
      );
      expect(book.chapterPlainText(0), '漢字を読む');
    });

    test('strips rp parentheses wrappers', () {
      final EpubBook book = _bookWithHtml(
        '<ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>',
      );
      expect(book.chapterPlainText(0), '漢字');
    });

    test('strips rtc elements', () {
      final EpubBook book = _bookWithHtml(
        '<ruby>漢字<rtc><rt>かんじ</rt></rtc></ruby>',
      );
      expect(book.chapterPlainText(0), '漢字');
    });

    test('handles mixed ruby and plain text', () {
      final EpubBook book = _bookWithHtml(
        '<p>私は<ruby>猫<rt>ねこ</rt></ruby>である。</p>',
      );
      expect(book.chapterPlainText(0), '私は猫である。');
    });

    test('returns empty for out-of-range index', () {
      final EpubBook book = _bookWithHtml('<p>text</p>');
      expect(book.chapterPlainText(-1), '');
      expect(book.chapterPlainText(5), '');
    });

    test('strips all HTML tags after ruby removal', () {
      final EpubBook book = _bookWithHtml(
        '<div><p>hello <em>world</em></p></div>',
      );
      expect(book.chapterPlainText(0), 'hello world');
    });

    test('decodes named HTML entities', () {
      final EpubBook book = _bookWithHtml(
        '<p>A&amp;B&nbsp;C&lt;D&gt;E</p>',
      );
      expect(book.chapterPlainText(0), 'A&B C<D>E');
    });

    test('decodes numeric hex entities', () {
      final EpubBook book = _bookWithHtml(
        '<p>&#x6F22;&#x5B57;</p>',
      );
      expect(book.chapterPlainText(0), '漢字');
    });

    test('decodes numeric decimal entities', () {
      final EpubBook book = _bookWithHtml(
        '<p>&#28450;&#23383;</p>',
      );
      expect(book.chapterPlainText(0), '漢字');
    });

    test('preserves unknown entities as-is', () {
      final EpubBook book = _bookWithHtml(
        '<p>&unknownxyz;</p>',
      );
      expect(book.chapterPlainText(0), '&unknownxyz;');
    });
  });
}
