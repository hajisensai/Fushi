// TODO-1174: guards the broadened illustration-page classifier
// [EpubBook.isImageOnlyChapter] and the image-ref extraction that feeds the
// inline image-merge renderer. The old classifier required *exactly one* `<img>`
// and *zero* text, so real illustration pages — SVG `<image>` wrappers, pages
// with a caption / page number, and multi-image pages — were never recognised
// and each kept its own page instead of merging into the following prose.
//
// The two hard invariants under test:
//   1) an illustration page (image + only a short caption) IS recognised, so it
//      can merge;
//   2) a real prose chapter (any paragraph past the small text threshold) is
//      NEVER recognised, so the merge pass can never silently drop its body.
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';

EpubBook _book(String html) {
  return EpubBook(
    title: 'test',
    chapters: <EpubChapter>[
      EpubChapter(
        id: 'ch1',
        href: 'text/ch1.xhtml',
        mediaType: 'application/xhtml+xml',
        html: html,
      ),
    ],
  );
}

void main() {
  group('isImageOnlyChapter — recognises illustration pages', () {
    test('classic single <img>, no text (regression)', () {
      expect(
          _book('<html><body><img src="p1.jpg"/></body></html>')
              .isImageOnlyChapter(0),
          isTrue);
    });

    test('SVG <image xlink:href> with no <img> (Japanese fixed layout)', () {
      const html = '<html><body><svg viewBox="0 0 800 1200" '
          'xmlns:xlink="http://www.w3.org/1999/xlink">'
          '<image width="800" height="1200" xlink:href="../image/i-001.jpg"/>'
          '</svg></body></html>';
      expect(_book(html).isImageOnlyChapter(0), isTrue);
    });

    test('SVG <image href> without xlink namespace', () {
      const html = '<html><body><svg viewBox="0 0 800 1200">'
          '<image href="../image/i-002.jpg"/></svg></body></html>';
      expect(_book(html).isImageOnlyChapter(0), isTrue);
    });

    test('CSS background-image via inline style', () {
      const html = '<html><body>'
          '<div style="background-image: url(../img/bg.jpg)"></div>'
          '</body></html>';
      expect(_book(html).isImageOnlyChapter(0), isTrue);
    });

    test('CSS background-image via <style> block', () {
      const html = '<html><head><style>'
          '.page{background-image:url("../img/bg2.png")}'
          '</style></head><body><div class="page"></div></body></html>';
      expect(_book(html).isImageOnlyChapter(0), isTrue);
    });

    test('image + short 「挿絵」 caption still counts', () {
      const html = '<html><body><img src="p1.jpg"/>'
          '<figcaption>挿絵</figcaption></body></html>';
      expect(_book(html).isImageOnlyChapter(0), isTrue);
    });

    test('image + page number still counts', () {
      const html = '<html><body><p>12</p><img src="p1.jpg"/></body></html>';
      expect(_book(html).isImageOnlyChapter(0), isTrue);
    });

    test('multiple <img>, short/no text (was rejected by "exactly one")', () {
      const html = '<html><body>'
          '<img src="a.jpg"/><img src="b.jpg"/><img src="c.jpg"/>'
          '</body></html>';
      expect(_book(html).isImageOnlyChapter(0), isTrue);
    });

    test('text of exactly the threshold length + image counts', () {
      // 20-char body text, at the inclusive boundary.
      const html = '<html><body><img src="p.jpg"/>'
          '<p>abcdefghijklmnopqrst</p></body></html>';
      expect(_book(html).isImageOnlyChapter(0), isTrue);
    });
  });

  group('isImageOnlyChapter — guardrail: never absorbs prose', () {
    test('image + a real prose paragraph is NOT image-only', () {
      const html = '<html><body><img src="p.jpg"/>'
          '<p>これは本文の段落であり、ただの挿絵の説明ではありません。</p>'
          '</body></html>';
      expect(_book(html).isImageOnlyChapter(0), isFalse);
    });

    test('multiple long <p> paragraphs (with an image) are NOT image-only', () {
      const html = '<html><body><img src="p.jpg"/>'
          '<p>First real paragraph of the chapter body.</p>'
          '<p>Second real paragraph continues the prose.</p>'
          '</body></html>';
      expect(_book(html).isImageOnlyChapter(0), isFalse);
    });

    test('one char past the threshold + image is NOT image-only', () {
      // 21-char body text, just over the boundary.
      const html = '<html><body><img src="p.jpg"/>'
          '<p>abcdefghijklmnopqrstu</p></body></html>';
      expect(_book(html).isImageOnlyChapter(0), isFalse);
    });

    test('pure text chapter (no image) is NOT image-only', () {
      expect(
          _book('<html><body><p>本文の段落。</p></body></html>')
              .isImageOnlyChapter(0),
          isFalse);
    });

    test('empty chapter (no image, no text) is NOT image-only', () {
      expect(
          _book('<html><body></body></html>').isImageOnlyChapter(0), isFalse);
    });

    test('out-of-range index is NOT image-only', () {
      final EpubBook book =
          _book('<html><body><img src="p.jpg"/></body></html>');
      expect(book.isImageOnlyChapter(-1), isFalse);
      expect(book.isImageOnlyChapter(9), isFalse);
    });
  });

  group('chapterImageSrc / chapterImageSrcs — feed the merge renderer', () {
    test('first <img> src', () {
      final EpubBook book =
          _book('<html><body><img src="p1.jpg"/></body></html>');
      expect(book.chapterImageSrc(0), 'p1.jpg');
      expect(book.chapterImageSrcs(0), <String>['p1.jpg']);
    });

    test('SVG <image> href is extracted for the renderer', () {
      final EpubBook book = _book('<html><body><svg '
          'xmlns:xlink="http://www.w3.org/1999/xlink">'
          '<image xlink:href="../image/i-001.jpg"/></svg></body></html>');
      expect(book.chapterImageSrc(0), '../image/i-001.jpg');
    });

    test('background-image url is extracted for the renderer', () {
      final EpubBook book = _book('<html><body>'
          '<div style="background-image: url(../img/bg.jpg)"></div>'
          '</body></html>');
      expect(book.chapterImageSrc(0), '../img/bg.jpg');
    });

    test('all references returned so multi-image pages lose nothing', () {
      final EpubBook book = _book('<html><body>'
          '<img src="a.jpg"/><img src="b.jpg"/>'
          '</body></html>');
      expect(book.chapterImageSrcs(0), <String>['a.jpg', 'b.jpg']);
    });

    test('no image → null / empty', () {
      final EpubBook book = _book('<html><body><p>text</p></body></html>');
      expect(book.chapterImageSrc(0), isNull);
      expect(book.chapterImageSrcs(0), isEmpty);
    });

    test('out-of-range → null / empty', () {
      final EpubBook book =
          _book('<html><body><img src="p.jpg"/></body></html>');
      expect(book.chapterImageSrc(5), isNull);
      expect(book.chapterImageSrcs(5), isEmpty);
    });
  });
}
