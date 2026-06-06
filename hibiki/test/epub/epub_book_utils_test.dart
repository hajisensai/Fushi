import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';

void main() {
  group('normalizeHref', () {
    test('trims whitespace', () {
      expect(normalizeHref('  path/to/file.xhtml  '), 'path/to/file.xhtml');
    });

    test('normalizes backslashes to forward slashes', () {
      expect(normalizeHref('OEBPS\\chapter1.xhtml'), 'OEBPS/chapter1.xhtml');
    });

    test('strips leading slash', () {
      expect(normalizeHref('/OEBPS/file.xhtml'), 'OEBPS/file.xhtml');
    });

    test('strips fragment identifier', () {
      expect(normalizeHref('ch1.xhtml#section2'), 'ch1.xhtml');
    });

    test('strips query string', () {
      expect(normalizeHref('ch1.xhtml?foo=bar'), 'ch1.xhtml');
    });

    test('handles combined: backslash + leading slash + fragment', () {
      expect(normalizeHref('/OEB\\ch.xhtml#frag'), 'OEB/ch.xhtml');
    });

    test('empty string returns empty', () {
      expect(normalizeHref(''), '');
    });
  });

  group('fallbackMimeType', () {
    test('returns text/css for .css', () {
      expect(fallbackMimeType('style.css'), 'text/css');
    });

    test('returns image/jpeg for .jpg', () {
      expect(fallbackMimeType('cover.jpg'), 'image/jpeg');
    });

    test('returns image/jpeg for .jpeg', () {
      expect(fallbackMimeType('photo.jpeg'), 'image/jpeg');
    });

    test('returns image/png for .png', () {
      expect(fallbackMimeType('icon.png'), 'image/png');
    });

    test('returns image/svg+xml for .svg', () {
      expect(fallbackMimeType('diagram.svg'), 'image/svg+xml');
    });

    test('returns font/woff2 for .woff2', () {
      expect(fallbackMimeType('font.woff2'), 'font/woff2');
    });

    test('returns text/html for .xhtml', () {
      expect(fallbackMimeType('chapter.xhtml'), 'text/html');
    });

    test('case insensitive extension matching', () {
      expect(fallbackMimeType('FILE.CSS'), 'text/css');
      expect(fallbackMimeType('cover.PNG'), 'image/png');
    });
  });

  group('EpubBook.chapterPlainText', () {
    test('extracts plain text from HTML', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '<html><body><p>Hello World</p></body></html>',
          ),
        ],
      );

      expect(book.chapterPlainText(0), 'Hello World');
    });

    test('strips ruby annotations (rt, rp, rtc)', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html:
                '<html><body><p><ruby>漢字<rt>かんじ</rt></ruby>を読む</p></body></html>',
          ),
        ],
      );

      final text = book.chapterPlainText(0);
      expect(text, contains('漢字'));
      expect(text, isNot(contains('かんじ')));
      expect(text, contains('を読む'));
    });

    test('collapses whitespace', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '<html><body><p>  Hello   World  </p></body></html>',
          ),
        ],
      );

      expect(book.chapterPlainText(0), 'Hello World');
    });

    test('returns empty for out-of-bounds index', () {
      final book = EpubBook(title: 'Test', chapters: []);

      expect(book.chapterPlainText(0), '');
      expect(book.chapterPlainText(-1), '');
    });
  });

  group('EpubBook.resolveInternalLink', () {
    test('resolves valid hoshi internal link to chapter index', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
          EpubChapter(
            id: 'ch2',
            href: 'OEBPS/ch2.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      final result =
          book.resolveInternalLink('https://hoshi.local/epub/OEBPS/ch2.xhtml');
      expect(result, isNotNull);
      expect(result!.chapterIndex, 1);
      expect(result.fragment, isNull);
    });

    test('resolves link with fragment', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      final result = book
          .resolveInternalLink('https://hoshi.local/epub/ch1.xhtml#section2');
      expect(result, isNotNull);
      expect(result!.chapterIndex, 0);
      expect(result.fragment, 'section2');
    });

    test('returns null for non-hoshi URL', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      expect(book.resolveInternalLink('https://example.com/page'), isNull);
    });

    test('returns null for malformed URL', () {
      final book = EpubBook(title: 'Test', chapters: []);
      expect(book.resolveInternalLink('://broken'), isNull);
    });

    test('returns null for href not matching any chapter', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      expect(
          book.resolveInternalLink(
              'https://hoshi.local/epub/nonexistent.xhtml'),
          isNull);
    });

    // BUG-097: the WebView resolves a relative `<a href>` against the document
    // URL, so the clicked link can carry `./` / `../` / duplicate slashes that
    // the canonicalized stored href does not. These must still resolve (else the
    // caller opens a blank OS browser for hoshi.local instead of jumping).
    group('BUG-097 path normalization (../ ./ // resolve, not external)', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'OEBPS/ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
          EpubChapter(
            id: 'ch2',
            href: 'OEBPS/text/ch2.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      test('parent-relative (../) link resolves to the chapter', () {
        final result = book.resolveInternalLink(
            'https://hoshi.local/epub/OEBPS/text/../ch1.xhtml');
        expect(result, isNotNull);
        expect(result!.chapterIndex, 0);
      });

      test('current-dir (./) link resolves to the chapter', () {
        final result = book.resolveInternalLink(
            'https://hoshi.local/epub/OEBPS/./text/ch2.xhtml#frag');
        expect(result, isNotNull);
        expect(result!.chapterIndex, 1);
        expect(result.fragment, 'frag');
      });

      test('duplicate slashes resolve to the chapter', () {
        final result = book
            .resolveInternalLink('https://hoshi.local/epub/OEBPS//ch1.xhtml');
        expect(result, isNotNull);
        expect(result!.chapterIndex, 0);
      });
    });
  });

  group('EpubResource.readBytes', () {
    test('returns in-memory bytes if available', () {
      final resource = EpubResource(
        mediaType: 'text/css',
        bytes: Uint8List.fromList([1, 2, 3]),
      );

      expect(resource.readBytes(), Uint8List.fromList([1, 2, 3]));
    });

    test('returns null if no bytes and no filePath', () {
      final resource = EpubResource(mediaType: 'text/css');

      expect(resource.readBytes(), isNull);
    });

    test('returns null if filePath does not exist', () {
      final resource = EpubResource(
        mediaType: 'text/css',
        filePath: '/nonexistent/path/file.css',
      );

      expect(resource.readBytes(), isNull);
    });
  });
}
